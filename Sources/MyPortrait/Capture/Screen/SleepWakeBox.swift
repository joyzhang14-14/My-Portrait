import Foundation

/// SleepWakeWatcher 是 @MainActor，从 CaptureCoordinator (actor) 直接持有要等
/// 跨 actor 调用。这个 box 把它包成"任何上下文都能 start/stop + 拿 stream"。
///
/// 与 EventSources 同思路：内部懒构造 watcher 到 @MainActor 上。
final class SleepWakeBox: @unchecked Sendable {

    private let stream: AsyncStream<SleepWakeEvent>
    private let _continuation: AsyncStream<SleepWakeEvent>.Continuation
    private let emit: @Sendable (SleepWakeEvent) -> Void

    private var watcher: SleepWakeWatcher?

    init() {
        var c: AsyncStream<SleepWakeEvent>.Continuation!
        self.stream = AsyncStream<SleepWakeEvent> { cont in c = cont }
        self._continuation = c
        let cont = c!
        self.emit = { event in cont.yield(event) }
    }

    @MainActor
    func start() -> AsyncStream<SleepWakeEvent> {
        if watcher == nil {
            watcher = SleepWakeWatcher(emit: emit)
            watcher?.start()
        }
        return stream
    }

    @MainActor
    func stop() {
        watcher?.stop()
        watcher = nil
        _continuation.finish()
    }
}
