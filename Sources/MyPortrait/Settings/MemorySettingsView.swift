import SwiftUI

/// Tunable fields for the Memory pipeline. Persists to ~/.myportrait/config.toml
/// via ConfigStore. MemoryBudget / WeightCalculator / Archiver each pull
/// `.fromConfig` so changes take effect on the next rebalance / weight pass /
/// archive run.
struct MemorySettingsView: View {
    private let cfg = ConfigStore.shared

    @State private var attention: [MemoryScheduler.AttentionItem] = []
    @State private var changelog: [ProcessingLogStore.ChangelogEntry] = []

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
    @State private var runningTrigger: ManualTrigger? = nil
    @State private var confirmTrigger: ManualTrigger? = nil
    @State private var runTask: Task<Void, Never>? = nil
    @State private var eventsChanges: [MemoryStaging.StagedChange] = []
    @State private var portraitChanges: [MemoryStaging.StagedChange] = []
    @State private var personalityChanges: [MemoryStaging.StagedChange] = []
    @State private var previewChange: MemoryStaging.StagedChange? = nil

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
            VStack(alignment: .leading, spacing: 24) {
                header

                switch tab {
                case .parameter:
                    budgetSection
                    decaySection
                    archiveSection
                    distillationSection
                case .scheduler:
                    schedulerSection
                    manualRunSection
                    reviewSection
                    attentionSection
                case .changelog:
                    changelogSection
                }

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { reload() }
        .confirmationDialog(
            "Run this now?",
            isPresented: Binding(get: { confirmTrigger != nil },
                                 set: { if !$0 { confirmTrigger = nil } }),
            presenting: confirmTrigger
        ) { trigger in
            Button("Run \(trigger.title)") {
                runTask = Task {
                    await run(trigger)
                    runTask = nil
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
        attention = MemoryScheduler.shared.attentionDays()
        changelog = ProcessingLogStore().recentChangelog(limit: 50)
        refreshStaging()
    }

    private func refreshStaging() {
        eventsChanges = MemoryStaging.changes(.events)
        portraitChanges = MemoryStaging.changes(.portrait)
        personalityChanges = MemoryStaging.changes(.personality)
    }

    // MARK: - Manual triggers

    @MainActor
    private func run(_ t: ManualTrigger) async {
        runningTrigger = t
        defer { runningTrigger = nil }
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
        let outcome = await MemoryScheduler.shared.runEventJob()
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.events, days: days)
            actionStatus = "Run complete — review the staged changes below."
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
        let outcome = await MemoryScheduler.shared.runPortraitJob()
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.portrait, days: days)
            actionStatus = "Run complete — review the staged changes below."
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
        let outcome = await MemoryScheduler.shared.runPersonalityJob()
        switch outcome {
        case .ran(let days):
            try? MemoryStaging.markRan(.personality, days: days)
            actionStatus = "Run complete — review the staged changes below."
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
        for day in MemoryStaging.pendingDays(kind) {
            MemoryScheduler.shared.resetDay(day)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory · \(tab.rawValue)")
                .font(.system(size: 26, weight: .semibold))
            Text(headerBlurb)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var headerBlurb: String {
        switch tab {
        case .parameter:
            return "Tune how the memory system weighs, consolidates, and forgets events. Changes write to `~/.myportrait/config.toml` (debounced)."
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
            Button("Reset Memory section") {
                cfg.mutate { $0.memory = MemoryConfig() }
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
            blurb: "Two independent schedulers. Each can run off (manual only), daily, weekly, or monthly. Times are local. Each run handles the oldest unprocessed days first, up to the per-run cap below; failed days retry on the next run."
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
            intRow("Days processed per run",
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
        let freq = cfg.binding(kp.appending(path: \.frequency))
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            frequencyRow("Frequency", value: freq)

            switch freq.wrappedValue {
            case .off:
                Text("Manual only — runs only when you trigger it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .daily:
                timeRow("Time", value: cfg.binding(kp.appending(path: \.timeOfDay)))
            case .weekly:
                weekdayRow("Day of week", value: cfg.binding(kp.appending(path: \.dayOfWeek)))
                timeRow("Time", value: cfg.binding(kp.appending(path: \.timeOfDay)))
            case .monthly:
                dayOfMonthRow("Day of month", value: cfg.binding(kp.appending(path: \.dayOfMonth)))
                timeRow("Time", value: cfg.binding(kp.appending(path: \.timeOfDay)))
            }
        }
    }

    private var manualRunSection: some View {
        section(
            title: "Run now",
            blurb: "Trigger a pipeline stage manually instead of waiting for the scheduler. Each uses LLM tokens, so you'll be asked to confirm. The weekly budget rebalance is not listed — it runs automatically after every impact rescore."
        ) {
            triggerRow(.eventProcessing)
            Divider().padding(.vertical, 2)
            triggerRow(.distill)
            Divider().padding(.vertical, 2)
            triggerRow(.personality)
            if runningTrigger != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Stop") {
                        let n = PiAgentRegistry.shared.stopAll()
                        runTask?.cancel()
                        runTask = nil
                        runningTrigger = nil
                        actionStatus = "Stopped — killed \(n) LLM process(es)."
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
                .padding(.top, 6)
            }
            if !actionStatus.isEmpty {
                Text(actionStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    private func triggerRow(_ t: ManualTrigger) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 13, weight: .semibold))
                Text(t.desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            let pending = MemoryStaging.hasPending(t.kind)
            Button(runningTrigger == t ? "Running…"
                   : pending ? "Pending review" : "Run") {
                confirmTrigger = t
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(runningTrigger != nil || pending)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var reviewSection: some View {
        let hasEvents = MemoryStaging.hasPending(.events)
        let hasPortrait = MemoryStaging.hasPending(.portrait)
        let hasPersonality = MemoryStaging.hasPending(.personality)
        if hasEvents || hasPortrait || hasPersonality {
            section(
                title: "Pending review",
                blurb: "Manual-run output is staged, not yet committed. Click a file to preview before vs after. Approve keeps it; Reject discards it and puts those days back to pending so they can be re-run."
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
        section(
            title: "Needs attention",
            blurb: "Days whose processing failed, hit a model budget limit, or gave up after repeated failures (dead_letter). Reset puts the day back to pending and zeroes its retry count so the next run retries it."
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
    }

    private func attentionRow(_ item: MemoryScheduler.AttentionItem) -> some View {
        let problemText = item.problems
            .map { "\($0.stage.rawValue): \($0.status.rawValue)" }
            .joined(separator: " · ")
        let title = item.date == "_distill_anchor" ? "Portrait distillation" : item.date
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(problemText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("retry \(item.retryCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button("Reset") {
                MemoryScheduler.shared.resetDay(item.date)
                reload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var budgetSection: some View {
        section(
            title: "Daily consolidation budget",
            blurb: "Mirrors the brain's nightly consolidation cap. Each day's events are scaled independently — when a day's LLM-given impacts sum above the budget, that day is compressed proportionally. Quiet days are left alone."
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
            blurb: "weight = impact × (1 + days_since_last_occurrence)^-α × (1 + log(1 + occurrence_days)). Higher α → faster forgetting."
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
            blurb: "Programmatic, no LLM. All three thresholds must be met (and the file must not live under skills/ or be pinned) for the file to move into _archive/."
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
            blurb: "How much new evidence is needed before a portrait section is updated. Lower = more responsive. Higher = more stable."
        ) {
            intRow("Portrait evidence threshold",
                   value: cfg.binding(\.memory.distillEvidenceThreshold),
                   range: 1...10)
        }
    }

    private var changelogSection: some View {
        section(
            title: "Distillation changelog",
            blurb: "Portrait body changes made by the distiller, newest first. Recorded for debugging and rollback."
        ) {
            if changelog.isEmpty {
                Text("No distillation changes recorded yet.")
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

    private func changelogRow(_ entry: ProcessingLogStore.ChangelogEntry) -> some View {
        let date = Date(timeIntervalSince1970: Double(entry.timestampMs) / 1000)
        let triggerCount = entry.triggeredByEventId?
            .split(separator: ",").count ?? 0
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.entityId)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text("\(Self.changelogDateFmt.string(from: date)) · \(triggerCount) event(s)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
            DatePicker("", selection: dateBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
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
