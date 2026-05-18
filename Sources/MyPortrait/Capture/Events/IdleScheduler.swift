import Foundation

/// idle 兜底定时器。固定间隔（默认 30s）发 .idle。
///
/// 设计：发就发，不判断"距上次 trigger 有多久"。重复 trigger 被
/// CaptureCoordinator 的最小帧间隔防抖 + FrameComparer 帧去重吸收。
/// 这样实现简单、不引入跨 watcher 的状态依赖。
final class IdleScheduler: @unchecked Sendable {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private let intervalMs: Int

    private var task: Task<Void, Never>?
    private let lock = NSLock()

    init(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        intervalMs: Int = 30_000
    ) {
        self.emit = emit
        self.intervalMs = intervalMs
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }

        let ms = intervalMs
        let e = emit
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if Task.isCancelled { return }
                e(.idle)
            }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }
}
