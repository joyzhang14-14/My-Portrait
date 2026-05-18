import SwiftUI

/// Popover shown when the user types `@` in the chat input. A floating
/// glass panel with a few canned filters (now / last Xm / today) plus an
/// app submenu, navigable with arrow keys + Enter, dismissed with Esc.
///
/// On selection: calls `onPick` with the chosen `ContextChip` and dismisses.
struct ContextPickerView: View {
    let onPick: (ContextChip) -> Void
    let onDismiss: () -> Void

    @State private var highlight: Int = 0
    @State private var appQuery: String = ""
    @State private var showingAppList: Bool = false
    @State private var showingSearchInput: Bool = false
    @State private var searchQuery: String = ""
    @State private var recentApps: [String] = []
    @State private var recentSpeakers: [String] = []
    @State private var showingSpeakerList: Bool = false

    private var rows: [Row] {
        if showingAppList { return appRows }
        if showingSpeakerList { return speakerRows }
        return [
            Row(spec: .now,             title: "now",        hint: "this moment", icon: "scope"),
            Row(spec: .lastMinutes(5),  title: "last 5m",    hint: "past five minutes",  icon: "clock"),
            Row(spec: .lastMinutes(30), title: "last 30m",   hint: "past half hour",     icon: "clock"),
            Row(spec: .lastMinutes(60), title: "last 1h",    hint: "past hour",          icon: "clock"),
            Row(spec: .today,           title: "today",      hint: "since midnight",     icon: "calendar"),
            Row(spec: nil,              title: "app…",       hint: "pick an app",        icon: "app.dashed",   intent: .appPrompt),
            Row(spec: nil,              title: "file…",      hint: "pick a file from disk", icon: "doc.badge.plus", intent: .filePrompt),
            Row(spec: nil,              title: "search…",    hint: "search OCR history", icon: "magnifyingglass", intent: .searchPrompt),
            Row(spec: nil,              title: "speaker…",   hint: "audio from a person",  icon: "person.wave.2", intent: .speakerPrompt)
        ]
    }

    private var appRows: [Row] {
        let q = appQuery.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = recentApps.filter { q.isEmpty || $0.lowercased().contains(q) }
        return filtered.prefix(8).map {
            Row(spec: .app($0), title: $0, hint: "last 1h in \($0)", icon: "app.fill")
        }
    }

    private var speakerRows: [Row] {
        recentSpeakers.prefix(8).map {
            Row(spec: .speaker($0), title: $0, hint: "last 1h of audio from \($0)", icon: "person.wave.2")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingAppList {
                searchField(placeholder: "Filter apps…", text: $appQuery)
                Divider().background(Color.white.opacity(0.08))
            }
            if showingSearchInput {
                searchField(placeholder: "OCR search query…", text: $searchQuery, onSubmit: {
                    let q = searchQuery.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty { onPick(ContextChip(spec: .search(q))) }
                })
                Divider().background(Color.white.opacity(0.08))
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    PickerRow(row: row, highlighted: highlight == idx)
                        .onTapGesture { commit(row) }
                        .onHover { hovering in
                            if hovering { highlight = idx }
                        }
                }
                if showingAppList && rows.isEmpty {
                    Text("No matching apps")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
        )
        .onAppear {
            highlight = 0
            recentApps = recentlyActiveApps()
            recentSpeakers = recentlyHeardSpeakers()
        }
        .onKeyPress(.upArrow)  { highlight = max(0, highlight - 1);   return .handled }
        .onKeyPress(.downArrow){ highlight = min(rows.count - 1, highlight + 1); return .handled }
        .onKeyPress(.return)   { commitHighlighted(); return .handled }
        .onKeyPress(.escape)   { onDismiss(); return .handled }
    }

    private func searchField(placeholder: String, text: Binding<String>,
                             onSubmit: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.95))
                .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func commitHighlighted() {
        guard rows.indices.contains(highlight) else { return }
        commit(rows[highlight])
    }

    private func commit(_ row: Row) {
        switch row.intent {
        case .appPrompt:
            withAnimation(.easeOut(duration: 0.15)) { showingAppList = true; highlight = 0 }
        case .filePrompt:
            pickFile()
        case .searchPrompt:
            withAnimation(.easeOut(duration: 0.15)) { showingSearchInput = true; highlight = 0 }
        case .speakerPrompt:
            withAnimation(.easeOut(duration: 0.15)) { showingSpeakerList = true; highlight = 0 }
        case .none:
            if let spec = row.spec { onPick(ContextChip(spec: spec)) }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            onPick(ContextChip(spec: .file(url)))
        }
    }

    private func recentlyHeardSpeakers() -> [String] {
        let db = ScreenpipeDB()
        guard db.exists else { return [] }
        let items = db.audioTranscripts(around: Date(), before: 60 * 60 * 24, after: 0)
        var seen = Set<String>()
        var ordered: [String] = []
        for item in items {
            let name = item.speakerName ?? "Speaker \(item.speakerId.map(String.init) ?? "?")"
            if seen.contains(name) || name.isEmpty { continue }
            seen.insert(name)
            ordered.append(name)
        }
        return ordered
    }

    /// Pull the union of app names seen in the last 24h from screenpipe so
    /// the app picker offers real options the user actually uses.
    private func recentlyActiveApps() -> [String] {
        let db = ScreenpipeDB()
        guard db.exists else { return [] }
        let apps = db.activeApps(around: Date(), window: 60 * 60 * 24)
        let names = apps.map { $0.appName }.filter { !$0.isEmpty }
        var seen = Set<String>()
        var ordered: [String] = []
        for n in names where !seen.contains(n) {
            seen.insert(n)
            ordered.append(n)
        }
        return ordered
    }
}

// MARK: - Row

private struct Row {
    let spec: ContextChip.Spec?
    let title: String
    let hint: String
    let icon: String
    var intent: Intent = .none

    /// Sub-mode the row enters when picked. `.none` ⇒ it carries a `spec`
    /// and commits immediately on Enter.
    enum Intent { case none, appPrompt, filePrompt, searchPrompt, speakerPrompt }
}

private struct PickerRow: View {
    let row: Row
    let highlighted: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                Text(row.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            if row.intent != .none {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted
                      ? LinearGradient(colors: [Color.purple.opacity(0.30), Color.blue.opacity(0.18)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                      : LinearGradient(colors: [Color.clear, Color.clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .padding(.horizontal, 5).padding(.vertical, 1)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}
