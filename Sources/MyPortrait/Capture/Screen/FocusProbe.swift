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
    /// 也用于 OCRService:浏览器系 AX 文本是 chrome(tab bar / 工具栏),
    /// 不能当 canvas 内容用,必须跑 Vision OCR。
    static let browserBundleIds: Set<String> = [
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
    /// 节流命中后是否已调度尾沿补刷。防止通知风暴期间重复调度。
    private var trailingRefreshScheduled = false

    private var cached: FocusInfo = FocusInfo(
        appName: "Unknown",
        bundleId: nil,
        windowTitle: nil,
        browserUrl: nil,
        axText: nil,
        isFocused: true
    )

    /// 通知 token 盒。`@unchecked Sendable` 是因为 tokens **只在主线程读写**
    /// (start/stop 都经 MainActor.run),类型本身只是跨 actor 传递的句柄盒
    /// (NSObjectProtocol 非 Sendable,不能直接当 MainActor.run 返回值带回)。
    private final class WorkspaceObserverBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }

    private let observerTokens = WorkspaceObserverBox()
    private var started = false
    private var axPermissionWarned = false

    init(reporter: UnimplementedReporter) {
        self.reporter = reporter
    }

    /// 启动监听。注册 NSWorkspace 通知，立即做一次初次刷新。
    ///
    /// ⚠️ 注册必须钉在主线程:全工程其它 NSWorkspace 通知注册方
    /// (WorkspaceWatcher / SleepWakeWatcher / TypingObserver)都是
    /// @MainActor,唯独本 actor 曾在协作线程上注册 —— macOS 26(Tahoe)
    /// 上偶发撞 AppKit 内部断言(EXC_BREAKPOINT / __CF_IS_OBJC,崩在
    /// addObserver 内部,真机抓到过)。统一钉 main,与 SCK 钉主线程的
    /// Tahoe 惯例一致(见 ScreenCaptureService 头注)。
    func start() async {
        guard !started else { return }
        started = true

        let box = observerTokens
        await MainActor.run {
            let center = NSWorkspace.shared.notificationCenter

            // 焦点 app 切换 → 立即刷新。
            // 通知会派发到 main thread，我们在闭包里再切回 actor。
            box.tokens.append(center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh() }
            })

            // 当前 app 被切走 → 重新刷一次（NSWorkspace.frontmostApplication 已更新）。
            box.tokens.append(center.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh() }
            })
        }

        await refresh()
    }

    func stop() async {
        started = false
        let box = observerTokens
        await MainActor.run {
            let center = NSWorkspace.shared.notificationCenter
            for t in box.tokens { center.removeObserver(t) }
            box.tokens.removeAll()
        }
    }

    /// 当前焦点快照。O(1)。
    func snapshot() -> FocusInfo {
        cached
    }

    /// 即时读系统**最前台 app**(名 + bundleId)。`NSWorkspace.frontmostApplication`
    /// 由系统实时维护,**无 refresh 节流 / AX 遍历延迟**。采集帧用它校正 active app:
    /// 缓存 `FocusInfo` 靠 didActivateApplication 通知刷新,会滞后于实时截图,切换
    /// 瞬间会出现"画面是 B、缓存还是 A"。
    func liveFrontmostApp() async -> (name: String, bundleId: String?)? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.localizedName ?? "Unknown", app.bundleIdentifier)
        }
    }

    // MARK: - 私有

    private func refresh() async {
        // 节流:NSWorkspace 通知风暴(Mission Control / 快速 Cmd-Tab)会瞬间
        // 派发七八条 didActivateApplication,跳过 refreshMinIntervalMs 内的
        // 重复触发,避免主线程被 AX walk 串行队列堵死。
        // 单调时钟:用 wall-clock 的话 NTP/手动回拨会让 delta 变负 → 永远早退、
        // focus 卡在旧 app(本文件别处 238/342/379 也用 uptime)。
        let nowMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        let elapsedMs = nowMs - lastRefreshAtMs
        if elapsedMs < refreshMinIntervalMs {
            // 尾沿补刷:节流是前沿丢弃,若直接 return,风暴里最后一条通知
            // (快速 Cmd-Tab A→B→C 的 C)会被永久吞掉 —— cached 停在旧 app,
            // DRMGate / 暂停名单读到过期焦点,直到下次 app 切换才恢复。
            // 这里调度一次延迟刷新兜底,保证风暴结束后 cached 收敛到真实前台。
            if !trailingRefreshScheduled {
                trailingRefreshScheduled = true
                let delayMs = refreshMinIntervalMs - elapsedMs + 10   // +10ms 余量,防边界再次命中节流
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    await self?.consumeTrailingRefresh()
                }
            }
            return
        }
        lastRefreshAtMs = nowMs

        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let name = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let pid = app.processIdentifier

        var windowTitle: String?
        var browserUrl: String?
        var axText: String?
        var axIdentifier: String?

        // AX 查询。若无权限就只返回 app 名。
        if AXIsProcessTrusted() {
            // AX 树深度递归遍历**必须在主线程跑** —— 在后台队列上调
            // AXUIElementCopyAttributeValue 会 _dispatch_assert_queue_fail 崩。
            // refresh 由 app 切换触发(不频繁)，遍历有 depth/char/超时三重
            // 上限，主线程上的停顿可忽略。
            let result: (title: String?, url: String?, axText: String?, axId: String?) =
                await MainActor.run { self.queryAX(pid: pid, bundleId: bundleId) }
            windowTitle = result.title
            browserUrl = result.url
            axText = result.axText
            axIdentifier = result.axId
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
            axIdentifier: axIdentifier,
            isFocused: true
        )
    }

    /// 尾沿补刷入口:清掉调度标记再走正常 refresh()。若期间又有前沿刷新把
    /// lastRefreshAtMs 推后、导致这次再被节流,refresh 会重新调度尾沿,最终必刷。
    private func consumeTrailingRefresh() async {
        trailingRefreshScheduled = false
        await refresh()
    }

    /// 调 AX 抓窗口标题 + URL（仅浏览器）+ AX tree 文本子树。
    /// AX API 是跨进程同步 XPC，可能 10–50ms（AX text 走到 100ms+ 时降级让出）。
    /// 仅在 refresh() 内调用，不在采集热路径上。
    nonisolated private func queryAX(pid: pid_t, bundleId: String?) -> (title: String?, url: String?, axText: String?, axId: String?) {
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
            return (nil, nil, nil, nil)
        }
        // swiftlint:disable:next force_cast
        let focusedWindow = focusedWindowRef as! AXUIElement

        // 2. 窗口标题
        var title: String?
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleRef) == .success {
            title = titleRef as? String
        }

        // 2b. AXIdentifier —— IncognitoGate Tier 1 用(Arc 等无痕窗口含
        //     "incognito"/"private")。多数 app/窗口为 nil,读不到不影响。
        var axId: String?
        var axIdRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedWindow, kAXIdentifierAttribute as CFString, &axIdRef) == .success {
            axId = axIdRef as? String
        }

        // 3. URL（仅浏览器）。
        //    - Chrome / Edge / Brave / Chromium 系:window 的 AXDocument 直接是 URL 字符串
        //    - Safari (macOS 26.x 起):window.AXDocument = nil。URL 改放在
        //      AXWebArea 的 AXURL 属性,或 toolbar 地址栏 AXTextField 的 AXValue
        //    - Firefox 不支持,Arc 需 AppleScript(P2)
        var url: String?
        if let bid = bundleId, Self.browserBundleIds.contains(bid) {
            url = Self.extractBrowserURL(focusedWindow: focusedWindow)
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

        return (title, url, axText, axId)
    }

    /// 浏览器 URL 抽取。fallback 链:
    ///   1. window.AXDocument                 — Chrome/Edge/Brave/Chromium 系
    ///   2. 焦点窗口子树里的 AXWebArea.AXURL    — Safari (macOS 26.x 起)
    ///   3. 子树里的 AXTextField.AXValue       — 地址栏兜底(subrole=AXAddressField)
    /// BFS 搜索,深度上限 6,元素上限 200。返回首个非空 URL。
    nonisolated static func extractBrowserURL(focusedWindow: AXUIElement) -> String? {
        // 1. AXDocument(快路)
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedWindow, "AXDocument" as CFString, &docRef) == .success,
           let s = docRef as? String, !s.isEmpty {
            return s
        }

        // 2/3. BFS 找 AXWebArea / AXTextField
        let maxDepth = 6
        let maxElements = 200
        var visited = 0
        var queue: [(AXUIElement, Int)] = [(focusedWindow, 0)]
        while !queue.isEmpty, visited < maxElements {
            let (elem, depth) = queue.removeFirst()
            visited += 1

            var roleRef: CFTypeRef?
            let role: String? = {
                guard AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef) == .success
                else { return nil }
                return roleRef as? String
            }()

            // 2. AXWebArea → AXURL(NSURL → absoluteString)
            if role == "AXWebArea" {
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, "AXURL" as CFString, &urlRef) == .success {
                    if let nsurl = urlRef as? NSURL, let s = nsurl.absoluteString, !s.isEmpty {
                        return s
                    }
                    if let s = urlRef as? String, !s.isEmpty { return s }
                }
            }
            // 3. 地址栏 AXTextField(subrole AXAddressField)→ AXValue
            if role == "AXTextField" {
                var subRef: CFTypeRef?
                let isAddr: Bool = {
                    guard AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &subRef) == .success
                    else { return false }
                    return (subRef as? String) == "AXAddressField"
                }()
                if isAddr {
                    var valRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef) == .success,
                       let s = valRef as? String, !s.isEmpty {
                        return s
                    }
                }
            }

            // 入队 children(不超深度)
            guard depth < maxDepth else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success
            else { continue }
            // swiftlint:disable:next force_cast
            guard let children = childrenRef as? [AXUIElement] else { continue }
            for c in children { queue.append((c, depth + 1)) }
        }
        return nil
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

        // 进入 AXWebArea(Electron 嵌入浏览器 / Safari 等)边界时,把 child
        // 的 depth 重置 0 —— 让 web 子树能拿到完整 maxDepth 走 budget。
        // 否则 VS Code / Discord / Slack 的 web 视图在 depth=1 就被截断,
        // 拿不到终端 / 聊天内容。安全网仍是 axMaxElements + axWalkBudgetNs。
        // 借鉴 upstream screenpipe commit 2b06b643d。
        let recurseDepth: Int = {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXWebArea" {
                return 0
            }
            return depth + 1
        }()

        // 递归 children。
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if charCount > maxChars || elemCount > maxElements { return }
                if DispatchTime.now().uptimeNanoseconds > deadlineNs { return }
                walkAXText(
                    element: child, depth: recurseDepth, maxDepth: maxDepth,
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
    /// 焦点窗口的 AXIdentifier。Arc 等浏览器的无痕窗口这里含
    /// "incognito"/"private" —— IncognitoGate Tier 1 用。其它情况多为 nil。
    public let axIdentifier: String?
    public let isFocused: Bool

    public init(
        appName: String, bundleId: String?, windowTitle: String?,
        browserUrl: String?, axText: String?, axIdentifier: String? = nil,
        isFocused: Bool
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserUrl = browserUrl
        self.axText = axText
        self.axIdentifier = axIdentifier
        self.isFocused = isFocused
    }
}
