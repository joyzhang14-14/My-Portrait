import Foundation

/// 焦点信息探针：当前 app 名、窗口标题、浏览器 URL。
///
/// 设计要点（性能优先）：
///   - 内部监听 NSWorkspace.didActivateApplicationNotification（焦点切换）
///     和窗口标题变化通知
///   - 状态变化时主动刷新 AX 信息并缓存
///   - 热路径上 `snapshot()` 只读 actor 内的属性，O(1)
///   - **不要**在每帧调用时同步走 AXUIElement（每次 10-50ms 跨进程 XPC，太重）
///
/// 浏览器 URL 抓取（命中 9 个浏览器之一时）：
///   - 主路径：AXDocument 属性
///   - Arc 浏览器：AppleScript fallback
actor FocusProbe {

    private let reporter: UnimplementedReporter
    private var cached: FocusInfo = FocusInfo(
        appName: "Unknown",
        bundleId: nil,
        windowTitle: nil,
        browserUrl: nil,
        isFocused: true
    )

    init(reporter: UnimplementedReporter) {
        self.reporter = reporter
    }

    /// 启动监听。idempotent。
    func start() async {
        // P0: 暂不注册通知
    }

    /// 停止监听，注销通知。
    func stop() async {
        // P0: noop
    }

    /// 当前焦点快照。O(1)。
    func snapshot() -> FocusInfo {
        cached
    }
}

/// 焦点信息载体。每帧元数据都会带一份。
public struct FocusInfo: Equatable, Sendable {
    public let appName: String
    public let bundleId: String?
    public let windowTitle: String?
    public let browserUrl: String?
    public let isFocused: Bool
}
