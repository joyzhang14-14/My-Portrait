import Foundation
import GRDB
import os.log

private let ivLog = Logger(subsystem: "com.myportrait.memory", category: "event-intervals")

/// `event_intervals` 的一行:event 链(含 impact、classify)的处理单位。
struct EventInterval: Sendable, Equatable {
    var id: String
    var startMs: Int64
    var endMs: Int64
    /// 封口时本机的 UTC 偏移(分钟),钉死;这个区间的事件按它算本地日。
    var tzOffsetMin: Int
    var sealedAtMs: Int64
    /// gap / run_now / backfill;过渡起点那一行是 origin。
    var trigger: String
    var frameCount: Int
    /// 区间帧 = 时间在 [start, end) 且 id 在 (afterFrameId, maxFrameId](外加事件链帧过滤)。
    var afterFrameId: Int64
    var maxFrameId: Int64
    var event: ProcessingStatus
    var impact: ProcessingStatus
    var retryCount: Int
    var updatedAtMs: Int64
}

/// `personality_days` 的一行:personality 按本地日跑,每天只跑一次。
struct PersonalityDay: Sendable, Equatable {
    var day: String
    var tzOffsetMin: Int
    var status: ProcessingStatus
    var retryCount: Int
    var updatedAtMs: Int64
}

/// 区间台账(workflow.sqlite `event_intervals` + `personality_days`),帧从 screen.sqlite 读。
///
/// - 封口规则在 `IntervalSegmenter`;这里负责取帧、落库和 T0 过渡。调用方持交换锁
///   (`PremiumExchange.FileLock`),helper 进程与 app 之间靠它互斥。
/// - 封口分三步:在 workflow 读上一截止点和已封最大帧 id;在 screen 用一个读事务取齐帧列表、
///   最旧的待 OCR 时间和晚到帧,在内存里算出每一刀的帧数和最大帧 id;最后写 workflow,
///   写之前再核一次截止点和最大帧 id 没被别人推进过。
/// - 状态语义沿用 processing_log(`ProcessingStatus` + retry_count + 退避),只由处理
///   结果推进(本机跑完或导入 Premium 结果),发包不推进。
/// - T0:第一次封口检查时写一行 `iv:origin`(start = end = T0,状态 complete),
///   T0 之前的数据留在旧的 UTC 日台账里。
struct EventIntervalStore: Sendable {

    static let originId = "iv:origin"
    static let triggerGap = "gap"
    static let triggerRunNow = "run_now"
    static let triggerBackfill = "backfill"
    static let triggerOrigin = "origin"

    /// 事件链的帧过滤(有 snapshot / video chunk / imported),同 `TimelineDB.frames(on:)`。
    static let eventFrameFilter =
        "(snapshot_path IS NOT NULL OR video_chunk_id IS NOT NULL OR device_name = 'imported')"
    /// 非空转帧。
    static let nonIdleSQL = "COALESCE(capture_trigger, '') NOT IN ('idle', 'manual')"

    /// 只读帧和 OCR 队列。
    let screenPool: DatabasePool
    /// 区间台账、personality 本地日、旧的 UTC 日台账。
    let workflowPool: DatabasePool

    init(pools: DBPools) {
        screenPool = pools.screen
        workflowPool = pools.workflow
    }

    static func nowMs(_ d: Date = Date()) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    // MARK: - 区间帧

    /// 某区间的帧条件(带 `frames` 表列名),参数见 `frameArguments(_:)`。
    static let intervalFrameSQL = """
        \(eventFrameFilter)
          AND timestamp_ms >= :iv_start AND timestamp_ms < :iv_end
          AND id > :iv_after AND id <= :iv_max
        """

    static func frameArguments(_ iv: EventInterval) -> StatementArguments {
        ["iv_start": iv.startMs, "iv_end": iv.endMs, "iv_after": iv.afterFrameId, "iv_max": iv.maxFrameId]
    }

    // MARK: - 读

