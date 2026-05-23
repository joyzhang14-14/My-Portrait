import Foundation
import Observation

/// Polls TemplateLibrary every minute while the app is running and fires
/// any template whose `schedule` is due. Each fire creates a brand-new
/// conversation and sends the template's prompt + window context. The
/// user finds the result in Recents.
///
/// In-process only — survives across switching sections, not across app
/// quits. (For background runs we'd register a LaunchAgent; not yet.)
@MainActor
@Observable
final class ScheduleRunner {
    static let shared = ScheduleRunner()

    /// Closure the runner calls to dispatch a template into chat. Wired up
    /// at app boot so the runner doesn't need to know about ChatController
    /// directly (keeps it testable + avoids retain cycles).
    var dispatch: (SummaryTemplate) -> Void = { _ in }
    /// Closure the runner calls to fire a cronJob — same idea, different
    /// destination (creates a NEW conv per fire, records a CronJobRun).
    var dispatchCronJob: (CronJob) -> Void = { _ in }

    private var timer: Timer?

    private init() {}

    /// Start the once-per-minute tick. Idempotent.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fire once immediately so a just-launched app catches up.
        tick()
    }

    private func tick() {
        let now = Date()

        // Templates (Home shortcut cards).
        let lib = TemplateLibrary.shared
        for t in lib.templates where t.schedule.isDue(lastRun: t.lastRunAt, now: now) {
            var updated = t
            updated.lastRunAt = now
            lib.update(updated)
            dispatch(updated)
        }

        // Cron Jobs (background workers).
        let cronJobs = CronJobStore.shared
        for p in cronJobs.cronJobs
            where p.isEnabled && p.schedule.isDue(lastRun: p.lastRunAt, now: now)
        {
            dispatchCronJob(p)
        }
    }
}
