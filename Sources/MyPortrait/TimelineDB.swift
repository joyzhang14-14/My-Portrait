import Foundation
import GRDB
import SQLite3
import os.log

private let timelineLog = Logger(subsystem: "com.myportrait.db", category: "timeline-sql")

/// 让 SQLite 在 bind 时立即拷贝字符串（Swift 临时 C 字符串只在调用期有效）。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 说话人列表行（SpeakersView 用）。
struct SpeakerListRow: Sendable {
    let id: Int64
    let name: String?
    let sampleCount: Int
    let lastHeardMs: Int64?
    /// 用户真正跑过 voice training 留下 fresh embedding 的时间。nil =
    /// 仅 diarization / 仅 rename(没真训过)。SpeakersView "identified"
    /// 计数只数这个非 nil 的,才是"我训过几条"的本意。
    let trainedAtMs: Int64?
}

/// 声音相似的说话人候选（用于建议合并）。
struct SimilarSpeaker: Sendable, Identifiable {
    let id: Int64
    let name: String?
    let similarity: Float
}

@inline(__always)
private func sqlErr(_ db: OpaquePointer?) -> String {
    sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "unknown"
}

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
    let snapshotPath: String?     // JPG path (already resolved to absolute, file exists)
    let videoPath: String?        // MP4 path (already resolved to absolute, file exists)
    let videoOffsetMs: Int        // offset within the MP4, in milliseconds
    let videoFps: Double          // chunk's frames-per-second

    /// True if the frame can actually paint pixels. `false` means the DB
    /// recorded the frame's metadata (OCR / app / window) but neither the
    /// JPG snapshot nor the MP4 chunk is loadable. FramePreview should
    /// short-circuit to a "no image" placeholder for these instead of
    /// repeatedly retrying loaders.
    var hasViewableMedia: Bool { snapshotPath != nil || videoPath != nil }
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

    // Path resolution is centralised in `AssetPath.resolve` — see
    // PortraitDBImpl + Sources/MyPortrait/AssetPath.swift. TimelineDB
    // delegates so the two read paths agree.

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

        // UTC —— 跟 pendingDays / availableDays / events/<date>/ 目录命名一致。
        // 用本地日历会把 UTC 午夜的 day 错位到前一天（负偏移时区）。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
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
        // 历史上限定"必须有 snapshot 或 video chunk",防止误显示空帧。
        // **screenpipe import 的帧没有媒体只有 OCR 文本**,放行 device_name='imported'
        // 让它们也出现在 timeline(渲染层有 NoMediaPlaceholder 兜底)。
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
            WHERE (f.snapshot_path IS NOT NULL
                   OR f.video_chunk_id IS NOT NULL
                   OR f.device_name = 'imported')
              AND f.timestamp_ms >= ? AND f.timestamp_ms < ?
            ORDER BY f.timestamp_ms ASC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
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
            let snap  = AssetPath.resolve(sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) })
            let vpath = AssetPath.resolve(sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) })
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

    /// 数当天有多少帧的 OCR 文本命中给定关键词集合中**任一个**(substring,
    /// 大小写不敏感)。给 PersonalityRefresh 的 OCR 验证器(≥20 帧才落 tag)用。
    /// 空 keywords → 返回 0。
    func frameCount(on day: Date, keywords: [String]) -> Int {
        guard exists, !keywords.isEmpty else { return 0 }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        // 拼 N 个 LOWER(full_text) LIKE ? 用 OR 串。SQLite ASCII LIKE 自带
        // 不敏感,但 LOWER 兜底中英混排里的大小写;中文走 substring 字面匹配。
        let likes = Array(repeating: "LOWER(full_text) LIKE ?", count: keywords.count)
            .joined(separator: " OR ")
        let sql = """
            SELECT COUNT(DISTINCT id) FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms < ?
              AND full_text IS NOT NULL AND length(full_text) > 4
              AND (\(likes))
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Self.dbMs(dayStart))
        sqlite3_bind_int64(stmt, 2, Self.dbMs(dayEnd))
        for (i, kw) in keywords.enumerated() {
            let pat = "%" + kw.lowercased() + "%"
            sqlite3_bind_text(stmt, Int32(3 + i), pat, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
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

        // Window by **recording** time, not transcription time — WhisperKit
        // may finish minutes after the audio was captured. The sidebar
        // shows "what was being said around X", which means the user's
        // wall-clock when they were talking, not when the worker drained.
        let sql = """
            SELECT ac.recorded_at_ms,
                   t.text,
                   COALESCE(ac.device, ''),
                   COALESCE(ac.is_input, 1),
                   t.speaker_id,
                   s.name
            FROM audio_transcriptions t
            JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
            LEFT JOIN speakers s ON s.id = t.speaker_id AND s.hallucination = 0
            WHERE ac.recorded_at_ms >= ? AND ac.recorded_at_ms <= ?
              AND t.text IS NOT NULL AND t.text != ''
            ORDER BY ac.recorded_at_ms ASC
            LIMIT 60
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
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
            let speakerName: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            out.append(.init(
                timestamp: Self.msToDate(ts),
                text: trimmed,
                device: device,
                isInput: isInput,
                speakerId: speakerId,
                speakerName: speakerName    // LEFT JOIN speakers(hallucination=0):命名簇出名字,匿名/误判出 nil
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
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

    /// 采集过的所有 app 名（去重），按出现次数从多到少。供 Settings → Privacy
    /// 的 "ignored apps" 下拉用——让用户从真实捕获过的名字里挑，不用猜精确名。
    func distinctAppNames(limit: Int = 200) -> [String] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT app_name, COUNT(*) AS n
            FROM frames
            WHERE app_name IS NOT NULL AND app_name != ''
            GROUP BY app_name
            ORDER BY n DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// 最近 `lookback` 秒内的活跃 app + 窗口频次。给 AI chat 的 Quick Actions
    /// 动态模板用 —— 端口自 screenpipe suggestions.rs 的 fetch_app_activity /
    /// fetch_window_activity。同一次查询拉两组数据,避免主线程跑两次 SQL。
    struct RecentActivity: Sendable {
        struct AppCount: Sendable {
            let appName: String
            /// 该 app 出现过帧的 distinct 分钟数 —— 真实活跃时长(粒度:分)。
            /// 跟 macOS Screen Time 的算法一致。
            let activeMinutes: Int
            /// raw frame 计数。给排序用,**不要拿来推时间** —— 帧是 event-
            /// driven(app/window 切换才记),不是均匀采样;
            /// 用 active_minutes 表达"用了多久"。
            let frameCount: Int
        }
        struct WindowCount: Sendable {
            let appName: String
            let windowName: String
            let activeMinutes: Int
            let frameCount: Int
        }
        let apps: [AppCount]
        let windows: [WindowCount]
        /// 整个查询窗口内出现过帧的 distinct 分钟数(跨所有 app 去重)。
        let totalActiveMinutes: Int
        var totalFrames: Int { apps.reduce(0) { $0 + $1.frameCount } }
    }

    /// 兼容旧调用方:从 `now - lookback` 到 `now`。HomeView Quick Actions 用。
    func recentActivity(lookback: TimeInterval = 3600) -> RecentActivity {
        let end = Date()
        let start = end.addingTimeInterval(-lookback)
        return activity(from: start, to: end)
    }

    /// 显式时间段:查 `[start, end]` 内的活跃 app + 窗口频次 +真实分钟数。
    ///
    /// **active_minutes 不是 frame_count / 60**:帧是 event-driven(app/window
    /// 切换才存),Terminal 光标停 6 小时可能只有 200 帧。改用
    /// `COUNT(DISTINCT 每分钟的桶)` —— 这分钟有任何帧 = 这分钟在用,
    /// 跟 macOS Screen Time 算法一致。
    func activity(from start: Date, to end: Date) -> RecentActivity {
        guard exists else { return .init(apps: [], windows: [], totalActiveMinutes: 0) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .init(apps: [], windows: [], totalActiveMinutes: 0)
        }
        defer { sqlite3_close(db) }

        let startMs = Self.dbMs(start)
        let endMs = Self.dbMs(end)

        // app 维度:active_minutes 用 timestamp_ms / 60000 当桶 ID 去重。
        // 同时回 frame_count 给排序。
        var appsOut: [RecentActivity.AppCount] = []
        let appSQL = """
            SELECT app_name,
                   COUNT(*) AS frames,
                   COUNT(DISTINCT timestamp_ms / 60000) AS active_min
            FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
              AND app_name IS NOT NULL AND app_name != ''
            GROUP BY app_name
            ORDER BY active_min DESC, frames DESC
            LIMIT 20
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, appSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, startMs)
            sqlite3_bind_int64(stmt, 2, endMs)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    let name = String(cString: c)
                    let frames = Int(sqlite3_column_int(stmt, 1))
                    let mins = Int(sqlite3_column_int(stmt, 2))
                    appsOut.append(.init(appName: name, activeMinutes: mins, frameCount: frames))
                }
            }
            sqlite3_finalize(stmt)
        }

        var winsOut: [RecentActivity.WindowCount] = []
        let winSQL = """
            SELECT app_name, window_name,
                   COUNT(*) AS frames,
                   COUNT(DISTINCT timestamp_ms / 60000) AS active_min
            FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
              AND app_name IS NOT NULL AND app_name != ''
              AND window_name IS NOT NULL AND window_name != ''
            GROUP BY app_name, window_name
            ORDER BY active_min DESC, frames DESC
            LIMIT 20
            """
        if sqlite3_prepare_v2(db, winSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, startMs)
            sqlite3_bind_int64(stmt, 2, endMs)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let appC = sqlite3_column_text(stmt, 0),
                   let winC = sqlite3_column_text(stmt, 1) {
                    let app = String(cString: appC)
                    let win = String(cString: winC)
                    let frames = Int(sqlite3_column_int(stmt, 2))
                    let mins = Int(sqlite3_column_int(stmt, 3))
                    winsOut.append(.init(appName: app, windowName: win,
                                          activeMinutes: mins, frameCount: frames))
                }
            }
            sqlite3_finalize(stmt)
        }

        // total_active_minutes: 整个窗口去重(任意 app),不是 sum(per-app)
        // ——同一分钟用了多个 app 只算 1 分钟,跟 Screen Time 一致。
        var totalMins = 0
        let totalSQL = """
            SELECT COUNT(DISTINCT timestamp_ms / 60000)
            FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
              AND app_name IS NOT NULL AND app_name != ''
            """
        if sqlite3_prepare_v2(db, totalSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, startMs)
            sqlite3_bind_int64(stmt, 2, endMs)
            if sqlite3_step(stmt) == SQLITE_ROW {
                totalMins = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        return .init(apps: appsOut, windows: winsOut, totalActiveMinutes: totalMins)
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
    /// Read-only — works against the unified portrait.sqlite.
    func sampleTranscripts(forSpeakerId speakerId: Int64, limit: Int = 5) -> [String] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT text
            FROM audio_transcriptions
            WHERE speaker_id = ?
              AND text IS NOT NULL
              AND length(text) > 12
            ORDER BY transcribed_at_ms DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, speakerId)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// 所有未隐藏的说话人 + 转录条数 + 最后听到时间。SpeakersView 列表用。
    func loadSpeakers() -> [SpeakerListRow] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        // 列表"最后活动时间"= **严格的最后转录时间** —— 不混 updated_at_ms。
        //
        // 之前为了让"重训完立刻显示 just now"取 max(transcribed, updated_at),
        // 副作用是任何 admin 操作(merge / dedupe / 重训 / 命名)都把时间顶
        // 到 now,造成"两条录音相隔很久但 UI 都显示 2 min ago"。
        //
        // 现在严格走 transcribed_at:行展示的"X ago"就是你最后听到这个人的
        // 时间,跟 UI 操作无关。ORDER BY 用 transcribed_at,没转录的(刚训
        // 完没说话)用 created_at 当 secondary 排序兜底。
        let sql = """
            SELECT s.id, s.name,
                   COUNT(t.id) AS sample_count,
                   MAX(t.transcribed_at_ms) AS last_transcribed,
                   s.updated_at_ms AS speaker_updated,
                   s.trained_at_ms AS trained_at
            FROM speakers s
            LEFT JOIN audio_transcriptions t ON t.speaker_id = s.id
            WHERE s.hallucination = 0
            GROUP BY s.id
            ORDER BY COALESCE(last_transcribed, s.created_at_ms) DESC, s.id DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [SpeakerListRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let count = Int(sqlite3_column_int(stmt, 2))
            let lastTranscribed: Int64? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, 3)
            _ = sqlite3_column_int64(stmt, 4)   // speakerUpdated 不再用,保留 SELECT 顺序
            let trainedAt: Int64? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, 5)
            // **严格只看转录时间**。没说过话(没转录)就 nil → UI 不显示
            // "X ago"那条 pill。不再混 updated_at_ms 防 admin 操作刷时间。
            out.append(SpeakerListRow(
                id: id, name: name, sampleCount: count,
                lastHeardMs: lastTranscribed, trainedAtMs: trainedAt
            ))
        }
        return out
    }

    /// 给说话人改名。
    @discardableResult
    /// 该 speaker 最近一条转录所属 audio chunk 的绝对文件路径,用于试听。
    /// nil = 没数据 / 文件已被清理。
    func latestAudioPath(forSpeakerId speakerId: Int64) -> String? {
        guard exists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT c.file_path
            FROM audio_transcriptions t
            JOIN audio_chunks c ON c.id = t.audio_chunk_id
            WHERE t.speaker_id = ?
              AND t.text IS NOT NULL AND t.text != ''
            ORDER BY c.recorded_at_ms DESC
            LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, speakerId)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        let raw = String(cString: cstr)
        // file_path 通常是相对 ~/.portrait/ 的 raw_data/audio/xxx.mp4。
        // resolve 到绝对路径,文件不存在就当无音频。
        return AssetPath.resolve(raw)
    }

    func renameSpeaker(id speakerId: Int64, to name: String) -> Bool {
        runSpeakerWrite(
            sql: "UPDATE speakers SET name = ?, updated_at_ms = ? WHERE id = ?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(stmt, 3, speakerId)
            }
        )
    }

    /// 把说话人标记为幻听（hallucination=1），列表不再显示。
    @discardableResult
    func markSpeakerHallucination(id speakerId: Int64) -> Bool {
        runSpeakerWrite(
            sql: "UPDATE speakers SET hallucination = 1, updated_at_ms = ? WHERE id = ?",
            bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(stmt, 2, speakerId)
            }
        )
    }

    /// 时间窗 [fromMs, toMs] 内、来自麦克风输入设备的音频块被分到的所有
    /// speaker_id（含重复，调用方计票）。声纹训练用。
    func inputSpeakerVotes(fromMs: Int64, toMs: Int64) -> [Int64] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT t.speaker_id
            FROM audio_transcriptions t
            JOIN audio_chunks c ON c.id = t.audio_chunk_id
            WHERE c.is_input = 1
              AND c.recorded_at_ms BETWEEN ? AND ?
              AND t.speaker_id IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fromMs)
        sqlite3_bind_int64(stmt, 2, toMs)
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_int64(stmt, 0))
        }
        return out
    }

    /// **voice training 用** —— 把训练录到的 30s embedding 直接写进
    /// speakers + speaker_embeddings 两张表。
    ///
    /// - 同名 speaker 已存在 → centroid 覆盖成新 embedding(刚训练的算
    ///   authoritative),embedding_count 重置 1,hallucination 清 0,追加
    ///   一条 sample 到 speaker_embeddings
    /// - 不存在 → INSERT 新行
    ///
    /// 不依赖 diarization、不依赖 transcription —— 纯 DB 写。返回 speaker_id。
    func upsertVoiceTrainedSpeaker(name: String, embedding: [Float]) -> Int64? {
        guard exists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let blob = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // 1) 找所有同名(case-insensitive,排除 hallucination)。
        //    历史 bug:有时 diarization 自动建的 speaker 在用户改名前先被
        //    rename,name 时机错位 → 上次 upsert 没命中老条目,又 INSERT
        //    一条新的,造成两个 "Joy"。这里取所有同名,**保留 id 最小**
        //    (= 最老 = sample 累计最多的那条)作为 keeper,后面的 dupe
        //    合并进 keeper 后删掉,保证 voice training 之后只有一条同名。
        var duplicateIds: [Int64] = []
        if let stmt = prepare(db, """
            SELECT id FROM speakers
            WHERE LOWER(name) = LOWER(?)
              AND hallucination = 0
            ORDER BY id ASC
            """) {
            sqlite3_bind_text(stmt, 1, name, -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                duplicateIds.append(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        var speakerId: Int64? = duplicateIds.first
        // 2a) 把后面的 dupe 合并进 keeper:把它们的 speaker_embeddings +
        //     audio_transcriptions reassign,再删 dupe speakers 行。这样
        //     keeper 拿到所有历史样本和转录归属。
        if duplicateIds.count > 1, let keeperId = speakerId {
            for dupeId in duplicateIds.dropFirst() {
                if let stmt = prepare(db, "UPDATE speaker_embeddings SET speaker_id = ? WHERE speaker_id = ?") {
                    sqlite3_bind_int64(stmt, 1, keeperId)
                    sqlite3_bind_int64(stmt, 2, dupeId)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
                if let stmt = prepare(db, "UPDATE audio_transcriptions SET speaker_id = ? WHERE speaker_id = ?") {
                    sqlite3_bind_int64(stmt, 1, keeperId)
                    sqlite3_bind_int64(stmt, 2, dupeId)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
                if let stmt = prepare(db, "DELETE FROM speakers WHERE id = ?") {
                    sqlite3_bind_int64(stmt, 1, dupeId)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
            timelineLog.warning("upsertVoiceTrainedSpeaker: merged \(duplicateIds.count - 1) duplicate '\(name, privacy: .public)' row(s) into id=\(keeperId)")
        }

        // 2) upsert speakers row(trained_at_ms = nowMs 标记"用户真训过")
        if speakerId == nil {
            guard let ins = prepare(db, """
                INSERT INTO speakers (name, centroid, embedding_count, hallucination, created_at_ms, updated_at_ms, trained_at_ms)
                VALUES (?, ?, 1, 0, ?, ?, ?)
                """) else { return nil }
            sqlite3_bind_text(ins, 1, name, -1, transient)
            blob.withUnsafeBytes { rawBuf in
                sqlite3_bind_blob(ins, 2, rawBuf.baseAddress, Int32(rawBuf.count), transient)
            }
            sqlite3_bind_int64(ins, 3, nowMs)
            sqlite3_bind_int64(ins, 4, nowMs)
            sqlite3_bind_int64(ins, 5, nowMs)   // trained_at_ms
            let ok = sqlite3_step(ins) == SQLITE_DONE
            sqlite3_finalize(ins)
            guard ok else { return nil }
            speakerId = sqlite3_last_insert_rowid(db)
        } else if let id = speakerId {
            guard let upd = prepare(db, """
                UPDATE speakers
                SET centroid = ?, embedding_count = 1, hallucination = 0,
                    updated_at_ms = ?, trained_at_ms = ?
                WHERE id = ?
                """) else { return nil }
            blob.withUnsafeBytes { rawBuf in
                sqlite3_bind_blob(upd, 1, rawBuf.baseAddress, Int32(rawBuf.count), transient)
            }
            sqlite3_bind_int64(upd, 2, nowMs)
            sqlite3_bind_int64(upd, 3, nowMs)   // trained_at_ms
            sqlite3_bind_int64(upd, 4, id)
            let ok = sqlite3_step(upd) == SQLITE_DONE
            sqlite3_finalize(upd)
            guard ok else { return nil }

            // 重训:清掉这个 speaker 的所有旧样本向量。否则 matchSpeaker 第 1 步
            // 遍历 speaker_embeddings 时,旧的(可能采到的是别人 / 是脏样本)
            // 余弦可能压过新训练的样本,导致重训后说话还被错配回原聚类。
            if let del = prepare(db, "DELETE FROM speaker_embeddings WHERE speaker_id = ?") {
                sqlite3_bind_int64(del, 1, id)
                _ = sqlite3_step(del)
                sqlite3_finalize(del)
            }
        }

        // 3) append sample to speaker_embeddings(matchSpeaker 也比对这张表)
        if let id = speakerId, let ins2 = prepare(db, """
            INSERT INTO speaker_embeddings (speaker_id, embedding, created_at_ms)
            VALUES (?, ?, ?)
            """) {
            sqlite3_bind_int64(ins2, 1, id)
            blob.withUnsafeBytes { rawBuf in
                sqlite3_bind_blob(ins2, 2, rawBuf.baseAddress, Int32(rawBuf.count), transient)
            }
            sqlite3_bind_int64(ins2, 3, nowMs)
            _ = sqlite3_step(ins2)
            sqlite3_finalize(ins2)
        }

        return speakerId
    }

    /// 窗口内**已转录**(audio_transcriptions 有行)的输入音频条数。
    /// voice training screenpipe 风格用 —— 不依赖 diarization,只看
    /// 转录是否产出行。≥1 就可以触发 reassignInputTranscriptionsToSpeaker。
    func transcribedInputCount(fromMs: Int64, toMs: Int64) -> Int {
        guard exists else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT count(*) FROM audio_transcriptions t
            JOIN audio_chunks c ON c.id = t.audio_chunk_id
            WHERE c.is_input = 1 AND c.recorded_at_ms BETWEEN ? AND ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fromMs)
        sqlite3_bind_int64(stmt, 2, toMs)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// 找已有同名 speaker(case-insensitive 不算,精确匹配)→ 返回 id;
    /// 没找到 → 新建一行返回新 id。voice training screenpipe 风格用。
    func findOrCreateSpeaker(name: String) -> Int64? {
        guard exists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        // 先查
        if let stmt = prepare(db, "SELECT id FROM speakers WHERE name = ? LIMIT 1") {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqlite3_column_int64(stmt, 0)
            }
        }
        // 没就插
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let ins = prepare(db,
            "INSERT INTO speakers (name, created_at_ms, updated_at_ms, hallucination) VALUES (?, ?, ?, 0)"
        ) else { return nil }
        defer { sqlite3_finalize(ins) }
        sqlite3_bind_text(ins, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(ins, 2, nowMs)
        sqlite3_bind_int64(ins, 3, nowMs)
        guard sqlite3_step(ins) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// **screenpipe 风格的 voice training 核心动作** —— 把训练窗口里所有
    /// input device 的 transcription 行直接重写 speaker_id 到指定 speaker,
    /// 不依赖 diarization 是否跑通 / 是否产出 cluster。返回更新行数。
    func reassignInputTranscriptionsToSpeaker(
        _ speakerId: Int64, fromMs: Int64, toMs: Int64
    ) -> Int {
        guard exists else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        let sql = """
            UPDATE audio_transcriptions
            SET speaker_id = ?
            WHERE audio_chunk_id IN (
                SELECT id FROM audio_chunks
                WHERE is_input = 1 AND recorded_at_ms BETWEEN ? AND ?
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, speakerId)
        sqlite3_bind_int64(stmt, 2, fromMs)
        sqlite3_bind_int64(stmt, 3, toMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// 窗口内还在处理中（status 不是 done/failed）的输入（麦克风）音频块数。
    /// voice training 用它判断「训练窗口的音频是否已全部转录 + 分离完」，
    /// 全部处理完再统计声纹簇，避免只拿到先处理完的那部分。
    func pendingInputChunkCount(fromMs: Int64, toMs: Int64) -> Int {
        guard exists else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT count(*) FROM audio_chunks
            WHERE is_input = 1
              AND recorded_at_ms BETWEEN ? AND ?
              AND status NOT IN ('done', 'failed')
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fromMs)
        sqlite3_bind_int64(stmt, 2, toMs)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// 找声音相似的说话人（centroid 余弦相似度 > 0.25，按相似度降序取前 limit）。
    /// 用于在 Speakers 页建议「这俩是不是同一个人 → 合并」。
    func similarSpeakers(to speakerId: Int64, limit: Int = 5) -> [SimilarSpeaker] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT id, name, centroid FROM speakers WHERE hallucination = 0 AND centroid IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var target: [Float]?
        var others: [(id: Int64, name: String?, vec: [Float])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 2))
            guard let vec = Data(bytes: blob, count: len).asFloats else { continue }
            if id == speakerId { target = vec } else { others.append((id, name, vec)) }
        }
        guard let t = target else { return [] }

        let scored = others.compactMap { item -> SimilarSpeaker? in
            guard item.vec.count == t.count else { return nil }
            let sim = VectorMath.cosineSimilarity(t, item.vec)
            guard sim > 0.25 else { return nil }
            return SimilarSpeaker(id: item.id, name: item.name, similarity: sim)
        }.sorted { $0.similarity > $1.similarity }
        return Array(scored.prefix(limit))
    }

    /// 合并两个说话人：把 `merge` 的转录 + 声纹样本全部改挂到 `keep`，再删掉 `merge`。
    /// 事务执行。keep 的 centroid 不重算 —— matchSpeaker 主要比对样本向量，已够用。
    ///
    /// **为什么用 GRDB 连接而不是裸 sqlite**：`UPDATE audio_transcriptions` 会触发
    /// FTS5 同步触发器 `__transcriptions_fts_au`，它要用自定义分词器 `foundation_icu`
    /// 重新分词。裸 sqlite 连接没注册这个分词器 → 触发器报错 → 整个事务回滚、
    /// 合并静默失败。GRDB 连接通过 prepareDatabase 注册分词器。
    @discardableResult
    func mergeSpeakers(keep keepId: Int64, merge mergeId: Int64) -> Bool {
        guard exists, keepId != mergeId else { return false }
        do {
            var config = Configuration()
            config.prepareDatabase { db in
                db.add(tokenizer: FoundationTokenizer.self)
            }
            let queue = try DatabaseQueue(path: dbPath, configuration: config)
            try queue.write { db in
                // dict-form 参数:绕开 [Int64,Int64] → [any DatabaseValueConvertible]
                // existential 转换里 Swift runtime _getWitnessTable 偶发死循环。
                try db.execute(sql:
                    "UPDATE audio_transcriptions SET speaker_id = :keep WHERE speaker_id = :merge",
                    arguments: ["keep": keepId, "merge": mergeId])
                try db.execute(sql:
                    "UPDATE speaker_embeddings SET speaker_id = :keep WHERE speaker_id = :merge",
                    arguments: ["keep": keepId, "merge": mergeId])
                try db.execute(sql: "DELETE FROM speakers WHERE id = :merge",
                               arguments: ["merge": mergeId])
            }
            return true
        } catch {
            timelineLog.error("mergeSpeakers failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// speakers 表的单语句写入小工具。
    private func runSpeakerWrite(sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        guard exists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            timelineLog.error("SQL prepare failed: \(sqlErr(db), privacy: .public) — sql=\(sql, privacy: .public)")
            return nil
        }
        return stmt
    }
}
