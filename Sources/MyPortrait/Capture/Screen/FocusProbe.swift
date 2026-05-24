import AppKit
import ApplicationServices
import Foundation
import os.log

/// 焦点信息探针：当前 app 名、窗口标题、浏览器 URL。
///
/// 设计要点（性能优先）：
///   - 监听 `NSWorkspace.didActivateApplicationNotification`（焦点切换）
///   - 状态变化时主动调 AX 抓窗口标题 / 浏览器 URL，缓存进 actor
///   - 热路径上 `snapshot()` 只读缓存，O(1)
///
/// AX 权限：第一次调用 `AXUIElement` API 会触发系统弹"辅助功能"权限请求。
/// 用户拒绝时：probe 仍可用，但 windowTitle / browserUrl 永远 nil（只 log 一次）。
actor FocusProbe {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "focus")

    /// 9 个浏览器 bundle ID。命中其中之一才尝试抓 URL。
    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "org.chromium.Chromium",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.mozilla.firefox",
    ]

    /// 终端类 app。这些 app 里 AX tree 经常拿到的是空 / placeholder /
    /// 旧 buffer，远不如 OCR 准。OCRService 看到这些 bundle ID 会强制走 Vision。
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
    ]

    /// AX 文本抓取的最大递归深度。3 层覆盖大多数 app 的「窗口 → 主区 →
    /// 子组件」三段,Electron / SwiftUI 嵌套深的不强求(它们 OCR 也够)。
    /// 从 5 降到 3 主要是为了减少 walkAXText 时主线程持有时间。
    private let axMaxDepth = 3

    /// AX 文本总长度上限（字符）。防止巨型页面（如 Twitter timeline）撑爆 RSS。
    private let axMaxChars = 100_000

    /// AX 树元素数上限。深度门槛只能挡递归层数,挡不住一个窗口里 10000
    /// 个 sibling 的情况(Chrome 大页面、Slack 长 timeline)。500 是经验值,
    /// 主线程上 500 次跨进程 XPC 大约 30–80ms,可以接受。
    private let axMaxElements = 500

    /// 单次 walkAXText 总墙钟预算(纳秒)。超时立即返回当前已抓到的内容。
    /// 150ms 是「用户感觉到的卡顿门槛」边界 —— 比这再长一帧就掉。
    private let axWalkBudgetNs: UInt64 = 150_000_000

    /// 节流:相邻两次 refresh 最小间隔。NSWorkspace 通知风暴时(Mission
    /// Control / 快速 Cmd-Tab)会一秒打过来七八条,如果每条都跑一整次 AX
    /// 遍历,主线程当场跪。
    private let refreshMinIntervalMs: Int64 = 300
    private var lastRefreshAtMs: Int64 = 0

    private var cached: FocusInfo = FocusInfo(
        appName: "Unknown",
        bundleId: nil,
        windowTitle: nil,
        browserUrl: nil,
        axText: nil,
        isFocused: true
    )

    /// 仅在 `start()` 后非 nil。停止时反注册。
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var axPermissionWarned = false

    init(reporter: UnimplementedReporter) {
        self.reporter = reporter
    }

    /// 启动监听。注册 NSWorkspace 通知，立即做一次初次刷新。
    func start() async {
        guard activationObserver == nil else { return }

        let center = NSWorkspace.shared.notificationCenter

        // 焦点 app 切换 → 立即刷新。
        // 通知会派发到 main thread，我们在闭包里再切回 actor。
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }

        // 当前 app 被切走 → 重新刷一次（NSWorkspace.frontmostApplication 已更新）。
        deactivationObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }

        await refresh()
    }

    func stop() async {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = activationObserver { center.removeObserver(obs) }
        if let obs = deactivationObserver { center.removeObserver(obs) }
        activationObserver = nil
        deactivationObserver = nil
    }

    /// 当前焦点快照。O(1)。
    func snapshot() -> FocusInfo {
        cached
    }

    // MARK: - 私有

    private func refresh() async {
        // 节流:NSWorkspace 通知风暴(Mission Control / 快速 Cmd-Tab)会瞬间
        // 派发七八条 didActivateApplication,跳过 refreshMinIntervalMs 内的
        // 重复触发,避免主线程被 AX walk 串行队列堵死。
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - lastRefreshAtMs < refreshMinIntervalMs { return }
        lastRefreshAtMs = nowMs

        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let name = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let pid = app.processIdentifier

        var windowTitle: String?
        var browserUrl: String?
        var axText: String?

        // AX 查询。若无权限就只返回 app 名。
        if AXIsProcessTrusted() {
            // AX 树深度递归遍历**必须在主线程跑** —— 在后台队列上调
            // AXUIElementCopyAttributeValue 会 _dispatch_assert_queue_fail 崩。
            // refresh 由 app 切换触发(不频繁)，遍历有 depth/char/超时三重
            // 上限，主线程上的停顿可忽略。
            let result: (title: String?, url: String?, axText: String?) =
                await MainActor.run { self.queryAX(pid: pid, bundleId: bundleId) }
            windowTitle = result.title
            browserUrl = result.url
            axText = result.axText
        } else if !axPermissionWarned {
            logger.warning("Accessibility permission not granted — window title / browser URL / AX text will be nil. Grant in System Settings → Privacy & Security → Accessibility.")
            axPermissionWarned = true
        }

        cached = FocusInfo(
            appName: name,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserUrl: browserUrl,
            axText: axText,
            isFocused: true
        )
    }

    /// 调 AX 抓窗口标题 + URL（仅浏览器）+ AX tree 文本子树。
    /// AX API 是跨进程同步 XPC，可能 10–50ms（AX text 走到 100ms+ 时降级让出）。
    /// 仅在 refresh() 内调用，不在采集热路径上。
    nonisolated private func queryAX(pid: pid_t, bundleId: String?) -> (title: String?, url: String?, axText: String?) {
        let axApp = AXUIElementCreateApplication(pid)
        // 卡死时单次调用最多等 1.5s —— 共用串行队列,一个慢调用别拖垮全局。
        AXUIElementSetMessagingTimeout(axApp, 1.5)

        // 1. 焦点窗口
        var focusedWindowRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        guard focusedStatus == .success,
              let focusedWindowRef,
              CFGetTypeID(focusedWindowRef) == AXUIElementGetTypeID()
        else {
            return (nil, nil, nil)
        }
        // swiftlint:disable:next force_cast
        let focusedWindow = focusedWindowRef as! AXUIElement

        // 2. 窗口标题
        var title: String?
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleRef) == .success {
            title = titleRef as? String
        }

        // 3. URL（仅浏览器）。AXDocument 在 Chrome/Safari/Edge/Brave/Vivaldi/
        //    Opera/Chromium 上是 URL 字符串；Firefox 不支持，Arc 需 AppleScript（P2）。
        var url: String?
        if let bid = bundleId, Self.browserBundleIds.contains(bid) {
            var docRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedWindow, "AXDocument" as CFString, &docRef) == .success {
                url = docRef as? String
            }
        }

        // 4. AX tree 文本子树。终端类 app 跳过（拿到的是脏数据，OCR 更准）。
        var axText: String?
        if let bid = bundleId, !Self.terminalBundleIds.contains(bid) {
            var pieces: [String] = []
            var charCount = 0
            var elemCount = 0
            // 墙钟 deadline:从「现在」开始的 axWalkBudgetNs。任何递归层
            // 看到当前时间超出就 return。最差情况:抓到的 axText 不全,
            // 但主线程一定能在 150ms 内放手。
            let deadline = DispatchTime.now().uptimeNanoseconds + axWalkBudgetNs
            walkAXText(
                element: focusedWindow,
                depth: 0,
                maxDepth: axMaxDepth,
                maxChars: axMaxChars,
                maxElements: axMaxElements,
                deadlineNs: deadline,
                pieces: &pieces,
                charCount: &charCount,
                elemCount: &elemCount
            )
            let joined = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                axText = joined
            }
        }

        return (title, url, axText)
    }

    /// 递归遍历 AX element，累计 AXValue / AXTitle / AXDescription 文本。
    /// 写成迭代风格其实更快，但递归读起来直观；depth ≤ 3 时栈深度可控。
    /// 三重早退保护:depth / charCount / elemCount,加上墙钟 deadline。
    nonisolated private func walkAXText(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxChars: Int,
        maxElements: Int,
        deadlineNs: UInt64,
        pieces: inout [String],
        charCount: inout Int,
        elemCount: inout Int
    ) {
        if depth > maxDepth || charCount > maxChars || elemCount > maxElements { return }
        if DispatchTime.now().uptimeNanoseconds > deadlineNs { return }
        elemCount += 1

        // 顺序尝试：AXValue → AXTitle → AXDescription。一个元素只取一份，
        // 不双计 title+value（title 通常是 value 的标签）。
        for attr in ["AXValue", kAXTitleAttribute as String, "AXDescription"] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let str = ref as? String, !str.isEmpty {
                pieces.append(str)
                charCount += str.count
                break
            }
        }

        if charCount > maxChars { return }

        // 递归 children。
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if charCount > maxChars || elemCount > maxElements { return }
                if DispatchTime.now().uptimeNanoseconds > deadlineNs { return }
                walkAXText(
                    element: child, depth: depth + 1, maxDepth: maxDepth,
                    maxChars: maxChars, maxElements: maxElements,
                    deadlineNs: deadlineNs,
                    pieces: &pieces, charCount: &charCount, elemCount: &elemCount
                )
            }
        }
    }
}

/// 焦点信息载体。每帧元数据都会带一份。
public struct FocusInfo: Equatable, Sendable {
    public let appName: String
    public let bundleId: String?
    public let windowTitle: String?
    public let browserUrl: String?
    /// 当前焦点窗口 AX tree 文本子树（去重 + 拼接）。
    /// nil = 无 AX 权限 / 是终端 app / 抓不到内容。OCRService 用它走快路。
    public let axText: String?
    public let isFocused: Bool

    public init(
        appName: String, bundleId: String?, windowTitle: String?,
        browserUrl: String?, axText: String?, isFocused: Bool
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserUrl = browserUrl
        self.axText = axText
        self.isFocused = isFocused
    }
}
