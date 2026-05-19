import Foundation
import UserNotifications
import os.log

/// Thin facade around `UNUserNotificationCenter`. Handles:
///   - One-time authorization request at app launch
///   - Posting banner / sound notifications (respecting per-feature toggles)
///   - Per-pipe mute via `notifications.mutedPipes`
///
/// Callers don't decide what's allowed — they pass the *kind* of event
/// (`.pipeRun(pipeName:)`, `.appUpdate`, `.captureStall`) and the service
/// gates it against the config + system authorization status.
@MainActor
final class NotificationCenterService {
    static let shared = NotificationCenterService()

    enum Kind {
        case pipeRun(pipeName: String, preview: String)
        case appUpdate(version: String)
        case captureStall(reason: String)
    }

    private let log = Logger(subsystem: "com.myportrait", category: "notifications")
    private(set) var authorized: Bool = false
    private var didRequest = false

    private init() {}

    /// Called from AppDelegate. If the user hasn't been asked yet, prompt
    /// for banner + sound permission. Idempotent — re-calling is cheap.
    func requestAuthorizationOnce() {
        guard !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                if let error {
                    self?.log.error("authorization error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Post a notification iff the matching config toggle is on AND we have
    /// system authorization. Silent no-op otherwise.
    func post(_ kind: Kind) {
        let n = ConfigStore.shared.notifications
        let title: String
        let body: String
        let categoryId: String
        switch kind {
        case let .pipeRun(pipeName, preview):
            guard n.pipeAlerts else { return }
            guard !n.mutedPipes.contains(pipeName) else { return }
            title = "🛰️ \(pipeName)"
            body  = preview.isEmpty ? "Run finished." : preview
            categoryId = "pipe.run"

        case let .appUpdate(version):
            guard n.appUpdates else { return }
            title = "My Portrait \(version) available"
            body  = "Open the app to install."
            categoryId = "app.update"

        case let .captureStall(reason):
            guard n.captureStalls else { return }
            title = "Capture stalled"
            body  = reason
            categoryId = "capture.stall"
        }
        deliver(title: title, body: body, categoryId: categoryId)
    }

    private func deliver(title: String, body: String, categoryId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        content.categoryIdentifier = categoryId

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil    // deliver immediately
        )
        UNUserNotificationCenter.current().add(req) { [weak self] error in
            if let error {
                self?.log.warning("post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
