import Foundation
import SQLite3

// MARK: - Chip model

/// A single context filter the user picked via the `@` popover. A chat send
/// may carry zero or many chips; each contributes one section to the
/// `ScreenpipeContext` we prepend to the prompt.
struct ContextChip: Identifiable, Hashable {
    enum Spec: Hashable {
        case now                    // the single most recent OCR frame
        case lastMinutes(Int)
        case today                  // since 00:00 local time
        case app(String)            // that app, last 1h
        case file(URL)              // user-picked file (we include its text contents)
        case search(String)         // OCR full-text search
        case speaker(String)        // audio transcripts from this speaker, last 1h
    }
    let id: UUID
    let spec: Spec

    init(spec: Spec) { self.id = UUID(); self.spec = spec }

    var label: String {
        switch spec {
        case .now:                  return "@now"
        case .lastMinutes(let m):   return "@last \(m)m"
        case .today:                return "@today"
        case .app(let name):        return "@\(name.lowercased())"
        case .file(let url):        return "@\(url.lastPathComponent)"
        case .search(let q):
            let trimmed = q.count > 24 ? String(q.prefix(24)) + "…" : q
            return "@search:\(trimmed)"
        case .speaker(let name):    return "@speaker:\(name)"
        }
    }

    var icon: String {
        switch spec {
        case .now:                  return "scope"
        case .lastMinutes:          return "clock"
        case .today:                return "calendar"
        case .app:                  return "app.dashed"
        case .file:                 return "doc.text"
        case .search:               return "magnifyingglass"
        case .speaker:              return "person.wave.2"
        }
    }
}

// MARK: - Built context

/// Result of resolving a `[ContextChip]` against the screenpipe DB.
struct ScreenpipeContext {
    /// Markdown-formatted block ready to prepend to the user prompt. Empty
    /// if no chips resolved or no frames were found.
    let markdown: String
    /// Brief one-line summary shown in the user bubble next to the chips.
    let summary: String
    let frameCount: Int
    let truncated: Bool

    static let empty = ScreenpipeContext(markdown: "", summary: "", frameCount: 0, truncated: false)
}

// MARK: - Builder

enum ScreenpipeContextBuilder {
    /// Build a prompt-ready context for a list of chips. Each chip contributes
    /// one section. Total OCR text is capped at `maxChars` (≈ maxChars/4 tokens)
    /// so we don't blow Pi's context window. When `redactPII` is true, the
    /// final text is run through `PIIRedactor` before being returned.
    static func build(chips: [ContextChip], redactPII: Bool = false, maxChars: Int = 24_000) -> ScreenpipeContext {
        guard !chips.isEmpty else { return .empty }
        let db = ScreenpipeDB()
        guard db.exists else {
            return ScreenpipeContext(
                markdown: "",
                summary: "screenpipe DB not found",
                frameCount: 0, truncated: false
            )
        }

        var sections: [String] = []
        var totalFrames = 0
        var remaining = maxChars
        var truncated = false

        for chip in chips {
            guard remaining > 200 else { truncated = true; break }
            switch chip.spec {
            case .file(let url):
                if let text = readFile(url, cap: min(remaining, 8000)) {
                    sections.append("## \(chip.label)\n\(text)")
                    remaining -= text.count
                }
            case .search(let q):
                let block = db.searchOCR(query: q, maxChars: min(remaining, 6000))
                if !block.text.isEmpty {
                    sections.append("## \(chip.label) — \(block.frameCount) matches\n\(block.text)")
                    remaining -= block.text.count
                    totalFrames += block.frameCount
                }
            case .speaker(let name):
                let block = db.speakerTranscripts(name: name, maxChars: min(remaining, 6000))
                if !block.isEmpty {
                    sections.append("## \(chip.label)\n\(block)")
                    remaining -= block.count
                }
            case .now, .lastMinutes, .today, .app:
                let (start, end, app) = resolveTimeWindow(chip.spec)
                let block = db.ocrBlock(from: start, to: end, appFilter: app, maxChars: remaining)
                if block.frameCount == 0 { continue }
                totalFrames += block.frameCount
                remaining -= block.text.count
                if block.truncated { truncated = true }
                let header = sectionHeader(for: chip, frames: block.frameCount, apps: block.topApps)
                sections.append("\(header)\n\(block.text)")
            }
        }

        guard !sections.isEmpty else {
            return ScreenpipeContext(
                markdown: "",
                summary: "no screen activity found in those filters",
                frameCount: 0, truncated: false
            )
        }

        let header = "[Screen context follows — \(totalFrames) frames" +
                     (truncated ? " (truncated)" : "") +
                     (redactPII ? " · PII redacted" : "") + "]"
        let body = sections.joined(separator: "\n\n")
        var md = "\(header)\n\n\(body)\n\n---"
        if redactPII { md = PIIRedactor.redact(md) }

        let summary = "\(totalFrames) frames" +
                      (truncated ? " (truncated)" : "")
        return ScreenpipeContext(markdown: md, summary: summary,
                                 frameCount: totalFrames, truncated: truncated)
    }

    private static func sectionHeader(for chip: ContextChip,
                                      frames: Int,
                                      apps: [String]) -> String {
        let appList = apps.prefix(3).joined(separator: ", ")
        let appsBit = apps.isEmpty ? "" : " across \(appList)"
        return "## \(chip.label) — \(frames) frames\(appsBit)"
    }

