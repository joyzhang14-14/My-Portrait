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

    /// AX 文本抓取的最大递归深度。5 层足够触达大多数 app 的内容区，
    /// 而不会爆。10K 项以上的 Chrome 页面树会走早退保护。
    private let axMaxDepth = 5

    /// AX 文本总长度上限（字符）。防止巨型页面（如 Twitter timeline）撑爆 RSS。
    private let axMaxChars = 100_000

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

        refresh()
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

    private func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let name = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let pid = app.processIdentifier

        var windowTitle: String?
        var browserUrl: String?
        var axText: String?

        // AX 查询。若无权限就只返回 app 名。
        if AXIsProcessTrusted() {
            let result = queryAX(pid: pid, bundleId: bundleId)
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
    private func queryAX(pid: pid_t, bundleId: String?) -> (title: String?, url: String?, axText: String?) {
        let axApp = AXUIElementCreateApplication(pid)

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
            walkAXText(
                element: focusedWindow,
                depth: 0,
                maxDepth: axMaxDepth,
                maxChars: axMaxChars,
                pieces: &pieces,
                charCount: &charCount
            )
            let joined = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                axText = joined
            }
        }

        return (title, url, axText)
    }

    /// 递归遍历 AX element，累计 AXValue / AXTitle / AXDescription 文本。
    /// 写成迭代风格其实更快，但递归读起来直观；depth ≤ 5 时栈深度可控。
    private func walkAXText(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxChars: Int,
        pieces: inout [String],
        charCount: inout Int
    ) {
        if depth > maxDepth || charCount > maxChars { return }

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
                if charCount > maxChars { return }
                walkAXText(
                    element: child, depth: depth + 1, maxDepth: maxDepth,
                    maxChars: maxChars, pieces: &pieces, charCount: &charCount
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
