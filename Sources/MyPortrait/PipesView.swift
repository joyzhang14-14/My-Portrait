import SwiftUI

/// "Pipes" — background AI workers that fire on a cadence and store their
/// runs as conversations. List on the left, detail (runs of the selected
/// pipe) on the right. Each run row opens its source conversation in Home.
struct PipesView: View {
    @Environment(ChatController.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @State private var store = PipeStore.shared
    @State private var selection: UUID? = nil
    @State private var editing: PipeJob? = nil

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
            Divider()
            detail
                .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .sheet(item: $editing) { pipe in
            PipeEditor(initial: pipe) { saved in
                if store.pipes.contains(where: { $0.id == saved.id }) {
                    store.update(saved)
                } else {
                    store.add(saved)
                }
                editing = nil
                selection = saved.id
            } onCancel: { editing = nil }
        }
    }

    // MARK: - Left: list

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PIPES")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button { editing = blankPipe() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("New pipe")
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.06))

            if store.pipes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.40))
                    Text("No pipes yet.\nClick + to create one.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 60)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.pipes) { p in
                            PipeRow(pipe: p, isActive: selection == p.id) {
                                selection = p.id
                            } onToggle: {
                                store.toggleEnabled(p.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Right: detail

    @ViewBuilder private var detail: some View {
        if let pipe = currentPipe {
            PipeDetailView(
                pipe: pipe,
                onEdit: { editing = pipe },
                onDelete: {
                    store.delete(pipe.id)
                    selection = nil
                },
                onRunNow: { PipeExecutor.run(pipe) },
                onOpenConv: { convId in
                    chat.switchTo(convId)
                    NotificationCenter.default.post(name: .navigateToHome, object: nil)
                }
            )
        } else {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.30))
                Text(store.pipes.isEmpty ? "Create a pipe to get started"
                                         : "Select a pipe")
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var currentPipe: PipeJob? {
        guard let id = selection else { return nil }
        return store.pipes.first { $0.id == id }
    }

    private func blankPipe() -> PipeJob {
        PipeJob(name: "New pipe",
             prompt: "Summarize what changed since the last run.",
             window: .lastHours(1),
             schedule: .everyMinutes(60))
    }
}

extension Notification.Name {
    /// Posted by PipesView to ask ContentView to jump back to .home after
    /// opening a pipe-run conversation.
    static let navigateToHome = Notification.Name("MyPortrait.NavigateToHome")
}

// MARK: - PipeJob row in sidebar

private struct PipeRow: View {
    let pipe: PipeJob
    let isActive: Bool
    let onTap: () -> Void
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { pipe.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(pipe.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                Text(pipe.schedule.label + lastRunSuffix)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.white.opacity(0.10)
                      : hover ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
    }

    private var lastRunSuffix: String {
        guard let t = pipe.lastRunAt else { return " · never run" }
        let df = RelativeDateTimeFormatter()
        df.unitsStyle = .short
        return " · " + df.localizedString(for: t, relativeTo: Date())
    }
}

// MARK: - PipeJob detail

private struct PipeDetailView: View {
    let pipe: PipeJob
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRunNow: () -> Void
    let onOpenConv: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(pipe.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
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
                    .foregroundStyle(.white.opacity(0.55))

                if pipe.runs.isEmpty {
                    Text("No runs yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    VStack(spacing: 4) {
                        ForEach(pipe.runs) { run in
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
            metaRow("Schedule", pipe.schedule.label, icon: "clock")
            metaRow("Context", pipe.window.label, icon: "viewfinder")
            metaRow("Status", pipe.isEnabled ? "enabled" : "paused",
                    icon: pipe.isEnabled ? "checkmark.circle" : "pause.circle")
            VStack(alignment: .leading, spacing: 4) {
                Text("PROMPT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
                Text(pipe.prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
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
                .foregroundStyle(.white.opacity(0.55))
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 70, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
    }
}

private struct RunRow: View {
    let run: PipeRun
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
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 90, alignment: .leading)
                Text(run.preview.isEmpty ? "(empty)" : run.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(2)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(hover ? 0.85 : 0.35))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hover ? 0.05 : 0.02))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - PipeJob editor sheet

private struct PipeEditor: View {
    @State var initial: PipeJob
    let onSave: (PipeJob) -> Void
    let onCancel: () -> Void

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
                Text("PipeJob").font(.system(size: 14, weight: .semibold))
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
        }
        .padding(20)
        .frame(width: 480)
    }
}
