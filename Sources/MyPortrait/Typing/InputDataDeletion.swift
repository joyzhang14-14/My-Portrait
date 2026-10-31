import GRDB

/// 按时间删 input.sqlite 里的击键、鼠标、打字事件、剪贴板。
/// 隐私删除(删最近 N 分钟)传 `fromMs`,保留清理(删 N 天前)传 `beforeMs`。
/// 打字事件按结束时间算:跨过边界的一段,隐私删除整段删,保留清理整段留。
enum InputDataDeletion {
    @discardableResult
    static func delete(_ db: Database, fromMs: Int64?, beforeMs: Int64?) throws -> Int {
        let lo = fromMs ?? Int64.min, hi = beforeMs ?? Int64.max
        var deleted = 0
        for (table, column) in [("keystroke_log", "ts_ms"), ("mouse_log", "ts_ms"),
                                ("clipboard_log", "ts_ms"), ("typing_events", "ended_at")] {
            try db.execute(sql: "DELETE FROM \(table) WHERE \(column) >= :lo AND \(column) < :hi",
                           arguments: ["lo": lo, "hi": hi])
            deleted += db.changesCount
        }
        return deleted
    }
}
