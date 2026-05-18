import Foundation

/// 采集层总调度。一个 app 一个实例，AppDelegate 持有。
///
/// 职责：
///   1. 持有 ScreenCaptureService / OCRService / FocusProbe / FrameComparer 等子服务
///   2. 启动/停止采集流水线
///   3. 把每帧完成事件通过 `frameEvents` AsyncStream 推给订阅方
///
/// P0：所有公开方法 throw `notImplemented`。
actor CaptureCoordinator {

    private let db: PortraitDB
    private let config: CaptureConfig
    private let reporter: UnimplementedReporter

    private var _isRunning: Bool = false

    /// AsyncStream 的 continuation，发事件用。
    /// `nil` 表示 frameEvents 还没被订阅过（懒初始化）。
    private var eventsContinuation: AsyncStream<FrameEvent>.Continuation?

    /// 一帧入库完成事件流。
    /// 订阅方（日志处理 Agent / Portrait 距离器 / UI live preview）：
    /// ```swift
    /// for await event in coordinator.frameEvents { ... }
    /// ```
    /// **多订阅者注意**：当前实现是单消费者流。多订阅需求出现时改成 broadcast。
    nonisolated let frameEvents: AsyncStream<FrameEvent>

    private let _continuation: AsyncStream<FrameEvent>.Continuation

    init(db: PortraitDB, reporter: UnimplementedReporter, config: CaptureConfig = .default) {
        self.db = db
        self.reporter = reporter
        self.config = config

        var continuation: AsyncStream<FrameEvent>.Continuation!
        self.frameEvents = AsyncStream<FrameEvent> { c in
            continuation = c
        }
        self._continuation = continuation
    }

    var isRunning: Bool { _isRunning }

    /// 启动采集流水线。幂等。
    /// 失败抛错（含 notImplemented），调用方 catch 后状态栏会自动亮红点。
    func start() async throws {
        guard !_isRunning else { return }
        throw reporter.notImplemented("CaptureCoordinator.start")
    }

    /// 停止采集流水线。释放 SCStream、刷盘、关 reporter 流。
    func stop() async {
        guard _isRunning else { return }
        // P0：除了关流没别的可做
        _continuation.finish()
        _isRunning = false
    }

    /// 手动触发一帧（调试 / UI "立即截图" 按钮 / 测试用）。
    func captureOnce() async throws {
        throw reporter.notImplemented("CaptureCoordinator.captureOnce")
    }
}

/// 一帧入库完成（含 OCR 完成或确认空）后由 Coordinator 发出。
public struct FrameEvent: Sendable {
    public let frameId: Int64
    public let timestampMs: Int64
    public let appName: String
    public let windowName: String?
    public let browserUrl: String?
    public let snapshotPath: String
    /// `nil` = OCR 还没完成或失败。订阅方按需 poll DB。
    public let ocrText: String?
    public let captureTrigger: String
}
