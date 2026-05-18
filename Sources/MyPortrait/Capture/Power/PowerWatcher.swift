import Foundation
import IOKit.ps
import os.log

/// 事件驱动的电源状态监听。基于 `IOPSNotificationCreateRunLoopSource`，
/// 设计文档明确要求"IOKit 事件驱动、即时响应、不轮询"。
///
/// 输出：`AsyncStream<PowerState>`。每次电源状态变化（包括启动时初始）都
/// 推一个事件。订阅方应记住上一次值，自行判断真实变化。
///
/// 与 `PowerMonitor.currentState()` 的关系：
///   - PowerMonitor 是同步一次性查询，调用方按需问
///   - PowerWatcher 是长期订阅，状态变了才知道
///
/// 内部用 RunLoop source 挂主线程，回调里调 `currentState()` 拿快照后 yield。
final class PowerWatcher: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "power")

    nonisolated let states: AsyncStream<PowerState>
    private let _continuation: AsyncStream<PowerState>.Continuation

    private var runLoopSource: CFRunLoopSource?

    init() {
        var c: AsyncStream<PowerState>.Continuation!
        self.states = AsyncStream<PowerState> { cont in c = cont }
        self._continuation = c
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
        _continuation.finish()
        logger.info("PowerWatcher stopped")
    }

    // MARK: - 私有

    /// 由 C 回调调用（任意线程，多半是 main）。yield 是 thread-safe。
    private func deliverCurrentState() {
        let state = PowerMonitor.currentState()
        _continuation.yield(state)
    }
}
