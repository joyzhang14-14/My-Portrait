import Foundation
import GRDB
import os.log

private let storeLog = Logger(subsystem: "com.myportrait.memory", category: "writing-store")

// MARK: - 跑过的天状态

enum WritingCaptureRunStatus: String, Sendable {
    case pending             // 该天有 raw 但没跑过 / 等下次 Run
    case processing          // 正在跑(防并发)
    case pendingReview = "pending_review"
    case approved
    case rejectedForRerun = "rejected_for_rerun"
    case failed
}

struct WritingCaptureRun: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var dateUtc: String                // 'YYYY-MM-DD'
    var status: String                 // WritingCaptureRunStatus.rawValue
    var runId: String?
    var startedAt: Int64?
    var completedAt: Int64?
    var errorMessage: String?
    var pass1TokenUsage: Int?
    var pass2TokenUsage: Int?
    var discardedCount: Int?
    var recordsCount: Int?

    static let databaseTableName = "writing_capture_runs"
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - WritingCaptureStore

/// 写作采集 worker 的 DAO —— `writing_records` / `writing_records_staged` /
/// `writing_capture_runs` + 跨 raw 表读(`typing_events` / `keystroke_log` /
/// `frames`)。
///
/// 所有 DB IO 在 `dbPool` 上同步执行(GRDB 内部已 thread-safe)。`Worker` 从
/// MainActor 调用时用 `Task.detached` 包一下。
struct WritingCaptureStore: Sendable {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - 「未处理的天」

