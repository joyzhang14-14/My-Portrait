import Foundation
import SQLite3

/// Read/write client for the unified timeline database
/// (`~/.portrait/portrait.sqlite`). Same DB the capture layer writes to —
/// the legacy snapshot was migrated into this schema 2026-05-19.
///
/// Schema highlights (capture / GRDB):
///   - `frames.timestamp_ms`  INTEGER  UTC milliseconds since epoch
///   - `frames.full_text`     TEXT     OCR text inlined per frame
///   - `video_chunks.file_path` / `frames.snapshot_path` are stored
///     RELATIVE to `~/.portrait/` so the data tree is relocatable.
struct TimelineFrame: Identifiable, Hashable {
    let id: Int64
    let timestamp: Date           // UTC
    let appName: String
    let windowName: String
    let browserUrl: String?       // set when the active app is a browser
    let snapshotPath: String?     // JPG path (already resolved to absolute)
    let videoPath: String?        // MP4 path (already resolved to absolute)
    let videoOffsetMs: Int        // offset within the MP4, in milliseconds
    let videoFps: Double          // chunk's frames-per-second
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

struct TimelineDB: Sendable {
    let dbPath: String

    init(path: String? = nil) {
        if let path {
            self.dbPath = path
            return
        }
        // Default order:
        //   1. User-overridden directory in Settings → Storage → Data directory
        //      (lets people relocate to an external drive).
        //   2. The unified capture/timeline DB at ~/.portrait/portrait.sqlite.
        let userDir = ConfigStore.snapshot.dataDirectory
        if !userDir.isEmpty {
            let candidate = (userDir as NSString).expandingTildeInPath
                + "/portrait.sqlite"
            if FileManager.default.fileExists(atPath: candidate) {
                self.dbPath = candidate
                return
            }
        }
        self.dbPath = Storage.portraitDBPath
    }

    /// Root of the assets tree. Relative file paths stored in the DB
    /// (snapshot_path / video_chunks.file_path / audio_chunks.file_path)
    /// are resolved against this. Equal to `~/.portrait/` so the data
    /// tree is fully relocatable.
    private var assetsRoot: String { Storage.rootURL.path }

