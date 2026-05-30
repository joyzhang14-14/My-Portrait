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

/// 一条用户手动拒绝的 record(给 Pass 3 prompt 当 few-shot 用)。
struct UserRejectionRow: Sendable, Equatable {
    let text: String
    let app: String
    let url: String?
    let kind: String
    let reasonCategory: String
    let reasonText: String?
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

    /// 把所有 status='processing' 的 run 标 failed —— 给 Stop 按钮 / 启动恢复用。
    /// 没 Stop / 进程崩了之后留下来的僵尸 'processing' 行会让 runBacklog
    /// 拒绝再跑("Backlog run already in progress")。
    @discardableResult
    func markStuckProcessingAsFailed(message: String) throws -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try dbPool.write { db in
            try db.execute(sql: """
                UPDATE writing_capture_runs
                SET status        = :status,
                    completed_at  = :now,
                    error_message = :msg
                WHERE status = 'processing'
                """,
                arguments: [
                    "status": WritingCaptureRunStatus.failed.rawValue,
                    "now": now, "msg": message
                ])
            return db.changesCount
        }
    }

    func fetchRun(date: String) throws -> WritingCaptureRun? {
        try dbPool.read { db in
            try WritingCaptureRun.fetchOne(
                db,
                sql: "SELECT * FROM writing_capture_runs WHERE date_utc = :d LIMIT 1",
                arguments: ["d": date]
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
                VALUES (:d, :status, :runId, :startedAt, :completedAt, :errMsg,
                        :p1, :p2, :discarded, :records)
                ON CONFLICT(date_utc) DO UPDATE SET
                    status            = excluded.status,
                    run_id            = COALESCE(excluded.run_id, writing_capture_runs.run_id),
                    started_at        = COALESCE(excluded.started_at, writing_capture_runs.started_at),
                    -- 新 run 开始(processing)时清掉上一次的 completed_at / 错误信息 / 计数,
                    -- 避免 UI 把残留旧字段当成本次的状态展示。
                    completed_at      = CASE WHEN excluded.status='processing' THEN NULL
                                              ELSE COALESCE(excluded.completed_at, writing_capture_runs.completed_at) END,
                    error_message     = CASE WHEN excluded.status='processing' THEN NULL
                                              ELSE COALESCE(excluded.error_message, writing_capture_runs.error_message) END,
                    pass1_token_usage = CASE WHEN excluded.status='processing' THEN NULL
                                              ELSE COALESCE(excluded.pass1_token_usage, writing_capture_runs.pass1_token_usage) END,
                    pass2_token_usage = CASE WHEN excluded.status='processing' THEN NULL
                                              ELSE COALESCE(excluded.pass2_token_usage, writing_capture_runs.pass2_token_usage) END,
                    discarded_count   = CASE WHEN excluded.status='processing' THEN NULL
                                              ELSE COALESCE(excluded.discarded_count, writing_capture_runs.discarded_count) END,
                    records_count     = CASE WHEN excluded.status='processing' THEN NULL
                                              ELSE COALESCE(excluded.records_count, writing_capture_runs.records_count) END
                """,
                arguments: [
                    "d": date, "status": status.rawValue, "runId": runId,
                    "startedAt": startedAt, "completedAt": completedAt, "errMsg": errorMessage,
                    "p1": pass1TokenUsage.map { Int64($0) },
                    "p2": pass2TokenUsage.map { Int64($0) },
                    "discarded": discardedCount.map { Int64($0) },
                    "records": recordsCount.map { Int64($0) }
                ])
        }
    }

    // MARK: - 读 raw(某 UTC 天)

    /// 读某 UTC 日期的 typing_events。
    // MARK: - Backlog cursor(v27) —— 全历史一次跑用

    /// 读 cursor:上次 approve 后处理到的 max ts(exclusive lower bound)。
    /// 0 = 还没 approve 过任何 backlog,从最早 typing 开始。
    func getCursor() throws -> Int64 {
        try dbPool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT last_processed_ts FROM writing_capture_cursor WHERE id = 1"
            ) ?? 0
        }
    }

    /// 推进 cursor。approve backlog 时调。
    func setCursor(_ ts: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE writing_capture_cursor SET last_processed_ts = :ts WHERE id = 1",
                arguments: ["ts": ts]
            )
        }
    }

    /// 读某 run 的 completed_at —— backlog approve 时拿来推进 cursor。
    func fetchRunCompletedAt(date: String) throws -> Int64? {
        try dbPool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT completed_at FROM writing_capture_runs WHERE date_utc = :d",
                arguments: ["d": date]
            )
        }
    }

    /// cursor 之后还有没有未处理的 typing_event。给 UI 灰按钮用。
    func hasTypingEventsAfter(cursor: Int64) throws -> Bool {
        try dbPool.read { db in
            (try Int64.fetchOne(
                db,
                sql: "SELECT 1 FROM typing_events WHERE started_at > :c LIMIT 1",
                arguments: ["c": cursor]
            )) != nil
        }
    }

    /// 第一条 typing_event 的 ts(给 UI / log 展示用)。无 typing 返回 nil。
    func firstTypingEventTs() throws -> Int64? {
        try dbPool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT MIN(started_at) FROM typing_events"
            )
        }
    }

    // MARK: - Range queries(backlog 用)

    func typingEventsInRange(startMs: Int64, endMs: Int64) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: """
                    SELECT id, bundle_id, element_hash, started_at, ended_at, text, edit_log,
                           total_chars, session_start, end_value, stripped, url
                    FROM typing_events
                    WHERE started_at >= :s AND started_at < :e
                    ORDER BY started_at ASC
                    """,
                arguments: ["s": startMs, "e": endMs]
            )
        }
    }

    func keystrokesInRange(
        startMs: Int64, endMs: Int64, excludeBundleIds: Set<String>
    ) throws -> [KeystrokeEntry] {
        try dbPool.read { db in
            if excludeBundleIds.isEmpty {
                return try KeystrokeEntry.fetchAll(
                    db,
                    sql: """
                        SELECT id, ts_ms, bundle_id, char, is_backspace, modifiers FROM keystroke_log
                        WHERE ts_ms >= :s AND ts_ms < :e
                        ORDER BY ts_ms ASC
                        """,
                    arguments: ["s": startMs, "e": endMs]
                )
            }
            let placeholders = excludeBundleIds.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [startMs, endMs]
            args.append(contentsOf: excludeBundleIds.map { $0 as DatabaseValueConvertible })
            return try KeystrokeEntry.fetchAll(
                db,
                sql: """
                    SELECT id, ts_ms, bundle_id, char, is_backspace, modifiers FROM keystroke_log
                    WHERE ts_ms >= ? AND ts_ms < ?
                      AND bundle_id NOT IN (\(placeholders))
                    ORDER BY ts_ms ASC
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    func framesInRange(startMs: Int64, endMs: Int64) throws -> [WritingCaptureRawOcr] {
        let normalizer = AppIdentifierNormalizer.snapshot()
        return try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timestamp_ms, app_name, window_name, browser_url,
                           full_text, ocr_words_json, text_source
                    FROM frames
                    WHERE timestamp_ms >= :s AND timestamp_ms < :e
                      AND full_text IS NOT NULL AND full_text != ''
                    ORDER BY timestamp_ms ASC
                    """,
                arguments: ["s": startMs, "e": endMs]
            )
            return rows.map {
                let rawApp = ($0["app_name"] as String?) ?? "unknown"
                let src = $0["text_source"] as String?
                let raw = ($0["full_text"] as String?) ?? ""
                let filtered = WritingCaptureChromeFilter.applyIfOcr(
                    rawText: raw,
                    wordsJson: $0["ocr_words_json"] as String?,
                    textSource: src
                )
                return WritingCaptureRawOcr(
                    id: $0["id"], tsMs: $0["timestamp_ms"],
                    app: normalizer.bundleId(forLocalizedName: rawApp),
                    url: $0["browser_url"],
                    windowTitle: $0["window_name"] as String?,
                    text: filtered,
                    textSource: src
                )
            }
        }
    }

    /// 某 UTC 日是否有 typing_events。`runUnprocessedDays()` 拿来过滤纯 OCR 天。
    func hasTypingEvents(date: String) throws -> Bool {
        let (startMs, endMs) = try Self.utcDayRangeMs(date: date)
        return try dbPool.read { db in
            let n: Int = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM typing_events WHERE started_at >= :s AND started_at < :e LIMIT 1",
                arguments: ["s": startMs, "e": endMs]
            ) ?? 0
            return n > 0
        }
    }

    func typingEventsForDay(_ date: String) throws -> [TypingEvent] {
        let (startMs, endMs) = try Self.utcDayRangeMs(date: date)
        return try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: """
                    SELECT id, bundle_id, element_hash, started_at, ended_at, text, edit_log,
                           total_chars, session_start, end_value, stripped, url
                    FROM typing_events
                    WHERE started_at >= :startMs AND started_at < :endMs
                    ORDER BY started_at ASC
                    """,
                arguments: ["startMs": startMs, "endMs": endMs]
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
                        SELECT id, ts_ms, bundle_id, char, is_backspace, modifiers FROM keystroke_log
                        WHERE ts_ms >= :startMs AND ts_ms < :endMs
                        ORDER BY ts_ms ASC
                        """,
                    arguments: ["startMs": startMs, "endMs": endMs]
                )
            }
            // 用 IN(?, ?, ?) 排除
            let placeholders = excludeBundleIds.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [startMs, endMs]
            args.append(contentsOf: excludeBundleIds.map { $0 as DatabaseValueConvertible })
            return try KeystrokeEntry.fetchAll(
                db,
                sql: """
                    SELECT id, ts_ms, bundle_id, char, is_backspace, modifiers FROM keystroke_log
                    WHERE ts_ms >= ? AND ts_ms < ?
                      AND bundle_id NOT IN (\(placeholders))
                    ORDER BY ts_ms ASC
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// 读某 UTC 日期的 frames(已过滤 full_text 非空)。
    /// **frames.app_name 是 localized name**(如 "Claude" / "Obsidian"),跟
    /// typing_events.bundle_id("com.anthropic.claudefordesktop")不能直接对比。
    /// 这里用 `AppIdentifierNormalizer` 翻译成 bundle_id 风格,让 Step 0
    /// 按 app 合并时同物理 app 不会被切成两条 session。
    func framesForDay(_ date: String) throws -> [WritingCaptureRawOcr] {
        let (startMs, endMs) = try Self.utcDayRangeMs(date: date)
        let normalizer = AppIdentifierNormalizer.snapshot()
        return try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timestamp_ms, app_name, window_name, browser_url,
                           full_text, ocr_words_json, text_source
                    FROM frames
                    WHERE timestamp_ms >= :startMs AND timestamp_ms < :endMs
                      AND full_text IS NOT NULL AND full_text != ''
                    ORDER BY timestamp_ms ASC
                    """,
                arguments: ["startMs": startMs, "endMs": endMs]
            )
            return rows.map {
                let rawApp = ($0["app_name"] as String?) ?? "unknown"
                let src = $0["text_source"] as String?
                let raw = ($0["full_text"] as String?) ?? ""
                let filtered = WritingCaptureChromeFilter.applyIfOcr(
                    rawText: raw,
                    wordsJson: $0["ocr_words_json"] as String?,
                    textSource: src
                )
                return WritingCaptureRawOcr(
                    id: $0["id"],
                    tsMs: $0["timestamp_ms"],
                    app: normalizer.bundleId(forLocalizedName: rawApp),
                    url: $0["browser_url"],
                    windowTitle: $0["window_name"] as String?,
                    text: filtered,
                    textSource: src
                )
            }
        }
    }

    // MARK: - staged 写 / 读 / 清

    /// 把 Pass 3 输出落到 writing_records_staged。
    func insertStaged(
        date: String,
        runId: String,
        promptId: String,
        records: [WritingCaptureRecord],
        rawPass1Output: String,
        rawPass3Output: String
    ) throws {
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            for r in records {
                let editLogJSON = Self.encodeJSON(r.editLog) ?? "[]"
                let refTypingJSON = Self.encodeJSON(r.referenceTypingEventIds) ?? "[]"
                let refFrameJSON = Self.encodeJSON(r.referenceFrameIds) ?? "[]"
                let refRangeJSON = Self.encodeJSON(r.referenceKeystrokeRange) ?? "{}"
                // raw_output:每条 record 都重复存一份 prompt + pass1 + pass3 raw?
                // 太冗余,只在第一条 record 上挂全 raw。其他 record 的 raw_output
                // 留空,DB 查询时按 worker_run_id JOIN 拿同一份。
                let rawOut: String? = nil  // 暂时简化:不在 staged 上存 raw,
                                            // 由 worker_runs 元数据 + 后续 query 还原。
                try db.execute(sql: """
                    INSERT INTO writing_records_staged
                        (date_utc, start_ts, end_ts, app, url, text, edit_log, confidence,
                         context_summary, source, kind, reference_typing_event_ids,
                         reference_frame_ids, reference_keystroke_range, raw_output,
                         prompt_id, created_at, worker_run_id)
                    VALUES (:d, :startTs, :endTs, :app, :url, :text, :editLog, :conf,
                            :ctxSum, :source, :kind, :refTyping,
                            :refFrame, :refRange, :rawOut,
                            :promptId, :createdAt, :runId)
                    """,
                    arguments: [
                        "d": date, "startTs": r.startTs, "endTs": r.endTs,
                        "app": r.app, "url": r.url, "text": r.text,
                        "editLog": editLogJSON, "conf": r.confidence,
                        "ctxSum": r.contextSummary, "source": r.source, "kind": r.kind,
                        "refTyping": refTypingJSON,
                        "refFrame": refFrameJSON, "refRange": refRangeJSON, "rawOut": rawOut,
                        "promptId": promptId, "createdAt": createdAt, "runId": runId
                    ])
            }
            _ = rawPass1Output; _ = rawPass3Output
        }
    }

    /// CLI 导入增量游标:某源(app)已导入记录的最新发送时刻(ms)。
    /// 下次 scan/import 只取 `ts > 此值` 的,避免重复扫全量。无记录 → nil(首次全量)。
    func cliImportLastTs(app: String) throws -> Int64? {
        try dbPool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MAX(start_ts) FROM writing_records WHERE source = 'cli_import' AND app = :app",
                arguments: ["app": app])
        }
    }

    /// CLI 导入:把 Claude Code / Codex 手打 prompt **直接**写进 writing_records
    /// (不走 staged / 不审查 —— 地面真值)。按 (app, start_ts, text) 去重,
    /// 重复导入不重复入库。返回 (新增, 跳过重复)。
    func insertCLIImported(
        _ rows: [CLIInputImporter.Imported],
        onProgress: (@Sendable (_ current: Int, _ total: Int) -> Void)? = nil
    ) throws -> (inserted: Int, skipped: Int) {
        guard !rows.isEmpty else { return (0, 0) }
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        return try dbPool.write { db in
            // 已导入的去重 key —— 只看 source='cli_import' 的历史。
            var seen = Set<String>()
            let existing = try Row.fetchAll(
                db, sql: "SELECT app, start_ts, text FROM writing_records WHERE source = 'cli_import'")
            for r in existing {
                let app: String = r["app"] ?? ""
                let ts: Int64 = r["start_ts"] ?? 0
                let text: String = r["text"] ?? ""
                seen.insert("\(app)\t\(ts)\t\(text)")
            }
            var inserted = 0, skipped = 0
            let total = rows.count
            for (i, row) in rows.enumerated() {
                // 每 100 条(及最后一条)报一次进度,避免回调过密。
                if let onProgress, i % 100 == 0 || i == total - 1 { onProgress(i + 1, total) }
                let key = "\(row.app)\t\(row.tsMs)\t\(row.text)"
                if seen.contains(key) { skipped += 1; continue }
                seen.insert(key)
                try db.execute(sql: """
                    INSERT INTO writing_records
                        (start_ts, end_ts, app, url, location, text, edit_log, confidence,
                         context_summary, source, kind, reference_typing_event_ids,
                         reference_frame_ids, reference_keystroke_range, raw_output,
                         prompt_id, created_at, worker_run_id)
                    VALUES (:ts, :ts, :app, :url, :location, :text, '[]', 1.0,
                            NULL, 'cli_import', :kind, '[]',
                            '[]', '{}', NULL,
                            'cli_import', :createdAt, 'cli_import')
                    """,
                    arguments: [
                        "ts": row.tsMs, "app": row.app, "url": row.url,
                        "location": row.location, "text": row.text,
                        "kind": CLIInputImporter.classifyKind(row.text),
                        "createdAt": createdAt,
                    ])
                inserted += 1
            }
            return (inserted, skipped)
        }
    }

    /// 把 Pass 3 输出的 discarded[] 落到 writing_records_discarded 表(staged 阶段)。
    /// Approve 时拷成 kind='committed',Reject 时跟 staged records 一起清。
    func insertStagedDiscarded(
        date: String,
        runId: String,
        discarded: [WritingCaptureDiscarded]
    ) throws {
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            for d in discarded {
                let sessionIdsJSON = Self.encodeJSON(d.sessionIds) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO writing_records_discarded
                        (date_utc, reason, session_ids, preview, worker_run_id, kind, created_at)
                    VALUES (:d, :reason, :ids, :preview, :runId, 'staged', :createdAt)
                    """,
                    arguments: [
                        "d": date, "reason": d.reason, "ids": sessionIdsJSON,
                        "preview": d.preview, "runId": runId, "createdAt": createdAt
                    ])
            }
        }
    }

    /// 读某日 staged 的所有 records(Pending review UI 用)。
    func fetchStagedRecords(date: String) throws -> [WritingRecordViewRow] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_ts, end_ts, app, url, text, edit_log, confidence,
                           context_summary, source, kind, worker_run_id, created_at
                    FROM writing_records_staged
                    WHERE date_utc = :d AND hidden_at IS NULL
                    ORDER BY start_ts ASC
                    """,
                arguments: ["d": date]
            ).map { Self.rowToView($0) }
        }
    }

    /// 用户手动拒一条 staged record:写到 user_rejected 表 + 标 hidden_at,
    /// 下次跑 Pass 3 时把它当 few-shot 例子塞 prompt,让 LLM 自动判类似 candidate。
    func rejectStagedRecord(
        stagedId: Int64,
        reasonCategory: String,
        reasonText: String?
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            // 取 staged 那条的内容写到 rejected 表
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT text, app, url, kind, worker_run_id
                    FROM writing_records_staged WHERE id = :id
                    """,
                arguments: ["id": stagedId]
            ) else { return }
            try db.execute(
                sql: """
                    INSERT INTO writing_records_user_rejected
                    (text, app, url, kind, reason_category, reason_text,
                     staged_id, worker_run_id, rejected_at)
                    VALUES (:t, :a, :u, :k, :rc, :rt, :sid, :wrid, :now)
                    """,
                arguments: [
                    "t":   row["text"] as String? ?? "",
                    "a":   row["app"]  as String? ?? "",
                    "u":   row["url"]  as String?,
                    "k":   row["kind"] as String? ?? "other",
                    "rc":  reasonCategory,
                    "rt":  reasonText,
                    "sid": stagedId,
                    "wrid": row["worker_run_id"] as String?,
                    "now": now
                ]
            )
            // 标 hidden,不删原行
            try db.execute(
                sql: "UPDATE writing_records_staged SET hidden_at = :now WHERE id = :id",
                arguments: ["now": now, "id": stagedId]
            )
        }
    }

    /// 拉最近 N 天内最多 M 条用户拒绝记录,给 Pass 3 prompt 当 few-shot。
    /// 90 天 / 100 条,哪个小用哪个。
    func fetchRecentUserRejections(maxCount: Int = 100, withinDays: Int = 90)
        throws -> [UserRejectionRow]
    {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) -
            Int64(withinDays) * 86_400_000
        return try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT text, app, url, kind, reason_category, reason_text
                    FROM writing_records_user_rejected
                    WHERE rejected_at >= :cutoff
                    ORDER BY rejected_at DESC
                    LIMIT :lim
                    """,
                arguments: ["cutoff": cutoff, "lim": Int64(maxCount)]
            ).map {
                UserRejectionRow(
                    text:           $0["text"] as String? ?? "",
                    app:            $0["app"]  as String? ?? "",
                    url:            $0["url"]  as String?,
                    kind:           $0["kind"] as String? ?? "other",
                    reasonCategory: $0["reason_category"] as String? ?? "other",
                    reasonText:     $0["reason_text"] as String?
                )
            }
        }
    }

    /// 查 writing_records(approved 后才进)里跟给定时间窗 + app 重叠的记录。
    /// InputCaptureView detail 用 —— 该天 approved 时,把 LLM 最终输出展示在
    /// 对应 typing_event 的旁边。
    func writingRecordsOverlapping(
        startTs: Int64, endTs: Int64, app: String
    ) throws -> [WritingRecordViewRow] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_ts, end_ts, app, url, text, edit_log, confidence,
                           context_summary, source, kind, worker_run_id, created_at
                    FROM writing_records
                    WHERE app = :app AND start_ts < :endTs AND end_ts > :startTs
                    ORDER BY start_ts ASC
                    """,
                arguments: ["app": app, "endTs": endTs, "startTs": startTs]
            ).map { Self.rowToView($0) }
        }
    }

    /// InputCaptureView 左列:writing_records 按 (app, url) 聚合。
    /// COALESCE(url, '') —— 跟 TypingAppSummary.url 语义一致(空 = 非浏览器)。
    func writingRecordAppSummaries() throws -> [WritingCaptureAppSummary] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT app, COALESCE(url, '') AS url,
                           COUNT(*) AS n, MAX(end_ts) AS last
                    FROM writing_records
                    GROUP BY app, url
                    ORDER BY last DESC
                    """
            )
            return rows.map { r in
                WritingCaptureAppSummary(
                    app: r["app"],
                    url: r["url"],
                    recordCount: r["n"],
                    lastEndedAt: r["last"]
                )
            }
        }
    }

    /// 某 (app, url) 分组的全部 writing_records,start_ts 倒序。
    /// url 传 "" 匹配 url IS NULL OR url = ''(跟 TypingEventStore 一致)。
    func writingRecordsForGroup(app: String, url: String) throws -> [WritingRecordViewRow] {
        try dbPool.read { db in
            let urlMatch: String
            if url.isEmpty {
                urlMatch = "AND (url IS NULL OR url = '')"
            } else {
                urlMatch = "AND url = :url"
            }
            var args: [String: DatabaseValueConvertible] = ["app": app]
            if !url.isEmpty { args["url"] = url }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_ts, end_ts, app, url, location, text, edit_log, confidence,
                           context_summary, source, kind, worker_run_id, created_at
                    FROM writing_records
                    WHERE app = :app \(urlMatch)
                    ORDER BY start_ts DESC
                    """,
                arguments: StatementArguments(args)
            ).map { Self.rowToView($0) }
        }
    }

    /// 删除某 (app, url) 分组的全部 writing_records(用户手动清除)。
    func deleteWritingRecordsForGroup(app: String, url: String) throws {
        try dbPool.write { db in
            if url.isEmpty {
                try db.execute(
                    sql: "DELETE FROM writing_records WHERE app = :app AND (url IS NULL OR url = '')",
                    arguments: ["app": app]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM writing_records WHERE app = :app AND url = :url",
                    arguments: ["app": app, "url": url]
                )
            }
        }
    }

    /// 删除单条 writing_record。
    func deleteWritingRecord(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM writing_records WHERE id = :id",
                arguments: ["id": id]
            )
        }
    }

    /// 给定时间戳所在 UTC 日的 writing_capture_runs 状态。未跑过返回 nil。
    func dayStatus(forTsMs ts: Int64) throws -> WritingCaptureRunStatus? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let date = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
        let statusStr: String? = try dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT status FROM writing_capture_runs WHERE date_utc = :d",
                arguments: ["d": date]
            )
        }
        return statusStr.flatMap { WritingCaptureRunStatus(rawValue: $0) }
    }

    private static func rowToView(_ r: Row) -> WritingRecordViewRow {
        WritingRecordViewRow(
            id: r["id"],
            startTs: r["start_ts"], endTs: r["end_ts"],
            app: r["app"], url: r["url"],
            location: r["location"],     // staged 表无此列 → GRDB 返回 nil
            text: r["text"], editLog: r["edit_log"],
            confidence: r["confidence"],
            contextSummary: r["context_summary"],
            source: r["source"],
            kind: (r["kind"] as String?) ?? "long_form",
            workerRunId: r["worker_run_id"],
            createdAt: r["created_at"]
        )
    }

    /// 清某日 staged(Reject 用)。同时清 discarded 表里 kind='staged' 的行。
    func clearStaged(date: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM writing_records_staged WHERE date_utc = :d",
                arguments: ["d": date]
            )
            try db.execute(
                sql: "DELETE FROM writing_records_discarded WHERE date_utc = :d AND kind = 'staged'",
                arguments: ["d": date]
            )
        }
    }

    /// Approve:把某日 staged 拷到 writing_records,清 staged,标 runs.status = approved。
    /// 原子事务。
    func approveStaged(date: String) throws -> Int {
        try dbPool.write { db in
            // 1. 拷 staged → writing_records(跳过被用户 reject 标 hidden 的)
            try db.execute(sql: """
                INSERT INTO writing_records
                    (start_ts, end_ts, app, url, text, edit_log, confidence,
                     context_summary, source, kind, reference_typing_event_ids,
                     reference_frame_ids, reference_keystroke_range, raw_output,
                     prompt_id, created_at, worker_run_id)
                SELECT start_ts, end_ts, app, url, text, edit_log, confidence,
                       context_summary, source, kind, reference_typing_event_ids,
                       reference_frame_ids, reference_keystroke_range, raw_output,
                       prompt_id, created_at, worker_run_id
                FROM writing_records_staged
                WHERE date_utc = :d AND hidden_at IS NULL
                """,
                arguments: ["d": date])
            let copied = db.changesCount
            // 2. 清 staged
            try db.execute(
                sql: "DELETE FROM writing_records_staged WHERE date_utc = :d",
                arguments: ["d": date])
            // 3. discarded: staged → committed
            try db.execute(sql: """
                UPDATE writing_records_discarded SET kind = 'committed'
                WHERE date_utc = :d AND kind = 'staged'
                """,
                arguments: ["d": date])
            // 4. 标 runs.status = approved
            try db.execute(sql: """
                UPDATE writing_capture_runs SET status = 'approved',
                                                 completed_at = :completedAt
                WHERE date_utc = :d
                """,
                arguments: ["completedAt": Int64(Date().timeIntervalSince1970 * 1000), "d": date])
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

/// 给 InputCaptureView 左列用 —— writing_records 按 (app, url) 聚合的一个分组。
/// url 空字符串表示非浏览器 app(跟 TypingAppSummary 同语义)。
struct WritingCaptureAppSummary: Identifiable, Sendable {
    let app: String
    let url: String                 // "" = 非浏览器
    let recordCount: Int
    let lastEndedAt: Int64          // ms
    var id: String { app + "\u{1}" + url }
}

/// 给 UI 展示用的 writing_record 行投影。staged 和 committed 共用同一个字段集。
struct WritingRecordViewRow: Sendable, Identifiable {
    let id: Int64
    let startTs: Int64
    let endTs: Int64
    let app: String
    let url: String?
    let location: String?            // cli_import 的会话/项目目录;其它来源 nil
    let text: String
    let editLog: String              // JSON
    let confidence: Double
    let contextSummary: String?
    let source: String
    let kind: String                 // "long_form" | "short_form" | "other"
    let workerRunId: String?
    let createdAt: Int64
}

/// 兼容老名字。不要在新代码里用。
typealias StagedRecordRow = WritingRecordViewRow
