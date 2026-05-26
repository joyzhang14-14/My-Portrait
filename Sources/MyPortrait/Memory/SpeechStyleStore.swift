import Foundation
import GRDB
import os.log

private let speechStoreLog = Logger(subsystem: "com.myportrait.memory", category: "speech-style-store")

/// speech_style 提炼链路的 DAO ——
///   - 读 writing_records 里 speech_style_processed_at IS NULL 的行
///   - 标 completed(单条或批量)
///   - speech_style_runs CRUD
///   - speech_style_staged CRUD(manual 模式 staged → Approve → 落盘 + 标 completed)
///
/// GRDB arguments 一律 dict 形式(避开 Swift runtime existential 转换 bug)。
struct SpeechStyleStore: Sendable {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - 读未处理 records

    /// 读 writing_records(approved)里 speech_style_processed_at IS NULL 的行,
    /// 按 start_ts 升序,上限 `limit`。LLM 喂这一批,Approve / auto-commit 后
    /// 调 `markRecordsProcessed` 标完。
    func unprocessedRecords(limit: Int) throws -> [SpeechStyleRecordInput] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_ts, app, url, text, edit_log, kind, context_summary
                    FROM writing_records
                    WHERE speech_style_processed_at IS NULL
                    ORDER BY start_ts ASC
                    LIMIT :lim
                    """,
                arguments: ["lim": Int64(limit)]
            )
            return rows.map {
                SpeechStyleRecordInput(
                    id: $0["id"],
                    startTs: $0["start_ts"],
                    app: $0["app"],
                    url: $0["url"],
                    text: $0["text"],
                    editLog: ($0["edit_log"] as String?) ?? "[]",
                    kind: ($0["kind"] as String?) ?? "other",
                    contextSummary: $0["context_summary"]
                )
            }
        }
    }

    /// 按 id list 拉 writing_records —— UI Draft sheet 展开"N refs"用。
    /// 跟 unprocessedRecords 同投影,只是 WHERE 条件不一样。
    func fetchRecordsByIds(_ ids: [Int64]) throws -> [SpeechStyleRecordInput] {
        guard !ids.isEmpty else { return [] }
        return try dbPool.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let args: [DatabaseValueConvertible] = ids.map { $0 as DatabaseValueConvertible }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_ts, app, url, text, edit_log, kind, context_summary
                    FROM writing_records
                    WHERE id IN (\(placeholders))
                    ORDER BY start_ts ASC
                    """,
                arguments: StatementArguments(args)
            )
            return rows.map {
                SpeechStyleRecordInput(
                    id: $0["id"],
                    startTs: $0["start_ts"],
                    app: $0["app"],
                    url: $0["url"],
                    text: $0["text"],
                    editLog: ($0["edit_log"] as String?) ?? "[]",
                    kind: ($0["kind"] as String?) ?? "other",
                    contextSummary: $0["context_summary"]
                )
            }
        }
    }

    /// 还有多少未处理 record(UI Run 按钮文案 + 灰按钮判断)。
    func unprocessedCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM writing_records WHERE speech_style_processed_at IS NULL"
            ) ?? 0
        }
    }

    /// 标一批 record completed —— manual Approve 落盘后 / auto 落盘后调。
    func markRecordsProcessed(ids: [Int64], at tsMs: Int64) throws {
        guard !ids.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [tsMs]
            args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
            try db.execute(
                sql: """
                    UPDATE writing_records
                    SET speech_style_processed_at = ?
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - runs

    /// 写入这次 run 喂给 LLM 的整批 record ids —— approve / auto-commit 时
    /// 按它标 completed,而不是按"LLM 引用过的"子集。
    func setInputRecordIds(runId: String, ids: [Int64]) throws {
        let json = Self.encodeJSON(ids) ?? "[]"
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE speech_style_runs SET input_record_ids = :ids WHERE run_id = :rid",
                arguments: ["ids": json, "rid": runId]
            )
        }
    }

    /// 读 run 的 input_record_ids。approve / auto-commit 路径用。
    func fetchInputRecordIds(runId: String) throws -> [Int64] {
        try dbPool.read { db in
            let json: String? = try String.fetchOne(
                db,
                sql: "SELECT input_record_ids FROM speech_style_runs WHERE run_id = :rid",
                arguments: ["rid": runId]
            )
            guard let s = json, let data = s.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([Int64].self, from: data)
            else { return [] }
            return arr
        }
    }

    func insertRun(
        runId: String, mode: SpeechStyleMode, startedAt: Int64
    ) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO speech_style_runs
                    (run_id, mode, status, started_at)
                VALUES (:rid, :mode, :status, :started)
                """,
                arguments: [
                    "rid": runId, "mode": mode.rawValue,
                    "status": SpeechStyleRunStatus.processing.rawValue,
                    "started": startedAt
                ])
        }
    }

    func updateRun(
        runId: String,
        status: SpeechStyleRunStatus,
        completedAt: Int64? = nil,
        errorMessage: String? = nil,
        recordsCount: Int? = nil,
        draftsCount: Int? = nil,
        tokenUsage: Int? = nil
    ) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE speech_style_runs SET
                    status         = :status,
                    completed_at   = COALESCE(:completed, completed_at),
                    error_message  = COALESCE(:err, error_message),
                    records_count  = COALESCE(:rec, records_count),
                    drafts_count   = COALESCE(:dft, drafts_count),
                    token_usage    = COALESCE(:tok, token_usage)
                WHERE run_id = :rid
                """,
                arguments: [
                    "status": status.rawValue,
                    "completed": completedAt,
                    "err": errorMessage,
                    "rec": recordsCount.map { Int64($0) },
                    "dft": draftsCount.map { Int64($0) },
                    "tok": tokenUsage.map { Int64($0) },
                    "rid": runId
                ])
        }
    }

    func fetchRun(runId: String) throws -> SpeechStyleRunRow? {
        try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM speech_style_runs WHERE run_id = :rid",
                arguments: ["rid": runId]
            ).map(Self.rowToRun)
        }
    }

    /// 把所有卡在 'processing' 的 run 标为 failed —— 给 Stop 按钮 / 启动恢复用。
    /// 没 Stop / 进程崩了之后留下来的僵尸行会污染下次 unprocessedCount 判断。
    @discardableResult
    func markStuckProcessingAsFailed(message: String) throws -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try dbPool.write { db in
            try db.execute(sql: """
                UPDATE speech_style_runs
                SET status        = :status,
                    completed_at  = :now,
                    error_message = :msg
                WHERE status = 'processing'
                """,
                arguments: [
                    "status": SpeechStyleRunStatus.failed.rawValue,
                    "now": now, "msg": message
                ])
            return db.changesCount
        }
    }

    /// status = pending_review 的所有 run,新到旧。
    func fetchPendingReviewRuns() throws -> [SpeechStyleRunRow] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM speech_style_runs
                    WHERE status = 'pending_review'
                    ORDER BY started_at DESC
                    """
            ).map(Self.rowToRun)
        }
    }

    // MARK: - staged

    func insertStaged(runId: String, drafts: [SpeechStyleDraft]) throws {
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            for d in drafts {
                let idsJSON = Self.encodeJSON(d.sourceRecordIds) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO speech_style_staged
                        (run_id, created_at, action, slug, title, body,
                         source_record_ids, existing_slug)
                    VALUES (:rid, :created, :action, :slug, :title, :body,
                            :ids, :existing)
                    """,
                    arguments: [
                        "rid": runId, "created": createdAt,
                        "action": d.action.rawValue,
                        "slug": d.slug, "title": d.title, "body": d.body,
                        "ids": idsJSON,
                        "existing": d.existingSlug
                    ])
            }
        }
    }

    /// 某 run 的 staged drafts(hidden 排除)。
    func fetchStaged(runId: String) throws -> [SpeechStyleStagedRow] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM speech_style_staged
                    WHERE run_id = :rid AND hidden_at IS NULL
                    ORDER BY id ASC
                    """,
                arguments: ["rid": runId]
            ).map(Self.rowToStaged)
        }
    }

    /// 用户拒一条 staged(标 hidden,留行审计)。
    func hideStaged(stagedId: Int64) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE speech_style_staged SET hidden_at = :now WHERE id = :id",
                arguments: ["now": now, "id": stagedId]
            )
        }
    }

    /// 整 run reject:清掉所有 staged(包括 hidden),run.status = rejected_for_rerun。
    /// **不**标 records completed,下次 run 这批 records 会重进 LLM。
    func rejectRun(runId: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM speech_style_staged WHERE run_id = :rid",
                arguments: ["rid": runId]
            )
            try db.execute(sql: """
                UPDATE speech_style_runs
                SET status = :status, completed_at = :now
                WHERE run_id = :rid
                """,
                arguments: [
                    "status": SpeechStyleRunStatus.rejectedForRerun.rawValue,
                    "now": now, "rid": runId
                ])
        }
    }

    /// 整 run approve:清掉 staged(不删 records,Distiller 调 markRecordsProcessed
    /// 落 completed)。run.status = approved。
    func approveRunMeta(runId: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM speech_style_staged WHERE run_id = :rid",
                arguments: ["rid": runId]
            )
            try db.execute(sql: """
                UPDATE speech_style_runs
                SET status = :status, completed_at = :now
                WHERE run_id = :rid
                """,
                arguments: [
                    "status": SpeechStyleRunStatus.approved.rawValue,
                    "now": now, "rid": runId
                ])
        }
    }

    // MARK: - Helpers

    private static func rowToRun(_ r: Row) -> SpeechStyleRunRow {
        SpeechStyleRunRow(
            id: r["id"],
            runId: r["run_id"],
            mode: SpeechStyleMode(rawValue: (r["mode"] as String?) ?? "manual") ?? .manual,
            status: SpeechStyleRunStatus(rawValue: (r["status"] as String?) ?? "failed") ?? .failed,
            startedAt: r["started_at"],
            completedAt: r["completed_at"],
            recordsCount: (r["records_count"] as Int64?).map { Int($0) },
            draftsCount: (r["drafts_count"] as Int64?).map { Int($0) },
            errorMessage: r["error_message"]
        )
    }

    private static func rowToStaged(_ r: Row) -> SpeechStyleStagedRow {
        let idsJSON = (r["source_record_ids"] as String?) ?? "[]"
        let ids: [Int64] = (try? JSONDecoder().decode([Int64].self, from: Data(idsJSON.utf8))) ?? []
        return SpeechStyleStagedRow(
            id: r["id"],
            runId: r["run_id"],
            createdAt: r["created_at"],
            action: SpeechStyleDraft.Action(rawValue: (r["action"] as String?) ?? "noop") ?? .noop,
            slug: r["slug"],
            title: r["title"],
            body: r["body"],
            sourceRecordIds: ids,
            existingSlug: r["existing_slug"]
        )
    }

    private static func encodeJSON<T: Encodable>(_ v: T) -> String? {
        guard let data = try? JSONEncoder().encode(v),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
