import Foundation
import Observation
import os.log

private let schedLog = Logger(subsystem: "com.myportrait.memory", category: "scheduler")

/// 记忆流水线的调度器。两个 job（频率各自可配 off/daily/weekly/monthly）：
///   - event   ：跑当天及之前未处理日的 event 聚类 + impact 评分（per-day）。
///   - portrait ：跑 distill（事件 → 画像蒸馏），用 `_distill_anchor` 哨兵行记状态。
///
/// "event / portrait" 是调度器身份（跑什么），频率是它的配置（多久跑一次）。
/// 每次触发最多处理 7 个数据日（`dayCap`），从最旧的未处理日开始。
///
/// 失败语义（见 ProcessingStatus）：
///   - 真实失败 → status=failed，retry_count +1；retry_count ≥ 3 → dead_letter。
///   - 撞 LLM 额度 → status=budget_deferred，retry_count 不变，自动重试。
///   - dead_letter 的日 / 阶段被排除出自动处理，等用户在 Settings 手动重置。
///
/// 状态全部落在 `processing_log` 表。`active_processor` + `heartbeat_ms` 做崩溃
/// 保护：每个 LLM 步（event / impact / distill）持锁并每 30s 续心跳；启动时
/// `recoverStaleLocks` 把心跳过期的 in_progress 行当一次失败回收（retry +1）。
///
/// 进程内并发由 `@MainActor` + 3 把分离的锁保证:
///   - `eventRunning`        :event job 跑着,屏蔽所有其它 job(它 rebalance
///                              重写整个 events/,distill/personality 同跑会
///                              读到撕裂状态)
///   - `distillRunning`      :distill 跑着,屏蔽 event 和自己重入(distill
///                              跟 personality 可以并行 —— 写盘目录不重叠)
///   - `personalityRunning`  :personality 跑着,屏蔽 event 和自己重入
/// 写作采集 worker **完全独立**,不参与上面三把锁(它走另一套 DB 表,跟
/// memory pipeline 零交集,在用户手动调试时不被 memory 阻塞)。
@MainActor
@Observable
final class MemoryScheduler {

    static let shared = MemoryScheduler()

    /// 失败 / 撞额度 / dead_letter 的日，给 Settings 的 "Needs attention" 用。
    struct AttentionItem: Identifiable, Sendable {
        var id: String { date }
        let date: String
        let retryCount: Int
        /// 出问题的阶段及其状态。
        let problems: [(stage: ProcessingStage, status: ProcessingStatus)]
    }

    private enum StepOutcome { case success, failed, budgetExhausted }

    private let store = ProcessingLogStore()

    /// 每次触发处理的数据日上限。
    /// 每次 event-processing 跑最多处理几个未处理日 —— 由 Settings 配置。
    private var dayCap: Int { ConfigStore.shared.current.memory.eventDayCap }
    /// 失败重试上限：retry_count ≥ 此值转 dead_letter。
    private let maxRetries = 3
    /// 原始数据"收齐"判定：数据日结束（UTC 次日 0 点）后再等这么久。
    private let rawGraceSeconds: TimeInterval = 2 * 3600
    /// tick 周期。
    private let tickInterval: TimeInterval = 15 * 60
    /// distill 锚行的 date 值。anchor 是 distill 这个 processor 的锁身份，与
    /// 运行频率无关。定义 / 语义见 `ProcessingLogStore.distillAnchorDate`。
    private let distillAnchor = ProcessingLogStore.distillAnchorDate
    // classify(EventClassifier 自动分 folder)已下线 —— 改成 chat AI 通过
    // mp-folders 按用户对话需求手动整理。anchor case 在 ProcessingLog 里保留
    // (DB 历史值 + 崩溃恢复仍需识别老 inProgress),不再有 scheduler hook。
    // personality 不用 anchor —— 它是 per-day 流水线(每天的 events 各自有
    // 各自的 personality_status 列),进度直接落在日期行里。

