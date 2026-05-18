import AppKit
import Foundation

/// 剪贴板内容变化 → .clipboard。
///
/// 用 `NSPasteboard.changeCount` 轮询（200ms 一次）。
/// 没有官方通知 API；轮询是大家的标准做法。
@MainActor
final class PasteboardWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private let intervalMs: Int

    private var lastChangeCount: Int = 0
    private var pollTask: Task<Void, Never>?

    init(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        intervalMs: Int = 200
    ) {
        self.emit = emit
        self.intervalMs = intervalMs
    }

    func start() {
        guard pollTask == nil else { return }
        // 初始基线 —— 不触发初次 emit。
        lastChangeCount = NSPasteboard.general.changeCount

        let ms = intervalMs
        let e = emit
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                guard let self else { break }
                self.poll(emit: e)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll(emit: @Sendable (CaptureTrigger) -> Void) {
        let curr = NSPasteboard.general.changeCount
        if curr != lastChangeCount {
            lastChangeCount = curr
            emit(.clipboard)
        }
    }
}
