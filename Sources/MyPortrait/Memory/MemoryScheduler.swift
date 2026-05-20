import Foundation
import os.log

private let schedLog = Logger(subsystem: "com.myportrait.memory", category: "scheduler")

/// 记忆流水线的调度器。两个 job：
///   - daily   ：跑当天及之前未处理日的 event 聚类 + impact 评分
///   - weekly  ：跑 distill（事件 → 画像蒸馏）
///
/// 每次触发最多处理 7 个数据日（`dayCap`），从最旧的未处理日开始。失败的日
/// 下次触发会被重新捡起。
///
/// 状态全部落在 `processing_log` 表（见 ProcessingLog.swift）。`active_processor`
/// + `heartbeat_ms` 做崩溃保护：启动时把心跳过期的 in_progress 行回收。
///
/// 进程内并发由 `@MainActor` + `isRunning` 标志保证，同一时刻只有一个 job 在跑。
@MainActor
final class MemoryScheduler {

    static let shared = MemoryScheduler()

    private let store = ProcessingLogStore()

    /// 每次触发处理的数据日上限。
    private let dayCap = 7
    /// 原始数据"收齐"判定：数据日结束（UTC 次日 0 点）后再等这么久。
    private let rawGraceSeconds: TimeInterval = 2 * 3600
    /// 心跳超过这个时长视为死锁（处理器崩溃）。
    private let staleLockMs: Int64 = 10 * 60 * 1000
    /// tick 周期。
    private let tickInterval: TimeInterval = 15 * 60

    private var isRunning = false
    private var timer: Timer?

    private let model = "gpt-5.4"

    // UserDefaults 键：记录两个 job 上次跑的本地日，避免一天内重复触发。
    private let kLastDaily  = "scheduler.lastDailyRun"
    private let kLastWeekly = "scheduler.lastWeeklyRun"

    private init() {}

    // MARK: - 生命周期

    /// App 启动调用：先回收死锁，立刻 tick 一次，再起周期 timer。
    func start() {
        recoverStaleLocks()
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            Task { @MainActor in await MemoryScheduler.shared.tick() }
        }
        timer = t
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 周期检查：到点且今天还没跑过就跑。
    func tick() async {
        guard !isRunning else { return }
        let cfg = ConfigStore.shared.current.scheduler
        let now = Date()

        if cfg.dailyEnabled, isDailyDue(now: now, cfg: cfg) {
            setLastRun(kLastDaily, now)
            await runDailyJob()
        }
        if cfg.weeklyEnabled, isWeeklyDue(now: now, cfg: cfg) {
            setLastRun(kLastWeekly, now)
            await runWeeklyJob()
        }
    }

    // MARK: - daily job：event 聚类 + impact 评分

    /// 处理至多 `dayCap` 个未完成 event 处理的数据日（旧 → 新），再统一评分。
    func runDailyJob() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let days = pendingEventDays(cap: dayCap)
        guard !days.isEmpty else {
            schedLog.info("daily job: no pending days")
            return
        }
        print("[Scheduler] daily job — \(days.count) day(s) to process")

        var succeededDays: [String] = []

        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            _ = store.ensureRow(for: ds)

            // raw gate：数据还没收齐就跳过，下次触发再处理。
            guard isRawReady(day) else {
                store.setStatus(date: ds, stage: .raw, status: .pending)
                continue
            }
            store.setStatus(date: ds, stage: .raw, status: .complete)

            // event 步：跑 Backfill 单日。
            store.setStatus(date: ds, stage: .event, status: .inProgress)
            store.acquireLock(date: ds, processor: "event")
            let hb = startHeartbeat(for: ds)

            let nb = daysBackToCover(day)
            var ok = false
            do {
                let r = try await Backfill.run(daysBack: nb, onlyDay: day)
                ok = r.llmFailedDays == 0
            } catch {
                schedLog.error("daily job: Backfill threw for \(ds, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                ok = false
            }
            hb.cancel()

            if ok {
                store.setStatus(date: ds, stage: .event, status: .complete)
                succeededDays.append(ds)
                print("[Scheduler] \(ds): event clustering OK")
            } else {
                // 失败：清掉当天产生的 event，标 failed，下次触发重跑不会污染数据。
                deleteEvents(on: day)
                store.setStatus(date: ds, stage: .event, status: .failed)
                store.setStatus(date: ds, stage: .impact, status: .idle)
                print("[Scheduler] \(ds): event clustering FAILED — events purged")
            }
            store.releaseLock(date: ds)
        }

        guard !succeededDays.isEmpty else { return }

