import Foundation

/// 把所有"应该抓帧"的事件源合流到一条 `AsyncStream<CaptureTrigger>`。
///
/// CaptureCoordinator 订阅这条流，每个 trigger 触发一次 captureOneFrame。
/// 重复 / 高频事件由 coordinator 的最小帧间隔防抖 + FrameComparer 帧去重吸收。
///
/// 当前事件源（P2）：
///   - WorkspaceWatcher: 焦点 app 切换
///   - InputWatcher: 键盘停顿 / 滚轮停止 / 鼠标点击
///   - PasteboardWatcher: 剪贴板变化
///   - IdleScheduler: 30s 兜底
///
/// **每次 `start()` 建全新的 stream**：`AsyncStream` 一旦 `finish()` 就永久死了，
/// 不能复用。早期实现把 stream 在 init 里建一次，结果 coordinator stop→start
/// 第二轮拿到的是已 finished 的死流 —— 事件循环立刻退出，只剩 start() 里那一帧
/// 初始抓拍。所以 stream 的生命周期必须跟 start/stop 对齐。
///
/// 子 watcher 都依赖 AppKit 通知 / NSEvent monitor / NSPasteboard，
/// 必须在 main thread 注册 → `start` / `stop` 标记 `@MainActor`。
final class EventSources: @unchecked Sendable {

    // 子 watcher 懒构造（start 时建，stop 时拆）。
    private var workspace: WorkspaceWatcher?
    private var input: InputWatcher?
    private var pasteboard: PasteboardWatcher?
    private var idle: IdleScheduler?

    private var continuation: AsyncStream<CaptureTrigger>.Continuation?

    init() {}

    /// 启动所有事件源，返回一条**新的** trigger 流。调用方（CaptureCoordinator）
    /// 拿这条流跑 runEventLoop。重复 start 先静默 stop 旧的。
    @MainActor
    func start() -> AsyncStream<CaptureTrigger> {
        if workspace != nil { stop() }

        var c: AsyncStream<CaptureTrigger>.Continuation!
        let stream = AsyncStream<CaptureTrigger> { cont in c = cont }
        continuation = c
        let cont = c!
        let emit: @Sendable (CaptureTrigger) -> Void = { cont.yield($0) }

        workspace = WorkspaceWatcher(emit: emit)
        input = InputWatcher(emit: emit)
        pasteboard = PasteboardWatcher(emit: emit)
        idle = IdleScheduler(emit: emit)

        workspace?.start()
        input?.start()
        pasteboard?.start()
        idle?.start()

        return stream
    }

    @MainActor
    func stop() {
        workspace?.stop()
        input?.stop()
        pasteboard?.stop()
        idle?.stop()

        workspace = nil
        input = nil
        pasteboard = nil
        idle = nil

        continuation?.finish()
        continuation = nil
    }
}
