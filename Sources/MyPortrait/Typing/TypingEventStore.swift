import Foundation
import GRDB

/// 打字会话 editLog 里的一笔明细 —— 会话内一次 commit 或 delete。
///
/// `ts` 是相对会话第一条 `IMEFoldEvent` 的秒数（首条 = 0.0）。
/// 整个 editLog 以 JSON 数组存进 `typing_events.edit_log` 列：
///   `[{"ts":0.0,"kind":"commit","text":"hello"}]`
struct EditEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case commit, delete }
    var ts: TimeInterval
    var kind: Kind
    var text: String
}

/// 一条打字事件 —— 一次连续输入会话（started_at_ms ~ ended_at_ms）。
/// 对应 `typing_events` 表（v12 schema）。
///
/// `edit_log` 列在 SQLite 里是 JSON string。`[EditEntry]` 不是合法的
/// SQLite 列值类型，所以这里**不走 Codable 自动合成**——手写
/// `FetchableRecord.init(row:)` 与 `EncodableRecord.encode(to:)`，
/// 在 `[EditEntry]` ↔ JSON string 之间手动互转，其余列普通映射。
struct TypingEvent: FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var startedAtMs: Int64
    var endedAtMs: Int64
    var bundleId: String
    var appName: String?
    var windowTitle: String?
    var url: String?
    var elementRole: String?
    var threadId: String
    var text: String
    var charCount: Int
    var languageHint: String?
    var createdAtMs: Int64
    /// 会话内每次 commit / delete 的有序明细。`edit_log` 列存其 JSON 数组。
    var editLog: [EditEntry]
    /// 会话关闭原因：submit / idle / focus_change / app_change / max_chars。
    var closeReason: String?

    static let databaseTableName = "typing_events"

    init(id: Int64?,
         startedAtMs: Int64,
         endedAtMs: Int64,
         bundleId: String,
         appName: String?,
         windowTitle: String?,
         url: String?,
         elementRole: String?,
         threadId: String,
         text: String,
         charCount: Int,
         languageHint: String?,
         createdAtMs: Int64,
         editLog: [EditEntry] = [],
         closeReason: String? = nil) {
        self.id = id
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.elementRole = elementRole
        self.threadId = threadId
        self.text = text
        self.charCount = charCount
        self.languageHint = languageHint
        self.createdAtMs = createdAtMs
        self.editLog = editLog
        self.closeReason = closeReason
    }

    // MARK: - FetchableRecord：从 DB 行解码（手写，处理 edit_log JSON）

    init(row: Row) throws {
        id = row["id"]
        startedAtMs = row["started_at_ms"]
        endedAtMs = row["ended_at_ms"]
        bundleId = row["bundle_id"]
        appName = row["app_name"]
        windowTitle = row["window_title"]
        url = row["url"]
        elementRole = row["element_role"]
        threadId = row["thread_id"]
        text = row["text"]
        charCount = row["char_count"]
        languageHint = row["language_hint"]
        createdAtMs = row["created_at_ms"]
        closeReason = row["close_reason"]
        let json: String = row["edit_log"] ?? "[]"
        editLog = Self.decodeEditLog(json)
    }

    // MARK: - PersistableRecord：编码进 DB 行（手写，edit_log → JSON）

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["started_at_ms"] = startedAtMs
        container["ended_at_ms"] = endedAtMs
        container["bundle_id"] = bundleId
        container["app_name"] = appName
        container["window_title"] = windowTitle
        container["url"] = url
        container["element_role"] = elementRole
        container["thread_id"] = threadId
        container["text"] = text
        container["char_count"] = charCount
        container["language_hint"] = languageHint
        container["created_at_ms"] = createdAtMs
        container["close_reason"] = closeReason
        container["edit_log"] = Self.encodeEditLog(editLog)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - editLog JSON 互转

    /// `[EditEntry]` → JSON string。编码失败退化 `"[]"`。
    private static func encodeEditLog(_ entries: [EditEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    /// JSON string → `[EditEntry]`。坏数据退化空数组。
    private static func decodeEditLog(_ json: String) -> [EditEntry] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EditEntry].self, from: data)
        else { return [] }
        return decoded
    }
}

/// 一个打字 thread 的聚合摘要 —— 一次 session 一行。
/// 由 `recentThreads(limit:)` 用 GROUP BY thread_id 算出来。
struct TypingThreadSummary: Identifiable, Sendable {
    var threadId: String
    var appName: String?
    var bundleId: String
    var startedAt: Int64
    var endedAt: Int64
    var eventCount: Int
    var charCount: Int

    var id: String { threadId }
}

/// `typing_events` 表的 DAO。接受外部注入的 `DatabasePool`，不自己开 DB。
struct TypingEventStore {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// 显式列清单，所有 SELECT 复用 —— 不用 `SELECT *`（列顺序/新增列都不会出岔）。
    private static let columns =
        "id, started_at_ms, ended_at_ms, bundle_id, app_name, window_title, " +
        "url, element_role, thread_id, text, char_count, language_hint, " +
        "created_at_ms, edit_log, close_reason"

    /// 单条写入，事务内。`insert` 是 mutating，块内做可变拷贝。
    func insert(_ event: TypingEvent) throws {
        try dbPool.write { db in
            var copy = event
            try copy.insert(db)
        }
    }

    /// 调试用：最近 `limit` 条，按 started_at_ms 降序。
    func recent(limit: Int) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "ORDER BY started_at_ms DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    /// 同一 thread 的全部事件，按 started_at_ms 升序。
    func eventsInThread(threadId: String) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "WHERE thread_id = ? ORDER BY started_at_ms ASC",
                arguments: [threadId]
            )
        }
    }

    /// 按 thread 聚合的最近会话摘要，按起始时间降序。
    /// 显式列名，不用 `SELECT *`。
    func recentThreads(limit: Int) throws -> [TypingThreadSummary] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT thread_id, app_name, bundle_id, " +
                     "MIN(started_at_ms) AS started, MAX(ended_at_ms) AS ended, " +
                     "COUNT(*) AS n, SUM(char_count) AS chars " +
                     "FROM typing_events GROUP BY thread_id " +
                     "ORDER BY started DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map { row in
                TypingThreadSummary(
                    threadId: row["thread_id"],
                    appName: row["app_name"],
                    bundleId: row["bundle_id"],
                    startedAt: row["started"],
                    endedAt: row["ended"],
                    eventCount: row["n"],
                    charCount: row["chars"]
                )
            }
        }
    }

    /// 查最近 `withinMs` 毫秒内、同 (bundle_id, window_title) 的最后一条。
    /// SQLite 的 `IS` 对 NULL 和非 NULL 都正确，windowTitle 为 nil 时绑 NULL 即可。
    func lastEvent(bundleId: String,
                   windowTitle: String?,
                   withinMs: Int64) throws -> TypingEvent? {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - withinMs
        return try dbPool.read { db in
            try TypingEvent.fetchOne(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "WHERE bundle_id = ? AND window_title IS ? AND started_at_ms >= ? " +
                     "ORDER BY started_at_ms DESC LIMIT 1",
                arguments: [bundleId, windowTitle, cutoff]
            )
        }
    }
}
