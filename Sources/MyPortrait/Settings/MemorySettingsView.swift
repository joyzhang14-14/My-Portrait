import SwiftUI

/// Tunable fields for the Memory pipeline. Persists to ~/.portrait/config.toml
/// via ConfigStore. MemoryBudget / WeightCalculator / Archiver each pull
/// `.fromConfig` so changes take effect on the next rebalance / weight pass /
/// archive run.
struct MemorySettingsView: View {
    private let cfg = ConfigStore.shared
    @Environment(AppState.self) private var appState

    @State private var attention: [MemoryScheduler.AttentionItem] = []
    @State private var changelog: [ProcessingLogStore.PipelineRunRecord] = []

    /// 手动触发的 pipeline 阶段（都烧 LLM token）。两个，对齐调度器的两个
    /// scheduler。Rebalance 不在列 —— 程序化的，已挂成 hook 在 rescore 后自动跑。
    private enum ManualTrigger: String, Identifiable {
        case eventProcessing, distill, personality
        var id: String { rawValue }
        var title: String {
            switch self {
            case .eventProcessing: return "Process events"
            case .distill:         return "Distill portrait"
            case .personality:     return "Refresh personality"
            }
        }
        var desc: String {
            switch self {
            case .eventProcessing:
                return "Reads the raw timeline, builds event files for unprocessed days, then re-scores every event's impact with the LLM. The weekly budget rebalance runs automatically at the end. Mirrors the scheduler's Event processing job. Output is staged for review before it commits."
            case .distill:
                return "Distills events into long-term portrait entries. Uses the LLM once per portrait category. Output is staged for review before it commits."
            case .personality:
                return "Aggregates today's events, other portrait sections, and today's OCR into personality tags. Output is staged for review before it commits."
            }
        }
        var kind: MemoryStaging.Kind {
            switch self {
            case .eventProcessing: return .events
            case .distill:         return .portrait
            case .personality:     return .personality
            }
        }
    }
    @State private var actionStatus: String = ""
    /// 同时可能跑多个(distill || personality)。每个 trigger 独立持有 Task,
    /// 由对应 runXxxJob 的 scheduler 锁实际把关并发安全。
    @State private var runningTriggers: Set<ManualTrigger> = []
    @State private var confirmTrigger: ManualTrigger? = nil
    @State private var runTasks: [ManualTrigger: Task<Void, Never>] = [:]
    @State private var eventsChanges: [MemoryStaging.StagedChange] = []
    @State private var portraitChanges: [MemoryStaging.StagedChange] = []
    @State private var personalityChanges: [MemoryStaging.StagedChange] = []
    /// 三个 job 当前有没有活要干。每次 reload / run / approve / reject 后
    /// 刷新,不每帧扫 DB(扫 timeline + processing_log 有成本)。
    @State private var hasEventWork: Bool = true
    @State private var hasDistillWork: Bool = true
    @State private var hasPersonalityWork: Bool = true
    /// writing capture backlog 现在有没有未处理的 typing_event。
    @State private var hasWritingCaptureWork: Bool = true
    /// body 渲染期间不再直接查 DB / 文件系统 —— 下面这些探测缓存在
    /// reload()/refreshStaging() 既有刷新点后台重算,body 只读缓存。
    /// (原来 triggerRow×3 + reviewSection×3 每次 body 求值各开一条 sqlite
    /// 连接全表扫 processing_log,job 跑着时每帧 6 次;hasPending 是同步
    /// fileExists;attentionRow 每行还各一次查询。)
    @State private var dbInProgressEvent = false
    @State private var dbInProgressDistill = false
    @State private var dbInProgressPersonality = false
    @State private var pendingEvents = false
    @State private var pendingPortrait = false
    @State private var pendingPersonality = false
    /// Needs attention 每行的 DB row(nextRetryLabel 用),per-date,
    /// 跟 attention 列表同一个 reload 后台任务里算好。
    @State private var attentionDbRows: [String: ProcessingLogRow] = [:]
    /// staging diff 的后台刷新 task —— 连续触发时 cancel 旧的合并成一次(debounce)。
    @State private var stagingRefreshTask: Task<Void, Never>? = nil
    @State private var previewChange: MemoryStaging.StagedChange? = nil

    // EventClassifier 已下线 —— folder 整理改由 chat AI 通过 mp-folders 按用户
    // 对话需求触发,UI 这里不再挂"Run classifier"按钮。

    // 写作采集 worker 的 UI 状态(独立于 Memory pipeline 的 ManualTrigger 体系
    // —— 不共用 MemoryStaging,自己一套)
    // Running / status / summary / task 全走 UIState.shared,view 切走再回来
    // Stop 按钮仍可点,状态不丢。
    @ObservedObject private var writingCaptureUI = WritingCaptureUIState.shared
    @State private var writingCaptureConfirm: Bool = false
    /// pending_review 的天 + 各自 staged 内容,UI 同步 reload 后展示。
    @State private var writingCapturePending: [WritingCaptureRun] = []
    /// 用户点开某天后展示的 staged records(preview sheet)。
    @State private var writingCapturePreviewDate: String? = nil
    /// 哪些 pending 行已展开内联预览(按 date_utc)
    @State private var writingCaptureExpanded: Set<String> = []
    /// 每天的 staged records 缓存(展开时按需加载)
    @State private var writingCaptureExpandedRecords: [String: [StagedRecordRow]] = [:]
    @State private var writingCaptureExpandedError: [String: String] = [:]

    // writing_style 提炼链路的 UI 状态(独立于上面所有 pipeline)。
    // Running / status / task 走 UIState.shared,跟 writing capture 同模式。
    @ObservedObject private var writingStyleUI = WritingStyleUIState.shared
    @State private var writingStyleConfirm: Bool = false
    @State private var writingStylePending: [WritingStyleRunRow] = []
    @State private var writingStyleUnprocessed: Int = 0
    @State private var writingStylePreviewRun: String? = nil
    /// 点击某一行 draft 时打开的 sheet,只显示这一条 draft 详情。
    @State private var writingStylePreviewDraft: WritingStyleStagedRow? = nil
    @State private var writingStyleExpandedDrafts: [String: [WritingStyleStagedRow]] = [:]

    /// Memory 区的三个子板块。由左侧栏选中项决定，不在页内切换。
    enum Tab: String {
        case parameter = "Parameter"
        case scheduler = "Scheduler"
        case changelog = "Changelog"
    }
    /// 由 SettingsView 的路由根据侧栏选中的子分区注入。
    let tab: Tab

