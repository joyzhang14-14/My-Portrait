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
/// 子 watcher 都依赖 AppKit 通知 / NSEvent monitor / NSPasteboard，
/// 必须在 main thread 注册 → `start` / `stop` 标记 `@MainActor`。
/// init 本身不动 UI，可以从任何上下文构造（包括 CaptureCoordinator actor.init）。
final class EventSources: @unchecked Sendable {

    nonisolated let stream: AsyncStream<CaptureTrigger>
    private let _continuation: AsyncStream<CaptureTrigger>.Continuation
    private let emit: @Sendable (CaptureTrigger) -> Void

    // 子 watcher 懒构造（start 时建，stop 时拆），避免 init 跨 actor 上下文。
    private var workspace: WorkspaceWatcher?
    private var input: InputWatcher?
    private var pasteboard: PasteboardWatcher?
    private var idle: IdleScheduler?

    init() {
        var c: AsyncStream<CaptureTrigger>.Continuation!
        self.stream = AsyncStream<CaptureTrigger> { cont in
            c = cont
        }
        self._continuation = c
        let cont = c!
        self.emit = { trigger in cont.yield(trigger) }
    }

    @MainActor
    func start() {
        guard workspace == nil else { return }

        workspace = WorkspaceWatcher(emit: emit)
        input = InputWatcher(emit: emit)
        pasteboard = PasteboardWatcher(emit: emit)
        idle = IdleScheduler(emit: emit)

        workspace?.start()
        input?.start()
        pasteboard?.start()
        idle?.start()
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

        _continuation.finish()
    }
}