    /// Resolve a DB-stored file path. Relative paths are joined with the
    /// assets root; absolute paths pass through unchanged (covers any
    /// pre-migration rows that still have an absolute path).
    private func resolvePath(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return p }
        if (p as NSString).isAbsolutePath { return p }
        return (assetsRoot as NSString).appendingPathComponent(p)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// Convert a Swift Date to UTC milliseconds since 1970-01-01.
    private static func dbMs(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func msToDate(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// Fetch frames for a given day window. Returns ordered ascending by timestamp.
    /// `limit` caps the result to keep the UI snappy; default 800 is roughly one
    /// frame per ~2 minutes for 24h.
    func frames(on day: Date, limit: Int = 800) -> [TimelineFrame] {
        guard exists else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let startMs = Self.dbMs(dayStart)
        let endMs = Self.dbMs(dayEnd)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // Most frames live inside an MP4 chunk; a handful have a standalone
        // JPG snapshot. We accept either. video_chunks JOIN surfaces the
        // chunk's file path + fps + start_ts_ms so we can compute the
        // offset (in ms) into the MP4 for any extracted frame.
        let sql = """
            SELECT f.id, f.timestamp_ms, f.app_name,
                   COALESCE(f.window_name, ''),
                   f.browser_url,
                   f.snapshot_path,
                   v.file_path,
                   COALESCE(f.offset_ms, MAX(0, f.timestamp_ms - COALESCE(v.start_ts_ms, f.timestamp_ms))),
                   COALESCE(v.fps, 0)
            FROM frames f
            LEFT JOIN video_chunks v ON v.id = f.video_chunk_id
            WHERE (f.snapshot_path IS NOT NULL OR f.video_chunk_id IS NOT NULL)
              AND f.timestamp_ms >= ? AND f.timestamp_ms < ?
            ORDER BY f.timestamp_ms ASC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var results: [TimelineFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_int64(stmt, 1)
            let app = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let win = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
            let snap  = resolvePath(sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) })
            let vpath = resolvePath(sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) })
            let offsetMs = Int(sqlite3_column_int64(stmt, 7))
            let fps = sqlite3_column_double(stmt, 8)
            results.append(.init(
                id: id, timestamp: Self.msToDate(ts), appName: app, windowName: win,
                browserUrl: url, snapshotPath: snap,
                videoPath: vpath, videoOffsetMs: offsetMs, videoFps: fps
            ))
        }
        return results
    }

    /// Pull deduped OCR text for the given frame IDs. The same screen content
    /// repeats across many adjacent frames, so we line-dedupe and cap total
    /// chars to keep LLM context bounded.
    ///
    /// Reads `frames.full_text` directly (capture schema inlines OCR per
    /// frame — no separate ocr_text table).
    func ocrText(forFrameIds frameIds: [Int64], maxChars: Int = 1500) -> String {
        guard exists, !frameIds.isEmpty else { return "" }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_close(db) }

        // SQLite parameter binding limit is 999 by default — chunk if larger.
        let chunks = stride(from: 0, to: frameIds.count, by: 500).map {
            Array(frameIds[$0..<min($0 + 500, frameIds.count)])
        }

        var seenLines = Set<String>()
        var orderedLines: [String] = []
        var totalLen = 0

        for chunk in chunks {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT full_text
                FROM frames
                WHERE id IN (\(placeholders))
                  AND full_text IS NOT NULL AND length(full_text) > 4
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            for (i, id) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), id)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let raw = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
                for line in raw.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.count >= 3 else { continue }
                    if seenLines.contains(trimmed) { continue }
                    seenLines.insert(trimmed)
                    orderedLines.append(trimmed)
                    totalLen += trimmed.count + 1
                    if totalLen >= maxChars { break }
                }
                if totalLen >= maxChars { break }
            }
            if totalLen >= maxChars { break }
        }

        return orderedLines.joined(separator: "\n")
    }

    /// Distinct app/window combinations active around the given moment.
    /// Used by the Timeline sidebar's "Active Apps" panel.
    func activeApps(around moment: Date, window: TimeInterval = 45) -> [ActiveAppEntry] {
        guard exists else { return [] }

        let startMs = Self.dbMs(moment.addingTimeInterval(-window))
        let endMs = Self.dbMs(moment.addingTimeInterval(window))

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT app_name,
                   COALESCE(window_name, ''),
                   COALESCE(browser_url, ''),
                   MAX(timestamp_ms) as latest
            FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
              AND app_name IS NOT NULL AND app_name != ''
            GROUP BY app_name, window_name
            ORDER BY latest DESC
            LIMIT 30
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)

        var out: [ActiveAppEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let win = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let ts = sqlite3_column_int64(stmt, 3)
            out.append(.init(
                appName: app,
                windowName: win,
                browserUrl: url.isEmpty ? nil : url,
                lastSeen: Self.msToDate(ts)
            ))
        }
        return out
    }

    /// Audio transcriptions near the focused moment. Defaults span the
    /// conversation that was actively happening (favors slightly before,
    /// since you usually look back to read what was just said).
    func audioTranscripts(
        around moment: Date,
        before: TimeInterval = 120,
        after: TimeInterval = 30
    ) -> [AudioTranscriptEntry] {
        guard exists else { return [] }

        let startMs = Self.dbMs(moment.addingTimeInterval(-before))
        let endMs = Self.dbMs(moment.addingTimeInterval(after))

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        // Speakers JOIN goes through audio_chunks → device/is_input + the
        // optional speakers table (older migrated rows may not have a
        // speakers table; LEFT JOIN keeps everything resilient).
        let sql = """
            SELECT t.transcribed_at_ms,
                   t.text,
                   COALESCE(ac.device, ''),
                   COALESCE(ac.is_input, 1),
                   t.speaker_id
            FROM audio_transcriptions t
            LEFT JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
            WHERE t.transcribed_at_ms >= ? AND t.transcribed_at_ms <= ?
              AND t.text IS NOT NULL AND t.text != ''
            ORDER BY t.transcribed_at_ms ASC
            LIMIT 60
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)

        var out: [AudioTranscriptEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let text = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let device = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let isInput = sqlite3_column_int(stmt, 3) != 0
            let speakerIdRaw = sqlite3_column_int64(stmt, 4)
            let speakerId: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(speakerIdRaw)

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            out.append(.init(
                timestamp: Self.msToDate(ts),
                text: trimmed,
                device: device,
                isInput: isInput,
                speakerId: speakerId,
                speakerName: nil    // capture schema doesn't have a speakers table yet
            ))
        }
        return out
    }

    /// Day-bounded set of distinct dates that have at least one frame.
    /// Used to gray-out empty days in the calendar.
    func availableDays(monthsBack: Int = 3) -> Set<DateComponents> {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let cutoffMs = Self.dbMs(
            Calendar(identifier: .gregorian)
                .date(byAdding: .month, value: -monthsBack, to: Date()) ?? Date()
        )
        let sql = """
            SELECT DISTINCT DATE(timestamp_ms/1000, 'unixepoch') AS day
            FROM frames
            WHERE timestamp_ms >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)

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

    // MARK: - Write operations (auto-delete / manual purge)

    struct DeleteResult: Sendable {
        var frames: Int = 0
        var audio: Int = 0
        var error: String? = nil
    }

    /// Delete frames + audio transcriptions strictly before `cutoff`.
    func deleteBefore(_ cutoff: Date, mediaOnly: Bool) -> DeleteResult {
        guard exists else { return DeleteResult() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return DeleteResult(error: "Couldn't open DB read-write at \(dbPath)")
        }
        defer { sqlite3_close(db) }

        let cutoffMs = Self.dbMs(cutoff)
        var result = DeleteResult()

        if let stmt = prepare(db, "DELETE FROM frames WHERE timestamp_ms < ?") {
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_DONE {
                result.frames = Int(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)
        }

        if !mediaOnly,
           let stmt = prepare(db, "DELETE FROM audio_transcriptions WHERE transcribed_at_ms < ?") {
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_DONE {
                result.audio = Int(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)
        }

        return result
    }

    /// Delete frames + audio transcriptions strictly *after* `cutoff`.
    @discardableResult
    func deleteAfter(_ cutoff: Date) -> DeleteResult {
        guard exists else { return DeleteResult() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return DeleteResult(error: "Couldn't open DB read-write at \(dbPath)")
        }
        defer { sqlite3_close(db) }
        let cutoffMs = Self.dbMs(cutoff)
        var result = DeleteResult()
        if let stmt = prepare(db, "DELETE FROM frames WHERE timestamp_ms >= ?") {
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_DONE { result.frames = Int(sqlite3_changes(db)) }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "DELETE FROM audio_transcriptions WHERE transcribed_at_ms >= ?") {
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_DONE { result.audio = Int(sqlite3_changes(db)) }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Speakers: pull a few representative transcripts so the LLM-driven
    /// organiser can guess a name. Filters out short / one-word lines.
    /// Read-only — works against the imported snapshot DB.
    func sampleTranscripts(forSpeakerId speakerId: Int64, limit: Int = 5) -> [String] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT transcription
            FROM audio_transcriptions
            WHERE speaker_id = ?
              AND transcription IS NOT NULL
              AND length(transcription) > 12
            ORDER BY timestamp DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, speakerId)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// Speakers table not part of the capture schema yet — these are
    /// no-ops until a speakers/diarisation pipeline is added.
    @discardableResult
    func renameSpeaker(id speakerId: Int64, to name: String) -> Bool { false }

    @discardableResult
    func markSpeakerHallucination(id speakerId: Int64) -> Bool { false }

    private func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }
}
