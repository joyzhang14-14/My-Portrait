import AppKit
import Combine
import CoreGraphics
import Foundation
import os.log

/// 锁屏状态监听 —— 给 "Record audio while locked" 开关用。
///
/// 事件驱动:订阅 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
/// distributed notifications,锁屏/解锁即时翻转 `screenLocked`。启动时用
/// CGSession 字典读一次初始状态。
///
/// 跟 MusicPlaybackMonitor 同形态:只发布一个 raw bool,由 Services 的 audio
/// 采集 sink 组合 `recordAudioWhileLocked` 设置决定要不要暂停。
@MainActor
final class ScreenLockMonitor: ObservableObject {

    @Published private(set) var screenLocked: Bool = false

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "screenlock")
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        screenLocked = Self.queryLocked()
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenLocked = true
            self?.logger.notice("screen locked")
        })
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenLocked = false
            self?.logger.notice("screen unlocked")
        })
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        observers.forEach { dnc.removeObserver($0) }
        observers.removeAll()
    }

    /// 启动时同步查一次当前锁屏状态。CGSession 字典里的
    /// `CGSSessionScreenIsLocked` == 1 表示已锁屏。
    private static func queryLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
