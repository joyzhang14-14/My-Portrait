import AppKit
import Foundation

/// 焦点 app / 窗口标题变化 → 发 .appSwitch / .windowFocus。
///
/// 注册的 NSWorkspace 通知在 main thread。
/// 激活通知比画面早 0.1–0.6s(新窗口还没画上屏),切换触发等 500ms 再发;
/// 连续切换只发最后一次。
/// Spotlight、Bob 这类面板拿到键盘焦点不会发激活通知,改为每 500ms 问一次
/// `FocusProbe.focusedPanelApp()`,面板开 / 关时也发 .appSwitch。
@MainActor
final class WorkspaceWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var panelPollTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private static let switchDelayNs: UInt64 = 500_000_000
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
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitSwitchSoon() }
        }

        // 当前 app 被切走 —— 焦点已落到新 app，也算 app_switch 边缘。
        deactivationObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitSwitchSoon() }
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

    private func emitSwitchSoon() {
        switchTask?.cancel()
        switchTask = Task { [emit] in
            try? await Task.sleep(nanoseconds: Self.switchDelayNs)
            if !Task.isCancelled { emit(.appSwitch) }
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
        switchTask?.cancel()
        switchTask = nil
    }
}
