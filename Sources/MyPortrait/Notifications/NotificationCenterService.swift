import Foundation
import UserNotifications
import os.log

/// Thin facade around `UNUserNotificationCenter`. Handles:
///   - One-time authorization request at app launch
///   - Posting banner / sound notifications (respecting per-feature toggles)
///   - Per-cronJob mute via `notifications.mutedCronJobs`
///
/// Callers don't decide what's allowed — they pass the *kind* of event
/// (`.cronJobRun(jobName:)`, `.appUpdate`, `.captureStall`) and the service
/// gates it against the config + system authorization status.
@MainActor
final class NotificationCenterService {
    static let shared = NotificationCenterService()

    enum Kind {
        case cronJobRun(jobName: String, preview: String)
        case appUpdate(version: String)
        case captureStall(reason: String)
    }

    private let log = Logger(subsystem: "com.myportrait", category: "notifications")
    private(set) var authorized: Bool = false
    private var didRequest = false

    private init() {}

    /// Called from AppDelegate. If the user hasn't been asked yet, prompt
    /// for banner + sound permission. Idempotent — re-calling is cheap.
    ///
    /// `UNUserNotificationCenter` requires the process to be inside a real
    /// `.app` bundle; Xcode's "Run" path executes a loose binary inside
    /// `DerivedData/.../Build/Products/Debug/` and the framework throws an
    /// uncatchable Obj-C exception (`bundleProxyForCurrentProcess is nil`).
    /// We skip the call in that case so dev builds don't crash.
    func requestAuthorizationOnce() {
        guard !didRequest else { return }
        didRequest = true
        guard isBundledApp else {
            log.notice("skipping notification authorization — not running inside a .app bundle")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                self?.log.notice("authorization result: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            }
        }
    }

    /// Diagnostic: log macOS-level authorization status without changing it.
    func logCurrentSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            // 提取 Sendable 标量再跨 actor 边界,避免 UNNotificationSettings
            // 自身非 Sendable 触发 Swift 6 data race 报错。
            let auth = s.authorizationStatus.rawValue
            let alert = s.alertSetting.rawValue
            let nc = s.notificationCenterSetting.rawValue
            let sound = s.soundSetting.rawValue
            Task { @MainActor in
                self?.log.notice("settings: authStatus=\(auth, privacy: .public) alert=\(alert, privacy: .public) banner=\(nc, privacy: .public) sound=\(sound, privacy: .public)")
            }
        }
    }

    /// True when `Bundle.main` resolves to a real `.app` package. The
    /// UserNotifications framework only works in that case — see comment
    /// on `requestAuthorizationOnce` above.
    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Post a notification iff the matching config toggle is on AND we have
    /// system authorization. Silent no-op otherwise.
    func post(_ kind: Kind) {
        let n = ConfigStore.shared.notifications
        let title: String
        let body: String
        let categoryId: String
        switch kind {
        case let .cronJobRun(jobName, preview):
            guard n.cronJobAlerts else {
                log.notice("post skipped: cronJobAlerts toggle is OFF")
                return
            }
            guard !n.mutedCronJobs.contains(jobName) else {
                log.notice("post skipped: '\(jobName, privacy: .public)' is muted")
                return
            }
            title = "🛰️ \(jobName)"
            body  = preview.isEmpty ? "Run finished." : preview
            categoryId = "cron-job.run"

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
        // Same guard as requestAuthorizationOnce — Xcode dev runs would
        // otherwise crash inside UNUserNotificationCenter.add.
        guard isBundledApp else {
            log.notice("deliver skipped: not running inside a .app bundle")
            return
        }
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
        log.notice("deliver attempt: title='\(title, privacy: .public)' authorized=\(self.authorized, privacy: .public)")
        UNUserNotificationCenter.current().add(req) { [weak self] error in
            if let error {
                self?.log.error("deliver failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self?.log.notice("deliver ok")
            }
        }
    }
}
