import AppKit
import Foundation

/// 焦点 app / 窗口标题变化 → 发 .appSwitch / .windowFocus。
///
/// 注册的 NSWorkspace 通知在 main thread。
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
            emit(.appSwitch)
        }

        // 当前 app 被切走 —— 焦点已落到新 app，也算 app_switch 边缘。
        deactivationObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [emit] _ in
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
