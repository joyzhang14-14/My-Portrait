import SwiftUI

/// Main pane is the detail only. The cron job list + `+` action lives in the
/// left sidebar (alongside Home's Recents + Memory scope) so Cron Jobs feels
/// like a first-class section instead of having a nested column.
struct CronJobsView: View {
    @Environment(ChatController.self) private var chat
    @Binding var selection: UUID?
    @State private var store = CronJobStore.shared
    @State private var editing: CronJob? = nil

    var body: some View {
        Group {
            if let cronJob = currentCronJob {
                CronJobDetailView(
                    cronJob: cronJob,
                    onEdit: { editing = cronJob },
                    onDelete: {
                        store.delete(cronJob.id)
                        selection = nil
                    },
                    onRunNow: { CronJobExecutor.run(cronJob) },
                    onOpenConv: { convId in
                        chat.switchTo(convId)
                        NotificationCenter.default.post(name: .navigateToHome, object: nil)
                    }
                )
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SidebarBackdrop().ignoresSafeArea())
        .sheet(item: $editing) { cronJob in
            CronJobQuickEditor(initial: cronJob) { saved in
                if store.cronJobs.contains(where: { $0.id == saved.id }) {
                    store.update(saved)
                } else {
                    store.add(saved)
                }
                editing = nil
                selection = saved.id
            } onCancel: { editing = nil }
        }
        .onAppear {
            // Land on the first cronJob if none picked yet.
            if selection == nil, let first = store.cronJobs.first {
                selection = first.id
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.textPrimary.opacity(0.35))
            Text(store.cronJobs.isEmpty ? "No cron jobs yet"
                                     : "Select a cron job from the sidebar")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary.opacity(0.60))
            if store.cronJobs.isEmpty {
                Button {
                    editing = Self.blankCronJob()
                } label: {
                    Label("New cron job", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentCronJob: CronJob? {
        guard let id = selection else { return nil }
        return store.cronJobs.first { $0.id == id }
    }

    static func blankCronJob() -> CronJob {
        CronJob(name: "New cron job",
                prompt: "Summarize what changed since the last run.",
                window: .lastHours(1),
                schedule: .everyMinutes(60))
    }
}

extension Notification.Name {
    /// Posted by CronJobsView to ask ContentView to jump back to .home after
    /// opening a cronJob-run conversation.
    static let navigateToHome = Notification.Name("MyPortrait.NavigateToHome")
}

// MARK: - CronJob row in sidebar (also used by TimelineSidebar)

struct CronJobSidebarRow: View {
    let cronJob: CronJob
    let isActive: Bool
    let onTap: () -> Void
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { cronJob.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(cronJob.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                Text(cronJob.schedule.label + lastRunSuffix)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isActive ? Theme.accent.opacity(0.16)
                      : hover ? Theme.hover : .clear)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(isActive ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
    }

    private var lastRunSuffix: String {
        guard let t = cronJob.lastRunAt else { return " · never run" }
        let df = RelativeDateTimeFormatter()
        df.unitsStyle = .short
        return " · " + df.localizedString(for: t, relativeTo: Date())
    }
}

// MARK: - CronJob detail

private struct CronJobDetailView: View {
    let cronJob: CronJob
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRunNow: () -> Void
    let onOpenConv: (UUID) -> Void

    /// 用来过滤掉「conv 已被用户在 CRON JOB HISTORY 里删了」的旧 run 记录,
    /// 否则点 run 跳过去是个 404 的死链。
    @Environment(ChatStore.self) private var chatStore

    private var visibleRuns: [CronJobRun] {
        let existing = Set(chatStore.conversations.map { $0.id })
        return cronJob.runs.filter { existing.contains($0.convId) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(cronJob.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    Spacer()
                    Button(action: onRunNow) {
                        Label("Run now", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                }

                metaGrid

                Divider().background(Color.white.opacity(0.08))

                Text("RUNS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))

                if visibleRuns.isEmpty {
                    Text("No runs yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                } else {
                    VStack(spacing: 4) {
                        ForEach(visibleRuns) { run in
                            RunRow(run: run) { onOpenConv(run.convId) }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metaGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaRow("Schedule", cronJob.schedule.label, icon: "clock")
            metaRow("Context", cronJob.window.label, icon: "viewfinder")
            metaRow("Status", cronJob.isEnabled ? "enabled" : "paused",
                    icon: cronJob.isEnabled ? "checkmark.circle" : "pause.circle")
            metaRow("Notify", cronJob.muted ? "muted" : "on",
                    icon: cronJob.muted ? "bell.slash" : "bell")
            VStack(alignment: .leading, spacing: 4) {
                Text("PROMPT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
                Text(cronJob.prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
            }
            .padding(.top, 4)
        }
    }

    private func metaRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textPrimary.opacity(0.55))
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary.opacity(0.45))
                .frame(width: 70, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
    }
}

private struct RunRow: View {
    let run: CronJobRun
    let onTap: () -> Void
    @State private var hover = false
    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · HH:mm"; return f
    }()
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.fmt.string(from: run.startedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    .frame(width: 90, alignment: .leading)
                Text(run.preview.isEmpty ? "(empty)" : run.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary.opacity(0.90))
                    .lineLimit(2)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.85 : 0.35))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hover ? 0.05 : 0.02))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}

// MARK: - CronJob editor sheet

/// Sheet for create/edit. Used by both CronJobsView (main pane) and
/// TimelineSidebar's cronJobs section.
struct CronJobQuickEditor: View {
    @Environment(AppState.self) private var appState
    @State var initial: CronJob
    let onSave: (CronJob) -> Void
    let onCancel: () -> Void

    /// Integrations the user has actually connected — the only ones a cronJob
    /// can attach, since unconnected ones have no credentials to inject.
    private var connectedIntegrations: [Integration] {
        IntegrationRegistry.all.filter { appState.isConnected($0.id) }
    }

    private let windowOptions: [ContextWindow] = [
        .none, .lastMinutes(5), .lastMinutes(30),
        .lastHours(1), .lastHours(4), .lastHours(8), .today
    ]
    private let cadenceOptions: [Cadence] = [
        .everyMinutes(15), .everyMinutes(30), .everyMinutes(60), .everyMinutes(180),
        .dailyAt(hour: 9), .dailyAt(hour: 17),
        .weeklyOn(weekday: 2, hour: 9)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CronJob").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(initial) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(initial.name.isEmpty || initial.prompt.isEmpty)
            }

            TextField("name", text: $initial.name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $initial.prompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $initial.window) {
                        ForEach(windowOptions, id: \.self) { w in
                            Text(w.label).tag(w)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schedule").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $initial.schedule) {
                        ForEach(cadenceOptions, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                Toggle("Enabled", isOn: $initial.isEnabled)
                    .toggleStyle(.switch)
            }

            // 静音通知。任务照常跑、写 conv 历史,只是 banner 不弹。
            // 单独一行,跟上面 Context/Schedule/Enabled 那行的 picker 错开,
            // 避免长 label 被宽度挤成多行。
            Toggle("Mute notifications", isOn: $initial.muted)
                .toggleStyle(.switch)

            connectionsSelector
        }
        .padding(20)
        .frame(width: 480)
    }

    /// Multi-select menu over connected integrations. Toggling a row adds /
    /// removes its id from `initial.connections`; at run time those ids
    /// resolve into injected env-var credentials.
    private var connectionsSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connections").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if connectedIntegrations.isEmpty {
                Text("No connected integrations. Add one in Connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Menu {
                    ForEach(connectedIntegrations) { integ in
                        Button {
                            toggleConnection(integ.id)
                        } label: {
                            Label(integ.name,
                                  systemImage: initial.connections.contains(integ.id)
                                      ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text(connectionsSummary)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private var connectionsSummary: String {
        let names = initial.connections.compactMap { id in
            IntegrationRegistry.all.first { $0.id == id }?.name
        }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func toggleConnection(_ id: String) {
        if let idx = initial.connections.firstIndex(of: id) {
            initial.connections.remove(at: idx)
        } else {
            initial.connections.append(id)
        }
    }
}
