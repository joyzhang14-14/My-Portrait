import AppKit
import Foundation

/// 剪贴板内容变化 → .clipboard。
///
/// 用 `NSPasteboard.changeCount` 轮询（200ms 一次）。
/// 没有官方通知 API；轮询是大家的标准做法。轮询在后台串行队列上跑:锁屏/解锁时
/// 剪贴板服务会十几秒不响应,连读 changeCount 都要等,不能放主线程。
@MainActor
final class PasteboardWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private let intervalMs: Int

    private let queue = DispatchQueue(label: "com.myportrait.pasteboard.watch")
    private var timer: DispatchSourceTimer?

    init(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        intervalMs: Int = 200
    ) {
        self.emit = emit
        self.intervalMs = intervalMs
    }

    func start() {
        guard timer == nil else { return }
        let e = emit
        let last = PasteboardChangeCount()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
        t.setEventHandler { @Sendable in
            let curr = NSPasteboard.general.changeCount
            // 第一拍只记基线 —— 不触发初次 emit。
            if let prev = last.value, prev != curr { e(.clipboard) }
            last.value = curr
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// 上次看到的 `changeCount`,nil = 还没取基线。只在所属轮询队列上读写。
final class PasteboardChangeCount: @unchecked Sendable {
    var value: Int?
}