    var body: some View {
        ScrollView {
            // VStack spacing / 外层 padding 跟 SettingsPage 完全对齐
            // (spacing 20 / top 30 / bottom 40)—— 原来钉死 24 / 44 / 28 跟
             // General / Display 等页对比明显错位。
            VStack(alignment: .leading, spacing: 20) {
                header

                switch tab {
                case .parameter:
                    providerSection
                    budgetSection
                    decaySection
                    archiveSection
                    distillationSection
                case .scheduler:
                    schedulerSection
                    runNowSection
                    reviewSection
                    attentionSection
                case .changelog:
                    changelogSection
                }

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { reload() }
        // 跑完 / approve / reject 改了 UIState 后,自动刷新 Pending review 列表,
        // 不再依赖手动点刷新。运行状态翻转(true→false)和最后一次 summary 变化
        // 都触发。
        .onChange(of: writingCaptureUI.isRunning) { _, newValue in
            if !newValue { refreshWritingCapture() }
        }
        .onChange(of: writingCaptureUI.lastSummary?.runId) { _, _ in
            refreshWritingCapture()
        }
        .confirmationDialog(
            "Run this now?",
            isPresented: Binding(get: { confirmTrigger != nil },
                                 set: { if !$0 { confirmTrigger = nil } }),
            presenting: confirmTrigger
        ) { trigger in
            Button("Run \(trigger.title)") {
                let t = trigger
                runTasks[t] = Task {
                    await run(t)
                    runTasks[t] = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { trigger in
            Text("\(trigger.title) uses LLM tokens. \(trigger.desc)")
        }
        .sheet(item: $previewChange) { change in
            StagedChangePreview(change: change)
        }
    }

    private func reload() {
        // attentionDays + recentChangelog 是同步 sqlite 扫表,放主线程会卡。
        // attentionDays 已 nonisolated,可以 off-main 跑;ProcessingLogStore
        // 是 Sendable struct,本来就能 off-main。
        Task.detached(priority: .userInitiated) {
            let scheduler = await MemoryScheduler.shared
            let att = scheduler.attentionDays()
            // 每行的 DB row 在这里一次算好,attentionRow(date:) 不再在 body 里逐行查。
            let rows = Dictionary(
                att.compactMap { item in
                    scheduler.attentionRow(date: item.date).map { (item.date, $0) }
                },
                uniquingKeysWith: { a, _ in a }
            )
            let log = ProcessingLogStore().recentPipelineRuns(limit: 50)
            await MainActor.run {
                attention = att
                attentionDbRows = rows
                changelog = log
            }
        }
        refreshStaging()
        refreshWritingCapture()
        refreshWritingStyle()
    }

    /// 重新从 DB 拉 backlog pending row(date_utc='all')。
    /// Run / Approve / Reject 后都调一次。GUI 只关心 backlog 模式,
    /// per-day 老 rows 即使存在也不显示(走 CLI 兼容路径)。
    private func refreshWritingCapture() {
        guard let worker = WritingCaptureWorker.shared else { return }
        let store = worker.store
        Task.detached(priority: .userInitiated) {
            let pending = (try? store.fetchPendingReviewDays()) ?? []
            let backlogOnly = pending.filter {
                $0.dateUtc == WritingCaptureWorker.backlogDateKey
            }
            let hasWork = await worker.backlogHasWork()
            await MainActor.run {
                writingCapturePending = backlogOnly
                hasWritingCaptureWork = hasWork
            }
        }
    }

    @MainActor
    private func approveWritingCapture(date: String) async {
        guard let worker = WritingCaptureWorker.shared else { return }
        do {
            let copied = try await worker.approveBacklog()
            writingCaptureUI.statusMessage = "Approved backlog — \(copied) record(s) → writing_records, cursor advanced."
            // 清 lastSummary,不然之前 run 的摘要行带着旧 pending_review 标签
            // 继续显示,看着像还有东西要审
            writingCaptureUI.lastSummary = nil
            writingCaptureExpanded.remove(date)
            writingCaptureExpandedRecords.removeValue(forKey: date)
        } catch {
            writingCaptureUI.statusMessage = "Approve failed: \(error.localizedDescription)"
        }
        refreshWritingCapture()
    }

    @MainActor
    private func rejectWritingCapture(date: String) async {
        guard let worker = WritingCaptureWorker.shared else { return }
        do {
            try await worker.rejectBacklog()
            writingCaptureUI.statusMessage = "Rejected backlog — staged dropped, cursor unchanged."
            // 清 lastSummary,不然摘要行带着旧 pending_review 标签继续显示
            writingCaptureUI.lastSummary = nil
            writingCaptureExpanded.remove(date)
            writingCaptureExpandedRecords.removeValue(forKey: date)
        } catch {
            writingCaptureUI.statusMessage = "Reject failed: \(error.localizedDescription)"
        }
        refreshWritingCapture()
    }

    private func refreshStaging() {
        // changes() 有 pending snapshot 时递归读 backup+live 两棵树全部 .md
        // 全文做 diff(events 树可达数千文件)—— 放后台跑,不卡主线程。
        // 300ms debounce:manual run 期间 attentionVersion 反复 bump 触发
        // reload→refreshStaging,连续触发合并成一次。
        stagingRefreshTask?.cancel()
        stagingRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let (e, p, s) = await Task.detached(priority: .userInitiated) {
                (MemoryStaging.changes(.events),
                 MemoryStaging.changes(.portrait),
                 MemoryStaging.changes(.personality))
            }.value
            guard !Task.isCancelled else { return }
            eventsChanges = e
            portraitChanges = p
            personalityChanges = s
        }
        refreshHasWork()
        refreshProbes()
    }

    /// 后台重算 body 要读的探测缓存:三个 in_progress bool(每个都是新开
    /// sqlite 连接全表扫 processing_log)+ 三个 hasPending bool(fileExists)。
    /// 跟 refreshHasWork 同模式,挂在 refreshStaging 这个既有刷新漏斗上
    /// (reload / run 收尾 / approve / reject 都会经过)。
    private func refreshProbes() {
        Task.detached(priority: .userInitiated) {
            let s = await MemoryScheduler.shared
            let e = s.hasInProgressRowForEvent()
            let d = s.hasInProgressRowForDistill()
            let p = s.hasInProgressRowForPersonality()
            let pe = MemoryStaging.hasPending(.events)
            let pp = MemoryStaging.hasPending(.portrait)
            let ps = MemoryStaging.hasPending(.personality)
            await MainActor.run {
                dbInProgressEvent = e
                dbInProgressDistill = d
                dbInProgressPersonality = p
                pendingEvents = pe
                pendingPortrait = pp
                pendingPersonality = ps
            }
        }
    }

    /// 重新算三个 job 当前有没有活。off-main 跑(扫 timeline+processing_log)。
    private func refreshHasWork() {
        Task.detached(priority: .userInitiated) {
            let s = await MemoryScheduler.shared
            let e = await s.eventJobHasWork()
            let d = await s.portraitJobHasWork()
            let p = await s.personalityJobHasWork()
            await MainActor.run {
                hasEventWork = e
                hasDistillWork = d
                hasPersonalityWork = p
            }
        }
    }

    // MARK: - Manual triggers

    @MainActor
    private func run(_ t: ManualTrigger) async {
        runningTriggers.insert(t)
        defer { runningTriggers.remove(t) }
        switch t {
        case .eventProcessing: await runEventProcessing()
        case .distill:         await runDistill()
        case .personality:     await runPersonalityRefresh()
        }
    }

    /// 走调度器的 runEventJob（与定时触发同一函数：pending-days + 上限 7 +
    /// 没活罢工）。跑前拍快照，跑完进审核。
    @MainActor
    private func runEventProcessing() async {
        guard MemoryScheduler.shared.eventJobHasWork() else {
            actionStatus = "All days already processed — nothing to run."
            return
        }
        do { try MemoryStaging.beginRun(.events) }
        catch { actionStatus = "Can't start: \(error.localizedDescription)"; return }

        actionStatus = "Processing events… (Backfill + impact rescore)"
        let outcome = await MemoryScheduler.shared.runEventJob(trigger: .runNow)
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.events, days: days)
            if !autoFinishEmptyStaging(.events, days: days) {
                actionStatus = "Run complete — review the staged changes below."
            }
        case .noWork:
            try? MemoryStaging.approve(.events)   // race: 活没了，丢快照
            actionStatus = "All days already processed — nothing to run."
        case .busy:
            try? MemoryStaging.approve(.events)
            actionStatus = "The scheduler is already running. Try again shortly."
        }
        refreshStaging()
    }

    /// 走调度器的 runPortraitJob。跑前拍快照，跑完进审核。
    @MainActor
    private func runDistill() async {
        guard MemoryScheduler.shared.portraitJobHasWork() else {
            actionStatus = "Portrait is already up to date — nothing to distill."
            return
        }
        do { try MemoryStaging.beginRun(.portrait) }
        catch { actionStatus = "Can't start: \(error.localizedDescription)"; return }

        actionStatus = "Distilling portrait from events…"
        let outcome = await MemoryScheduler.shared.runPortraitJob(trigger: .runNow)
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.portrait, days: days)
            if !autoFinishEmptyStaging(.portrait, days: days) {
                actionStatus = "Run complete — review the staged changes below."
            }
        case .noWork:
            try? MemoryStaging.approve(.portrait)
            actionStatus = "Portrait is already up to date — nothing to distill."
        case .busy:
            try? MemoryStaging.approve(.portrait)
            actionStatus = "The scheduler is already running. Try again shortly."
        }
        refreshStaging()
    }

