import Foundation

/// Background sweeper: reads `storage.retentionDays` + `storage.autoDeleteMode`
/// from ConfigStore and deletes TimelineDB rows older than the window.
/// Fires once on app launch (so a long-closed laptop catches up) and every
/// 6 hours after that.
///
/// Single-shot — there's only one timer per process. Installed from
/// AppDelegate after `ConfigApplier.install`.
@MainActor
final class RetentionRunner {
    static let shared = RetentionRunner()
    private var timer: Timer?
    private var started = false
    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // First pass — light delay so launch isn't slowed.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.runOnce()
        }
        // Wake every 6h. Cheap when retention=forever or mode=off.
        let t = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    private func runOnce() {
        let s = ConfigStore.shared.storage
        guard let days = RetentionDays(rawValue: s.retentionDays)?.days,
              let mode = AutoDeleteMode(rawValue: s.autoDeleteMode),
              mode != .off else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let mediaOnly = (mode == .mediaOnly)

        Task.detached(priority: .background) {
            let res = TimelineDB().deleteBefore(cutoff, mediaOnly: mediaOnly)
            if res.frames + res.audio > 0 {
                NSLog("[Retention] swept frames=\(res.frames) audio=\(res.audio) older than \(days)d (mode=\(mode.rawValue))")
            }
        }
    }
}