    /// 找有 raw 但还没 approved 的 UTC 日期(YYYY-MM-DD)。
    /// 状态 NULL / pending / rejected_for_rerun / failed 都算未处理。
    func unprocessedDays() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: """
                WITH days_with_raw AS (
                    SELECT DISTINCT date(started_at/1000, 'unixepoch') AS d FROM typing_events
                    UNION
                    SELECT DISTINCT date(ts_ms/1000, 'unixepoch')      AS d FROM keystroke_log
                    UNION
                    SELECT DISTINCT date(timestamp_ms/1000, 'unixepoch') AS d FROM frames
                )
                SELECT d.d FROM days_with_raw d
                LEFT JOIN writing_capture_runs r ON r.date_utc = d.d
                WHERE r.status IS NULL
                   OR r.status IN ('pending', 'rejected_for_rerun', 'failed')
                ORDER BY d.d ASC
                """)
        }
    }

    /// 查所有 status = 'pending_review' 的天,按 date 升序。给 UI Pending review 区。
    func fetchPendingReviewDays() throws -> [WritingCaptureRun] {
        try dbPool.read { db in
            try WritingCaptureRun.fetchAll(
                db,
                sql: "SELECT * FROM writing_capture_runs WHERE status = 'pending_review' ORDER BY date_utc ASC"
            )
        }
    }

    func fetchRun(date: String) throws -> WritingCaptureRun? {
        try dbPool.read { db in
            try WritingCaptureRun.fetchOne(
                db,
                sql: "SELECT * FROM writing_capture_runs WHERE date_utc = ? LIMIT 1",
                arguments: [date]
            )
        }
    }

    /// upsert 一行 writing_capture_runs(`date_utc` UNIQUE → ON CONFLICT 替换关键字段)。
    func upsertRunStatus(
        date: String,
        status: WritingCaptureRunStatus,
        runId: String? = nil,
        startedAt: Int64? = nil,
        completedAt: Int64? = nil,
        errorMessage: String? = nil,
        pass1TokenUsage: Int? = nil,
        pass2TokenUsage: Int? = nil,
        discardedCount: Int? = nil,
        recordsCount: Int? = nil
    ) throws {
        try dbPool.write { db in
            // 用 INSERT ON CONFLICT(date_utc) 做 upsert。COALESCE 让 nil 入参
            // 保持表里现有值,不被覆盖成 NULL。
            try db.execute(sql: """
                INSERT INTO writing_capture_runs
                    (date_utc, status, run_id, started_at, completed_at, error_message,
                     pass1_token_usage, pass2_token_usage, discarded_count, records_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(date_utc) DO UPDATE SET
                    status            = excluded.status,
                    run_id            = COALESCE(excluded.run_id, writing_capture_runs.run_id),
                    started_at        = COALESCE(excluded.started_at, writing_capture_runs.started_at),
                    completed_at      = COALESCE(excluded.completed_at, writing_capture_runs.completed_at),
                    error_message     = COALESCE(excluded.error_message, writing_capture_runs.error_message),
                    pass1_token_usage = COALESCE(excluded.pass1_token_usage, writing_capture_runs.pass1_token_usage),
                    pass2_token_usage = COALESCE(excluded.pass2_token_usage, writing_capture_runs.pass2_token_usage),
                    discarded_count   = COALESCE(excluded.discarded_count, writing_capture_runs.discarded_count),
                    records_count     = COALESCE(excluded.records_count, writing_capture_runs.records_count)
                """,
                arguments: [
                    date, status.rawValue, runId, startedAt, completedAt, errorMessage,
                    pass1TokenUsage, pass2TokenUsage, discardedCount, recordsCount
                ])
        }
    }

    // MARK: - 读 raw(某 UTC 天)

    /// 读某 UTC 日期的 typing_events。
    func typingEventsForDay(_ date: String) throws -> [TypingEvent] {
        let (startMs, endMs) = try Self.utcDayRangeMs(date: date)
        return try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: """
                    SELECT id, bundle_id, element_hash, started_at, ended_at, text, edit_log,
                           total_chars, session_start, end_value, stripped, url
                    FROM typing_events
                    WHERE started_at >= ? AND started_at < ?
                    ORDER BY started_at ASC
                    """,
                arguments: [startMs, endMs]
            )
        }
    }

    /// 读某 UTC 日期的 keystrokes,排除黑名单。
    func keystrokesForDay(
        _ date: String,
        excludeBundleIds: Set<String>
    ) throws -> [KeystrokeEntry] {
        let (startMs, endMs) = try Self.utcDayRangeMs(date: date)
        return try dbPool.read { db in
            if excludeBundleIds.isEmpty {
                return try KeystrokeEntry.fetchAll(
                    db,
                    sql: """
                        SELECT id, ts_ms, bundle_id, char, is_backspace FROM keystroke_log
                        WHERE ts_ms >= ? AND ts_ms < ?
                        ORDER BY ts_ms ASC
                        """,
                    arguments: [startMs, endMs]
                )
            }
            // 用 IN(?, ?, ?) 排除
            let placeholders = excludeBundleIds.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [startMs, endMs]
            args.append(contentsOf: excludeBundleIds.map { $0 as DatabaseValueConvertible })
            return try KeystrokeEntry.fetchAll(
                db,
                sql: """
                    SELECT id, ts_ms, bundle_id, char, is_backspace FROM keystroke_log
                    WHERE ts_ms >= ? AND ts_ms < ?
                      AND bundle_id NOT IN (\(placeholders))
                    ORDER BY ts_ms ASC
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// 读某 UTC 日期的 frames(已过滤 full_text 非空)。
    /// 注:frames.app_name 是 localized name(如 "Obsidian"),不是 bundle id。
    /// 跨表跟 typing_events.bundle_id 不能直接比对 —— 调用方(Step 0)按时间
    /// 关联,不强求 app 字段相等。
    func framesForDay(_ date: String) throws -> [WritingCaptureRawOcr] {
        let (startMs, endMs) = try Self.utcDayRangeMs(date: date)
        return try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timestamp_ms, app_name, browser_url, full_text FROM frames
                    WHERE timestamp_ms >= ? AND timestamp_ms < ?
                      AND full_text IS NOT NULL AND full_text != ''
                    ORDER BY timestamp_ms ASC
                    """,
                arguments: [startMs, endMs]
            )
            return rows.map {
                WritingCaptureRawOcr(
                    id: $0["id"],
                    tsMs: $0["timestamp_ms"],
                    app: ($0["app_name"] as String?) ?? "unknown",
                    url: $0["browser_url"],
                    text: ($0["full_text"] as String?) ?? ""
                )
            }
        }
    }

    // MARK: - staged 写 / 读 / 清

    /// 把 Pass 2 输出落到 writing_records_staged。
    func insertStaged(
        date: String,
        runId: String,
        promptId: String,
        records: [WritingCaptureRecord],
        rawPass1Output: String,
        rawPass2Output: String
    ) throws {
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            for r in records {
                let editLogJSON = Self.encodeJSON(r.editLog) ?? "[]"
                let refTypingJSON = Self.encodeJSON(r.referenceTypingEventIds) ?? "[]"
                let refFrameJSON = Self.encodeJSON(r.referenceFrameIds) ?? "[]"
                let refRangeJSON = Self.encodeJSON(r.referenceKeystrokeRange) ?? "{}"
                // raw_output:每条 record 都重复存一份 prompt + pass1 + pass2 raw?
                // 太冗余,只在第一条 record 上挂全 raw。其他 record 的 raw_output
                // 留空,DB 查询时按 worker_run_id JOIN 拿同一份。
                let rawOut: String? = nil  // 暂时简化:不在 staged 上存 raw,
                                            // 由 worker_runs 元数据 + 后续 query 还原。
                try db.execute(sql: """
                    INSERT INTO writing_records_staged
                        (date_utc, start_ts, end_ts, app, url, text, edit_log, confidence,
                         context_summary, source, reference_typing_event_ids,
                         reference_frame_ids, reference_keystroke_range, raw_output,
                         prompt_id, created_at, worker_run_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        date, r.startTs, r.endTs, r.app, r.url, r.text, editLogJSON, r.confidence,
                        r.contextSummary, r.source, refTypingJSON,
                        refFrameJSON, refRangeJSON, rawOut,
                        promptId, createdAt, runId
                    ])
            }
            // 简单存一份 raw 摘要到 writing_capture_runs.error_message 字段?太 hack。
            // 真要存到 staged 第一条的 raw_output 上(下次 Approve 时挪到 writing_records)。
            // 此版本暂不实现,等需要时再加专门的 staging_raw_outputs 表。
            _ = rawPass1Output; _ = rawPass2Output
        }
    }

    /// 读某日 staged 的所有 records(Pending review UI 用)。
    func fetchStagedRecords(date: String) throws -> [StagedRecordRow] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_ts, end_ts, app, url, text, edit_log, confidence,
                           context_summary, source, worker_run_id, created_at
                    FROM writing_records_staged
                    WHERE date_utc = ?
                    ORDER BY start_ts ASC
                    """,
                arguments: [date]
            ).map { r in
                StagedRecordRow(
                    id: r["id"],
                    startTs: r["start_ts"], endTs: r["end_ts"],
                    app: r["app"], url: r["url"],
                    text: r["text"], editLog: r["edit_log"],
                    confidence: r["confidence"],
                    contextSummary: r["context_summary"],
                    source: r["source"],
                    workerRunId: r["worker_run_id"],
                    createdAt: r["created_at"]
                )
            }
        }
    }

    /// 清某日 staged(Reject 用)。
    func clearStaged(date: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM writing_records_staged WHERE date_utc = ?",
                arguments: [date]
            )
        }
    }

    /// Approve:把某日 staged 拷到 writing_records,清 staged,标 runs.status = approved。
    /// 原子事务。
    func approveStaged(date: String) throws -> Int {
        try dbPool.write { db in
            // 1. 拷 staged → writing_records
            try db.execute(sql: """
                INSERT INTO writing_records
                    (start_ts, end_ts, app, url, text, edit_log, confidence,
                     context_summary, source, reference_typing_event_ids,
                     reference_frame_ids, reference_keystroke_range, raw_output,
                     prompt_id, created_at, worker_run_id)
                SELECT start_ts, end_ts, app, url, text, edit_log, confidence,
                       context_summary, source, reference_typing_event_ids,
                       reference_frame_ids, reference_keystroke_range, raw_output,
                       prompt_id, created_at, worker_run_id
                FROM writing_records_staged WHERE date_utc = ?
                """,
                arguments: [date])
            let copied = db.changesCount
            // 2. 清 staged
            try db.execute(
                sql: "DELETE FROM writing_records_staged WHERE date_utc = ?",
                arguments: [date])
            // 3. 标 runs.status = approved
            try db.execute(sql: """
                UPDATE writing_capture_runs SET status = 'approved',
                                                 completed_at = ?
                WHERE date_utc = ?
                """,
                arguments: [Int64(Date().timeIntervalSince1970 * 1000), date])
            return copied
        }
    }

    // MARK: - Helpers

    /// "YYYY-MM-DD" UTC → [start_ms, end_ms) range。
    private static func utcDayRangeMs(date: String) throws -> (Int64, Int64) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let d = fmt.date(from: date) else {
            throw StoreError.invalidDate(date)
        }
        let start = Int64(d.timeIntervalSince1970 * 1000)
        let end = start + 24 * 60 * 60 * 1000
        return (start, end)
    }

    private static func encodeJSON<T: Encodable>(_ v: T) -> String? {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    enum StoreError: LocalizedError {
        case invalidDate(String)
        var errorDescription: String? {
            switch self {
            case .invalidDate(let d): return "Invalid UTC date string: \(d)"
            }
        }
    }
}

/// Pending review UI 显示用的 staged 行投影。
struct StagedRecordRow: Sendable {
    let id: Int64
    let startTs: Int64
    let endTs: Int64
    let app: String
    let url: String?
    let text: String
    let editLog: String              // JSON
    let confidence: Double
    let contextSummary: String?
    let source: String
    let workerRunId: String?
    let createdAt: Int64
}
