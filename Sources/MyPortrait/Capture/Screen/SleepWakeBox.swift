import Foundation

/// SleepWakeWatcher 是 @MainActor，从 CaptureCoordinator (actor) 直接持有要等
/// 跨 actor 调用。这个 box 把它包成"任何上下文都能 start/stop + 拿 stream"。
///
/// 与 EventSources 同思路：内部懒构造 watcher 到 @MainActor 上。
final class SleepWakeBox: @unchecked Sendable {

    // 可变状态只在 @MainActor 的 start/stop 里碰 —— @unchecked Sendable 成立。
    private var _continuation: AsyncStream<SleepWakeEvent>.Continuation?
    private var watcher: SleepWakeWatcher?

    /// 启动监听,返回一条**新的**睡眠/唤醒事件流。
    ///
    /// **每次 start 都重建流**:本 box 被 CaptureCoordinator 跨 capture off/on
    /// toggle 复用,而 stop() 会 `finish()` 掉旧流(AsyncStream finish 后永久
    /// 死亡)。旧实现 init 建一次流、start 永远返回同一条 —— toggle 一次之后
    /// for-await 立即退出,handleSleepWake 永不再执行:screenAsleep 冻结在
    /// toggle 时的值(StallDetector 误报或静默失效)、唤醒后 comparer.reset()
    /// 不再发生。镜像 EventSources / DRMWatcher 的「start 返回新流」模式。
    @MainActor
    func start() -> AsyncStream<SleepWakeEvent> {
        watcher?.stop()
        _continuation?.finish()
        var c: AsyncStream<SleepWakeEvent>.Continuation!
        let stream = AsyncStream<SleepWakeEvent> { cont in c = cont }
        _continuation = c
        let cont = c!
        watcher = SleepWakeWatcher(emit: { event in cont.yield(event) })
        watcher?.start()
        return stream
    }

    @MainActor
    func stop() {
        watcher?.stop()
        watcher = nil
        _continuation?.finish()
        _continuation = nil
    }
}