    /// 心跳超过这个时长视为死锁。默认 10min（单日 Backfill 多轮 LLM 可能 >5min
    /// 仍在正常跑）。可经 env `MYPORTRAIT_SCHEDULER_STALE_MS` 覆盖（测试用）。
    private let staleLockMs: Int64 = {
        if let s = ProcessInfo.processInfo.environment["MYPORTRAIT_SCHEDULER_STALE_MS"],
           let v = Int64(s) {
            return v
        }
        return 10 * 60 * 1000
    }()

    /// 四把分离的锁。View 侧 @Observable 跟踪它们,Run 按钮根据 canRunXxx
    /// 实时灰掉 + tooltip 说理由。
    private(set) var eventRunning = false
    // classifyRunning 已下线(EventClassifier 砍掉了)。canRunEvent 不再需要
    // classify 锁。
    private(set) var distillRunning = false
    private(set) var personalityRunning = false
    /// tick() 自身的可重入防护(timer 与 startup 并发触发时只跑一次)。
    private var tickRunning = false
    private var timer: Timer?

    // MARK: - View bindings(canRunXxx + 解释文案)
    /// 当前是否有事件家族(distill or personality)在跑。
    var portraitFamilyRunning: Bool { distillRunning || personalityRunning }

    /// 能不能现在起 event job(必须自己空闲 + portrait/personality 都空闲)。
    var canRunEvent: Bool { !eventRunning && !portraitFamilyRunning }
    /// 能不能现在起 distill(必须 event 空闲 + 自己空闲;personality/classify 不挡)。
    var canRunDistill: Bool { !eventRunning && !distillRunning }
    /// 能不能现在起 personality(必须 event 空闲 + 自己空闲;distill 不挡)。
    var canRunPersonality: Bool { !eventRunning && !personalityRunning }

    /// 当前 memory pipeline 的 provider/model — 从 ConfigStore 读。每次需要时
    /// 现拉,这样用户在 Settings 改完无需重启 scheduler 立刻生效。
    private var memoryCfg: MemoryConfig { ConfigStore.shared.current.memory }

    // UserDefaults 键：记录两个 job 上次跑的本地日，避免一天内重复触发。
    private let kLastEvent          = "scheduler.lastEventRun"
    // kLastClassify 已下线(EventClassifier 砍掉)。老 UserDefaults key 保留
    // 不读 = 静默忽略。
    private let kLastPortrait       = "scheduler.lastPortraitRun"
    private let kLastPersonality    = "scheduler.lastPersonalityRun"
    private let kLastWritingCapture = "scheduler.lastWritingCaptureRun"
    private let kLastWritingStyle    = "scheduler.lastWritingStyleRun"

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

