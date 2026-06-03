import Foundation
import SQLite3
import os.log

private let procLog = Logger(subsystem: "com.myportrait.memory", category: "processing-log")

/// 让 SQLite 在 bind 时立即拷贝字符串（Swift 临时 C 字符串只在调用期有效）。
private let PL_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 单阶段的状态机。
/// idle → pending → in_progress → complete | failed | partial | budget_deferred
///   - failed         ：可重试失败，retry_count 已 +1。
///   - budget_deferred ：撞 LLM 额度，等额度恢复自动重试，不计 retry_count。
///   - dead_letter     ：retry_count ≥ 3，放弃自动重试，等用户手动重置。
enum ProcessingStatus: String, Sendable {
    case idle
    case pending
    case inProgress = "in_progress"
    case complete
    case failed
    case partial
    case budgetDeferred = "budget_deferred"
    case deadLetter = "dead_letter"
    /// 用户主动退出(Cmd+Q / shutdown / 关 app)时,把跑到一半的步从 inProgress
    /// 改成 paused,不计 retry。重启时被 recoverPausedJobs 转回 pending 重跑。
    /// 跟真崩溃(SIGKILL / 断电 / force quit)的 inProgress→failed+bumpRetry 路径区分,
    /// 这样反复正常关电脑不会让某天累积 retry 进 dead_letter。
    /// LLM 服务本身不支持续接,所以重跑 = 从头跑(event 步会 deleteEvents 回滚)。
    case paused

    /// 该状态是否还需要（自动）处理。pendingDays 据此筛选。
    /// `paused` 算需要 —— 防御性:万一启动时漏跑 recoverPausedJobs,pendingDays
    /// 仍会捡到这天再次处理。
    var needsWork: Bool {
        switch self {
        case .idle, .pending, .failed, .budgetDeferred, .paused: return true
        case .inProgress, .complete, .partial, .deadLetter: return false
        }
    }
}

/// processing_log 的五个处理阶段，对应五个 `_status` 列。
///
/// 行的语义分两类（见 `ProcessingLogRow.isAnchor`）：
///   - 日期行（date = "yyyy-MM-dd"）：用 `raw` / `event` / `impact` 三列。
///     `distill` 列对日期行**无语义**，恒为 idle —— distill 不是 per-day 操作。
///   - distill 锚行（date = `ProcessingLogStore.distillAnchorDate`）：只用
///     `distill` 列。distill 是一次性整体操作，锁 / 状态 / retry 全记在这一行。
enum ProcessingStage: String, CaseIterable, Sendable {
    case raw
    case event
    case impact
    case classify     // event 之后 / distill 之前:按项目归 events 到 _folders/*.json
    case distill
    case personality

    var column: String { "\(rawValue)_status" }
}

/// processing_log 的一行：一个 UTC 日的四阶段状态 + 并发锁 + 续跑信息。
struct ProcessingLogRow: Sendable {
    var date: String                 // UTC yyyy-MM-dd
    var raw: ProcessingStatus = .idle
    var event: ProcessingStatus = .idle
    var impact: ProcessingStatus = .idle
    var classify: ProcessingStatus = .idle    // 仅 _classify_anchor 行有意义
    var distill: ProcessingStatus = .idle
    var personality: ProcessingStatus = .idle
    var activeProcessor: String? = nil   // 非空 = 有处理器持锁
    var checkpoint: [String] = []        // 已处理的 event id
    var heartbeatMs: Int64? = nil        // 持锁处理器的心跳 UTC ms
    var retryCount: Int = 0              // 失败重试次数，≥3 转 dead_letter
    var updatedAtMs: Int64 = 0

    func status(of stage: ProcessingStage) -> ProcessingStatus {
        switch stage {
        case .raw:         return raw
        case .event:       return event
        case .impact:      return impact
        case .classify:    return classify
        case .distill:     return distill
        case .personality: return personality
        }
    }

    /// 是否为锚行（而非某个数据日的行）。锚行只用对应阶段列;
    /// 日期行只用 `raw` / `event` / `impact` 列。
    var isAnchor: Bool {
        date == ProcessingLogStore.distillAnchorDate
            || date == ProcessingLogStore.personalityAnchorDate
            || date == ProcessingLogStore.classifyAnchorDate
    }
}

/// processing_log 表的读写客户端。裸 SQLite3、每方法自开连接，风格与
/// `TimelineDB` 一致 —— Memory 层不引 GRDB。表本身由 `DBSchema` 的
/// `v8_processing_log` 迁移建好。
struct ProcessingLogStore: Sendable {
    /// distill 锚行的 `date` 值。distill 是一次性整体操作（非 per-day），它的
    /// 锁 / 状态 / retry 记在这一行的 `distill_status` 列。不是真实日期，不会
    /// 与 "yyyy-MM-dd" 冲突。
    static let distillAnchorDate = "_distill_anchor"

