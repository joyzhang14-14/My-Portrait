import Foundation
import GRDB

/// Data → Input 读击键的 DAO(`keystroke_log`),外加写作风格引用标签按 id
/// 回查 `writing_records`(写作采集的还原记录已清空,查不到就返回空)。
///
/// 击键在 input.sqlite,writing_records 在 workflow.sqlite;DB IO 同步执行(GRDB 内部已 thread-safe)。
struct WritingCaptureStore: Sendable {

    /// Services 启动时填上。
    @MainActor static var shared: WritingCaptureStore?

    let inputPool: DatabasePool
    let workflowPool: DatabasePool

    init(inputPool: DatabasePool, workflowPool: DatabasePool) {
        self.inputPool = inputPool
        self.workflowPool = workflowPool
    }

    /// 某段时间里的点击次数(左键 / 右键按下;抬起不算)。
    func clickCount(startMs: Int64, endMs: Int64) throws -> Int {
        try inputPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM mouse_log
                WHERE ts_ms >= :s AND ts_ms < :e AND kind IN ('left_down', 'right_down')
                """, arguments: ["s": startMs, "e": endMs]) ?? 0
        }
    }

    /// 这些天里哪些天有击键或点击 —— 日历把没有输入的天灰掉。每天各一次索引命中
    /// (ts_ms 索引 + LIMIT 1),不按天扫整月。
    func daysWithInput(_ days: [Date]) throws -> Set<Date> {
        let cal = Calendar(identifier: .gregorian)
        return try inputPool.read { db in
            var hit = Set<Date>()
            for day in days {
                let start = cal.startOfDay(for: day)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
                let args: StatementArguments = ["s": Int64(start.timeIntervalSince1970 * 1000),
                                                "e": Int64(end.timeIntervalSince1970 * 1000)]
                let keys = try Row.fetchOne(db, sql: """
                    SELECT 1 FROM keystroke_log WHERE ts_ms >= :s AND ts_ms < :e LIMIT 1
                    """, arguments: args) != nil
                let clicks = keys ? false : try Row.fetchOne(db, sql: """
                    SELECT 1 FROM mouse_log
                    WHERE ts_ms >= :s AND ts_ms < :e AND kind IN ('left_down', 'right_down') LIMIT 1
                    """, arguments: args) != nil
                if keys || clicks { hit.insert(day) }
            }
            return hit
        }
    }

    /// 击键里记到过的输入法(输入源 ID),按击键数从多到少;没记输入源的旧行不算。
    func inputSources() throws -> [InputSourceUsage] {
        try inputPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT input_source AS id, COUNT(*) AS n, MAX(ts_ms) AS last FROM keystroke_log
                WHERE input_source IS NOT NULL AND input_source != ''
                GROUP BY input_source ORDER BY n DESC
                """).map { InputSourceUsage(id: $0["id"], keys: $0["n"], lastMs: $0["last"]) }
        }
    }

    func keystrokesInRange(
        startMs: Int64, endMs: Int64, excludeBundleIds: Set<String>
    ) throws -> [KeystrokeEntry] {
        try inputPool.read { db in
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

    /// Memory → Input 左列:各 app 记下了字符的击键数,最近打字的排前面。
    /// 字符全被抹掉的 app(密码类 / 黑名单)自然不出现。
    func keystrokeAppSummaries() throws -> [InputAppSummary] {
        try inputPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundle_id, COUNT(*) AS n, MAX(ts_ms) AS last FROM keystroke_log
                WHERE char IS NOT NULL GROUP BY bundle_id ORDER BY last DESC
                """).map { InputAppSummary(app: $0["bundle_id"], keys: $0["n"], lastMs: $0["last"]) }
        }
    }

    /// 某 app 在 `beforeMs` 之前最近的 `limit` 次击键,按时间升序返回。
    func keystrokesForApp(_ app: String, beforeMs: Int64, limit: Int) throws -> [KeystrokeEntry] {
        try inputPool.read { db in
            try KeystrokeEntry.fetchAll(db, sql: """
                SELECT id, ts_ms, bundle_id, char, is_backspace, modifiers FROM keystroke_log
                WHERE bundle_id = :app AND ts_ms < :before
                ORDER BY ts_ms DESC LIMIT :n
                """, arguments: ["app": app, "before": beforeMs, "n": Int64(limit)]).reversed()
        }
    }

    /// 按 record id 反查它所属的 (app, url) 分组 —— writing-style chip 跳转用。
    func groupForRecord(id: Int64) -> (app: String, url: String)? {
        try? workflowPool.read { db -> (String, String)? in
            guard let r = try Row.fetchOne(
                db, sql: "SELECT app, url FROM writing_records WHERE id = :id",
                arguments: ["id": id]) else { return nil }
            let app: String? = r["app"]; let url: String? = r["url"]
            return (app ?? "", url ?? "")
        } ?? nil
    }

    /// 按 record id 反查它的 start_ts(毫秒)—— Neural Graph 的 Input 图跳转定位用
    /// (先据此切到该 record 所在那天)。record 不存在返回 nil。
    func writingRecordStartTs(id: Int64) -> Int64? {
        try? workflowPool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT start_ts FROM writing_records WHERE id = :id",
                arguments: ["id": id])
        } ?? nil
    }

    /// 批量取 record 文本预览(chip label 用)。ids 是 Int64,直接内联安全(无注入)。
    func writingRecordPreviews(ids: [Int64]) -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let inList = ids.map(String.init).joined(separator: ",")
        return (try? workflowPool.read { db -> [Int64: String] in
            var out: [Int64: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT id, text FROM writing_records WHERE id IN (\(inList))") {
                let id: Int64? = r["id"]; let t: String? = r["text"]
                if let id, let t { out[id] = t }
            }
            return out
        }) ?? [:]
    }
}

/// Memory → Input 左列的一个 app:记下了字符的击键数 + 最近一次打字时刻。
struct InputAppSummary: Identifiable, Sendable {
    let app: String
    let keys: Int
    let lastMs: Int64
    var id: String { app }
}

/// 给 UI 展示用的 writing_record 行投影。staged 和 committed 共用同一个字段集。
struct WritingRecordViewRow: Sendable, Identifiable {
    let id: Int64
    let startTs: Int64
    let endTs: Int64
    let app: String
    let url: String?
    let location: String?
    let text: String
    let editLog: String              // JSON
    let confidence: Double
    let contextSummary: String?
    let source: String
    let kind: String                 // "long_form" | "short_form" | "other"
    let workerRunId: String?
    let createdAt: Int64
}

/// 一个输入法在击键库里的用量。
struct InputSourceUsage: Sendable, Identifiable {
    let id: String
    let keys: Int
    let lastMs: Int64
}
