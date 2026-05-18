import AppKit
import Foundation
import os.log

/// 全局键盘 / 鼠标事件 → debounced .typingPause / .scrollStop / .click。
///
/// 用 `NSEvent.addGlobalMonitorForEvents`（CGEventTap 的高层包装）。
/// 需要"输入监控"权限（macOS 10.15+：System Settings → Privacy → Input Monitoring）。
/// 权限缺失时静默降级 —— 只有 workspace 切换会触发抓帧。
///
/// 防抖规则（抄 My-Orphies）：
///   - 键盘按下后 500ms 内无新按下 → 发 .typingPause
///   - 滚轮事件后 300ms 内无新滚轮 → 发 .scrollStop
///   - 左键点击 → 立即发 .click（无防抖）
@MainActor
final class InputWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private let typingPauseMs: Int
    private let scrollStopMs: Int
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "input")

    private var monitor: Any?
    private var typingDebounceTask: Task<Void, Never>?
    private var scrollDebounceTask: Task<Void, Never>?

    init(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        typingPauseMs: Int = 500,
        scrollStopMs: Int = 300
    ) {
        self.emit = emit
        self.typingPauseMs = typingPauseMs
        self.scrollStopMs = scrollStopMs
    }

    func start() {
        guard monitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .scrollWheel]
        let handle = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }

        if handle == nil {
            logger.warning("Input monitor not granted — typing / click / scroll triggers will be silent. Grant in System Settings → Privacy & Security → Input Monitoring.")
        }
        monitor = handle
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        typingDebounceTask?.cancel()
        scrollDebounceTask?.cancel()
        typingDebounceTask = nil
        scrollDebounceTask = nil
    }

    // MARK: - 私有

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            typingDebounceTask?.cancel()
            let ms = typingPauseMs
            let e = emit
            typingDebounceTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if !Task.isCancelled { e(.typingPause) }
            }

        case .leftMouseDown:
            emit(.click)

        case .scrollWheel:
            scrollDebounceTask?.cancel()
            let ms = scrollStopMs
            let e = emit
            scrollDebounceTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if !Task.isCancelled { e(.scrollStop) }
            }

        default:
            break
        }
    }
}