    /// personality 锚行的 `date` 值。personality 是 distill 后一站、一次性整体
    /// 操作(非 per-day),锁 / 状态 / retry 记在这一行的 `personality_status` 列。
    static let personalityAnchorDate = "_personality_anchor"

    /// classify 锚行的 `date` 值。classify(EventClassifier)是 event 后 /
    /// distill 前的整体操作,把未分组 events 归到 _folders/*.json。锁 / 状态 /
    /// retry 记在这一行的 `classify_status` 列。
    static let classifyAnchorDate = "_classify_anchor"

    let dbPath: String

    init(path: String? = nil) {
        self.dbPath = path ?? Storage.portraitDBPath
    }

    var exists: Bool { FileManager.default.fileExists(atPath: dbPath) }

    // MARK: - 日期工具（UTC yyyy-MM-dd）

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 把 Date 折算成所在 UTC 日的 "yyyy-MM-dd"。
    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// "yyyy-MM-dd" → 该 UTC 日 00:00:00 的 Date。
    static func day(from string: String) -> Date? {
        dayFormatter.date(from: string)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - 读

    /// 读某一天的行；不存在返回 nil。
    func row(for date: String) -> ProcessingLogRow? {
        guard exists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT date, raw_status, event_status, impact_status, distill_status,
                   personality_status, classify_status,
                   active_processor, checkpoint, heartbeat_ms, retry_count, updated_at_ms
            FROM processing_log WHERE date = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, date, -1, PL_SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.decodeRow(stmt)
    }

    /// 全表所有行。
    func allRows() -> [ProcessingLogRow] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT date, raw_status, event_status, impact_status, distill_status,
                   personality_status, classify_status,
                   active_processor, checkpoint, heartbeat_ms, retry_count, updated_at_ms
            FROM processing_log ORDER BY date ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [ProcessingLogRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.decodeRow(stmt)) }
        return out
    }

    private static func decodeRow(_ stmt: OpaquePointer?) -> ProcessingLogRow {
        func text(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL
                ? nil : sqlite3_column_text(stmt, i).flatMap { String(cString: $0) }
        }
        func status(_ i: Int32) -> ProcessingStatus {
            ProcessingStatus(rawValue: text(i) ?? "idle") ?? .idle
        }
        var row = ProcessingLogRow(date: text(0) ?? "")
        row.raw     = status(1)
        row.event   = status(2)
        row.impact  = status(3)
        row.distill = status(4)
        row.personality = status(5)
        row.classify = status(6)
        row.activeProcessor = text(7)
        if let cp = text(8), let data = cp.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            row.checkpoint = ids
        }
        row.heartbeatMs = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil : sqlite3_column_int64(stmt, 9)
        row.retryCount = Int(sqlite3_column_int64(stmt, 10))
        row.updatedAtMs = sqlite3_column_int64(stmt, 11)
        return row
    }

    // MARK: - 写

    /// 整行 upsert（INSERT OR REPLACE）。
    @discardableResult
    func upsert(_ row: ProcessingLogRow) -> Bool {
        runWrite { db in
            let sql = """
                INSERT OR REPLACE INTO processing_log
                  (date, raw_status, event_status, impact_status, distill_status,
                   personality_status, classify_status,
                   active_processor, checkpoint, heartbeat_ms, retry_count, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, row.date, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.raw.rawValue, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, row.event.rawValue, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, row.impact.rawValue, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, row.distill.rawValue, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, row.personality.rawValue, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, row.classify.rawValue, -1, PL_SQLITE_TRANSIENT)
            if let p = row.activeProcessor {
                sqlite3_bind_text(stmt, 8, p, -1, PL_SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            let cpJSON = (try? JSONEncoder().encode(row.checkpoint))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            sqlite3_bind_text(stmt, 9, cpJSON, -1, PL_SQLITE_TRANSIENT)
            if let hb = row.heartbeatMs {
                sqlite3_bind_int64(stmt, 10, hb)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_int64(stmt, 11, Int64(row.retryCount))
            sqlite3_bind_int64(stmt, 12, Self.nowMs())
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// 确保某天有一行（没有就建一个全 idle 行），返回当前行。
    func ensureRow(for date: String) -> ProcessingLogRow {
        if let existing = row(for: date) { return existing }
        var fresh = ProcessingLogRow(date: date)
        fresh.updatedAtMs = Self.nowMs()
        upsert(fresh)
        return fresh
    }

    /// 改单个阶段的状态。
    @discardableResult
    func setStatus(date: String, stage: ProcessingStage, status: ProcessingStatus) -> Bool {
        runWrite { db in
            let sql = "UPDATE processing_log SET \(stage.column) = ?, updated_at_ms = ? WHERE date = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Self.nowMs())
            sqlite3_bind_text(stmt, 3, date, -1, PL_SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// retry_count += 1，返回自增后的值。失败 / 崩溃恢复时调。
    func bumpRetry(date: String) -> Int {
        let current = row(for: date)?.retryCount ?? 0
        let next = current + 1
        _ = setRetryCount(date: date, count: next)
        return next
    }

    /// 直接设 retry_count（UI 重置时归零）。
    @discardableResult
    func setRetryCount(date: String, count: Int) -> Bool {
        runWrite { db in
            let sql = "UPDATE processing_log SET retry_count = ?, updated_at_ms = ? WHERE date = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(count))
            sqlite3_bind_int64(stmt, 2, Self.nowMs())
            sqlite3_bind_text(stmt, 3, date, -1, PL_SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// 持锁：写 active_processor + 新心跳。调用方负责先确认未被别人持锁。
    @discardableResult
    func acquireLock(date: String, processor: String) -> Bool {
        runWrite { db in
            let sql = """
                UPDATE processing_log
                SET active_processor = ?, heartbeat_ms = ?, updated_at_ms = ?
                WHERE date = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            let now = Self.nowMs()
            sqlite3_bind_text(stmt, 1, processor, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, now)
            sqlite3_bind_int64(stmt, 3, now)
            sqlite3_bind_text(stmt, 4, date, -1, PL_SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// 续命：刷新持锁处理器的心跳。
    @discardableResult
    func heartbeat(date: String) -> Bool {
        runWrite { db in
            let sql = "UPDATE processing_log SET heartbeat_ms = ? WHERE date = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Self.nowMs())
            sqlite3_bind_text(stmt, 2, date, -1, PL_SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// 释放锁：清空 active_processor + heartbeat_ms。
    @discardableResult
    func releaseLock(date: String) -> Bool {
        runWrite { db in
            let sql = """
                UPDATE processing_log
                SET active_processor = NULL, heartbeat_ms = NULL, updated_at_ms = ?
                WHERE date = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Self.nowMs())
            sqlite3_bind_text(stmt, 2, date, -1, PL_SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// 写续跑断点（已处理 event id 列表）。
    @discardableResult
    func setCheckpoint(date: String, eventIds: [String]) -> Bool {
        runWrite { db in
            let json = (try? JSONEncoder().encode(eventIds))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let sql = "UPDATE processing_log SET checkpoint = ?, updated_at_ms = ? WHERE date = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, json, -1, PL_SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Self.nowMs())
            sqlite3_bind_text(stmt, 3, date, -1, PL_SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    // MARK: - distill_changelog

    /// distill_changelog 的一行（UI / debug 用）。
    struct ChangelogEntry: Identifiable, Sendable {
        let id: Int64
        let entityId: String
        let before: String?
        let after: String
        let triggeredByEventId: String?
        let reasoning: String?
        let timestampMs: Int64
    }

    /// 最近的 changelog 条目（按时间倒序）。
    func recentChangelog(limit: Int = 50) -> [ChangelogEntry] {
        guard exists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, entity_id, before, after, triggered_by_event_id,
                   llm_reasoning, timestamp_ms
            FROM distill_changelog ORDER BY timestamp_ms DESC LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [ChangelogEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL
                    ? nil : sqlite3_column_text(stmt, i).flatMap { String(cString: $0) }
            }
            out.append(ChangelogEntry(
                id: sqlite3_column_int64(stmt, 0),
                entityId: text(1) ?? "",
                before: text(2),
                after: text(3) ?? "",
                triggeredByEventId: text(4),
                reasoning: text(5),
                timestampMs: sqlite3_column_int64(stmt, 6)
            ))
        }
        return out
    }

    /// 记一条 distiller 对 portrait body 的改动，供 debug / 回滚。
    func appendChangelog(
        entityId: String,
        before: String?,
        after: String,
        triggeredByEventId: String?,
        reasoning: String?
    ) {
        _ = runWrite { db in
            let sql = """
                INSERT INTO distill_changelog
                  (entity_id, field_name, before, after,
                   triggered_by_event_id, llm_reasoning, timestamp_ms)
                VALUES (?, 'body', ?, ?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, entityId, -1, PL_SQLITE_TRANSIENT)
            if let b = before { sqlite3_bind_text(stmt, 2, b, -1, PL_SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_text(stmt, 3, after, -1, PL_SQLITE_TRANSIENT)
            if let e = triggeredByEventId { sqlite3_bind_text(stmt, 4, e, -1, PL_SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 4) }
            if let r = reasoning { sqlite3_bind_text(stmt, 5, r, -1, PL_SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_int64(stmt, 6, Self.nowMs())
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    // MARK: - 私有

    private func runWrite(_ body: (OpaquePointer?) -> Bool) -> Bool {
        guard exists else {
            procLog.error("processing_log write skipped — DB missing at \(dbPath, privacy: .public)")
            return false
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            procLog.error("processing_log open RW failed at \(dbPath, privacy: .public)")
            return false
        }
        defer { sqlite3_close(db) }
        return body(db)
    }
}
