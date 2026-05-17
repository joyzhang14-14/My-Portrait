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
    let snapshotPath: String?     // JPG for the small fraction of recent frames
    let videoPath: String?        // MP4 file containing this frame (most cases)
    let videoOffsetIndex: Int     // frame number inside the MP4
    let videoFps: Double           // frames per second the MP4 was written at
}

/// Distinct app + window that was active within a small time window
/// around the focused frame. Used in the Timeline sidebar's "Active Apps" panel.
struct ActiveAppEntry: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let windowName: String
    let browserUrl: String?
    let lastSeen: Date
}

/// One audio transcription chunk near the focused frame's timestamp.
/// Used in the Timeline sidebar's "Audio" panel.
struct AudioTranscriptEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let device: String
    let isInput: Bool
    let speakerId: Int?
    let speakerName: String?
}

struct ScreenpipeDB: Sendable {
    let dbPath: String

    init(path: String = NSString(string: "~/.screenpipe/db.sqlite").expandingTildeInPath) {
        self.dbPath = path
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// SQLite stores timestamps as TEXT and compares lexicographically.
    /// DB format is "2026-05-15T07:00:00.123456+00:00".
    /// We format query bounds as "2026-05-15T07:00:00" (no fractional, no zone
    /// suffix) — strictly a prefix of the DB format, so `>=` / `<` comparisons
    /// work without missing boundary rows.
    ///
    /// (ISO8601DateFormatter with .withInternetDateTime emits "...Z" which
    /// sorts AFTER ".XXX+00:00" lexicographically and was silently dropping
    /// rows at midnight boundaries on past-day queries.)
    private static let queryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func dbTimestamp(_ date: Date) -> String {
        queryDateFormatter.string(from: date)
    }

    /// Fetch frames for a given day window. Returns ordered ascending by timestamp.
    /// `limit` caps the result to keep the UI snappy; default 800 is roughly one frame per ~2 minutes for 24h.
    func frames(on day: Date, limit: Int = 800) -> [ScreenpipeFrame] {
        guard exists else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let startStr = Self.dbTimestamp(dayStart)
        let endStr = Self.dbTimestamp(dayEnd)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // screenpipe stores 99%+ of frames inside MP4 video chunks rather than
        // as individual JPGs. We accept either, JOINing video_chunks to surface
        // the file path + fps so an AVAssetImageGenerator can extract the
        // specific frame on demand.
        let sql = """
            SELECT f.id, f.timestamp, f.app_name, f.window_name, f.browser_url,
                   f.snapshot_path, v.file_path, f.offset_index,
                   COALESCE(v.fps, 0)
            FROM frames f
            LEFT JOIN video_chunks v ON v.id = f.video_chunk_id
            WHERE (f.snapshot_path IS NOT NULL OR f.video_chunk_id IS NOT NULL)
              AND f.timestamp >= ? AND f.timestamp < ?
            ORDER BY f.timestamp ASC
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
            let vpath = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) }
            let offset = Int(sqlite3_column_int64(stmt, 7))
            let fps = sqlite3_column_double(stmt, 8)
            let date = parser.date(from: ts) ?? fallback.date(from: ts) ?? Date()
            results.append(.init(
                id: id, timestamp: date, appName: app, windowName: win,
                browserUrl: url, snapshotPath: snap,
                videoPath: vpath, videoOffsetIndex: offset, videoFps: fps
            ))
        }

        return results
    }

    /// Distinct app/window combinations active around the given moment.
    /// Used by the Timeline sidebar's "Active Apps" panel — shows what the
    /// user had open at this point in the day.
    func activeApps(around moment: Date, window: TimeInterval = 45) -> [ActiveAppEntry] {
        guard exists else { return [] }

        let start = Self.dbTimestamp(moment.addingTimeInterval(-window))
        let end = Self.dbTimestamp(moment.addingTimeInterval(window))

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT app_name,
                   COALESCE(window_name, ''),
                   COALESCE(browser_url, ''),
                   MAX(timestamp) as latest
            FROM frames
            WHERE timestamp >= ? AND timestamp <= ?
              AND app_name IS NOT NULL AND app_name != ''
            GROUP BY app_name, window_name
            ORDER BY latest DESC
            LIMIT 30
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, start, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, end,   -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime, .withTimeZone]

        var out: [ActiveAppEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let win = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let ts = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
            let date = parser.date(from: ts) ?? fallback.date(from: ts) ?? Date()
            out.append(.init(
                appName: app,
                windowName: win,
                browserUrl: url.isEmpty ? nil : url,
                lastSeen: date
            ))
        }
        return out
    }

    /// Audio transcriptions near the focused moment. Defaults span the conversation
    /// that was actively happening (favors slightly before, since you usually look
    /// back to read what was just said).
    func audioTranscripts(
        around moment: Date,
        before: TimeInterval = 120,
        after: TimeInterval = 30
    ) -> [AudioTranscriptEntry] {
        guard exists else { return [] }

        let start = Self.dbTimestamp(moment.addingTimeInterval(-before))
        let end = Self.dbTimestamp(moment.addingTimeInterval(after))

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT t.timestamp,
                   t.transcription,
                   t.device,
                   t.is_input_device,
                   t.speaker_id,
                   s.name
            FROM audio_transcriptions t
            LEFT JOIN speakers s ON s.id = t.speaker_id
            WHERE t.timestamp >= ? AND t.timestamp <= ?
              AND t.transcription IS NOT NULL AND t.transcription != ''
            ORDER BY t.timestamp ASC
            LIMIT 60
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, start, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, end,   -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime, .withTimeZone]

        var out: [AudioTranscriptEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let device = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let isInput = sqlite3_column_int(stmt, 3) != 0
            let speakerIdRaw = sqlite3_column_int64(stmt, 4)
            let speakerId: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(speakerIdRaw)
            let speakerName = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
            let date = parser.date(from: ts) ?? fallback.date(from: ts) ?? Date()

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            out.append(.init(
                timestamp: date,
                text: trimmed,
                device: device,
                isInput: isInput,
                speakerId: speakerId,
                speakerName: speakerName
            ))
        }
        return out
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
