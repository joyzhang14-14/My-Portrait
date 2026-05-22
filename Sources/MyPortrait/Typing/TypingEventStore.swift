import Foundation
import GRDB

/// `edit_log` 里的一条流水。commit = 写的字 / delete = 删的字 / submit = 发出的消息。
/// `ts` 是 UTC 毫秒（绝对时间）。
struct EditEntry: Codable, Equatable, Sendable {
    var ts: Int64
    var kind: String   // "commit" | "delete" | "submit"
    var text: String
}

/// 一条打字记录 —— 一个 (app, element) 的一段输入 session（v14 event-log schema）。
/// v15 起可被 continuation 合并：新 session 接得上时 UPDATE 这条 record。
struct TypingEvent: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var bundleId: String
    var elementHash: Int
    var startedAt: Int64       // UTC ms
    var endedAt: Int64         // UTC ms
    var text: String           // 本次 session 用户真实输入
    var editLog: String        // JSON [EditEntry]
    var totalChars: Int
    /// session 开始时 element 已有的完整内容（continuation 重算 text 用）。
    var sessionStart: String = ""
    /// 该 record 结束时 element 的完整内容（continuation 匹配用）。
    var endValue: String = ""
    /// 这条 record 实际剔除过的噪声段（JSON [String]）—— merge 重算 text
    /// 时一并剔除，不依赖内存黑名单存活。
    var stripped: String = "[]"
    /// 浏览器输入时所在页面的 URL；非浏览器为空。Input 页据此 per-URL 分组。
    var url: String = ""

    static let databaseTableName = "typing_events"
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Input 页左列的一个分组。非浏览器 = 一个 app 一组（`url` 空）；浏览器 =
/// 一个 (app, URL) 一组。
struct TypingAppSummary: Identifiable, Sendable {
    var bundleId: String
    var url: String
    var recordCount: Int
    var lastEndedAt: Int64
    var id: String { bundleId + "\u{1}" + url }
}

/// `typing_events` 的 DAO。接受外部注入的 DatabasePool。
/// `Sendable` —— 可交给 TypingRecordWriter 的后台 DB 队列。
struct TypingEventStore: Sendable {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// 显式列清单，所有 SELECT 复用。
    private static let columns =
        "id, bundle_id, element_hash, started_at, ended_at, text, edit_log, " +
        "total_chars, session_start, end_value, stripped, url"

    /// INSERT 一条新 record。
    func insert(_ event: TypingEvent) throws {
        try dbPool.write { db in
            var copy = event
            try copy.insert(db)
        }
    }

    /// UPDATE 一条已有 record（continuation 合并用，按 id）。
    func update(_ event: TypingEvent) throws {
        try dbPool.write { db in
            try event.update(db)
        }
    }

    /// 某 (app, element) 的全部 records，按 ended_at 倒序 —— continuation 候选。
    func recordsForElement(bundleId: String, elementHash: Int) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "WHERE bundle_id = ? AND element_hash = ? ORDER BY ended_at DESC",
                arguments: [bundleId, elementHash]
            )
        }
    }

    /// 按 (app, URL) 聚合 —— Input 页左列。非浏览器 url 恒为空 → 一个 app
    /// 归一组；浏览器每个 URL 一组。
    func appSummaries() throws -> [TypingAppSummary] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT bundle_id, url, COUNT(*) AS n, MAX(ended_at) AS last " +
                     "FROM typing_events GROUP BY bundle_id, url ORDER BY last DESC"
            )
            return rows.map {
                TypingAppSummary(bundleId: $0["bundle_id"],
                                 url: $0["url"],
                                 recordCount: $0["n"],
                                 lastEndedAt: $0["last"])
            }
        }
    }

    /// 某 (app, URL) 分组的全部 records，按 started_at 倒序。
    func records(bundleId: String, url: String) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "WHERE bundle_id = ? AND url = ? ORDER BY started_at DESC",
                arguments: [bundleId, url]
            )
        }
    }

    /// 删除某 (app, URL) 分组的全部 records。Input 页分组级删除键用。
    func delete(bundleId: String, url: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM typing_events WHERE bundle_id = ? AND url = ?",
                arguments: [bundleId, url]
            )
        }
    }

    /// 删除单条 record（按 id）。Input 页单条 session 删除键用。
    func delete(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM typing_events WHERE id = ?",
                arguments: [id]
            )
        }
    }
}
