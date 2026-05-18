import AppKit
import Foundation
import os.log

/// 睡眠 / 唤醒 / 屏幕锁定通知监听。
///
/// 输出事件：
///   - `.willSleep` —— 系统准备睡眠或屏幕锁定。下游应释放 SCStream 缓存
///     （My-Orphies 撞过：睡眠后 SCStream 句柄变 zombie，回来要全新建）。
///   - `.didWake`  —— 系统唤醒/解锁。下游应重置 FrameComparer（避免拿
///     "睡前那一帧"做差异判断）。
///
/// 用 NSWorkspace.notificationCenter（专门的系统级通知，比 NSWorkspace 普通通知更准）。
@MainActor
final class SleepWakeWatcher {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "sleep")
    private let emit: @Sendable (SleepWakeEvent) -> Void

    private var observers: [NSObjectProtocol] = []

    init(emit: @escaping @Sendable (SleepWakeEvent) -> Void) {
        self.emit = emit
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [emit, logger] _ in
            logger.info("system will sleep")
            emit(.willSleep)
        }

        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [emit, logger] _ in
            logger.info("system did wake")
            emit(.didWake)
        }

        let screensSleep = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [emit, logger] _ in
            logger.info("screens did sleep (lock)")
            emit(.willSleep)
        }

        let screensWake = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [emit, logger] _ in
            logger.info("screens did wake (unlock)")
            emit(.didWake)
        }

        observers = [willSleep, didWake, screensSleep, screensWake]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for obs in observers {
            center.removeObserver(obs)
        }
        observers.removeAll()
    }
}

public enum SleepWakeEvent: Sendable {
    case willSleep
    case didWake
}