    private static let columns = """
        id, start_ms, end_ms, tz_offset_min, sealed_at_ms, trigger, frame_count,
        after_frame_id, max_frame_id, event_status, impact_status, retry_count, updated_at_ms
        """

    private static func decode(_ r: Row) -> EventInterval {
        EventInterval(
            id: r["id"], startMs: r["start_ms"], endMs: r["end_ms"],
            tzOffsetMin: Int((r["tz_offset_min"] as Int64?) ?? 0),
            sealedAtMs: r["sealed_at_ms"],
            trigger: (r["trigger"] as String) == "nightly" ? triggerGap : r["trigger"],   // 旧 nightly 行按 gap 读
            frameCount: Int((r["frame_count"] as Int64?) ?? 0),
            afterFrameId: r["after_frame_id"], maxFrameId: r["max_frame_id"],
            event: ProcessingStatus(rawValue: r["event_status"]) ?? .idle,
            impact: ProcessingStatus(rawValue: r["impact_status"]) ?? .idle,
            retryCount: Int((r["retry_count"] as Int64?) ?? 0),
            updatedAtMs: r["updated_at_ms"])
    }

    /// 全部区间(不含 origin),按 start_ms 升序。
    func all() throws -> [EventInterval] {
        try workflowPool.read { db in try Self.fetchAll(db) }
    }

    private static func fetchAll(_ db: Database) throws -> [EventInterval] {
        try Row.fetchAll(db, sql: """
            SELECT \(columns) FROM event_intervals WHERE id != :origin ORDER BY start_ms, id
            """, arguments: ["origin": originId]).map(decode)
    }

