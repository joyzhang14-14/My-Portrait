import Foundation
import IOKit.ps
import os.log

/// 事件驱动的电源状态监听。基于 `IOPSNotificationCreateRunLoopSource`，
/// 设计文档明确要求"IOKit 事件驱动、即时响应、不轮询"。
///
/// 输出:`subscribe()` 返回一条**每订阅者独立**的 `AsyncStream<PowerState>`,
/// 订阅时立即推一次当前状态作 baseline,之后每次电源状态变化都广播给所有
/// 订阅者。订阅方应记住上一次值,自行判断真实变化。
///
/// **为什么不是单条共享流**:AsyncStream 是单播(unicast)的,多个消费者
/// for-await 同一条流时,每个事件只派发给其中一个 —— Services(屏幕采集
/// 档位重算)和 TranscriptionScheduler(插电唤醒转录)曾共享一条流,插拔
/// 电源事件被随机瓜分,各拿一半。
///
/// 与 `PowerMonitor.currentState()` 的关系：
///   - PowerMonitor 是同步一次性查询，调用方按需问
///   - PowerWatcher 是长期订阅，状态变了才知道
///
/// 内部用 RunLoop source 挂主线程，回调里调 `currentState()` 拿快照后 yield。
final class PowerWatcher: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "power")

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PowerState>.Continuation] = [:]

    private var runLoopSource: CFRunLoopSource?

    /// 订阅电源状态。返回的新流先立即收到一次当前状态(baseline),之后收到
    /// 每次变化的广播。消费者 task 取消时自动退订(onTermination)。
    func subscribe() -> AsyncStream<PowerState> {
        let id = UUID()
        var c: AsyncStream<PowerState>.Continuation!
        let stream = AsyncStream<PowerState> { cont in c = cont }
        let cont = c!
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
        }
        lock.lock()
        continuations[id] = cont
        lock.unlock()
        cont.yield(PowerMonitor.currentState())
        return stream
    }

    @MainActor
    func start() {
        guard runLoopSource == nil else { return }

        // IOPSNotificationCreateRunLoopSource 期望一个 C 函数指针 + 透明 context。
        // 用 Unmanaged passUnretained 把 self 转成 raw pointer，C 回调里再还原。
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.deliverCurrentState()
        }

        guard let src = IOPSNotificationCreateRunLoopSource(callback, opaque)?.takeRetainedValue() else {
            logger.warning("IOPSNotificationCreateRunLoopSource returned nil; falling back to no power events")
            return
        }
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        // 启动时立刻推一次当前状态，订阅方拿到 baseline。
        deliverCurrentState()
        logger.info("PowerWatcher started (event-driven IOKit notifications)")
    }

    @MainActor
    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        lock.lock()
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
        logger.info("PowerWatcher stopped")
    }

    // MARK: - 私有

    /// 由 C 回调调用（任意线程，多半是 main）。yield 是 thread-safe。
    private func deliverCurrentState() {
        let state = PowerMonitor.currentState()
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(state) }
    }
}
