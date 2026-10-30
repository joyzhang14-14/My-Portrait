import AppKit
import Foundation

/// 焦点 app / 窗口标题变化 → 发 .appSwitch / .windowFocus。
///
/// 注册的 NSWorkspace 通知在 main thread。每次发 .appSwitch 先在 `SwitchClock` 记下时刻。
/// 激活通知比画面早(新窗口还没画上屏),什么时候抓帧由 CaptureCoordinator 看画面定。
/// Spotlight、Bob 这类面板拿到键盘焦点不会发激活通知,改为每 500ms 问一次
/// `FocusProbe.focusedPanelApp()`,面板开 / 关时也发 .appSwitch。
@MainActor
final class WorkspaceWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var panelPollTask: Task<Void, Never>?
    private var lastPanelPid: pid_t?

    init(emit: @escaping @Sendable (CaptureTrigger) -> Void) {
        self.emit = emit
    }

    func start() {
        guard activationObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter

        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [emit] _ in
            SwitchClock.shared.mark()
            emit(.appSwitch)
        }

        // 当前 app 被切走 —— 焦点已落到新 app，也算 app_switch 边缘。
        deactivationObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [emit] _ in
            SwitchClock.shared.mark()
            emit(.appSwitch)
        }

        lastPanelPid = FocusProbe.focusedPanelApp()?.processIdentifier
        panelPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { break }
                let pid = FocusProbe.focusedPanelApp()?.processIdentifier
                if pid != self.lastPanelPid {
                    self.lastPanelPid = pid
                    SwitchClock.shared.mark()
                    self.emit(.appSwitch)
                }
            }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = activationObserver { center.removeObserver(obs) }
        if let obs = deactivationObserver { center.removeObserver(obs) }
        activationObserver = nil
        deactivationObserver = nil
        panelPollTask?.cancel()
        panelPollTask = nil
    }
}

/// 最近一次前台切换(激活 / 失活通知、面板开关)的时刻。
/// 抓帧时判「截图途中是不是来了切换」:按下鼠标点别的 app 时,点击帧先开始截图、激活通知随后才到。
/// 通知在 main thread 写,CaptureCoordinator 在自己的 actor 上读,所以加锁。
final class SwitchClock: @unchecked Sendable {
    static let shared = SwitchClock()
    private let lock = NSLock()
    private var last = Date.distantPast

    func mark() {
        lock.lock(); last = Date(); lock.unlock()
    }

    var lastSwitch: Date {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}
