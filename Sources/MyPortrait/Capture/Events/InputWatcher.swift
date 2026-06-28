import AppKit
import Foundation
import os.log

/// 全局键盘 / 鼠标事件 → .typingPause / .scrollStop / .click。
///
/// 用 `NSEvent.addGlobalMonitorForEvents`（CGEventTap 的高层包装）。
/// 需要"输入监控"权限（macOS 10.15+：System Settings → Privacy → Input Monitoring）。
/// 权限缺失时静默降级 —— 只有 workspace 切换会触发抓帧。
///
/// 规则：
///   - 按下 Return / Enter → **立即**发 .typingPause(敲回车 = 一个动作完成,
///     发消息 / 换行 / 提交,越快抓帧越好)。其它按键不触发。
///     连发 / 长按回车的防抖交给 CaptureCoordinator 的 minCaptureIntervalMs
///     (200ms)+ 画面去重,不在这里设计时器。
///   - 滚轮事件后 300ms 内无新滚轮 → 发 .scrollStop
///   - 左键点击 → 立即发 .click（无防抖）
@MainActor
final class InputWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private let scrollStopMs: Int
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "input")

    private var monitor: Any?
    private var scrollDebounceTask: Task<Void, Never>?

    /// keyCode：36 = Return，76 = 小键盘 Enter。
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    init(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        scrollStopMs: Int = 300
    ) {
        self.emit = emit
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
        scrollDebounceTask?.cancel()
        scrollDebounceTask = nil
    }

    // MARK: - 私有

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // 只在 Return / Enter 的瞬间触发,立刻抓帧。其它按键不抓。
            if Self.returnKeyCodes.contains(event.keyCode) {
                emit(.typingPause)
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