    func interval(id: String) throws -> EventInterval? {
        try workflowPool.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM event_intervals WHERE id = :id",
                             arguments: ["id": id]).map(Self.decode)
        }
    }

    /// T0(还没做过封口检查 → nil)。
    func origin() throws -> Int64? {
        try workflowPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT end_ms FROM event_intervals WHERE id = :id",
                               arguments: ["id": Self.originId])
        }
    }

    /// 上一截止点 = 已封区间的最大 end_ms(还没有 origin → nil)。
    func lastCut() throws -> Int64? {
        try workflowPool.read { db in try Self.lastCut(db) }
    }

    private static func lastCut(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT MAX(end_ms) FROM event_intervals")
    }

    /// 最旧一张还在等 OCR 的帧(screen `ocr_pending`,DeferredOCRWorker)。封口截止点不越过它:
    /// workflow 第 1 层(OCR)没做完的帧不进事件链。
    private static func ocrHold(_ screen: Database) throws -> Int64? {
        try Int64.fetchOne(screen, sql: "SELECT MIN(timestamp_ms) FROM ocr_pending")
    }

    /// 需要 event job 处理的区间:event 还有活,或 event 已完成而 impact 还有活,且都已
    /// 过退避窗口(规则同 `MemoryScheduler.backoffMs`)。按 start_ms 升序。
    func needsWork(nowMs: Int64 = EventIntervalStore.nowMs()) throws -> [EventInterval] {
        try all().filter { Self.isCandidate($0, nowMs: nowMs) }
    }

    static func isCandidate(_ iv: EventInterval, nowMs: Int64) -> Bool {
        if iv.event.needsWork, backoffReady(iv.event, iv.retryCount, iv.updatedAtMs, nowMs) { return true }
        if iv.event == .complete, iv.impact.needsWork,
           backoffReady(iv.impact, iv.retryCount, iv.updatedAtMs, nowMs) { return true }
        return false
    }

    static func backoffReady(_ s: ProcessingStatus, _ retry: Int, _ updatedAtMs: Int64, _ nowMs: Int64) -> Bool {
        switch s {
        case .idle, .pending, .paused: return true
        case .failed, .budgetDeferred, .deadLetter:
            return nowMs >= updatedAtMs + MemoryScheduler.backoffMs(retry: retry)
        case .inProgress, .complete, .partial: return false
        }
    }

    /// 上一截止点之后、`beforeMs` 之前还没封进区间的事件链帧数(Run now 的「有没有活」)。
    /// 还没有 origin 时按 T0 规则现算。
    func unsealedFrameCount(beforeMs: Int64) throws -> Int {
        let from = try lastCut() ?? computeOrigin(nowMs: beforeMs)
        return try screenPool.read { db in
            let hold = try Self.ocrHold(db)
            let beforeMs = min(beforeMs, hold ?? beforeMs)
            guard beforeMs > from else { return 0 }
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM frames
                WHERE \(Self.eventFrameFilter) AND timestamp_ms >= :from AND timestamp_ms < :to
                """, arguments: ["from": from, "to": beforeMs]) ?? 0
        }
    }

    // MARK: - 写(状态)

    /// 改 event / impact 阶段的状态(其他阶段不在这张表)。
    func setStatus(id: String, stage: ProcessingStage, status: ProcessingStatus,
                   nowMs: Int64 = EventIntervalStore.nowMs()) throws {
        let col: String
        switch stage {
        case .event: col = "event_status"
        case .impact: col = "impact_status"
        default: throw NSError(domain: "EventIntervalStore", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "event_intervals has no \(stage.rawValue) stage"])
        }
        try workflowPool.write { db in
            try db.execute(sql: "UPDATE event_intervals SET \(col) = :s, updated_at_ms = :now WHERE id = :id",
                           arguments: ["s": status.rawValue, "now": nowMs, "id": id])
        }
    }

    /// retry_count += 1,返回新值。
    @discardableResult
    func bumpRetry(id: String, nowMs: Int64 = EventIntervalStore.nowMs()) throws -> Int {
        try workflowPool.write { db in
            try db.execute(sql: """
                UPDATE event_intervals SET retry_count = retry_count + 1, updated_at_ms = :now WHERE id = :id
                """, arguments: ["now": nowMs, "id": id])
            return Int(try Int64.fetchOne(db, sql: "SELECT retry_count FROM event_intervals WHERE id = :id",
                                          arguments: ["id": id]) ?? 0)
        }
    }

    func setRetryCount(id: String, count: Int, nowMs: Int64 = EventIntervalStore.nowMs()) throws {
        try workflowPool.write { db in
            try db.execute(sql: "UPDATE event_intervals SET retry_count = :n, updated_at_ms = :now WHERE id = :id",
                           arguments: ["n": Int64(count), "now": nowMs, "id": id])
        }
    }

    /// 心跳:本机正在处理这一行时每 30 秒刷一次 updated_at_ms(只刷还在 in_progress 的行),
    /// 恢复逻辑据此判断进程是不是死了。
    func touch(id: String, nowMs: Int64 = EventIntervalStore.nowMs()) throws {
        try workflowPool.write { db in
            try db.execute(sql: """
                UPDATE event_intervals SET updated_at_ms = :now
                WHERE id = :id AND (event_status = :ip OR impact_status = :ip)
                """, arguments: ["now": nowMs, "id": id, "ip": ProcessingStatus.inProgress.rawValue])
        }
    }

    // MARK: - 封口

    /// 上一截止点(已封区间最大 end_ms)和已封最大帧 id。写之前再读一次,变了说明别人刚封过。
    private struct Ledger: Equatable {
        var lastCut: Int64
        var floor: Int64
    }

    private static func ledger(_ db: Database) throws -> Ledger? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT MAX(end_ms) AS cut, COALESCE(MAX(max_frame_id), 0) AS floor FROM event_intervals
            """), let cut = row["cut"] as Int64? else { return nil }
        return Ledger(lastCut: cut, floor: row["floor"])
    }

    /// 封口要用的帧,在 screen 上一个读事务里取齐。
    private struct SealFrames {
        /// 上一截止点到 now(含)之间的事件链帧,按时间排序。
        var frames: [IntervalSegmenter.Frame]
        /// 上一截止点之前、id 大于已封最大帧 id 的晚到帧。
        var late: [IntervalSegmenter.Frame]
        /// 最旧的待 OCR 帧时间。
        var ocrHold: Int64?

        /// [start, end) 里的帧数和最大帧 id(start ≥ 上一截止点,end ≤ now)。
        func count(_ start: Int64, _ end: Int64) -> (n: Int, maxId: Int64)? {
            let inRange = frames.filter { $0.ts >= start && $0.ts < end }
            guard let maxId = inRange.map(\.id).max() else { return nil }
            return (inRange.count, maxId)
        }
    }

    private func sealFrames(_ ledger: Ledger, nowMs: Int64) throws -> SealFrames {
        try screenPool.read { db in
            let frames = try Row.fetchAll(db, sql: """
                SELECT id, timestamp_ms, \(Self.nonIdleSQL) AS active FROM frames
                WHERE \(Self.eventFrameFilter) AND timestamp_ms >= :from AND timestamp_ms <= :now
                ORDER BY timestamp_ms, id
                """, arguments: ["from": ledger.lastCut, "now": nowMs]).map {
                IntervalSegmenter.Frame(id: $0["id"], ts: $0["timestamp_ms"], nonIdle: $0["active"])
            }
            let late = try Row.fetchAll(db, sql: """
                SELECT id, timestamp_ms FROM frames
                WHERE id > :floor AND timestamp_ms < :cut AND \(Self.eventFrameFilter)
                """, arguments: ["floor": ledger.floor, "cut": ledger.lastCut]).map {
                IntervalSegmenter.Frame(id: $0["id"], ts: $0["timestamp_ms"], nonIdle: true)
            }
            let hold = try Self.ocrHold(db)
            return SealFrames(frames: frames, late: late, ocrHold: hold)
        }
    }

    /// 空档封口检查(helper 每 :00 / :30 与 app tick 共用)。会封口时先把晚到帧封成补漏
    /// 区间,再按时间顺序封出上一截止点之后所有已成立的空档区间。返回本次新封的区间(可能
    /// 为空)。
    @discardableResult
    func sealCheck(now: Date = Date(), tzOffsetMin: Int? = nil) throws -> [EventInterval] {
        let nowMs = Self.nowMs(now)
        let off = tzOffsetMin ?? IntervalSegmenter.currentOffsetMin(at: now)
        try ensureOrigin(nowMs: nowMs, tzOffsetMin: off)
        guard let ledger = try workflowPool.read({ try Self.ledger($0) }) else { return [] }
        let snap = try sealFrames(ledger, nowMs: nowMs)
        let gapCuts = IntervalSegmenter.gapCuts(frames: snap.frames, lastCut: ledger.lastCut, nowMs: nowMs)
        guard !gapCuts.isEmpty else { return [] }
        return try workflowPool.write { db in
            guard try Self.ledger(db) == ledger else { return [] }
            let cuts = gapCuts.filter { $0 <= (snap.ocrHold ?? $0) }
            var out = try Self.sealBackfill(db, snap, ledger, nowMs: nowMs, tzOffsetMin: off).map { [$0] } ?? []
            var start = ledger.lastCut
            for cut in cuts {
                // 这段没有帧(不封)→ 起点不动,并进下一个区间,区间仍首尾相接。
                guard let iv = try Self.insert(db, snap, start: start, end: cut, trigger: Self.triggerGap,
                                               nowMs: nowMs, tzOffsetMin: off) else { continue }
                out.append(iv)
                start = cut
            }
            return out
        }
    }

    /// Run now:先封补漏区间,再封 [上一截止点, now − 60 s);这段没有帧就不封。
    @discardableResult
    func sealRunNow(now: Date = Date(), tzOffsetMin: Int? = nil) throws -> [EventInterval] {
        let nowMs = Self.nowMs(now)
        let off = tzOffsetMin ?? IntervalSegmenter.currentOffsetMin(at: now)
        try ensureOrigin(nowMs: nowMs, tzOffsetMin: off)
        guard let ledger = try workflowPool.read({ try Self.ledger($0) }) else { return [] }
        let snap = try sealFrames(ledger, nowMs: nowMs)
        return try workflowPool.write { db in
            guard try Self.ledger(db) == ledger else { return [] }
            let last = ledger.lastCut
            var out = try Self.sealBackfill(db, snap, ledger, nowMs: nowMs, tzOffsetMin: off).map { [$0] } ?? []
            if let raw = IntervalSegmenter.runNowCut(lastCut: last, nowMs: nowMs),
               case let cut = min(raw, snap.ocrHold ?? raw), cut > last,
               let iv = try Self.insert(db, snap, start: last, end: cut, trigger: Self.triggerRunNow,
                                        nowMs: nowMs, tzOffsetMin: off) {
                out.append(iv)
            }
            return out
        }
    }

    /// 上一截止点之前、帧 id 大于所有已封区间最大帧 id 的晚到帧 → 一个补漏区间。
    private static func sealBackfill(_ db: Database, _ snap: SealFrames, _ ledger: Ledger, nowMs: Int64,
                                     tzOffsetMin: Int) throws -> EventInterval? {
        let late = snap.late, floor = ledger.floor
        guard let r = IntervalSegmenter.backfillRange(late) else { return nil }
        ivLog.notice("backfill: \(late.count) late frame(s) id > \(floor) in [\(r.start), \(r.end))")
        print("[intervals] backfill: \(late.count) late frame(s) id > \(floor), ts \(r.start)…\(r.end - 1)")
        var id = "iv:\(r.start)"
        if try Bool.fetchOne(db, sql: "SELECT 1 FROM event_intervals WHERE id = :id", arguments: ["id": id]) == true {
            id += "-b\(r.maxId)"
        }
        let iv = EventInterval(id: id, startMs: r.start, endMs: r.end, tzOffsetMin: tzOffsetMin,
                               sealedAtMs: nowMs, trigger: triggerBackfill, frameCount: late.count,
                               afterFrameId: floor, maxFrameId: r.maxId, event: .pending, impact: .idle,
                               retryCount: 0, updatedAtMs: nowMs)
        try write(db, iv)
        return iv
    }

    /// 封 [start, end);这段没有事件链帧 → 不封。
    private static func insert(_ db: Database, _ snap: SealFrames, start: Int64, end: Int64, trigger: String,
                               nowMs: Int64, tzOffsetMin: Int) throws -> EventInterval? {
        guard let c = snap.count(start, end) else { return nil }
        let (n, maxId) = c
        let iv = EventInterval(id: "iv:\(start)", startMs: start, endMs: end, tzOffsetMin: tzOffsetMin,
                               sealedAtMs: nowMs, trigger: trigger, frameCount: n,
                               afterFrameId: 0, maxFrameId: maxId, event: .pending, impact: .idle,
                               retryCount: 0, updatedAtMs: nowMs)
        try write(db, iv)
        ivLog.notice("sealed \(iv.id, privacy: .public) [\(start), \(end)) \(trigger, privacy: .public) · \(n) frame(s)")
        print("[intervals] sealed \(iv.id) \(trigger) [\(start), \(end)) · \(n) frame(s)")
        return iv
    }

    private static func write(_ db: Database, _ iv: EventInterval, orIgnore: Bool = false) throws {
        try db.execute(sql: """
            INSERT \(orIgnore ? "OR IGNORE " : "")INTO event_intervals (\(columns))
            VALUES (:id, :start, :end, :tz, :sealed, :trigger, :n, :after, :max, :ev, :imp, :rc, :now)
            """, arguments: [
                "id": iv.id, "start": iv.startMs, "end": iv.endMs, "tz": Int64(iv.tzOffsetMin),
                "sealed": iv.sealedAtMs, "trigger": iv.trigger, "n": Int64(iv.frameCount),
                "after": iv.afterFrameId, "max": iv.maxFrameId, "ev": iv.event.rawValue,
                "imp": iv.impact.rawValue, "rc": Int64(iv.retryCount), "now": iv.updatedAtMs,
            ])
    }

    // MARK: - T0 过渡

    /// 没有 origin 行就按 T0 规则算出来并写入,返回 T0。两个进程同时插起点时以先写进去的为准。
    @discardableResult
    func ensureOrigin(nowMs: Int64, tzOffsetMin: Int) throws -> Int64 {
        if let t0 = try origin() { return t0 }
        let t0 = try computeOrigin(nowMs: nowMs)
        let maxId = try screenPool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT MAX(id) FROM frames WHERE \(Self.eventFrameFilter) AND timestamp_ms < :t0
                """, arguments: ["t0": t0]) ?? 0
        }
        let iv = EventInterval(id: Self.originId, startMs: t0, endMs: t0, tzOffsetMin: tzOffsetMin,
                               sealedAtMs: nowMs, trigger: Self.triggerOrigin, frameCount: 0,
                               afterFrameId: 0, maxFrameId: maxId, event: .complete, impact: .complete,
                               retryCount: 0, updatedAtMs: nowMs)
        return try workflowPool.write { db in
            try Self.write(db, iv, orIgnore: true)
            let stored = try Int64.fetchOne(db, sql: "SELECT end_ms FROM event_intervals WHERE id = :id",
                                            arguments: ["id": Self.originId]) ?? t0
            if stored == t0 {
                ivLog.notice("origin T0 = \(t0) (max frame id before T0 = \(maxId))")
                print("[intervals] origin T0 = \(t0) (max frame id before T0 = \(maxId))")
            }
            return stored
        }
    }

    func computeOrigin(nowMs: Int64) throws -> Int64 {
        let days = try workflowPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT date, event_status, impact_status FROM processing_log
                WHERE date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
                """).map { r -> (date: String, complete: Bool) in
                (r["date"], (r["event_status"] as String?) == "complete" && (r["impact_status"] as String?) == "complete")
            }
        }
        let first = try screenPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(timestamp_ms) FROM frames WHERE \(Self.eventFrameFilter)")
        }
        return IntervalSegmenter.originCut(days: days, firstFrameMs: first, nowMs: nowMs)
    }

    // MARK: - personality 本地日

    private static func decodeDay(_ r: Row) -> PersonalityDay {
        PersonalityDay(day: r["day"], tzOffsetMin: Int((r["tz_offset_min"] as Int64?) ?? 0),
                       status: ProcessingStatus(rawValue: r["status"]) ?? .idle,
                       retryCount: Int((r["retry_count"] as Int64?) ?? 0),
                       updatedAtMs: r["updated_at_ms"])
    }

    func personalityDay(_ day: String) throws -> PersonalityDay? {
        try workflowPool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT day, tz_offset_min, status, retry_count, updated_at_ms FROM personality_days WHERE day = :d
                """, arguments: ["d": day]).map(Self.decodeDay)
        }
    }

    /// 可以跑 personality 的本地日(升序):该日开始不早于 T0、已封区间覆盖到该日本地
    /// 24:00、所有与该日重叠的区间 event / impact 都 complete、该日有帧,且台账里还没有
    /// 这一天或它还需处理并已过退避。偏移取第一个碰到这天的区间的 tz_offset_min。
    /// `inBundle`:同一个 Premium 包里先跑的区间,算作满足「complete」(Premium 在同一次运行里
    /// 等它们真的 complete 才跑这一天)。本机路径不传。
    func readyPersonalityDays(nowMs: Int64 = EventIntervalStore.nowMs(),
                              inBundle: Set<String> = []) throws -> [PersonalityDay] {
        let candidates: [(day: PersonalityDay, start: Int64, end: Int64)] = try workflowPool.read { db in
            guard let t0 = try Int64.fetchOne(db, sql: "SELECT end_ms FROM event_intervals WHERE id = :id",
                                              arguments: ["id": Self.originId]),
                  let lastCut = try Self.lastCut(db) else { return [] }
            let ivs = try Self.fetchAll(db)
            var offsets: [String: Int] = [:]
            var order: [String] = []
            for iv in ivs {
                for d in IntervalSegmenter.touchedDays(startMs: iv.startMs, endMs: iv.endMs,
                                                       tzOffsetMin: iv.tzOffsetMin) where offsets[d] == nil {
                    offsets[d] = iv.tzOffsetMin
                    order.append(d)
                }
            }
            var out: [(day: PersonalityDay, start: Int64, end: Int64)] = []
            for d in order.sorted() {
                guard let off = offsets[d], let w = IntervalSegmenter.dayWindow(d, tzOffsetMin: off),
                      w.start >= t0, lastCut >= w.end else { continue }
                let row = try Row.fetchOne(db, sql: """
                    SELECT day, tz_offset_min, status, retry_count, updated_at_ms FROM personality_days WHERE day = :d
                    """, arguments: ["d": d]).map(Self.decodeDay)
                if let row, !(row.status.needsWork
                              && Self.backoffReady(row.status, row.retryCount, row.updatedAtMs, nowMs)) {
                    continue
                }
                let overlapping = ivs.filter { $0.startMs < w.end && $0.endMs > w.start }
                guard overlapping.allSatisfy({
                    ($0.event == .complete && $0.impact == .complete) || inBundle.contains($0.id)
                }) else { continue }
                out.append((row ?? PersonalityDay(day: d, tzOffsetMin: off, status: .pending,
                                                  retryCount: 0, updatedAtMs: 0), w.start, w.end))
            }
            return out
        }
        guard !candidates.isEmpty else { return [] }
        // 该日有帧才跑:在 screen 上一次读完所有候选日的帧数。
        return try screenPool.read { db in
            try candidates.filter { c in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM frames WHERE timestamp_ms >= :s AND timestamp_ms < :e)
                    """, arguments: ["s": c.start, "e": c.end]) == true
            }.map(\.day)
        }
    }

    /// personality_days 全部行,按 day 升序。
    func allPersonalityDays() throws -> [PersonalityDay] {
        try workflowPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, tz_offset_min, status, retry_count, updated_at_ms FROM personality_days ORDER BY day
                """).map(Self.decodeDay)
        }
    }

    /// 心跳,同 `touch(id:)`。
    func touchPersonality(day: String, nowMs: Int64 = EventIntervalStore.nowMs()) throws {
        try workflowPool.write { db in
            try db.execute(sql: """
                UPDATE personality_days SET updated_at_ms = :now WHERE day = :d AND status = :ip
                """, arguments: ["now": nowMs, "d": day, "ip": ProcessingStatus.inProgress.rawValue])
        }
    }

    func setPersonalityRetryCount(day: String, count: Int, nowMs: Int64 = EventIntervalStore.nowMs()) throws {
        try workflowPool.write { db in
            try db.execute(sql: "UPDATE personality_days SET retry_count = :n, updated_at_ms = :now WHERE day = :d",
                           arguments: ["n": Int64(count), "now": nowMs, "d": day])
        }
    }

    /// 写某本地日的 personality 状态(没有这一行就建)。
    func setPersonalityStatus(day: String, tzOffsetMin: Int, status: ProcessingStatus,
                              nowMs: Int64 = EventIntervalStore.nowMs()) throws {
        try workflowPool.write { db in
            try db.execute(sql: """
                INSERT INTO personality_days (day, tz_offset_min, status, retry_count, updated_at_ms)
                VALUES (:d, :tz, :s, 0, :now)
                ON CONFLICT(day) DO UPDATE SET status = excluded.status, updated_at_ms = excluded.updated_at_ms
                """, arguments: ["d": day, "tz": Int64(tzOffsetMin), "s": status.rawValue, "now": nowMs])
        }
    }

    @discardableResult
    func bumpPersonalityRetry(day: String, nowMs: Int64 = EventIntervalStore.nowMs()) throws -> Int {
        try workflowPool.write { db in
            try db.execute(sql: """
                UPDATE personality_days SET retry_count = retry_count + 1, updated_at_ms = :now WHERE day = :d
                """, arguments: ["now": nowMs, "d": day])
            return Int(try Int64.fetchOne(db, sql: "SELECT retry_count FROM personality_days WHERE day = :d",
                                          arguments: ["d": day]) ?? 0)
        }
    }
}
