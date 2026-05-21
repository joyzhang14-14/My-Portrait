import Foundation
import GRDB

/// 一条打字事件 —— 一次连续输入会话（started_at_ms ~ ended_at_ms）。
/// 对应 `typing_events` 表（v11 schema）。
struct TypingEvent: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
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

    static let databaseTableName = "typing_events"

    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
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
        "url, element_role, thread_id, text, char_count, language_hint, created_at_ms"

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
