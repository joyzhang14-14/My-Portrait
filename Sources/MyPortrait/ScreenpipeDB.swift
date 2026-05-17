import Foundation
import SQLite3

/// Read-only reader for the on-disk screenpipe SQLite database. Used to pull
/// real frame metadata into the timeline demo without depending on screenpipe
/// being running.
struct ScreenpipeFrame: Identifiable, Hashable {
    let id: Int64
    let timestamp: Date           // UTC
    let appName: String
    let windowName: String
    let browserUrl: String?       // set when the active app is a browser
    let snapshotPath: String?
}

struct ScreenpipeDB: Sendable {
    let dbPath: String

    init(path: String = NSString(string: "~/.screenpipe/db.sqlite").expandingTildeInPath) {
        self.dbPath = path
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// Fetch frames for a given day window. Returns ordered ascending by timestamp.
    /// `limit` caps the result to keep the UI snappy; default 800 is roughly one frame per ~2 minutes for 24h.
    func frames(on day: Date, limit: Int = 800) -> [ScreenpipeFrame] {
        guard exists else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Use simpler ISO without fractional seconds for DB compare (sqlite TEXT compare is lexicographic on ISO)
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let startStr = plain.string(from: dayStart)
        let endStr = plain.string(from: dayEnd)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, timestamp, app_name, window_name, browser_url, snapshot_path
            FROM frames
            WHERE snapshot_path IS NOT NULL
              AND timestamp >= ?
              AND timestamp <  ?
            ORDER BY timestamp ASC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, startStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, endStr,   -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var results: [ScreenpipeFrame] = []
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime, .withTimeZone]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = String(cString: sqlite3_column_text(stmt, 1))
            let app = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let win = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
            let snap = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
            let date = parser.date(from: ts) ?? fallback.date(from: ts) ?? Date()
            results.append(.init(
                id: id, timestamp: date, appName: app, windowName: win,
                browserUrl: url, snapshotPath: snap
            ))
        }

        return results
    }

    /// Day-bounded set of distinct dates that have at least one frame. Used to gray-out empty days in the calendar.
    func availableDays(monthsBack: Int = 3) -> Set<DateComponents> {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT DISTINCT substr(timestamp, 1, 10) AS day
            FROM frames
            WHERE snapshot_path IS NOT NULL
              AND timestamp >= datetime('now', '-\(monthsBack) months')
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: Set<DateComponents> = []
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let str = String(cString: cStr)
                if let date = f.date(from: str) {
                    let comps = cal.dateComponents([.year, .month, .day], from: date)
                    out.insert(comps)
                }
            }
        }
        return out
    }
}
