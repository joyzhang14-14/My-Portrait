import Foundation
import GRDB

/// `edit_log` 里的一条流水。commit = 用户写的字符；delete = 实际删掉的字符。
/// `ts` 是 UTC 毫秒（绝对时间，不是单调时钟）。JSON array 的元素结构。
struct EditEntry: Codable, Equatable, Sendable {
    var ts: Int64
    var kind: String   // "commit" | "delete"
    var text: String
}

/// 一条打字记录 —— 一个 app 一条主记录（v13 schema，master record per app）。
/// 对应 `typing_events` 表：`bundle_id` 是主键。
struct TypingEvent: Codable, FetchableRecord, Sendable {
    var bundleId: String
    /// 用户在该 app 累积的最终输入内容。
    var text: String
    /// JSON array of `EditEntry`。
    var editLog: String
    /// UTC ms —— 该 app 首次记录时间。
    var timeStart: Int64
    /// UTC ms —— 最近一次 flush 时间。
    var lastUpdated: Int64
    /// `text` 字符数，查询加速用。
    var totalChars: Int

    static let databaseTableName = "typing_events"

    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
}

/// `typing_events` 表（v13 master-record schema）的 DAO。
/// 接受外部注入的 `DatabasePool`，不自己开 DB。
struct TypingEventStore {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// 显式列清单，所有 SELECT 复用 —— 不用 `SELECT *`。
    private static let columns =
        "bundle_id, text, edit_log, time_start, last_updated, total_chars"

    /// 取某 app 的主记录，没有返回 nil。
    func fetch(bundleId: String) throws -> TypingEvent? {
        try dbPool.read { db in
            try TypingEvent.fetchOne(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events WHERE bundle_id = ?",
                arguments: [bundleId]
            )
        }
    }

    /// 整行 upsert。`bundle_id` 是主键 —— `INSERT OR REPLACE` 命中冲突时
    /// 删旧行插新行。flushRecord / 跨记录 delete 都走它（传入已算好的完整行）。
    func upsert(_ event: TypingEvent) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO typing_events
                    (bundle_id, text, edit_log, time_start, last_updated, total_chars)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.bundleId, event.text, event.editLog,
                    event.timeStart, event.lastUpdated, event.totalChars,
                ]
            )
        }
    }

    /// 删除某 app 的整条主记录。Memory「Input」页的删除键用。
    func delete(bundleId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM typing_events WHERE bundle_id = ?",
                arguments: [bundleId]
            )
        }
    }

    /// 最近活跃的 `limit` 个 app，按 last_updated 降序。Memory「Input」页用。
    func recentApps(limit: Int) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "ORDER BY last_updated DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }
}