    /// Used to be `chip.resolve()`. Only used for the screen-time chip types.
    private static func resolveTimeWindow(_ spec: ContextChip.Spec) -> (start: Date, end: Date, appName: String?) {
        let now = Date()
        switch spec {
        case .now:                  return (now.addingTimeInterval(-60), now, nil)
        case .lastMinutes(let m):   return (now.addingTimeInterval(TimeInterval(-m * 60)), now, nil)
        case .today:                return (Calendar.current.startOfDay(for: now), now, nil)
        case .app(let n):           return (now.addingTimeInterval(-3600), now, n)
        default:                    return (now, now, nil)
        }
    }

    /// Read first `cap` chars of a file. Best-effort UTF-8; binary files
    /// produce a marker rather than garbage.
    private static func readFile(_ url: URL, cap: Int) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Heuristic: try UTF-8. If it fails, mark as binary.
        if let s = String(data: data.prefix(cap), encoding: .utf8) {
            return s
        }
        return "[binary file, \(data.count) bytes]"
    }
}

// MARK: - ScreenpipeDB extension for time-range OCR

extension ScreenpipeDB {
    /// Output of `ocrBlock`. `text` is dedup'd line-wise, capped at maxChars.
    struct OCRBlock {
        let text: String
        let frameCount: Int
        let topApps: [String]
        let truncated: Bool
    }

    /// Pull deduped OCR text from frames within [from, to], optionally only
    /// for one app (case-insensitive contains match on app_name).
    func ocrBlock(from: Date, to: Date, appFilter: String? = nil, maxChars: Int = 8000) -> OCRBlock {
        guard exists else { return OCRBlock(text: "", frameCount: 0, topApps: [], truncated: false) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return OCRBlock(text: "", frameCount: 0, topApps: [], truncated: false)
        }
        defer { sqlite3_close(db) }

        let fromTS = Self.fmt.string(from: from)
        let toTS   = Self.fmt.string(from: to)

        var sql = """
            SELECT f.app_name, o.text
            FROM frames f
            JOIN ocr_text o ON o.frame_id = f.id
            WHERE f.timestamp BETWEEN ? AND ?
              AND o.text IS NOT NULL AND length(o.text) > 4
            """
        if appFilter != nil { sql += " AND lower(f.app_name) LIKE ?" }
        sql += " ORDER BY f.timestamp DESC LIMIT 600"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return OCRBlock(text: "", frameCount: 0, topApps: [], truncated: false)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, fromTS, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, toTS,   -1, SQLITE_TRANSIENT)
        if let a = appFilter {
            sqlite3_bind_text(stmt, 3, "%\(a.lowercased())%", -1, SQLITE_TRANSIENT)
        }

        var seen = Set<String>()
        var lines: [String] = []
        var appCounts: [String: Int] = [:]
        var totalLen = 0
        var truncated = false

        while sqlite3_step(stmt) == SQLITE_ROW {
            let app  = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            if !app.isEmpty { appCounts[app, default: 0] += 1 }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.count >= 3 else { continue }
                if seen.contains(line) { continue }
                seen.insert(line)
                lines.append(line)
                totalLen += line.count + 1
                if totalLen >= maxChars { truncated = true; break }
            }
            if truncated { break }
        }

        let topApps = appCounts.sorted { $0.value > $1.value }.map { $0.key }
        return OCRBlock(
            text: lines.joined(separator: "\n"),
            frameCount: appCounts.values.reduce(0, +),
            topApps: topApps,
            truncated: truncated
        )
    }

    /// Full-text-ish search over OCR. Uses LIKE since the screenpipe schema
    /// doesn't ship FTS5. Returns matched lines + the count of distinct
    /// frames they came from.
    func searchOCR(query: String, maxChars: Int = 6000) -> OCRBlock {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard exists, !q.isEmpty else {
            return OCRBlock(text: "", frameCount: 0, topApps: [], truncated: false)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return OCRBlock(text: "", frameCount: 0, topApps: [], truncated: false)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT f.timestamp, f.app_name, o.text
            FROM frames f JOIN ocr_text o ON o.frame_id = f.id
            WHERE o.text LIKE ?
            ORDER BY f.timestamp DESC
            LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return OCRBlock(text: "", frameCount: 0, topApps: [], truncated: false)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%\(q)%", -1, SQLITE_TRANSIENT)

        var lines: [String] = []
        var seen = Set<String>()
        var totalLen = 0
        var truncated = false
        var frames = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts  = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let app = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let raw = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            frames += 1
            for line in raw.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.lowercased().contains(q.lowercased()), t.count >= 3 else { continue }
                let key = "\(ts)|\(t)"
                if seen.contains(key) { continue }
                seen.insert(key)
                let entry = "[\(ts) · \(app)] \(t)"
                lines.append(entry)
                totalLen += entry.count + 1
                if totalLen >= maxChars { truncated = true; break }
            }
            if truncated { break }
        }
        return OCRBlock(text: lines.joined(separator: "\n"),
                        frameCount: frames, topApps: [], truncated: truncated)
    }

    /// Last hour of transcripts from a particular speaker.
    func speakerTranscripts(name: String, maxChars: Int = 6000) -> String {
        guard exists else { return "" }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_close(db) }

        let since = Self.fmt.string(from: Date().addingTimeInterval(-3600))
        // No speaker_name column on audio_transcriptions; JOIN through
        // speakers.name to match by display name.
        let sql = """
            SELECT a.timestamp, a.transcription
            FROM audio_transcriptions a
            JOIN speakers s ON s.id = a.speaker_id
            WHERE s.name = ? AND a.timestamp >= ?
            ORDER BY a.timestamp ASC
            LIMIT 400
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, since, -1, SQLITE_TRANSIENT)

        var lines: [String] = []
        var total = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let t  = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let line = "[\(ts)] \(name): \(t)"
            lines.append(line)
            total += line.count + 1
            if total >= maxChars { break }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated(unsafe) static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