    /// 周期检查：每个调度器按各自频率到点、且今天还没跑过就跑。
    func tick() async {
        // tick 本身防重入。每个 runXxxJob 内部还会按 canRunXxx 二次把关,
        // 跟手动触发 / 上一次 tick 残留并发安全。
        guard !tickRunning else { return }
        tickRunning = true
        defer { tickRunning = false }
        // 有手动触发的结果在等审核 / AI 编辑 draft 在等审 → 暂停定时调度,
        // 避免 distill / personality 跑完覆盖了用户没拍板的改动。
        guard !MemoryStaging.hasPending(.events),
              !MemoryStaging.hasPending(.portrait),
              !MemoryStaging.hasPending(.personality),
              !EditDraft.hasAnyPending() else {
            schedLog.info("tick: manual run / AI edit draft pending — skip")
            return
        }
        let s = ConfigStore.shared.current.scheduler
        let now = Date()

        // **追赶分支**:除了"到点 + 今天没跑过"的 scheduled 触发,daily 频率
        // 下只要有 pending 活 + 今天还没跑过,任何 tick 都触发(catchUp)。
        // 解决"电脑半夜睡着,23:45 scheduled tick 错过 → 整天跳过"的滞后:
        // 用户白天开机,首次 tick 就能把昨晚没跑成的活捡起来。weekly/monthly
        // 维持原语义(只在 scheduled 日 + 到点跑),不被追赶逻辑破坏。
        var ranEvent = false
        let eventToday    = lastRunDay(kLastEvent) != localDayString(now)
        let eventCatchUp  = s.event.frequency == .daily && eventJobHasWork()
        if eventToday,
           Self.shouldTriggerNow(config: s.event, now: now) || eventCatchUp {
            setLastRun(kLastEvent, now)
            await runEventJob()
            ranEvent = true
        }
        // classify(自动 EventClassifier 分 folder)已下线 —— chat AI 通过
        // mp-folders 手动整理。tick 不再有 classify 分支。
        var ranPortrait = false
        let portraitToday   = lastRunDay(kLastPortrait) != localDayString(now)
        let portraitCatchUp = s.portrait.frequency == .daily && portraitJobHasWork()
        if portraitToday,
           Self.shouldTriggerNow(config: s.portrait, now: now) || portraitCatchUp {
            setLastRun(kLastPortrait, now)
            await runPortraitJob()
            ranPortrait = true
        } else if ranEvent, s.portrait.frequency != .off, portraitNeedsRetry() {
            // distill 之前被 defer / failed —— 借 event job 触发的节流顺带重试。
            await runPortraitJob()
            ranPortrait = true
        }
        let personalityToday   = lastRunDay(kLastPersonality) != localDayString(now)
        let personalityCatchUp = s.personality.frequency == .daily && personalityJobHasWork()
        if personalityToday,
           Self.shouldTriggerNow(config: s.personality, now: now) || personalityCatchUp {
            setLastRun(kLastPersonality, now)
            await runPersonalityJob()
        } else if ranPortrait, s.personality.frequency != .off, personalityNeedsRetry() {
            await runPersonalityJob()
        }

        // 写作采集:自动只是「把 staged 准备好」,等用户在 Pending review
        // 里 Approve/Reject,不直接 commit 到 writing_records。
        if Self.shouldTriggerNow(config: s.writingCapture, now: now),
           lastRunDay(kLastWritingCapture) != localDayString(now) {
            setLastRun(kLastWritingCapture, now)
            await runWritingCaptureJob()
        }

        // writing_style:auto 模式 → 直接落 portrait/writing_style/,不审核。
        // 跟 writing capture 一样不参与 event/portrait/personality 三锁。
        if Self.shouldTriggerNow(config: s.writingStyle, now: now),
           lastRunDay(kLastWritingStyle) != localDayString(now) {
            setLastRun(kLastWritingStyle, now)
            await runWritingStyleJob()
        }
    }

