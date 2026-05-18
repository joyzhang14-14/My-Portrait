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

    private var cached: FocusInfo = FocusInfo(
        appName: "Unknown",
        bundleId: nil,
        windowTitle: nil,
        browserUrl: nil,
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

    private func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let name = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let pid = app.processIdentifier

        var windowTitle: String?
        var browserUrl: String?

        // AX 查询。若无权限就只返回 app 名。
        if AXIsProcessTrusted() {
            (windowTitle, browserUrl) = queryAX(pid: pid, bundleId: bundleId)
        } else if !axPermissionWarned {
            logger.warning("Accessibility permission not granted — window title / browser URL will be nil. Grant in System Settings → Privacy & Security → Accessibility.")
            axPermissionWarned = true
        }

        cached = FocusInfo(
            appName: name,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserUrl: browserUrl,
            isFocused: true
        )
    }

    /// 调 AX 抓窗口标题 + URL（仅浏览器）。
    /// AX API 是跨进程同步 XPC，可能 10–50ms。仅在 refresh() 内调用，
    /// 不在采集热路径上。
    private func queryAX(pid: pid_t, bundleId: String?) -> (title: String?, url: String?) {
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
            return (nil, nil)
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

        return (title, url)
    }
}

/// 焦点信息载体。每帧元数据都会带一份。
public struct FocusInfo: Equatable, Sendable {
    public let appName: String
    public let bundleId: String?
    public let windowTitle: String?
    public let browserUrl: String?
    public let isFocused: Bool

    public init(
        appName: String, bundleId: String?, windowTitle: String?,
        browserUrl: String?, isFocused: Bool
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserUrl = browserUrl
        self.isFocused = isFocused
    }
}
