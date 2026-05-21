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

    static let databaseTableName = "typing_events"
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 一个 app 的 records 概览 —— Memory「Input」页左列用。
struct TypingAppSummary: Identifiable, Sendable {
    var bundleId: String
    var recordCount: Int
    var lastEndedAt: Int64
    var id: String { bundleId }
}

/// `typing_events`（v14 event-log schema）的 DAO。接受外部注入的 DatabasePool。
struct TypingEventStore {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// 显式列清单，所有 SELECT 复用。
    private static let columns =
        "id, bundle_id, element_hash, started_at, ended_at, text, edit_log, " +
        "total_chars, session_start, end_value"

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

    /// 按 app 聚合：每个 app 的 record 数 + 最近 ended_at。Input 页左列。
    func appSummaries() throws -> [TypingAppSummary] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT bundle_id, COUNT(*) AS n, MAX(ended_at) AS last " +
                     "FROM typing_events GROUP BY bundle_id ORDER BY last DESC"
            )
            return rows.map {
                TypingAppSummary(bundleId: $0["bundle_id"],
                                 recordCount: $0["n"],
                                 lastEndedAt: $0["last"])
            }
        }
    }

    /// 某 app 的全部 records，按 started_at 倒序。
    func records(bundleId: String) throws -> [TypingEvent] {
        try dbPool.read { db in
            try TypingEvent.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM typing_events " +
                     "WHERE bundle_id = ? ORDER BY started_at DESC",
                arguments: [bundleId]
            )
        }
    }

    /// 删除某 app 的全部 records。Input 页删除键用。
    func delete(bundleId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM typing_events WHERE bundle_id = ?",
                arguments: [bundleId]
            )
        }
    }
}
