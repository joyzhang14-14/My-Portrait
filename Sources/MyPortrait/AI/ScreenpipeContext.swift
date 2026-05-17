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
        }
    }

    var icon: String {
        switch spec {
        case .now:                  return "scope"
        case .lastMinutes:          return "clock"
        case .today:                return "calendar"
        case .app:                  return "app.dashed"
        }
    }

    /// Resolve this chip into a concrete (start, end, appName?) window.
    func resolve(now: Date = Date()) -> (start: Date, end: Date, appName: String?) {
        switch spec {
        case .now:
            return (now.addingTimeInterval(-60), now, nil)
        case .lastMinutes(let m):
            return (now.addingTimeInterval(TimeInterval(-m * 60)), now, nil)
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: now)
            return (startOfDay, now, nil)
        case .app(let name):
            return (now.addingTimeInterval(-3600), now, name)
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
    /// so we don't blow Pi's context window.
    static func build(chips: [ContextChip], maxChars: Int = 24_000) -> ScreenpipeContext {
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
            let (start, end, app) = chip.resolve()
            let block = db.ocrBlock(from: start, to: end, appFilter: app, maxChars: remaining)
            if block.frameCount == 0 { continue }
            totalFrames += block.frameCount
            remaining -= block.text.count
            if block.truncated { truncated = true }

            let header = sectionHeader(for: chip, frames: block.frameCount, apps: block.topApps)
            sections.append("\(header)\n\(block.text)")
        }

        guard !sections.isEmpty else {
            return ScreenpipeContext(
                markdown: "",
                summary: "no screen activity found in those filters",
                frameCount: 0, truncated: false
            )
        }

        let header = "[Screen context follows — \(totalFrames) frames" +
                     (truncated ? " (truncated)" : "") + "]"
        let body = sections.joined(separator: "\n\n")
        let md = "\(header)\n\n\(body)\n\n---"

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

    nonisolated(unsafe) static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
