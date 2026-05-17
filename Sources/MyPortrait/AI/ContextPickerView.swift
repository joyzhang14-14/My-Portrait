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
    @State private var recentApps: [String] = []

    private var rows: [Row] {
        if showingAppList { return appRows }
        return [
            Row(spec: .now,             title: "now",         hint: "this moment", icon: "scope"),
            Row(spec: .lastMinutes(5),  title: "last 5m",     hint: "past five minutes",  icon: "clock"),
            Row(spec: .lastMinutes(30), title: "last 30m",    hint: "past half hour",     icon: "clock"),
            Row(spec: .lastMinutes(60), title: "last 1h",     hint: "past hour",          icon: "clock"),
            Row(spec: .today,           title: "today",       hint: "since midnight",     icon: "calendar"),
            Row(spec: nil,              title: "app…",        hint: "pick an app",        icon: "app.dashed", isAppPrompt: true)
        ]
    }

    private var appRows: [Row] {
        let q = appQuery.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = recentApps.filter { q.isEmpty || $0.lowercased().contains(q) }
        return filtered.prefix(8).map {
            Row(spec: .app($0), title: $0, hint: "last 1h in \($0)", icon: "app.fill")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingAppList {
                searchField
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
        }
        .onKeyPress(.upArrow)  { highlight = max(0, highlight - 1);   return .handled }
        .onKeyPress(.downArrow){ highlight = min(rows.count - 1, highlight + 1); return .handled }
        .onKeyPress(.return)   { commitHighlighted(); return .handled }
        .onKeyPress(.escape)   { onDismiss(); return .handled }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            TextField("Filter apps…", text: $appQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func commitHighlighted() {
        guard rows.indices.contains(highlight) else { return }
        commit(rows[highlight])
    }

    private func commit(_ row: Row) {
        if row.isAppPrompt {
            withAnimation(.easeOut(duration: 0.15)) {
                showingAppList = true
                highlight = 0
            }
            return
        }
        guard let spec = row.spec else { return }
        onPick(ContextChip(spec: spec))
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
    var isAppPrompt: Bool = false
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
            if row.isAppPrompt {
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
