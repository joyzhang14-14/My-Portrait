import AppKit
import Foundation

/// 焦点 app / 窗口标题变化 → 发 .appSwitch / .windowFocus。
///
/// 注册的 NSWorkspace 通知在 main thread。
@MainActor
final class WorkspaceWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?

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
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = activationObserver { center.removeObserver(obs) }
        if let obs = deactivationObserver { center.removeObserver(obs) }
        activationObserver = nil
        deactivationObserver = nil
    }
}