        // impact 步：ImpactScorer 扫描所有 `unscored` 事件统一评分。处理顺序
        // 旧→新，跑到这里时盘上唯一 unscored 的就是本轮新建的事件。
        for ds in succeededDays {
            store.setStatus(date: ds, stage: .impact, status: .inProgress)
        }
        do {
            let r = try await ImpactScorer(model: model).rescoreAll()
            print("[Scheduler] impact scoring — \(r.scoredCount) scored, \(r.failedCount) failed")
            for ds in succeededDays {
                store.setStatus(date: ds, stage: .impact,
                                status: r.failedCount == 0 ? .complete : .partial)
            }
        } catch {
            schedLog.error("daily job: impact scoring failed — \(error.localizedDescription, privacy: .public)")
            for ds in succeededDays {
                store.setStatus(date: ds, stage: .impact, status: .failed)
            }
        }
    }

    // MARK: - weekly job：distill

    /// 跑一次完整 distill。distiller 扫盘上所有非归档事件 —— 失败日的事件已被
    /// daily job 清除，所以盘上事件天然只来自 event 处理成功的日。
    func runWeeklyJob() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // 标记所有 event 完成的日 distill in_progress。
        let completeDays = store.allRows()
            .filter { $0.event == .complete }
            .map { $0.date }
        for ds in completeDays {
            store.setStatus(date: ds, stage: .distill, status: .inProgress)
        }
        print("[Scheduler] weekly job — distilling (\(completeDays.count) source day(s))")

        do {
            let r = try await PortraitDistiller(model: model).distill()
            print("[Scheduler] distill — \(r.portraitFilesWritten) written, \(r.portraitFilesUpdated) updated, \(r.llmFailedCategories) failed categories")
            let status: ProcessingStatus = r.llmFailedCategories == 0 ? .complete : .partial
            for ds in completeDays {
                store.setStatus(date: ds, stage: .distill, status: status)
            }
        } catch {
            schedLog.error("weekly job: distill failed — \(error.localizedDescription, privacy: .public)")
            for ds in completeDays {
                store.setStatus(date: ds, stage: .distill, status: .failed)
            }
        }
    }

    // MARK: - 崩溃恢复

    /// 启动时回收死锁：心跳过期的 in_progress 行 —— 处理器在持锁期间崩了。
    private func recoverStaleLocks() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for row in store.allRows() {
            guard row.activeProcessor != nil else { continue }
            let hb = row.heartbeatMs ?? 0
            guard now - hb > staleLockMs else { continue }

            schedLog.notice("recovering stale lock on \(row.date, privacy: .public) (processor=\(row.activeProcessor ?? "?", privacy: .public))")
            store.releaseLock(date: row.date)

            // event 在 in_progress 时崩 → 当天数据可能半成品，清除并标 failed。
            if row.event == .inProgress {
                if let day = ProcessingLogStore.day(from: row.date) {
                    deleteEvents(on: day)
                }
                store.setStatus(date: row.date, stage: .event, status: .failed)
                store.setStatus(date: row.date, stage: .impact, status: .idle)
            }
            // impact / distill 幂等（重扫 unscored / 重蒸馏），回退 idle 即可。
            if row.impact == .inProgress {
                store.setStatus(date: row.date, stage: .impact, status: .idle)
            }
            if row.distill == .inProgress {
                store.setStatus(date: row.date, stage: .distill, status: .idle)
            }
        }
    }

    // MARK: - 候选日筛选

    /// 待 event 处理的数据日：有采集帧、raw 已收齐、event_status ≠ complete。
    /// 按日期升序、上限 `cap`。failed 日不是 complete，会被自动重新捡起。
    private func pendingEventDays(cap: Int) -> [Date] {
        let cal = utcCalendar()
        let dayComps = TimelineDB().availableDays(monthsBack: 3)
        var days: [Date] = dayComps.compactMap { cal.date(from: $0) }
        days.sort()

        var out: [Date] = []
        for day in days {
            guard isRawReady(day) else { continue }
            let ds = ProcessingLogStore.dayString(day)
            if store.row(for: ds)?.event == .complete { continue }
            out.append(day)
            if out.count >= cap { break }
        }
        return out
    }

    /// 原始数据"收齐"：数据日 UTC 结束后再过 `rawGraceSeconds`。
    private func isRawReady(_ day: Date) -> Bool {
        let cal = utcCalendar()
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return Date() > dayEnd.addingTimeInterval(rawGraceSeconds)
    }

    /// Backfill 的 `daysBack` 需覆盖到目标日 —— 算出 day 距今多少天 + 1。
    private func daysBackToCover(_ day: Date) -> Int {
        let cal = utcCalendar()
        let today = cal.startOfDay(for: Date())
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: today).day ?? 0
        return max(1, d + 1)
    }

    /// 删某个数据日产生的全部 event 文件（失败日清理）。
    private func deleteEvents(on day: Date) {
        let dir = PortraitPaths.eventsDayDir(for: day)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where name.hasSuffix(".md") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - 心跳

    /// 起一个后台 Task，每 30s 刷新某天的心跳，直到被 cancel。
    private func startHeartbeat(for date: String) -> Task<Void, Never> {
        let store = self.store
        return Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                _ = store.heartbeat(date: date)
            }
        }
    }

    // MARK: - 到点判定

    private func isDailyDue(now: Date, cfg: SchedulerConfig) -> Bool {
        let cal = Calendar.current
        if lastRunDay(kLastDaily) == localDayString(now) { return false }
        return cal.component(.hour, from: now) >= cfg.dailyHour
    }

    private func isWeeklyDue(now: Date, cfg: SchedulerConfig) -> Bool {
        let cal = Calendar.current
        if cal.component(.weekday, from: now) != cfg.weeklyWeekday { return false }
        if lastRunDay(kLastWeekly) == localDayString(now) { return false }
        return cal.component(.hour, from: now) >= cfg.weeklyHour
    }

    // MARK: - 工具

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private func localDayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func lastRunDay(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    private func setLastRun(_ key: String, _ date: Date) {
        UserDefaults.standard.set(localDayString(date), forKey: key)
    }
}