    /// 走调度器的 runPersonalityJob。跑前拍快照,跑完进审核。
    @MainActor
    private func runPersonalityRefresh() async {
        guard MemoryScheduler.shared.personalityJobHasWork() else {
            actionStatus = "Personality is already up to date — nothing to refresh."
            return
        }
        do { try MemoryStaging.beginRun(.personality) }
        catch { actionStatus = "Can't start: \(error.localizedDescription)"; return }

        actionStatus = "Refreshing personality (events + portraits + OCR)…"
        let outcome = await MemoryScheduler.shared.runPersonalityJob(trigger: .runNow)
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.personality, days: days)
            if !autoFinishEmptyStaging(.personality, days: days) {
                actionStatus = "Run complete — review the staged changes below."
            }
        case .noWork:
            try? MemoryStaging.approve(.personality)
            actionStatus = "Personality is already up to date — nothing to refresh."
        case .busy:
            try? MemoryStaging.approve(.personality)
            actionStatus = "The scheduler is already running. Try again shortly."
        }
        refreshStaging()
    }

    // MARK: - 审核

    /// `.ran` 收尾:审核列表为空时自动收掉,不留"空 Pending review"逼用户点。
    ///   - 该 run 的天、该 kind 的阶段**全部 complete** → 只有机械重算 →
    ///     自动 Approve(机械改动直接落盘,不值得人工审)
    ///   - 有阶段没到 complete(LLM 失败 / raw 没收齐被跳过)→ 自动 Reject:
    ///     还原文件树 + 未完成的天翻回 pending,Run 按钮立刻可重试
    /// 有实质改动 → 返回 false,走正常人工审核。
    private func autoFinishEmptyStaging(_ kind: MemoryStaging.Kind, days: [String]) -> Bool {
        guard MemoryStaging.changes(kind).isEmpty else { return false }
        let stages = Self.stagesOwned(by: kind)
        let s = MemoryScheduler.shared
        let incomplete = days.filter { !s.stagesComplete(date: $0, stages: stages) }
        if incomplete.isEmpty {
            try? MemoryStaging.approve(kind)
            actionStatus = "Run complete — no content changes, nothing to review."
        } else {
            // 只重置没跑完的天;跑完但零产出的天保持 complete(树还原对它是 no-op)。
            for day in incomplete {
                s.resetStagesForReject(date: day, stages: stages)
            }
            try? MemoryStaging.reject(kind)
            actionStatus = "Run didn't finish — staged changes discarded, unfinished days reset to pending."
            attention = s.attentionDays()
        }
        refreshStaging()
        return true
    }

    private func approveStaging(_ kind: MemoryStaging.Kind) {
        do {
            try MemoryStaging.approve(kind)
            actionStatus = "Approved — changes committed."
        } catch {
            actionStatus = "Approve failed: \(error.localizedDescription)"
        }
        refreshStaging()
    }

    private func rejectStaging(_ kind: MemoryStaging.Kind) {
        // 先把 ProcessingLog 那几天重置回 pending，再用快照还原文件树。
        // 注意必须用 resetStagesForReject 而不是 resetDay:run **成功**后
        // 阶段是 complete,resetDay 不碰 complete → 树回滚了状态没回,
        // 这些天永不重跑(产出丢失 + Run 按钮灰死)。
        let stages = Self.stagesOwned(by: kind)
        for day in MemoryStaging.pendingDays(kind) {
            MemoryScheduler.shared.resetStagesForReject(date: day, stages: stages)
        }
        do {
            try MemoryStaging.reject(kind)
            actionStatus = "Rejected — changes discarded, those days are pending again."
        } catch {
            actionStatus = "Reject failed: \(error.localizedDescription)"
        }
        attention = MemoryScheduler.shared.attentionDays()
        refreshStaging()
    }

    /// 各 staging kind 对应的 ProcessingLog 阶段 —— Reject 回退只动这些,
    /// 不跨 kind 误伤(比如 reject events 不该把 personality 翻回 pending)。
    private static func stagesOwned(by kind: MemoryStaging.Kind) -> [ProcessingStage] {
        switch kind {
        case .events:      return [.raw, .event, .impact]
        case .portrait:    return [.distill]
        case .personality: return [.personality]
        case .classify:    return [.classify]
        }
    }

    /// 标题块直接用 SettingsPageTitle 跟其他 Settings 页对齐(尺寸 / 颜色
     /// / spacing 全部一份组件控制)。原来用自己的 Text + size 26 default
     /// primary 渲染,subtitle 12 .secondary —— 跟 General/Display 用的
     /// SettingsPageTitle(title 26 / 0.96, subtitle 13 / 0.55)视觉对不上。
     ///
     /// title 也从 "Memory · Parameter" / "Memory · Scheduler" 改成单词
     /// (Parameter / Scheduler / Changelog),跟左边 sidebar 一致 ——
     /// Capture 页那边右边 pane 就是 "Screen Capture" 单词没有 "Capture · "
     /// 前缀。
    private var header: some View {
        SettingsPageTitle(title: tab.rawValue, subtitle: headerBlurb)
    }

    private var headerBlurb: String {
        switch tab {
        case .parameter:
            return "Tune how the memory system weighs, consolidates, and forgets events. Changes write to `~/.portrait/config.toml` (debounced)."
        case .scheduler:
            return "Configure when the event and portrait pipelines run, and review days that need attention."
        case .changelog:
            return "Portrait body changes made by the distiller, newest first."
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(cfg.fileURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button("Reveal in Finder") {
                cfg.revealInFinder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 8)
    }

    // MARK: - Sections

    private static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    private var schedulerSection: some View {
        section(
            title: "Automatic processing",
            blurb: "Choose when each kind of processing runs: off, daily, weekly, or monthly. Times are local, and the oldest unprocessed days are handled first."
        ) {
            schedulerBlock(
                title: "Event processing",
                desc: "Clusters captured activity into events and scores their impact.",
                config: \.scheduler.event)
            Divider().padding(.vertical, 4)
            schedulerBlock(
                title: "Portrait distillation",
                desc: "Distills events into long-term portrait entries.",
                config: \.scheduler.portrait)
            Divider().padding(.vertical, 4)
            schedulerBlock(
                title: "Personality refresh",
                desc: "Aggregates events / other portraits / OCR into personality tags.",
                config: \.scheduler.personality)
            Divider().padding(.vertical, 4)
            schedulerBlock(
                title: "Writing capture",
                desc: "Finds the writing you did and prepares it for review. Automatic runs only prepare it — you still approve or reject it below.",
                config: \.scheduler.writingCapture)
            Divider().padding(.vertical, 4)
            schedulerBlock(
                title: "Writing style distillation",
                desc: "Learns your writing style (tone, voice, editing habits) from approved writing. Automatic runs save directly; manual runs stage drafts for review.",
                config: \.scheduler.writingStyle)
            Divider().padding(.vertical, 4)
            intRow("Max days processed per run (event and personality)",
                   value: cfg.binding(\.memory.eventDayCap),
                   range: 1...30)
        }
    }

    @ViewBuilder
    private func schedulerBlock(
        title: String,
        desc: String,
        config kp: WritableKeyPath<MyPortraitConfig, SchedulerConfig>
    ) -> some View {
        // 单一 Auto-run toggle —— 砍掉 Frequency/Time/Day 配置(它们对实际
        // 行为没影响:tick 周期 15min 固定,catchUp + backoff 自动接管 retry,
        // Time 只在"全 complete + 无 pending"才生效,基本是死配置)。
        // 老 ConfigSchema 字段(timeOfDay/dayOfWeek/dayOfMonth)留着不动 —
        // toml 向后兼容,UI 只暴露 on/off。
        let freq = cfg.binding(kp.appending(path: \.frequency))
        let autoRun = Binding<Bool>(
            get: { freq.wrappedValue != .off },
            set: { freq.wrappedValue = $0 ? .daily : .off }
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: autoRun)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(autoRun.wrappedValue
                        ? "Scheduler runs this pipeline automatically (15-min tick + backoff for retries)."
                        : "Manual only — runs only when you trigger it from Run now.")
            }
            Text(autoRun.wrappedValue
                ? "Auto — scheduler picks it up when there's pending work, retries failures with backoff."
                : "Manual only — runs only when you trigger it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Writing Capture(独立于 Memory pipeline 的 manualRunSection)

    /// 写作采集 worker 的 Run now UI。仿照 manualRunSection,但状态完全独立
    /// (走 WritingCaptureWorker.shared,不走 MemoryStaging)。
    /// 写作采集 worker 的 inline 子区块 —— 由 runNowSection 拼装,跟其它
     /// triggerRow 同形:title + desc + Run。alert / sheet 由 runNowSection 顶端挂。
    @ViewBuilder
    private var writingCaptureBlock: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Process writing capture")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Processes the writing you've done since the last approved batch and stages it for review.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                let wcHasPending = writingCapturePending.contains {
                    $0.dateUtc == WritingCaptureWorker.backlogDateKey
                }
                let wcDisabledReason: String? = {
                    if WritingCaptureWorker.shared == nil { return "Writing capture worker is not available." }
                    if writingCaptureUI.isRunning { return "Writing capture is already running." }
                    if wcHasPending { return "Pending review — Approve / Reject first." }
                    if !hasWritingCaptureWork { return "No new typing events since the last approved cursor." }
                    return nil
                }()
                Button(writingCaptureUI.isRunning ? "Running…" : "Run") {
                    writingCaptureConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(wcDisabledReason != nil)
                .help(wcDisabledReason ?? "Run writing capture backlog now.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if writingCaptureUI.isRunning {
                runningIndicator(writingCaptureUI.stage, onStop: { stopWritingCapture() })
            }
            if !writingCaptureUI.statusMessage.isEmpty {
                Text(writingCaptureUI.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    /// 停 writing capture:杀 LLM + cancel task + 标僵尸 run failed + 清运行态。
    private func stopWritingCapture() {
        let n = PiAgentRegistry.shared.stopGroup(PipelineOwner.writingCapture)
        writingCaptureUI.task?.cancel()
        writingCaptureUI.task = nil
        writingCaptureUI.isRunning = false
        // 把 DB 里卡在 processing 的 run 标 failed —— 否则下次 runBacklog 会报
        // "Backlog run already in progress" 拒绝。
        let zombies = (try? WritingCaptureWorker.shared?.store
            .markStuckProcessingAsFailed(message: "manually stopped by user")) ?? 0
        writingCaptureUI.statusMessage = "Stopped — killed \(n) LLM process(es), marked \(zombies) run(s) as failed."
        refreshWritingCapture()
    }

    /// Writing capture 的结果区块 —— 由 reviewSection(统一 Pending 区)渲染,
    /// 不再 inline 在 Run now。字体跟 memory reviewBlock 对齐(普通字体)。
    @ViewBuilder
    private var writingCaptureResultBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Writing capture").font(.system(size: 13, weight: .semibold))
            if let s = writingCaptureUI.lastSummary {
                Text("Last run: \(s.recordsCount) records · \(s.discardedCount) discarded · \(s.status.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(s.status == .failed ? .red : .secondary)
            }
            ForEach(writingCapturePending, id: \.dateUtc) { run in
                let expanded = writingCaptureExpanded.contains(run.dateUtc)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            let title = run.dateUtc == WritingCaptureWorker.backlogDateKey
                                ? "Backlog" : run.dateUtc
                            Text(title).font(.system(size: 12, weight: .medium))
                            Text("\(run.recordsCount ?? 0) records · \(run.discardedCount ?? 0) discarded — click to \(expanded ? "collapse" : "expand")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleWritingCaptureExpand(date: run.dateUtc) }
                        Button("Detail") { writingCapturePreviewDate = run.dateUtc }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Reject") {
                            Task { @MainActor in await rejectWritingCapture(date: run.dateUtc) }
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                        Button("Approve") {
                            Task { @MainActor in await approveWritingCapture(date: run.dateUtc) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if expanded {
                        inlineRecordsList(date: run.dateUtc)
                            .padding(.leading, 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Writing style(独立链路,跟 writing capture 同模式)

    /// writing_style 提炼链路的 inline 子区块。manual 模式 = staged + pending
    /// review;auto 模式由 scheduler 自动跑,直接落 portrait/writing_style/。
    /// alert / sheet 由 runNowSection 顶端挂。跟其它 triggerRow 同形。
    @ViewBuilder
    private var writingStyleBlock: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Distill writing style")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Learns your writing style (tone, voice, editing habits) from approved writing. Up to \(WritingStyleDistiller.defaultBatchCap) pieces per run · \(writingStyleUnprocessed) still to process. Manual runs stage drafts; automatic runs save directly.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                let ssHasPending = !writingStylePending.isEmpty
                let ssDisabledReason: String? = {
                    if WritingStyleDistiller.shared == nil { return "Writing style distiller is not available." }
                    if writingStyleUI.isRunning { return "Writing style is already running." }
                    if ssHasPending { return "Pending review — Approve / Reject first." }
                    if writingStyleUnprocessed == 0 {
                        return "Nothing to distill — run writing capture first to produce writing_records."
                    }
                    return nil
                }()
                Button(writingStyleUI.isRunning ? "Running…" : "Run") {
                    writingStyleConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(ssDisabledReason != nil)
                .help(ssDisabledReason ?? "Run writing style distillation (manual mode, staged for review).")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if writingStyleUI.isRunning {
                runningIndicator(writingStyleUI.stage, onStop: { stopWritingStyle() })
            }
            if !writingStyleUI.statusMessage.isEmpty {
                Text(writingStyleUI.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    /// 停 writing style:杀 LLM + cancel task + 标僵尸 run failed + 清运行态。
    private func stopWritingStyle() {
        let n = PiAgentRegistry.shared.stopGroup(PipelineOwner.writingStyle)
        writingStyleUI.task?.cancel()
        writingStyleUI.task = nil
        writingStyleUI.isRunning = false
        let zombies = (try? WritingStyleDistiller.shared?.store
            .markStuckProcessingAsFailed(message: "manually stopped by user")) ?? 0
        writingStyleUI.statusMessage = "Stopped — killed \(n) LLM process(es), marked \(zombies) run(s) as failed."
        refreshWritingStyle()
    }

    /// Writing style 的结果区块 —— 由 reviewSection 统一渲染。字体跟
    /// memory reviewBlock 对齐。
    @ViewBuilder
    private var writingStyleResultBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Writing style").font(.system(size: 13, weight: .semibold))
            ForEach(writingStylePending, id: \.runId) { run in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("\(run.recordsCount ?? 0) records · \(run.draftsCount ?? 0) drafts")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reject") {
                            Task { @MainActor in await rejectWritingStyle(runId: run.runId) }
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                        Button("Approve") {
                            Task { @MainActor in await approveWritingStyle(runId: run.runId) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    inlineWritingStyleDrafts(runId: run.runId)
                        .onAppear { ensureWritingStyleDraftsLoaded(runId: run.runId) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 第一次展示 drafts 时按需 fetch(避免每帧重查 DB)。
    private func ensureWritingStyleDraftsLoaded(runId: String) {
        if writingStyleExpandedDrafts[runId] != nil { return }
        guard let distiller = WritingStyleDistiller.shared else { return }
        let store = distiller.store
        Task.detached(priority: .userInitiated) {
            let rows = (try? store.fetchStaged(runId: runId)) ?? []
            await MainActor.run { writingStyleExpandedDrafts[runId] = rows }
        }
    }

    /// 跟 event/portrait/personality 的 changeRow 同样的形态:NEW/CHANGED
    /// 标签 + 单行标题 + chevron → 点击直接打开 Detail sheet 看完整 body。
    /// 之前的卡片样式预览只截 200 字 + 没 diff,update 看着像没变化。
    @ViewBuilder
    private func inlineWritingStyleDrafts(runId: String) -> some View {
        if let rows = writingStyleExpandedDrafts[runId] {
            if rows.isEmpty {
                Text("(no drafts)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.id) { d in
                        writingStyleDraftRow(d, parentRunId: runId)
                    }
                }
            }
        } else {
            Text("Loading…")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// 一条 draft 的行:`[NEW|CHANGED|NOOP] <title>` + chevron → 整行点击
    /// 打开 detail sheet,跟 changeRow 视觉一致。
    private func writingStyleDraftRow(_ d: WritingStyleStagedRow, parentRunId: String) -> some View {
        let (label, color): (String, Color) = {
            switch d.action {
            case .create: return ("NEW", .green)
            case .update: return ("CHANGED", .orange)
            case .noop:   return ("NOOP", .gray)
            }
        }()
        _ = parentRunId    // 不再用 —— 改成 per-draft preview。
        return Button {
            writingStylePreviewDraft = d
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 62, alignment: .leading)
                Text(d.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func refreshWritingStyle() {
        guard let distiller = WritingStyleDistiller.shared else { return }
        let store = distiller.store
        Task.detached(priority: .userInitiated) {
            let pending = (try? store.fetchPendingReviewRuns()) ?? []
            let unprocessed = (try? store.unprocessedCount()) ?? 0
            await MainActor.run {
                writingStylePending = pending
                writingStyleUnprocessed = unprocessed
            }
        }
    }

    @MainActor
    private func runWritingStyleManual() async {
        guard let distiller = WritingStyleDistiller.shared else {
            writingStyleUI.statusMessage = "Distiller not initialized."
            return
        }
        writingStyleUI.isRunning = true
        writingStyleUI.stage = "Analyzing writing"
        writingStyleUI.statusMessage = ""
        defer {
            writingStyleUI.isRunning = false
            writingStyleUI.stage = ""
            refreshWritingStyle()
        }
        do {
            let s = try await distiller.runManual()
            writingStyleUI.statusMessage = "Done — status=\(s.status.rawValue) records=\(s.recordsCount) drafts=\(s.draftsCount)"
            recordWritingRun("Speech style", s.recordsCount > 0 ? "success" : "no-work")
        } catch {
            writingStyleUI.statusMessage = "Failed: \(error.localizedDescription)"
            recordWritingRun("Speech style", "failure", reason: error.localizedDescription)
        }
    }

    @MainActor
    private func approveWritingStyle(runId: String) async {
        guard let distiller = WritingStyleDistiller.shared else { return }
        do {
            let n = try distiller.approveStaged(runId: runId)
            writingStyleUI.statusMessage = "Approved \(String(runId.prefix(8))) — \(n) draft(s) applied to portrait/writing_style/."
            writingStyleExpandedDrafts.removeValue(forKey: runId)
        } catch {
            writingStyleUI.statusMessage = "Approve failed: \(error.localizedDescription)"
        }
        refreshWritingStyle()
    }

    @MainActor
    private func rejectWritingStyle(runId: String) async {
        guard let distiller = WritingStyleDistiller.shared else { return }
        do {
            try distiller.rejectStaged(runId: runId)
            writingStyleUI.statusMessage = "Rejected \(String(runId.prefix(8))) — staged cleared, records left unprocessed."
            writingStyleExpandedDrafts.removeValue(forKey: runId)
        } catch {
            writingStyleUI.statusMessage = "Reject failed: \(error.localizedDescription)"
        }
        refreshWritingStyle()
    }

    /// 展开 / 折叠某天的内联 record 列表。第一次展开时异步加载。
    private func toggleWritingCaptureExpand(date: String) {
        if writingCaptureExpanded.contains(date) {
            writingCaptureExpanded.remove(date)
            return
        }
        writingCaptureExpanded.insert(date)
        // 已缓存就不再加载
        if writingCaptureExpandedRecords[date] != nil { return }
        guard let worker = WritingCaptureWorker.shared else {
            writingCaptureExpandedError[date] = "Worker not initialized"
            return
        }
        let store = worker.store
        Task.detached(priority: .userInitiated) {
            do {
                let rows = try store.fetchStagedRecords(date: date)
                await MainActor.run { writingCaptureExpandedRecords[date] = rows }
            } catch {
                await MainActor.run { writingCaptureExpandedError[date] = error.localizedDescription }
            }
        }
    }

    /// 内联展开的 record 列表(每条:app · kind · text 前 200 字)。
    @ViewBuilder
    private func inlineRecordsList(date: String) -> some View {
        if let err = writingCaptureExpandedError[date] {
            Text("Load failed: \(err)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red)
        } else if let rows = writingCaptureExpandedRecords[date] {
            if rows.isEmpty {
                Text("(no records)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.id) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(r.app).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(r.kind).font(.system(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15))
                                    .cornerRadius(3)
                                Text(String(format: "conf %.2f", r.confidence))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if let cs = r.contextSummary, !cs.isEmpty {
                                Text(cs).font(.system(size: 10))
                                    .foregroundStyle(.secondary).italic()
                            }
                            Text(r.text.count > 200
                                 ? String(r.text.prefix(200)) + "…"
                                 : r.text)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(4)
                    }
                }
            }
        } else {
            Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @MainActor
    /// run-now writing 路径记一条 pipeline_runs(trigger=run-now)。off-main 写,
    /// 跟 reload 的 recentPipelineRuns 同一张表 → Changelog 页能看到。
    private func recordWritingRun(_ pipeline: String, _ outcome: String, reason: String? = nil) {
        Task.detached {
            ProcessingLogStore().appendPipelineRun(trigger: "run-now", pipeline: pipeline, outcome: outcome, reason: reason)
        }
    }

    private func runWritingCapture() async {
        guard let worker = WritingCaptureWorker.shared else {
            writingCaptureUI.statusMessage = "Worker not initialized (Services not started yet?)."
            return
        }
        writingCaptureUI.isRunning = true
        writingCaptureUI.statusMessage = ""
        defer {
            writingCaptureUI.isRunning = false
            writingCaptureUI.stage = ""
        }
        do {
            let s = try await worker.runBacklog()
            writingCaptureUI.lastSummary = s
            switch s.status {
            case .approved:
                writingCaptureUI.statusMessage = "No new data since last cursor — nothing staged."
                recordWritingRun("Writing capture", "no-work")
            case .pendingReview:
                writingCaptureUI.statusMessage =
                    "Done. \(s.recordsCount) record(s) / \(s.discardedCount) discarded — pending review below."
                recordWritingRun("Writing capture", "success")
            case .failed:
                writingCaptureUI.statusMessage = "Failed: \(s.errorMessage ?? "(unknown)")"
                recordWritingRun("Writing capture", "failure", reason: s.errorMessage)
            default:
                writingCaptureUI.statusMessage = "Status: \(s.status.rawValue)"
                recordWritingRun("Writing capture", "success")
            }
        } catch {
            writingCaptureUI.statusMessage = "Run failed: \(error.localizedDescription)"
            recordWritingRun("Writing capture", "failure", reason: error.localizedDescription)
        }
        refreshWritingCapture()
    }

    // MARK: - Memory pipeline 的 manualRunSection(原有)

    /// 统一的 Run now 卡片 —— 把 memory pipeline 3 个 trigger + writing capture
     /// + writing style distillation 全揉进一张卡,用 divider 分组。各自的 sheet /
     /// alert 全部挂在这张卡的最外层。
    private var runNowSection: some View {
        section(
            title: "Run now",
            blurb: "Run a step now instead of waiting for the schedule. Each one uses AI, so you'll be asked to confirm first."
        ) {
            // Memory pipeline 三个 trigger
            triggerRow(.eventProcessing)
            Divider().padding(.vertical, 2)
            triggerRow(.distill)
            Divider().padding(.vertical, 2)
            triggerRow(.personality)
            if !actionStatus.isEmpty {
                Text(actionStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

            // Event classifier(自动分 folder)已下线 —— chat AI 通过 mp-folders
            // 按用户对话需求整理,UI 不再挂 Run 按钮。

            // —— Writing capture(独立链路,跟 memory pipeline 不互锁)
            Divider().padding(.vertical, 2)
            writingCaptureBlock

            // —— Writing style distillation(独立链路)
            Divider().padding(.vertical, 2)
            writingStyleBlock
        }
        // 三种 sheet / alert 统一挂在最外层 —— 内层 block 只负责触发对应 @State。
        .sheet(item: $writingCapturePreviewDate.mappedToIdentifiable) { wrapped in
            WritingCapturePreview(date: wrapped.id)
        }
        .sheet(item: $writingStylePreviewRun.mappedToIdentifiable) { wrapped in
            WritingStylePreview(runId: wrapped.id)
        }
        // Per-draft sheet:点单条 NEW/CHANGED 行打开,只显示这一条 draft 详情。
        .sheet(item: $writingStylePreviewDraft) { draft in
            WritingStyleDraftDetail(draft: draft)
        }
        .alert("Run writing capture?", isPresented: $writingCaptureConfirm) {
            Button("Run", role: .none) {
                writingCaptureUI.task = Task { @MainActor in await runWritingCapture() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Process all your writing since the last approved batch. This uses AI and the results are staged for you to review.")
        }
        .alert("Run writing style distillation?", isPresented: $writingStyleConfirm) {
            Button("Run", role: .none) {
                writingStyleUI.task = Task { @MainActor in await runWritingStyleManual() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Analyze up to \(WritingStyleDistiller.defaultBatchCap) unprocessed pieces of your writing with AI. Drafts are staged for you to review.")
        }
    }

    private func triggerRow(_ t: ManualTrigger) -> some View {
        // 自己是不是正在跑(本 View 自己的并发 token 集合 = runningTriggers)。
        let selfRunning = runningTriggers.contains(t)
        // scheduler 后台 catch-up 触发的 run 不经过本 View click → 不在
        // runningTriggers 里。只看本 trigger 对应的 scheduler flag(不跨类型 OR),
        // 即使某一 @Observable flag 卡住也只影响那一个按钮,不会三按钮连锁灰。
        // 真实运行状态 = in-memory flag **AND** DB 真有 in_progress row。
        // in-memory 单飞会被 stale 欺骗(runStep 内 await 死 hang → defer
        // eventRunning=false 不执行 → 用户永远看到 "Running"),DB 是真相。
        // 两者 AND:in-memory 抑制并发 + DB 抑制 stale。
        let s = MemoryScheduler.shared
        let memFlag: Bool = {
            switch t {
            case .eventProcessing: return s.eventRunning
            case .distill:         return s.distillRunning
            case .personality:     return s.personalityRunning
            }
        }()
        // 读缓存,不在 body 里现查 DB(refreshProbes 在既有刷新点后台重算)。
        let dbInProgress: Bool = {
            switch t {
            case .eventProcessing: return dbInProgressEvent
            case .distill:         return dbInProgressDistill
            case .personality:     return dbInProgressPersonality
            }
        }()
        let schedulerSelfRunning = memFlag && dbInProgress
        let actuallyRunning = selfRunning || schedulerSelfRunning
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 13, weight: .semibold))
                    Text(t.desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                // 读缓存,不在 body 里做 fileExists 同步 IO。
                let pending: Bool = {
                    switch t {
                    case .eventProcessing: return pendingEvents
                    case .distill:         return pendingPortrait
                    case .personality:     return pendingPersonality
                    }
                }()
                let schedulerReason = schedulerBlockReason(for: t)
                // 有没有活要干 —— 全 complete / dead_letter 时按钮该灰,避免误点。
                let hasWork: Bool = {
                    switch t {
                    case .eventProcessing: return hasEventWork
                    case .distill:         return hasDistillWork
                    case .personality:     return hasPersonalityWork
                    }
                }()
                let noWorkReason: String? = {
                    switch t {
                    case .eventProcessing: return "All processed days are already complete — nothing to run."
                    case .distill:         return "Portrait is already up to date — nothing to distill."
                    case .personality:     return "Personality is already up to date — nothing to refresh."
                    }
                }()
                let disabledReason: String? = {
                    if actuallyRunning { return "\(t.title) is already running." }
                    if pending     { return "Pending review — Approve / Reject first." }
                    if let r = schedulerReason { return r }
                    if !hasWork    { return noWorkReason }
                    return nil
                }()
                let label: String = {
                    if actuallyRunning { return "Running…" }
                    if pending     { return "Pending review" }
                    return "Run"
                }()
                Button(label) {
                    confirmTrigger = t
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(disabledReason != nil)
                .help(disabledReason ?? "Trigger \(t.title) now.")
            }
            // 每条 trigger 自己的 inline 运行指示(实时阶段 + Stop)。
            if actuallyRunning {
                runningIndicator(triggerStage(t), onStop: { stopTrigger(t) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// spinner + "N jobs running…" + Stop all 行。同时考虑本 View 触发的 +
    /// scheduler 后台触发的 run —— 之前只看 runningTriggers,scheduler tick
    /// 跑起来时按钮显示 Running… 但没 spinner / 没 Stop,看着像卡死。
    /// 统一的运行指示:spinner + 当前阶段文案 + Stop。三类 pipeline 共用 ——
    /// 字体 / 布局 / 按钮一致。
    @ViewBuilder
    private func runningIndicator(_ stage: String, onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(stage.isEmpty ? "Running…" : stage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Stop", action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
        }
        .padding(.top, 6)
    }

    /// 某 memory trigger 当前阶段(scheduler 实时发布,跑时逐步推进)。
    private func triggerStage(_ t: ManualTrigger) -> String {
        let s = MemoryScheduler.shared
        switch t {
        case .eventProcessing: return s.eventStage
        case .distill:         return s.distillStage
        case .personality:     return s.personalityStage
        }
    }

    /// 停某个 memory trigger:杀 LLM 子进程 + cancel 它的 task + 清运行态。
    /// PiAgentRegistry.stopAll 会杀全部 LLM(无法只杀单条),跟 writing block 一致。
    private func stopTrigger(_ t: ManualTrigger) {
        let owner: String = {
            switch t {
            case .eventProcessing: return PipelineOwner.event
            case .distill:         return PipelineOwner.distill
            case .personality:     return PipelineOwner.personality
            }
        }()
        let n = PiAgentRegistry.shared.stopGroup(owner)
        runTasks[t]?.cancel()
        runTasks[t] = nil
        runningTriggers.remove(t)
        actionStatus = "Stopped — killed \(n) LLM process(es)."
    }

    /// UI 阻塞原因 —— 只看本 View 自己的 `runningTriggers`(用户点击驱动,
     /// run 完 defer 清,绝对不会卡)。**故意不读** scheduler 的
     /// eventRunning/distillRunning/personalityRunning in-memory flag —— 历史
     /// 上观察到 event job 返回后 @Observable flag 偶发不清,导致三个按钮一起
     /// 灰回不来。scheduler 的真实并发把关由 `runXxxJob` 里 `guard canRunXxx`
     /// 兜底:用户硬点上去也只是走 `.busy` 分支弹 status,不会真的双跑。
     /// 互斥规则跟 MemoryScheduler 一致:
     ///   - event 独占,跟 distill/personality 互斥
     ///   - distill 跟 distill 互斥(自身不重入)
     ///   - personality 跟 personality 互斥(自身不重入)
     ///   - distill 跟 personality 可以并行
    private func schedulerBlockReason(for t: ManualTrigger) -> String? {
        let eventRun       = runningTriggers.contains(.eventProcessing)
        let distillRun     = runningTriggers.contains(.distill)
        let personalityRun = runningTriggers.contains(.personality)
        switch t {
        case .eventProcessing:
            if distillRun || personalityRun { return "Waiting for distill / personality to finish." }
            return nil
        case .distill:
            if eventRun { return "Waiting for event job to finish." }
            return nil
        case .personality:
            if eventRun { return "Waiting for event job to finish." }
            return nil
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        // **跑步中不显示 Pending review 卡片** —— beginRun 拍快照那一刻
        // hasPending=true,但 runEventJob 还没产 .md,卡片显示"No content
        // changes" + Reject/Approve 误导用户。等真跑完(scheduler 标 idle +
        // 本 View 触发器集合也空)才呈现可审核状态。
        // 跟 triggerRow 同口径:in-memory flag AND DB 真有 in_progress
        // (避免 stale flag 让 reviewSection 误以为还在跑而藏住 pending review)。
        // in_progress / hasPending 都读缓存(refreshProbes 后台重算),
        // 不在 body 里现查 DB / fileExists。
        let s = MemoryScheduler.shared
        let eventsRunning = runningTriggers.contains(.eventProcessing)
            || (s.eventRunning && dbInProgressEvent)
        let portraitRunning = runningTriggers.contains(.distill)
            || (s.distillRunning && dbInProgressDistill)
        let personalityRunning = runningTriggers.contains(.personality)
            || (s.personalityRunning && dbInProgressPersonality)
        let hasEvents = pendingEvents && !eventsRunning
        let hasPortrait = pendingPortrait && !portraitRunning
        let hasPersonality = pendingPersonality && !personalityRunning
        // Writing capture / style 也归这里(同 memory 一样,跑步中不显示)。
        let hasWritingCapture = (!writingCapturePending.isEmpty || writingCaptureUI.lastSummary != nil)
            && !writingCaptureUI.isRunning
        let hasWritingStyle = !writingStylePending.isEmpty && !writingStyleUI.isRunning
        let anyMemory = hasEvents || hasPortrait || hasPersonality
        if anyMemory || hasWritingCapture || hasWritingStyle {
            section(
                title: "Pending review",
                blurb: "Results from a run are staged, not saved yet. Click an item to preview. Approve keeps it; Reject discards it."
            ) {
                if hasEvents {
                    reviewBlock(.events, "Process events", eventsChanges)
                }
                if hasEvents && (hasPortrait || hasPersonality) {
                    Divider().padding(.vertical, 6)
                }
                if hasPortrait {
                    reviewBlock(.portrait, "Distill portrait", portraitChanges)
                }
                if hasPortrait && hasPersonality {
                    Divider().padding(.vertical, 6)
                }
                if hasPersonality {
                    reviewBlock(.personality, "Refresh personality", personalityChanges)
                }
                if hasWritingCapture {
                    if anyMemory { Divider().padding(.vertical, 6) }
                    writingCaptureResultBlock
                }
                if hasWritingStyle {
                    if anyMemory || hasWritingCapture { Divider().padding(.vertical, 6) }
                    writingStyleResultBlock
                }
            }
        }
    }

    private func reviewBlock(_ kind: MemoryStaging.Kind,
                             _ title: String,
                             _ changes: [MemoryStaging.StagedChange]) -> some View {
        let newN = changes.filter(\.isNew).count
        let modN = changes.count - newN
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(changes.isEmpty
                         ? "No content changes — only mechanical weight recomputation."
                         : "\(newN) new, \(modN) changed — click a file to preview.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Reject") { rejectStaging(kind) }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
                Button("Approve") { approveStaging(kind) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            ForEach(changes) { ch in
                changeRow(ch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeRow(_ ch: MemoryStaging.StagedChange) -> some View {
        Button { previewChange = ch } label: {
            HStack(spacing: 8) {
                Text(ch.isNew ? "NEW" : "CHANGED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(ch.isNew ? Color.green : Color.orange)
                    .frame(width: 62, alignment: .leading)
                Text(ch.displayTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private var attentionSection: some View {
        // scheduler.attentionVersion 是 @Observable 计数 —— runStep success /
        // failed / recoverPausedJobs / dismissDay 等都会 bump 它。下面 .task(id:)
        // 监听这个版本号,变化时自动 reload(),retry 成功后 attention 行不再
        // 卡死,自动消失。
        let version = MemoryScheduler.shared.attentionVersion
        return section(
            title: "Needs attention",
            blurb: "Days that failed, hit a budget limit, or gave up after repeated tries. Reset moves a day back to pending so the next run tries it again."
        ) {
            if attention.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("All processed days are healthy.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(attention) { item in
                    attentionRow(item)
                }
            }
        }
        // 版本号变 → 自动 reload。version 引用让 SwiftUI 跟踪 @Observable。
        .task(id: version) {
            // 首次 mount(version=0)init 时已被 main task 调过 reload();
            // 但 version 变化时这条会重跑,刷新 attention 列表。
            reload()
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: MemoryScheduler.AttentionItem) -> some View {
        // 拿这 row 任一 problem stage 的 last failure kind(in-memory,进程重启丢)。
        // 优先 user-required kind,没有取第一个 transient kind,都没就 nil。
        let scheduler = MemoryScheduler.shared
        let kinds: [LLMFailureKind] = item.problems.compactMap {
            scheduler.lastFailureKind(date: item.date, stage: $0.stage)
        }
        let userKind = kinds.first { $0.isUserRequired }
        let transientKind = kinds.first { !$0.isUserRequired }
        let title = Self.attentionTitle(item.date)
        let problemText = item.problems
            .map { "\(Self.stageLabel($0.stage)): \(Self.statusLabel($0.status))" }
            .joined(separator: " · ")

        // 行号 row 的精确状态(找最新 updated row,给 nextRetryLabel 用)。
        // 读缓存 —— reload 的后台任务跟 attention 列表一起算好,不在 body 里逐行查 DB。
        let dbRow = attentionDbRows[item.date]

        if let kind = userKind {
            // ─── 桶 B:user-required → 红 banner + Problem solved 按钮 ───
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(kind.userMessage)
                        .font(.system(size: 11)).foregroundStyle(.primary)
                    Text("\(kind.shortLabel) · \(problemText)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // 完整 raw error reason(LLM / 网络 / DB 的原始 message)
                    // — 用户可以对症下药 / 复制反馈。
                    if let reason = kind.reasonDetail, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
                Spacer()
                Button("Dismiss") {
                    MemoryScheduler.shared.dismissDay(item.date)
                    reload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Mark complete — stop retrying this day")
                Button("Problem solved") {
                    MemoryScheduler.shared.resetDay(item.date)
                    reload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .help("Reset to pending — scheduler will retry on next tick")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.25), lineWidth: 0.7))
            )
        } else if let kind = transientKind {
            // ─── 桶 A:auto-recovering → 灰色信息行 + 无按钮 ───
            let nextLabel = dbRow.map {
                scheduler.nextRetryLabel(retryCount: $0.retryCount, updatedAtMs: $0.updatedAtMs)
            } ?? "next tick"
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text("Auto-recovering · next retry \(nextLabel)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("\(kind.shortLabel) · \(problemText)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let reason = kind.reasonDetail, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
                Spacer()
                Text("retry \(item.retryCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button("Dismiss") {
                    MemoryScheduler.shared.dismissDay(item.date)
                    reload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Mark complete — stop retrying this day")
            }
            .padding(.vertical, 2)
        } else {
            // ─── Fallback:没 kind 信息(进程刚重启 / DB 老行)→ 老样式 + Reset ───
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(problemText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("retry \(item.retryCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button("Dismiss") {
                    MemoryScheduler.shared.dismissDay(item.date)
                    reload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Mark complete — stop retrying this day")
                Button("Reset") {
                    MemoryScheduler.shared.resetDay(item.date)
                    reload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset to pending — scheduler will retry on next tick")
            }
        }
    }

    /// 把内部阶段名翻成给用户看的人话(「Needs attention」行用)。
    private static func stageLabel(_ s: ProcessingStage) -> String {
        switch s {
        case .raw:         return "Data prep"
        case .event:       return "Events"
        case .impact:      return "Scoring"
        case .classify:    return "Organizing"
        case .distill:     return "Portrait"
        case .personality: return "Personality"
        }
    }

    /// 把内部状态翻成人话。failed / budget_deferred / dead_letter 是这里唯一
    /// 会出现的三种(见 MemoryScheduler.attentionItems)。
    private static func statusLabel(_ s: ProcessingStatus) -> String {
        switch s {
        case .failed:         return "Failed"
        case .budgetDeferred: return "Paused (daily budget)"
        case .deadLetter:     return "Gave up after retries"
        default:              return s.rawValue
        }
    }

    /// anchor 行标题翻译。三个 anchor 都处理,否则会原样显示 _xxx_anchor。
    private static func attentionTitle(_ date: String) -> String {
        switch date {
        case ProcessingLogStore.distillAnchorDate:     return "Portrait update"
        case ProcessingLogStore.personalityAnchorDate: return "Personality update"
        case ProcessingLogStore.classifyAnchorDate:    return "Organizing events"
        default:                                        return date
        }
    }

    /// Memory pipeline 用哪个 AI provider + 哪两档 model。改完立即生效
    ///(scheduler 每次跑都现读 config),无需重启 app。
    ///
    /// 可选项跟 Settings → AI Models 联动:在那边关掉的 provider 这里就不
    /// 列;每个 provider 的 model 下拉也只列那边勾上的子集。AI Models 那边
    /// 完全没勾过 = 走 provider 全量(向后兼容)。
    private var providerSection: some View {
        let aiCfg = cfg.current.aiModels
        // Provider 列表:要同时满足
        //   1) Connections 里已连上(appState.connectedIds 有 integrationId)
        //   2) AI Models 那边没被 toggle off(disabledProviderIds 不含)
        // 跟 Settings → AI Models 用同一套谓词,避免出现「没连接的 provider
        // 也能选中给 memory pipeline 用」。
        let availableProviders = Provider.allCases.filter {
            appState.isConnected($0.integrationId)
            && !aiCfg.disabledProviderIds.contains($0.integrationId)
        }
        let providerId = cfg.current.memory.providerId
        let selectedProvider = Provider(rawValue: providerId) ?? .chatgpt
        // Model 列表:走 AIModelsConfig.visibleModels(空 / 缺省 = 全量)。
        let models = aiCfg.visibleModels(
            forIntegrationId: selectedProvider.integrationId,
            available: selectedProvider.availableModels
        )

        return section(
            title: "AI provider",
            blurb: "Which AI model powers the memory features. The list comes from Settings → AI Models, so disable a provider or hide a model there to remove it here. Changes take effect on the next run."
        ) {
            if availableProviders.isEmpty {
                Text("All AI providers are disabled in Settings → AI Models. Enable at least one to run the memory pipeline.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    Text("Provider")
                        .font(.system(size: 12))
                        .frame(maxWidth: 280, alignment: .leading)
                    Picker("", selection: cfg.binding(\.memory.providerId)) {
                        ForEach(availableProviders, id: \.rawValue) { p in
                            Text(Self.providerDisplayName(p)).tag(p.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Text("Main model (heavy tasks)")
                        .font(.system(size: 12))
                        .frame(maxWidth: 280, alignment: .leading)
                    Picker("", selection: cfg.binding(\.memory.model)) {
                        ForEach(models, id: \.self) { m in Text(m).tag(m) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Text("Light model (clustering / writing capture)")
                        .font(.system(size: 12))
                        .frame(maxWidth: 280, alignment: .leading)
                    Picker("", selection: cfg.binding(\.memory.modelLight)) {
                        ForEach(models, id: \.self) { m in Text(m).tag(m) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private static func providerDisplayName(_ p: Provider) -> String {
        switch p {
        case .chatgpt:     return "Codex (ChatGPT Pro / Plus OAuth)"
        case .openaiBYOK:  return "OpenAI (API key)"
        case .anthropic:   return "Anthropic (API key)"
        case .ollama:      return "Ollama (local)"
        case .gemini:      return "Gemini (API key)"
        case .perplexity:  return "Perplexity (API key)"
        case .deepseek:    return "DeepSeek (API key)"
        case .claudeCode:  return "Claude Code CLI (Pro / Max subscription)"
        }
    }

    private var budgetSection: some View {
        section(
            title: "Daily consolidation budget",
            blurb: "A daily cap on how much each day can add to your memory. Busy days are trimmed back to the cap, while quiet days are left alone."
        ) {
            doubleRow("Daily budget (sum of impacts per day)",
                      value: cfg.binding(\.memory.dailyBudget),
                      range: 10...200, step: 1)
            doubleRow("Peak protection (raw ≥ this is never scaled)",
                      value: cfg.binding(\.memory.peakProtection),
                      range: 3.0...5.0, step: 0.1)
            intRow("Max re-touches per event before freezing",
                   value: cfg.binding(\.memory.maxRebalances),
                   range: 1...20)
            intRow("Window (days)",
                   value: cfg.binding(\.memory.windowDays),
                   range: 1...30)
        }
    }

    private var decaySection: some View {
        section(
            title: "Weight decay",
            blurb: "Controls how quickly older memories fade. A higher value forgets faster."
        ) {
            doubleRow("α (decay exponent)",
                      value: cfg.binding(\.memory.alpha),
                      range: 0.05...1.0, step: 0.05)
            doubleRow("Minimum weight floor",
                      value: cfg.binding(\.memory.minWeight),
                      range: 0...0.5, step: 0.01)
        }
    }

    private var archiveSection: some View {
        section(
            title: "Archival rule",
            blurb: "When a memory falls below both limits and isn't pinned, it's moved to the archive."
        ) {
            doubleRow("Max weight",
                      value: cfg.binding(\.memory.archiveMaxWeight),
                      range: 0.001...0.5, step: 0.01)
            intRow("Min days idle",
                   value: cfg.binding(\.memory.archiveMinDaysIdle),
                   range: 7...365)
        }
    }

    private var distillationSection: some View {
        section(
            title: "Distillation",
            blurb: "How much new evidence is needed before a portrait section updates. A lower value reacts faster; a higher value stays more stable."
        ) {
            intRow("Portrait evidence threshold",
                   value: cfg.binding(\.memory.distillEvidenceThreshold),
                   range: 1...10)
        }
    }

    private var changelogSection: some View {
        section(
            title: "Pipeline run history",
            blurb: "The last 50 memory-pipeline runs — Run now and scheduled, newest first."
        ) {
            if changelog.isEmpty {
                Text("No pipeline runs recorded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(changelog) { entry in
                    changelogRow(entry)
                }
            }
        }
    }

    /// outcome → (展示文案, 颜色)。
    private static func runOutcomeStyle(_ outcome: String) -> (label: String, color: Color) {
        switch outcome {
        case "success":         return ("success", .green)
        case "failure":         return ("failure", .red)
        case "auto-recovering": return ("auto-recovering", .orange)
        case "no-work":         return ("no work", .gray)
        default:                return (outcome, .gray)
        }
    }

    private func changelogRow(_ entry: ProcessingLogStore.PipelineRunRecord) -> some View {
        let date = Date(timeIntervalSince1970: Double(entry.timestampMs) / 1000)
        let style = Self.runOutcomeStyle(entry.outcome)
        let triggerLabel = entry.trigger == "run-now" ? "Run now" : "Scheduled"
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(triggerLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                    Text(entry.pipeline)
                        .font(.system(size: 11, weight: .medium))
                }
                HStack(spacing: 4) {
                    Text(Self.changelogDateFmt.string(from: date))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("·").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(style.label + (entry.reason.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(style.color)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let changelogDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - Components

    @ViewBuilder
    private func section<C: View>(title: String,
                                  blurb: String,
                                  @ViewBuilder body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(blurb)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                body()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func doubleRow(_ label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: 280, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: .infinity)
            TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func frequencyRow(_ label: String, value: Binding<SchedulerFrequency>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: value) {
                Text("Off (manual only)").tag(SchedulerFrequency.off)
                Text("Daily").tag(SchedulerFrequency.daily)
                Text("Weekly").tag(SchedulerFrequency.weekly)
                Text("Monthly").tag(SchedulerFrequency.monthly)
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    /// 时刻选择：DatePicker(.hourAndMinute) ↔ "HH:mm" 字符串桥接。
    private func timeRow(_ label: String, value: Binding<String>) -> some View {
        let dateBinding = Binding<Date>(
            get: {
                let p = value.wrappedValue.split(separator: ":")
                var c = DateComponents()
                c.hour = Int(p.first ?? "0") ?? 0
                c.minute = p.count > 1 ? (Int(p[1]) ?? 0) : 0
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                value.wrappedValue = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
        )
        return HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            // 用 menu 风格的 dropdown 复刻一个 hour-minute 选择器 ——
            // 视觉上跟同一行 Frequency Picker(160 宽 menu)完全一致,
            // 右沿 + 内 padding 都对齐。
            // 原来用 DatePicker(.hourAndMinute) 出来的是 stepperField
            // 风格(内嵌小输入框 + 外挂上下箭头),宽度跟同一行 Frequency
            // Picker 视觉对不齐,Stan 复现"time 右侧选项框左右 padding
            // 不一致"就是这条。改成 menu 后两行控件一模一样。
            HStack(spacing: 4) {
                Picker("", selection: hourBinding(dateBinding)) {
                    ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Text(":").font(.system(size: 12))
                Picker("", selection: minuteBinding(dateBinding)) {
                    ForEach(Self.minuteSteps, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .frame(width: 160)
        }
    }

    /// 把 Date Binding 解出 hour 部分,反向 set 时合并回原 minute。
    private func hourBinding(_ d: Binding<Date>) -> Binding<Int> {
        Binding(
            get: { Calendar.current.component(.hour, from: d.wrappedValue) },
            set: { newHour in
                var comp = Calendar.current.dateComponents([.hour, .minute], from: d.wrappedValue)
                comp.hour = newHour
                if let nd = Calendar.current.date(from: comp) { d.wrappedValue = nd }
            }
        )
    }
    /// minute 选项只展示 0/15/30/45 四档,够 scheduler 用。已有 config 里
    /// 落在四档之外的值(配置文件手动改的)读时 round 到最近一档,避免
    /// menu Picker 因 tag 对不上显示空白。
    private func minuteBinding(_ d: Binding<Date>) -> Binding<Int> {
        Binding(
            get: {
                let raw = Calendar.current.component(.minute, from: d.wrappedValue)
                return Self.minuteSteps.min { abs($0 - raw) < abs($1 - raw) } ?? 0
            },
            set: { newMin in
                var comp = Calendar.current.dateComponents([.hour, .minute], from: d.wrappedValue)
                comp.minute = newMin
                if let nd = Calendar.current.date(from: comp) { d.wrappedValue = nd }
            }
        )
    }
    private static let minuteSteps = [0, 15, 30, 45]
    /// 24h 显示("00"…"23")。用户在 issue 里要 24h,不要 AM/PM。
    private static func hourLabel(_ h: Int) -> String {
        String(format: "%02d", h)
    }

    /// 星期选择：0=周日…6=周六。
    private func weekdayRow(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: value) {
                ForEach(0...6, id: \.self) { wd in
                    Text(Self.weekdayNames[wd]).tag(wd)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    /// 几号选择：1…31。当月不足时由调度逻辑落到当月最后一天，UI 不暴露。
    private func dayOfMonthRow(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: value) {
                ForEach(1...31, id: \.self) { d in
                    Text("\(d)").tag(d)
                }
            }
            .labelsHidden()
            .frame(width: 90)
        }
    }

    private func intRow(_ label: String,
                        value: Binding<Int>,
                        range: ClosedRange<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: 280, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .frame(maxWidth: .infinity)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

/// 暂存改动的内容预览 —— 改动前 vs 改动后并排。新文件只显示"现文"。
private struct StagedChangePreview: View {
    let change: MemoryStaging.StagedChange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(change.isNew ? "NEW" : "CHANGED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.isNew ? Color.green : Color.orange)
                Text(change.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            Text(change.relativePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let before = change.beforeText {
                HStack(spacing: 0) {
                    pane("Before", before)
                    Divider()
                    pane("After", change.afterText)
                }
            } else {
                pane("New file", change.afterText)
            }
        }
        .frame(width: 860, height: 580)
    }

    private func pane(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Writing Capture Preview Sheet

/// 写作采集 Pending review 的 preview sheet —— 显示某天 staged 的所有
/// writing_records(text + edit_log + context_summary + source / confidence)。
private struct WritingCapturePreview: View {
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var records: [StagedRecordRow] = []
    @State private var loadError: String? = nil
    @State private var rejectTarget: StagedRecordRow? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Writing capture · \(date)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = loadError {
                        Text("Load failed: \(err)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                    } else if records.isEmpty {
                        Text("(no staged records — should not happen if status=pending_review)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    } else {
                        ForEach(records, id: \.id) { row in
                            recordCard(row)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(width: 720, height: 520)
        .task { load() }
        .sheet(item: $rejectTarget) { row in
            RejectReasonSheet(row: row) { category, text in
                rejectOne(row, category: category, reasonText: text)
            }
        }
    }

    private func rejectOne(_ row: StagedRecordRow, category: String, reasonText: String?) {
        guard let worker = WritingCaptureWorker.shared else { return }
        let store = worker.store
        Task.detached(priority: .userInitiated) {
            do {
                try store.rejectStagedRecord(
                    stagedId: row.id, reasonCategory: category, reasonText: reasonText
                )
                let rows = try store.fetchStagedRecords(date: date)
                await MainActor.run { records = rows }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }

    private func recordCard(_ row: StagedRecordRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.app).font(.system(size: 11, design: .monospaced))
                if let u = row.url, !u.isEmpty {
                    Text(u).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(row.source).font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                Text(String(format: "conf %.2f", row.confidence))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    rejectTarget = row
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Reject this record (will be used as a learning example next run)")
            }
            if let s = row.contextSummary, !s.isEmpty {
                Text(s).font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Text(row.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Edit log (raw JSON):")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(row.editLog)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
        .padding(.horizontal, 12)
    }

    private func load() {
        guard let worker = WritingCaptureWorker.shared else {
            loadError = "Worker not initialized"
            return
        }
        let store = worker.store
        let date = self.date
        Task.detached(priority: .userInitiated) {
            do {
                let rows = try store.fetchStagedRecords(date: date)
                await MainActor.run { self.records = rows }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }
}

// MARK: - Reject reason sheet (用户拒一条 staged record)

/// 弹出表单:让用户从 5 个 reason category 里选一个 + 选填自由文本,
/// 提交时调 callback(category, text)。父 view 负责调 store + 刷新。
private struct RejectReasonSheet: View {
    let row: StagedRecordRow
    var onSubmit: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: String = "gibberish"
    @State private var reasonText: String = ""

    private static let categories: [(id: String, label: String)] = [
        ("gibberish",    "Gibberish"),
        ("private",      "Private"),
        ("irrelevant",   "Irrelevant"),
        ("typo_residue", "Typo residue"),
        ("other",        "Other"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reject this record")
                .font(.system(size: 14, weight: .semibold))
            Text(String(row.text.prefix(200)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            Text("Reason category")
                .font(.system(size: 11, weight: .semibold))
            Picker("", selection: $category) {
                ForEach(Self.categories, id: \.id) { c in
                    Text(c.label).tag(c.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text("Notes (optional)")
                .font(.system(size: 11, weight: .semibold))
            TextField("e.g. contains phone number, too short, OCR misread", text: $reasonText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Reject") {
                    let trimmed = reasonText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(category, trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

// MARK: - WritingStylePreview sheet

/// 单条 draft 的详情 sheet。布局:
///  - 顶部紧凑 header(action badge + slug + refs link + Close)
///  - 极小灰色 run meta 一行(mode · timestamp · records/drafts)
///  - 标题
///  - 正文:update 时 BEFORE / AFTER 两栏 diff,create / noop 时单栏
///
/// refs 点击 → 弹二级 sheet 列源 records 全文(WritingStyleRefsSheet)
private struct WritingStyleDraftDetail: View {
    let draft: WritingStyleStagedRow
    @Environment(\.dismiss) private var dismiss
    @State private var runMeta: WritingStyleRunRow? = nil
    @State private var existingBody: String? = nil
    @State private var showRefs: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    runMetaLine
                    Text(draft.title)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.top, 2)
                    bodySection
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 780, height: 540)
        .task { await load() }
        .sheet(isPresented: $showRefs) {
            WritingStyleRefsSheet(ids: draft.sourceRecordIds)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            actionBadge
            Text(draft.slug)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            if let prior = draft.existingSlug, prior != draft.slug {
                Text("← \(prior)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                showRefs = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text("\(draft.sourceRecordIds.count) refs")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .disabled(draft.sourceRecordIds.isEmpty)
            .help(draft.sourceRecordIds.isEmpty
                  ? "No source records"
                  : "View the \(draft.sourceRecordIds.count) writing_records that backed this draft")
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var actionBadge: some View {
        let (label, color): (String, Color) = {
            switch draft.action {
            case .create: return ("NEW", .green)
            case .update: return ("CHANGED", .orange)
            case .noop:   return ("NOOP", .gray)
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.15))
            )
    }

    // MARK: - Meta line

    @ViewBuilder
    private var runMetaLine: some View {
        if let m = runMeta {
            let dt = Date(timeIntervalSince1970: TimeInterval(m.startedAt) / 1000)
            let fmt: DateFormatter = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                return f
            }()
            Text("\(m.mode.rawValue) · \(fmt.string(from: dt)) · \(m.recordsCount ?? 0) records · \(m.draftsCount ?? 0) drafts · run \(String(m.runId.prefix(8)))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.35))
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySection: some View {
        // AFTER 是 approve 后的最终形态 —— 包含 LLM 输出 body + 自动追加的
        // `**Derived from writing records:**` 块。BEFORE 是现有 .md 的 body
        // 原样(也含 derived 块)。这样两栏直接对照 = 文件 approve 前后的
        // 完整对比,用户不会困惑"derived 块不见了"。
        let afterFinal = finalAfterBody
        if draft.action == .update, let prior = existingBody {
            HStack(alignment: .top, spacing: 12) {
                bodyColumn(label: "BEFORE", color: .secondary, text: prior)
                bodyColumn(label: "AFTER",  color: .orange,    text: afterFinal)
            }
        } else {
            bodyColumn(label: actionLabelForBody, color: actionColorForBody, text: afterFinal)
        }
    }

    /// approve 后落盘的最终 body —— LLM body + derived 块。
    /// 跟 WritingStyleDistiller.renderBody 的 update 路径行为一致(union 旧 ids)。
    private var finalAfterBody: String {
        // update 时 derived ids = 旧 .md 抽出的 ids ∪ 这次 draft 的 sourceRecordIds
        // create / noop 时 = 这次 draft 的 sourceRecordIds
        var ids: [Int64] = []
        if draft.action == .update, let prior = existingBody {
            ids = WritingStyleDistiller.extractDerivedIds(from: prior)
        }
        for id in draft.sourceRecordIds where !ids.contains(id) {
            ids.append(id)
        }
        return WritingStyleDistiller.renderBody(
            title: draft.title, body: draft.body, sourceIds: ids
        )
    }

    private var actionLabelForBody: String {
        switch draft.action {
        case .create: return "NEW BODY"
        case .update: return "BODY"
        case .noop:   return "BODY"
        }
    }
    private var actionColorForBody: Color {
        switch draft.action {
        case .create: return .green
        case .update: return .orange
        case .noop:   return .gray
        }
    }

    private func bodyColumn(label: String, color: Color, text: String) -> some View {
        // 跟 MemoriesView.markdownBody 同套路 —— 逐段 AttributedString 解析,
        // bold / 引用 / link 都渲染。Text(.init(markdown:)) 一段跨多行用
        // `\n` 保留,跨段 `\n\n` 强制分段(否则 SwiftUI 把空行也吞了)。
        let paragraphs = text
            .split(separator: "\n\n", omittingEmptySubsequences: true)
            .map(String.init)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                    let attr = (try? AttributedString(
                        markdown: para,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    )) ?? AttributedString(para)
                    Text(attr)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Load

    private func load() async {
        let runIdLocal = draft.runId
        let slugLocal: String? = draft.action == .update
            ? (draft.existingSlug ?? draft.slug)
            : nil
        // Run 元数据
        if let store = WritingStyleDistiller.shared?.store {
            let r = (try? store.fetchRun(runId: runIdLocal)) ?? nil
            runMeta = r
        }
        // 现有 portrait/writing_style/<slug>.md 的 body
        if let slug = slugLocal {
            let url = PortraitPaths.categoryDir("writing_style")
                .appendingPathComponent(slug + ".md")
            let body = (try? PortraitFileIO.read(from: url))?.body
            existingBody = body
        }
    }
}

/// 二级 sheet:展示一组 source writing_records 的全文。
/// 点 WritingStyleDraftDetail 顶部 "N refs" 按钮打开。
private struct WritingStyleRefsSheet: View {
    let ids: [Int64]
    @Environment(\.dismiss) private var dismiss
    @State private var records: [WritingStyleRecordInput] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "link")
                    .font(.system(size: 11))
                Text("\(ids.count) source writing_records")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !loaded {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else if records.isEmpty {
                        Text("(no records found — IDs may have been deleted)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ForEach(records, id: \.id) { r in
                            recordCard(r)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 720, height: 540)
        .task {
            if let store = WritingStyleDistiller.shared?.store {
                let rows = (try? store.fetchRecordsByIds(ids)) ?? []
                records = rows
            }
            loaded = true
        }
    }

    private func recordCard(_ r: WritingStyleRecordInput) -> some View {
        let dt = Date(timeIntervalSince1970: TimeInterval(r.startTs) / 1000)
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return f
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(r.kind)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                Text(r.app)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let u = r.url, !u.isEmpty {
                    Text(u)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(fmt.string(from: dt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.35))
                Text("#\(r.id)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.35))
            }
            if let cs = r.contextSummary, !cs.isEmpty {
                Text(cs)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Text(r.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

private struct WritingStylePreview: View {
    let runId: String
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [WritingStyleStagedRow] = []
    @State private var loadError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Writing style · run \(String(runId.prefix(8)))")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = loadError {
                        Text("Load failed: \(err)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                    } else if drafts.isEmpty {
                        Text("(no staged drafts)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    } else {
                        ForEach(drafts, id: \.id) { d in
                            draftCard(d)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(width: 720, height: 520)
        .task { load() }
    }

    private func draftCard(_ d: WritingStyleStagedRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(d.action.rawValue).font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .cornerRadius(4)
                Text(d.slug).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let prior = d.existingSlug, prior != d.slug {
                    Text("(was \(prior))").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(d.sourceRecordIds.count) refs")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(d.title).font(.system(size: 13, weight: .semibold))
            Text(d.body)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
        .padding(.horizontal, 12)
    }

    private func load() {
        guard let distiller = WritingStyleDistiller.shared else {
            loadError = "Distiller not initialized"
            return
        }
        let store = distiller.store
        Task.detached(priority: .userInitiated) {
            do {
                let rows = try store.fetchStaged(runId: runId)
                await MainActor.run { drafts = rows }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }
}

// MARK: - Optional<String> .sheet(item:) 适配

/// SwiftUI .sheet(item:) 要 Identifiable,Optional<String> 自身不满足。
/// 包一层 IdentifiableString。
private struct IdentifiableString: Identifiable {
    let id: String
}

private extension Binding where Value == Optional<String> {
    /// 把 Optional<String> 视图转成 Optional<IdentifiableString>(双向绑定)。
    var mappedToIdentifiable: Binding<IdentifiableString?> {
        Binding<IdentifiableString?>(
            get: { wrappedValue.map(IdentifiableString.init(id:)) },
            set: { wrappedValue = $0?.id }
        )
    }
}
