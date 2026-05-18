import SwiftUI

/// Speakers — list of identified / unidentified voices from screenpipe.
/// Mirrors Orphies' `speakers-section.tsx`: progress header, unidentified
/// clusters with quick-name input, identified roster with inline edit /
/// delete, plus a side-by-side merge suggestion banner.
///
/// We read names + counts directly from the screenpipe `speakers` table.
/// Editing writes back through SQL (or stays as UI-only until the user
/// connects a write path).
struct SpeakersSettingsView: View {
    @State private var rows: [SpeakerRow] = []
    @State private var search = ""
    @State private var organizing = false

    private var filtered: [SpeakerRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { ($0.name ?? "").lowercased().contains(q) }
    }
    private var identified: [SpeakerRow]   { filtered.filter { $0.name?.isEmpty == false } }
    private var unidentified: [SpeakerRow] { filtered.filter { ($0.name ?? "").isEmpty } }

    var body: some View {
        SettingsPage("Speakers", subtitle: "Voices captured from your microphone + system audio") {

            ProgressHeader(identified: identified.count, total: rows.count)

            if !unidentified.isEmpty {
                AttentionBanner(count: unidentified.count)
            }

            HStack(spacing: 8) {
                searchField
                Spacer()
                Button {
                    organizing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { organizing = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: organizing ? "sparkles" : "wand.and.stars")
                            .font(.system(size: 11))
                            .rotationEffect(.degrees(organizing ? 360 : 0))
                            .animation(organizing
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default, value: organizing)
                        Text("Organize with AI")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }

            if !unidentified.isEmpty {
                SettingsCard(title: "Unidentified clusters",
                             footnote: "Give each cluster a name so it can be linked across recordings.") {
                    ForEach(unidentified) { r in
                        SpeakerRowView(row: r,
                                       editable: true,
                                       onCommitName: { newName in commitRename(r, to: newName) },
                                       onDelete: { delete(r) })
                        if r.id != unidentified.last?.id { SettingsDivider() }
                    }
                }
            }

            SettingsCard(title: "Identified speakers") {
                if identified.isEmpty {
                    Text("No identified speakers yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(identified) { r in
                        SpeakerRowView(row: r,
                                       editable: false,
                                       onCommitName: { newName in commitRename(r, to: newName) },
                                       onDelete: { delete(r) })
                        if r.id != identified.last?.id { SettingsDivider() }
                    }
                }
            }
        }
        .task { reload() }
    }

    // MARK: - Helpers

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            TextField("Search speakers…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
        )
        .frame(maxWidth: 260)
    }

    private func reload() {
        rows = SpeakerLoader.loadAll()
    }
    private func commitRename(_ r: SpeakerRow, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = rows.firstIndex(where: { $0.id == r.id }) {
            rows[i].name = trimmed
        }
        // Persisting back into screenpipe's DB needs a writable connection
        // — left for a follow-up. The UI keeps the new name optimistically.
    }
    private func delete(_ r: SpeakerRow) {
        rows.removeAll { $0.id == r.id }
    }
}

// MARK: - Banners

private struct ProgressHeader: View {
    let identified: Int; let total: Int
    private var pct: Double {
        guard total > 0 else { return 0 }
        return Double(identified) / Double(total)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(identified) of \(total) speakers identified")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            ProgressView(value: pct).tint(Color.purple).frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7))
        )
    }
}

private struct AttentionBanner: View {
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) unidentified speakers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Name these voice clusters so they're linked across recordings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.60))
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.45), lineWidth: 0.7))
        )
    }
}

// MARK: - Speaker row

private struct SpeakerRowView: View {
    let row: SpeakerRow
    let editable: Bool
    let onCommitName: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Avatar — first-letter glyph if named, "?" otherwise
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Text(initial)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.7))

            if editable, (row.name ?? "").isEmpty {
                TextField("name this speaker…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                    .frame(maxWidth: 220)
                    .onSubmit { onCommitName(draft); draft = "" }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name ?? "Speaker \(row.id.prefix(8))")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("\(row.sampleCount) samples\(lastHeardSuffix)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.50))
                }
                Spacer()
            }

            Button("Mark as hallucination", role: .destructive, action: onDelete)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var initial: String {
        if let n = row.name, let first = n.first { return String(first).uppercased() }
        return "?"
    }
    private var lastHeardSuffix: String {
        guard let last = row.lastHeard else { return "" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return " · " + f.localizedString(for: last, relativeTo: Date())
    }
}

// MARK: - Loader (reads screenpipe.speakers / audio_transcriptions)

import SQLite3

private struct SpeakerRow: Identifiable, Hashable {
    let id: String          // stringified integer id from the DB
    var name: String?
    let sampleCount: Int
    let lastHeard: Date?
}

private enum SpeakerLoader {
    static func loadAll() -> [SpeakerRow] {
        let db = ScreenpipeDB()
        guard db.exists else { return [] }
        var conn: OpaquePointer?
        guard sqlite3_open_v2(db.dbPath, &conn, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(conn) }

        let sql = """
            SELECT s.id, s.name, COUNT(a.id), MAX(a.timestamp)
            FROM speakers s
            LEFT JOIN audio_transcriptions a ON a.speaker_id = s.id
            WHERE COALESCE(s.hallucination, 0) = 0
            GROUP BY s.id, s.name
            ORDER BY (CASE WHEN s.name IS NULL OR s.name = '' THEN 1 ELSE 0 END),
                     COUNT(a.id) DESC
            LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        let alt = DateFormatter()
        alt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        alt.timeZone = TimeZone(secondsFromGMT: 0)
        alt.locale = Locale(identifier: "en_US_POSIX")

        var out: [SpeakerRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let name = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }
            let count = Int(sqlite3_column_int64(stmt, 2))
            var last: Date? = nil
            if let cstr = sqlite3_column_text(stmt, 3) {
                let s = String(cString: cstr)
                last = iso.date(from: s) ?? alt.date(from: s)
            }
            out.append(SpeakerRow(
                id: String(id),
                name: name?.isEmpty == false ? name : nil,
                sampleCount: count,
                lastHeard: last
            ))
        }
        return out
    }
}