    /// 跑 writing_style auto —— 跟 writing capture 同模式:失败 swallow + log,
    /// 不阻塞下一次 tick。dependency gate:writing_style 是 writing_capture 的
    /// 下游,没新 writing_records 可消费就早退,避免空跑。
    func runWritingStyleJob() async {
        guard let distiller = WritingStyleDistiller.shared else {
            schedLog.warning("writingStyle tick: distiller not initialized — skip")
            return
        }
        // dependency gate:0 unprocessed → 跳本次 tick,不调 distiller。
        // distiller.runAuto 内部也有同样的 gate(双层兜底),但这里先查能省 token
        // 的 nap-guard / refresh-weights 一连串开销。
        let unprocessed = (try? distiller.store.unprocessedCount()) ?? 0
        guard unprocessed > 0 else {
            schedLog.info("writingStyle tick: 0 unprocessed writing_records — skip (waiting for writing_capture)")
            return
        }
        do {
            let s = try await distiller.runAuto()
            schedLog.info("writingStyle auto: status=\(s.status.rawValue, privacy: .public) records=\(s.recordsCount) drafts=\(s.draftsCount)")
        } catch {
            schedLog.warning("writingStyle auto failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 跑写作采集 worker(backlog 模式)—— 跟手动 Run 一样,从 cursor 跑到现在
    /// 一次性出一个 staged batch。失败 swallow + log,不阻塞下一次 tick。
    /// 已经有 pending_review / processing → backlog 内部自带 guard 跳过,不会
    /// 重复跑。
    func runWritingCaptureJob() async {
        guard let worker = WritingCaptureWorker.shared else {
            schedLog.warning("writingCapture tick: worker not initialized — skip")
            return
        }
        do {
            let summary = try await worker.runBacklog()
            schedLog.info("writingCapture backlog: status=\(summary.status.rawValue, privacy: .public) records=\(summary.recordsCount) discarded=\(summary.discardedCount)")
        } catch {
            schedLog.warning("writingCapture backlog failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 给定调度器配置与当前时刻，判断现在是否落在它的触发窗口内
    /// （频率匹配 + 到点）。是否"今天已跑过"由调用方另做去重。
    static func shouldTriggerNow(config: SchedulerConfig, now: Date) -> Bool {
        guard config.frequency != .off else { return false }
        let cal = Calendar.current

        switch config.frequency {
        case .off:
            return false
        case .daily:
            break   // 每天都匹配
        case .weekly:
            // Calendar.weekday 是 1…7（1=周日）；config.dayOfWeek 是 0…6。
            let wd = cal.component(.weekday, from: now) - 1
            guard wd == config.dayOfWeek else { return false }
        case .monthly:
            let day = cal.component(.day, from: now)
            guard day == effectiveDayOfMonth(config.dayOfMonth, now: now, cal: cal) else {
                return false
            }
        }

        // 到点：当前时刻 ≥ 配置时刻（按分钟比较）。
        let nowMinutes = cal.component(.hour, from: now) * 60
            + cal.component(.minute, from: now)
        return nowMinutes >= config.hour * 60 + config.minute
    }

    /// monthly 的 day-of-month edge case：选 31 但当月只有 30 天 → 落到当月
    /// 最后一天。
    static func effectiveDayOfMonth(_ requested: Int, now: Date, cal: Calendar) -> Int {
        let lastDay = cal.range(of: .day, in: .month, for: now)?.count ?? 28
        return min(max(requested, 1), lastDay)
    }

    /// runEventJob / runPortraitJob 的结果。手动触发的 UI 用它区分
    /// "真跑了" / "没活干直接罢工" / "调度器在忙"。
    enum JobOutcome: Sendable {
        /// 跑了。`days` 是处理的 ProcessingLog 行 key —— event job 是日期串，
        /// portrait job 是 ["_distill_anchor"]。Reject 时用来重置回 pending。
        case ran(days: [String])
        case noWork        // 没有待处理的天 / 画像已最新 —— 直接罢工
        case busy          // 调度器或另一次触发正在跑
    }

    /// event job 现在有没有活干（有未处理的天）。手动触发拍快照前先 check，
    /// 没活就直接罢工、不浪费快照。
    func eventJobHasWork() -> Bool {
        !pendingDays(cap: dayCap).isEmpty
    }

    /// portrait job 现在有没有活干（distill 哨兵 needsWork）。
    func portraitJobHasWork() -> Bool {
        _ = store.ensureRow(for: distillAnchor)
        return (store.row(for: distillAnchor)?.distill ?? .idle).needsWork
    }

    // classifierJobHasWork / scanAllEventPaths 已下线(EventClassifier 砍掉)。

    /// personality job 现在有没有活干（per-day 待处理列表非空）。
    func personalityJobHasWork() -> Bool {
        !pendingPersonalityDays(cap: dayCap).isEmpty
    }

    // MARK: - event job：event 聚类 + impact 评分（per-day）

    /// 处理至多 `dayCap` 个未完成的数据日（旧 → 新）。每天 event → impact
    /// 顺序跑，各自持锁 + 心跳。手动触发与定时触发走同一个函数。
    @discardableResult
    func runEventJob() async -> JobOutcome {
        guard canRunEvent else { return .busy }
        eventRunning = true
        defer { eventRunning = false }

        let days = pendingDays(cap: dayCap)
        guard !days.isEmpty else {
            schedLog.info("event job: no pending days")
            return .noWork
        }
        print("[Scheduler] event job — \(days.count) day(s) to process")
        DiagLog.event("scheduler.event.start", ctx: [
            "days":  days.map { ProcessingLogStore.dayString($0) },
            "count": days.count,
        ])

        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            _ = store.ensureRow(for: ds)

            // raw gate：数据还没收齐就跳过，下次触发再处理。
            guard isRawReady(day) else {
                store.setStatus(date: ds, stage: .raw, status: .pending)
                continue
            }
            store.setStatus(date: ds, stage: .raw, status: .complete)

            // event 步。
            var row = store.row(for: ds) ?? ProcessingLogRow(date: ds)
            if row.event.needsWork {
                await runStep(date: ds, stage: .event, processor: "event", rollbackDay: day) {
                    let nb = self.daysBackToCover(day)
                    let r = try await Backfill.run(daysBack: nb, onlyDay: day)
                    return r.llmFailedDays == 0 ? .success : .failed
                }
                row = store.row(for: ds) ?? row
            }

            // impact 步：仅当 event 已 complete。按日扫 events/<day>/ 下的 unscored。
            if row.event == .complete, row.impact.needsWork {
                await runStep(date: ds, stage: .impact, processor: "impact", rollbackDay: nil) {
                    let dir = PortraitPaths.eventsDayDir(for: day)
                    let cfg = self.memoryCfg
                    let r = try await ImpactScorer(provider: cfg.resolvedProvider, model: cfg.resolvedModel).rescoreAll(root: dir)
                    return r.failedCount == 0 ? .success : .failed
                }
            }
        }

        // 周预算 rebalance：整个 event 处理跑完只跑一次（不是按天跑 N 次，
        // 否则一次 run 就把 rebalance_count 烧到 maxRebalances 把事件冻死）。
        _ = MemoryBudget_applyToDisk()

        // 新事件到了 → distill 锚点重新标 pending,下一次 tick 自动 catch up。
        // (老 classify anchor 不再 mark pending —— EventClassifier 已下线。)
        _ = store.ensureRow(for: distillAnchor)
        store.setStatus(date: distillAnchor, stage: .distill, status: .pending)

        // 同时把这些天的 personality_status 标 pending —— 事件变了,
        // 那天的 personality 也得重跑(per-day,跟 distill 不一样)。
        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            let row = store.row(for: ds)
            // 仅 event+impact 都 complete 的天才有意义跑 personality。
            if row?.event == .complete, row?.impact == .complete {
                store.setStatus(date: ds, stage: .personality, status: .pending)
            }
        }

        return .ran(days: days.map { ProcessingLogStore.dayString($0) })
    }

    // classify job(自动 EventClassifier 跑 LLM 分 folder)已整段下线 ——
    // 改成 chat AI 通过 mp-folders 手动按用户对话需求整理。

    // MARK: - portrait job：distill

    /// 跑一次完整 distill，状态记在 `_distill_anchor` 哨兵行（持锁 + 心跳，
    /// 崩溃可恢复）。distiller 扫盘上所有非归档事件 —— 失败日的事件已被 event
    /// job 清除，所以盘上事件天然只来自 event 处理成功的日。
    @discardableResult
    func runPortraitJob() async -> JobOutcome {
        guard canRunDistill else { return .busy }
        distillRunning = true
        defer { distillRunning = false }

        _ = store.ensureRow(for: distillAnchor)
        let distill = store.row(for: distillAnchor)?.distill ?? .idle
        guard distill.needsWork else {
            schedLog.info("portrait job: distill is \(distill.rawValue, privacy: .public) — skip")
            return .noWork
        }
        print("[Scheduler] portrait job — distilling")
        DiagLog.event("scheduler.distill.start")

        await runStep(date: distillAnchor, stage: .distill, processor: "distill", rollbackDay: nil) {
            let cfg = self.memoryCfg
            let r = try await PortraitDistiller(provider: cfg.resolvedProvider, model: cfg.resolvedModel).distill()
            return r.llmFailedCategories == 0 ? .success : .failed
        }
        return .ran(days: [distillAnchor])
    }

    // MARK: - personality job:per-day events → personality(events + OCR 验证)

    /// 跑 personality refresh,**per-day**:遍历 event+impact 都 complete、
    /// 但 personality 还需做的天,最多 `dayCap` 个(从最旧未做开始)。跟
    /// distill(anchor 模式)不同 —— personality 跟 events 一样按天滚动,
    /// 进度落在每天那行的 `personality_status` 列。
    @discardableResult
    func runPersonalityJob() async -> JobOutcome {
        guard canRunPersonality else { return .busy }
        personalityRunning = true
        defer { personalityRunning = false }

        let days = pendingPersonalityDays(cap: dayCap)
        guard !days.isEmpty else {
            schedLog.info("personality job: no pending days")
            return .noWork
        }
        print("[Scheduler] personality job — \(days.count) day(s) to process")
        DiagLog.event("scheduler.personality.start", ctx: [
            "days": days.map { ProcessingLogStore.dayString($0) },
        ])

        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            await runStep(date: ds, stage: .personality,
                          processor: "personality", rollbackDay: nil) {
                let cfg = self.memoryCfg
                let r = try await PersonalityRefresh(provider: cfg.resolvedProvider, model: cfg.resolvedModel, clusterModel: cfg.resolvedModelLight).refresh(day: day)
                print("[Scheduler] personality \(ds): events \(r.eventsTotal)→\(r.eventsAboveWeight)(>w\(PersonalityRefresh.minEventWeight)) → snapshot \(r.snapshotTags) → ocr kept \(r.ocrKept)/dropped \(r.ocrDropped) | created=\(r.apply.created) merged=\(r.apply.merged) skipped=\(r.apply.skipped)")
                return .success
            }
        }
        return .ran(days: days.map { ProcessingLogStore.dayString($0) })
    }

    // MARK: - 单步执行（持锁 + 心跳 + 结果落库）

    /// 跑一个 LLM 步：先持锁起心跳，跑 `work`，再按结果落库、释放锁。
    /// `work` 返回 `.success` / `.failed`，撞额度时抛 `BudgetExhaustedError`。
    private func runStep(
        date: String,
        stage: ProcessingStage,
        processor: String,
        rollbackDay: Date?,
        _ work: () async throws -> StepOutcome
    ) async {
        // 先持锁（写 active_processor + 初始心跳），再标 in_progress。
        // 这个顺序下，若在两步之间崩溃，recoverStaleLocks 仍能凭 active_processor
        // 发现并释放锁。
        store.acquireLock(date: date, processor: processor)
        store.setStatus(date: date, stage: stage, status: .inProgress)
        let hb = startHeartbeat(for: date)

        let outcome: StepOutcome
        do {
            outcome = try await work()
        } catch let e as BudgetExhaustedError {
            schedLog.notice("\(date)/\(processor): budget exhausted — \(e.message, privacy: .public)")
            outcome = .budgetExhausted
        } catch {
            schedLog.error("\(date)/\(processor): \(error.localizedDescription, privacy: .public)")
            outcome = .failed
        }
        hb.cancel()

        applyOutcome(date: date, stage: stage, outcome: outcome, rollbackDay: rollbackDay)
        store.releaseLock(date: date)
    }

    /// 把一个步的结果落库：成功 → complete；撞额度 → budget_deferred（不计
    /// retry）；失败 → retry +1，回滚（event 步删当天 event），retry ≥ 上限转
    /// dead_letter。
    private func applyOutcome(
        date: String,
        stage: ProcessingStage,
        outcome: StepOutcome,
        rollbackDay: Date?
    ) {
        switch outcome {
        case .success:
            store.setStatus(date: date, stage: stage, status: .complete)
            print("[Scheduler] \(date)/\(stage.rawValue): complete")

        case .budgetExhausted:
            store.setStatus(date: date, stage: stage, status: .budgetDeferred)
            print("[Scheduler] \(date)/\(stage.rawValue): budget_deferred (retry_count unchanged)")

        case .failed:
            // 回滚：event 步失败删当天 event 目录，重跑不污染数据。
            // impact / distill 幂等（重扫 unscored / 整体重蒸馏），无需显式回滚。
            if let day = rollbackDay {
                deleteEvents(on: day)
            }
            let n = store.bumpRetry(date: date)
            if n >= maxRetries {
                store.setStatus(date: date, stage: stage, status: .deadLetter)
                print("[Scheduler] \(date)/\(stage.rawValue): dead_letter (retry_count=\(n))")
                DiagLog.error("scheduler.stage.dead_letter", ctx: [
                    "date": date, "stage": stage.rawValue, "retry": n,
                ])
            } else {
                store.setStatus(date: date, stage: stage, status: .failed)
                print("[Scheduler] \(date)/\(stage.rawValue): failed (retry_count=\(n))")
                DiagLog.warn("scheduler.stage.failed", ctx: [
                    "date": date, "stage": stage.rawValue, "retry": n,
                ])
            }
        }
    }

    // MARK: - 崩溃恢复

    /// 启动时回收死锁：心跳过期的 in_progress 行 —— 处理器在持锁期间崩了。
    /// 当一次失败处理（retry +1、event 回滚），跟显式失败一致，这样反复崩溃
    /// 最终也会到 dead_letter。
    func recoverStaleLocks() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for row in store.allRows() {
            guard row.activeProcessor != nil else { continue }
            let hb = row.heartbeatMs ?? 0
            guard now - hb > staleLockMs else { continue }

            schedLog.notice("recovering stale lock on \(row.date, privacy: .public) (processor=\(row.activeProcessor ?? "?", privacy: .public), heartbeat age=\(now - hb)ms)")
            print("[Scheduler] crash recovery: \(row.date) had stale lock (processor=\(row.activeProcessor ?? "?"))")
            store.releaseLock(date: row.date)

            let day = ProcessingLogStore.day(from: row.date)
            if row.event == .inProgress {
                applyOutcome(date: row.date, stage: .event, outcome: .failed, rollbackDay: day)
            }
            if row.impact == .inProgress {
                applyOutcome(date: row.date, stage: .impact, outcome: .failed, rollbackDay: nil)
            }
            if row.classify == .inProgress {
                applyOutcome(date: row.date, stage: .classify, outcome: .failed, rollbackDay: nil)
            }
            if row.distill == .inProgress {
                applyOutcome(date: row.date, stage: .distill, outcome: .failed, rollbackDay: nil)
            }
            if row.personality == .inProgress {
                applyOutcome(date: row.date, stage: .personality, outcome: .failed, rollbackDay: nil)
            }
        }
    }

    // MARK: - UI 支持：重置 / 待处理列表

    /// 手动重置某天 / `_distill_anchor`：把 failed / dead_letter /
    /// budget_deferred 的阶段回退 pending，retry_count 归零，释放锁。
    /// 下次 tick 会重新尝试。
    func resetDay(_ date: String) {
        guard let row = store.row(for: date) else { return }
        for stage in ProcessingStage.allCases {
            switch row.status(of: stage) {
            case .failed, .deadLetter, .budgetDeferred:
                store.setStatus(date: date, stage: stage, status: .pending)
            default:
                break
            }
        }
        store.setRetryCount(date: date, count: 0)
        store.releaseLock(date: date)
        print("[Scheduler] reset \(date) → pending, retry_count=0")
    }

    /// 需要用户关注的日：任一阶段处于 failed / dead_letter / budget_deferred。
    /// nonisolated:纯 DB 读 + 数据变换,不碰 MainActor 状态,可在后台调用
    /// 避免阻塞 UI(被 MemorySettingsView.reload 从 detached task 调)。
    nonisolated func attentionDays() -> [AttentionItem] {
        store.allRows().compactMap { row in
            let problems = ProcessingStage.allCases.compactMap {
                stage -> (stage: ProcessingStage, status: ProcessingStatus)? in
                let s = row.status(of: stage)
                switch s {
                case .failed, .deadLetter, .budgetDeferred: return (stage, s)
                default: return nil
                }
            }
            guard !problems.isEmpty else { return nil }
            return AttentionItem(date: row.date, retryCount: row.retryCount, problems: problems)
        }
    }

    // MARK: - 测试钩子（dev-only，被 SchedulerTestCLI 调用）

    /// 注入结果跑真实的 `runStep` —— 验证 applyOutcome 的 success / failed /
    /// budget_deferred 三个分支走的是生产代码路径。
    enum InjectedResult { case success, failure, budget }

    func runInjectedStep(date: String, stage: ProcessingStage, result: InjectedResult) async {
        await runStep(
            date: date, stage: stage, processor: stage.rawValue,
            rollbackDay: ProcessingLogStore.day(from: date)
        ) {
            switch result {
            case .success: return .success
            case .failure: return .failed
            case .budget:
                throw BudgetExhaustedError(processor: "injected-test",
                                           message: "simulated 429 quota exceeded")
            }
        }
    }

    // MARK: - 候选日筛选

    /// 待处理的数据日：有采集帧、raw 已收齐、且 event 或 impact 阶段还需处理。
    /// 按日期升序、上限 `cap`。
    ///
    /// 纳入：event/impact 处于 idle / pending / failed / budget_deferred。
    /// 排除：complete（已完成）、in_progress（在跑或待恢复）、dead_letter（放弃）。
    func pendingDays(cap: Int) -> [Date] {
        let cal = utcCalendar()
        var days: [Date] = TimelineDB().availableDays(monthsBack: 3)
            .compactMap { cal.date(from: $0) }
        days.sort()

        var out: [Date] = []
        for day in days {
            guard isRawReady(day) else { continue }
            let row = store.row(for: ProcessingLogStore.dayString(day))
            if isEventCandidate(row) {
                out.append(day)
                if out.count >= cap { break }
            }
        }
        return out
    }

    /// tick / event job 是否还会处理某天 —— 与 pendingDays 用的是同一谓词。
    /// dead_letter / 全 complete → false。测试 / UI 可查。
    func wouldProcessInEventJob(date: String) -> Bool {
        isEventCandidate(store.row(for: date))
    }

    /// 一天是否需要 event job 处理（event 或 impact 阶段还有活）。
    private func isEventCandidate(_ row: ProcessingLogRow?) -> Bool {
        guard let row else { return true }              // 无行 = idle = 需 event
        if row.event.needsWork { return true }          // event 待处理
        if row.event == .complete, row.impact.needsWork { return true }  // 待 impact
        return false                                    // complete / in_progress / dead_letter
    }

    /// distill 是否处于待重试态（failed / budget_deferred）。
    private func portraitNeedsRetry() -> Bool {
        switch store.row(for: distillAnchor)?.distill {
        case .failed, .budgetDeferred: return true
        default: return false
        }
    }

    /// personality 是否处于待重试态(任一天的 personality 失败/撞额度)。
    private func personalityNeedsRetry() -> Bool {
        for row in store.allRows() {
            if row.isAnchor { continue }
            switch row.personality {
            case .failed, .budgetDeferred: return true
            default: continue
            }
        }
        return false
    }

    /// personality job 的候选天:event+impact 都 complete、personality 还
    /// 需做(idle / pending / failed / budget_deferred);跳 in_progress /
    /// complete / dead_letter。按日期升序、上限 `cap`。
    func pendingPersonalityDays(cap: Int) -> [Date] {
        let cal = utcCalendar()
        var days: [Date] = TimelineDB().availableDays(monthsBack: 3)
            .compactMap { cal.date(from: $0) }
        days.sort()

        var out: [Date] = []
        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            guard let row = store.row(for: ds) else { continue }
            guard row.event == .complete, row.impact == .complete else { continue }
            guard row.personality.needsWork else { continue }
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

    /// 删某个数据日产生的全部 event 文件（失败日回滚）。
    private func deleteEvents(on day: Date) {
        let dir = PortraitPaths.eventsDayDir(for: day)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        var removed = 0
        for name in items where name.hasSuffix(".md") {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            print("[Scheduler] rollback: purged \(removed) event file(s) from \(dir.lastPathComponent)/")
        }
    }

    // MARK: - 心跳

    /// 起一个独立 Task，每 30s 刷新某行的心跳，直到被 cancel。
    /// `Task.detached` —— 与 LLM 调用的 async context 完全独立：即使
    /// `await` 在等网络挂起，这个循环照跑，stale detection 不会误杀在跑的步。
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
