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

    /// Closure the runner calls to dispatch a template into chat. ContentView
    /// 接上 ChatController 时设;没接上(开机自启还没开过窗口)时模板等着,
    /// 不标 lastRunAt,接上后 start() 补跑。
    var dispatch: ((SummaryTemplate) -> Void)?
    /// Closure the runner calls to fire a cronJob (creates a NEW conv per
    /// fire, records a CronJobRun). 不依赖界面。
    var dispatchCronJob: (CronJob) -> Void = { CronJobExecutor.run($0) }

    private var timer: Timer?

    private init() {}

    /// Start the once-per-minute tick. Idempotent;每次调都立刻补跑一轮
    /// (app 启动时,以及 ContentView 接上模板 dispatch 时)。
    func start() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        tick()
    }

    private func tick() {
        let now = Date()

        // Templates (Home shortcut cards).
        if let dispatch {
            let lib = TemplateLibrary.shared
            for t in lib.templates where t.schedule.isDue(lastRun: t.lastRunAt, now: now) {
                var updated = t
                updated.lastRunAt = now
                lib.update(updated)
                dispatch(updated)
            }
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
