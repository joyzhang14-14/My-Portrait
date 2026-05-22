import SwiftUI

/// Tunable fields for the Memory pipeline. Persists to ~/.myportrait/config.toml
/// via ConfigStore. MemoryBudget / WeightCalculator / Archiver each pull
/// `.fromConfig` so changes take effect on the next rebalance / weight pass /
/// archive run.
struct MemorySettingsView: View {
    private let cfg = ConfigStore.shared

    @State private var attention: [MemoryScheduler.AttentionItem] = []
    @State private var changelog: [ProcessingLogStore.ChangelogEntry] = []

    /// 手动触发的 pipeline 阶段（都烧 LLM token）。Rebalance 不在列 —— 它是
    /// 程序化的，已挂成 hook 在每次 impact rescore 后自动跑。
    private enum ManualTrigger: String, Identifiable {
        case backfill, rescore, distill
        var id: String { rawValue }
        var title: String {
            switch self {
            case .backfill: return "Backfill events"
            case .rescore:  return "Rescore impact"
            case .distill:  return "Distill portrait"
            }
        }
        var desc: String {
            switch self {
            case .backfill:
                return "Reads the raw timeline and builds event files for any unprocessed days. Uses the LLM to cluster captured activity into semantic events."
            case .rescore:
                return "Re-scores every event's long-term impact with the LLM. The weekly budget rebalance runs automatically right after."
            case .distill:
                return "Distills events into long-term portrait entries. Uses the LLM once per portrait category."
            }
        }
    }
    @State private var actionStatus: String = ""
    @State private var runningTrigger: ManualTrigger? = nil
    @State private var confirmTrigger: ManualTrigger? = nil

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
                Task { await run(trigger) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { trigger in
            Text("\(trigger.title) uses LLM tokens. \(trigger.desc)")
        }
    }

    private func reload() {
        attention = MemoryScheduler.shared.attentionDays()
        changelog = ProcessingLogStore().recentChangelog(limit: 50)
    }

    // MARK: - Manual triggers

    @MainActor
    private func run(_ t: ManualTrigger) async {
        runningTrigger = t
        defer { runningTrigger = nil }
        switch t {
        case .backfill: await runBackfill()
        case .rescore:  await runRescore()
        case .distill:  await runDistill()
        }
    }

    @MainActor
    private func runBackfill() async {
        actionStatus = "Backfilling events from the timeline…"
        do {
            let r = try await Backfill.run { p in
                Task { @MainActor in
                    actionStatus = "Day \(p.dayIndex)/\(p.dayCount) — \(p.phase)"
                }
            }
            actionStatus = "Done. \(r.rawFrameCount) frames → \(r.tier1SessionCount) sessions → \(r.newEventCount) new events, LLM-failed days: \(r.llmFailedDays)"
        } catch {
            actionStatus = "Backfill failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runRescore() async {
        actionStatus = "Rescoring impact with LLM…"
        do {
            let r = try await ImpactScorer().rescoreAll { p in
                Task { @MainActor in
                    actionStatus = "Rescoring batch \(p.batchIndex)/\(p.batchCount) — \(p.scoredCount)/\(p.totalCount) files"
                }
            }
            actionStatus = "Rescored \(r.scoredCount) (failed \(r.failedCount)) in \(String(format: "%.1f", r.elapsed))s. Weekly budget rebalance applied."
        } catch {
            actionStatus = "Rescore failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runDistill() async {
        actionStatus = "Distilling portrait from events…"
        do {
            let r = try await PortraitDistiller().distill { p in
                Task { @MainActor in
                    actionStatus = "Distilling \(p.categoryIndex)/\(p.categoryCount): \(p.category) (\(p.written) written)"
                }
            }
            actionStatus = "Distilled: \(r.portraitFilesWritten) new + \(r.portraitFilesUpdated) updated, \(r.llmFailedCategories) categories failed, \(String(format: "%.1f", r.elapsed))s"
        } catch {
            actionStatus = "Distill failed: \(error.localizedDescription)"
        }
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
            blurb: "Two independent schedulers. Each can run off (manual only), daily, weekly, or monthly. Times are local. Each trigger handles up to 7 unprocessed days, oldest first; failed days retry on the next run."
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
            triggerRow(.backfill)
            Divider().padding(.vertical, 2)
            triggerRow(.rescore)
            Divider().padding(.vertical, 2)
            triggerRow(.distill)
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
            Button(runningTrigger == t ? "Running…" : "Run") {
                confirmTrigger = t
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(runningTrigger != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            title: "Weekly consolidation budget",
            blurb: "Mirrors the brain's nightly consolidation cap. When the past N days of LLM-given impacts sum above the budget, the rebalance pass scales them down proportionally. Quiet weeks are not amplified."
        ) {
            doubleRow("Weekly budget (sum of impacts)",
                      value: cfg.binding(\.memory.weeklyBudget),
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
