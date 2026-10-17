import Foundation
import GRDB

/// `--segment-replay [--from yyyy-MM-dd] [--db PATH]`:只读回放封区间规则。
///
/// 从 `--from` 那天本地 00:00(不给 = 最早一帧)起,每个 :00 / :30 模拟一次封区间检查
/// (`IntervalSegmenter.gapCuts`,一次可封多个;晚到帧走补漏区间),一帧在它的
/// `created_at_ms` 之后才算已入库。输出每个区间的起止、帧数、封口时刻,以及:每帧是否
/// 恰好属于一个区间、被切断的 Tier-1 session 数(切点前后 5 分钟内两侧都有非空转帧)、
/// 每个本地日的区间数、区间帧数分布,并拿同一时段的 UTC / 本地午夜切点做对照。
/// 只开只读连接,不跑迁移,不写任何东西。检查时刻按「每 30 分钟都醒着」理想化:
/// 真机睡着时检查挪到唤醒那一刻,截止点不变,只有封口时刻往后移。
enum SegmentReplayCLI {

    private struct F {
        let id: Int64
        let ts: Int64
        let created: Int64
        let nonIdle: Bool
    }

    private struct IV {
        let start: Int64
        let end: Int64
        let after: Int64
        let maxId: Int64
        let count: Int
        let sealedAt: Int64
        let trigger: String
    }

    static func run(args: [String]) -> Never {
        do {
            try replay(args)
            exit(0)
        } catch {
            fputs("[segment-replay] ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func value(_ flag: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func fmt(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static func replay(_ args: [String]) throws {
        let path = value("--db", args).map { ($0 as NSString).expandingTildeInPath } ?? Storage.portraitDBPath
        var cfg = Configuration()
        cfg.readonly = true
        let q = try DatabaseQueue(path: path, configuration: cfg)

        var fromMs: Int64?
        if let s = value("--from", args) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: s) else {
                throw NSError(domain: "SegmentReplay", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "--from needs yyyy-MM-dd"])
            }
            fromMs = Int64(d.timeIntervalSince1970 * 1000)
        }
        let frames: [F] = try q.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, timestamp_ms, created_at_ms, \(EventIntervalStore.nonIdleSQL) AS active FROM frames
                WHERE \(EventIntervalStore.eventFrameFilter) AND timestamp_ms >= :from
                ORDER BY timestamp_ms, id
                """, arguments: ["from": fromMs ?? Int64.min]).map {
                F(id: $0["id"], ts: $0["timestamp_ms"], created: $0["created_at_ms"], nonIdle: $0["active"])
            }
        }
        guard let first = frames.first else { print("[segment-replay] no frames"); return }
        let nowMs = EventIntervalStore.nowMs()
        let grid: Int64 = 30 * 60_000
        let ts = frames.map(\.ts)
        let byId = frames.sorted { $0.id < $1.id }
        let ids = byId.map(\.id)
        let createdSorted = frames.map(\.created).sorted()

        let startCut = fromMs ?? first.ts
        var lastCut = startCut
        var floorId: Int64 = 0
        var ivs: [IV] = []
        var checks = 0
        var t = (startCut / grid + 1) * grid

        while t <= nowMs {
            checks += 1
            let lo = IntervalSegmenter.lowerBound(ts, lastCut)
            let hi = IntervalSegmenter.lowerBound(ts, t + 1)
            var vis: [IntervalSegmenter.Frame] = []
            if lo < hi {
                for i in lo..<hi where frames[i].created <= t {
                    vis.append(.init(id: frames[i].id, ts: frames[i].ts, nonIdle: frames[i].nonIdle))
                }
            }
            if vis.isEmpty {
                // 没有待封的帧 → 状态只会被下一帧入库改变,直接跳过去。
                let k = IntervalSegmenter.lowerBound(createdSorted, t + 1)
                guard k < createdSorted.count else { break }
                t = max(t + grid, (createdSorted[k] / grid + 1) * grid)
                continue
            }
            let cuts = IntervalSegmenter.gapCuts(frames: vis, lastCut: lastCut, nowMs: t)
            if !cuts.isEmpty {
                var late: [IntervalSegmenter.Frame] = []
                for k in IntervalSegmenter.lowerBound(ids, floorId + 1)..<byId.count
                where byId[k].created <= t && byId[k].ts < lastCut {
                    late.append(.init(id: byId[k].id, ts: byId[k].ts, nonIdle: byId[k].nonIdle))
                }
                if let r = IntervalSegmenter.backfillRange(late) {
                    ivs.append(IV(start: r.start, end: r.end, after: floorId, maxId: r.maxId,
                                  count: late.count, sealedAt: t, trigger: "backfill"))
                    floorId = max(floorId, r.maxId)
                }
                for cut in cuts {
                    let inside = vis.filter { $0.ts >= lastCut && $0.ts < cut }
                    guard let maxId = inside.map(\.id).max() else { continue }
                    ivs.append(IV(start: lastCut, end: cut, after: 0, maxId: maxId, count: inside.count,
                                  sealedAt: t, trigger: EventIntervalStore.triggerGap))
                    floorId = max(floorId, maxId)
                    lastCut = cut
                }
            }
            t += grid
        }

        // —— 区间列表 ——
        print("[segment-replay] db: \(path)")
        print("[segment-replay] from \(fmt(startCut)) · \(frames.count) event-chain frame(s) · \(checks) check(s) simulated · time zone \(TimeZone.current.identifier)")
        print("")
        print(" #  trigger   start (local)  end (local)    hours   frames  sealed at")
        for (i, iv) in ivs.enumerated() {
            let hrs = Double(iv.end - iv.start) / 3_600_000
            print(String(format: "%2d  %-8@  %@    %@  %6.1f  %7d  %@",
                         i + 1, iv.trigger as NSString, fmt(iv.start) as NSString, fmt(iv.end) as NSString,
                         hrs, iv.count, fmt(iv.sealedAt) as NSString))
        }

        // —— 每帧恰好属于一个区间 ——
        var membership = [Int](repeating: 0, count: frames.count)
        for iv in ivs {
            let lo = IntervalSegmenter.lowerBound(ts, iv.start), hi = IntervalSegmenter.lowerBound(ts, iv.end)
            guard lo < hi else { continue }
            for i in lo..<hi where frames[i].id > iv.after && frames[i].id <= iv.maxId { membership[i] += 1 }
        }
        var one = 0, zero = 0, multi = 0, lateWaiting = 0, unsealed = 0
        for (i, f) in frames.enumerated() {
            if f.ts >= lastCut { unsealed += 1; continue }
            switch membership[i] {
            case 1: one += 1
            case 0: if f.id > floorId { lateWaiting += 1 } else { zero += 1 }
            default: multi += 1
            }
        }
        let normal = ivs.filter { $0.trigger == EventIntervalStore.triggerGap }
        var contiguous = true
        for (a, b) in zip(normal, normal.dropFirst()) where a.end != b.start { contiguous = false }

        // —— Tier-1 session 切断 ——
        let active = frames.filter(\.nonIdle).map(\.ts)
        let cuts = normal.map(\.end)
        let cutHits = cuts.filter { IntervalSegmenter.cutsSession($0, nonIdleTs: active) }.count
        func midnights(_ tz: TimeZone) -> [Int64] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            var d = cal.startOfDay(for: Date(timeIntervalSince1970: Double(startCut) / 1000))
            var out: [Int64] = []
            while true {
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d
                let ms = Int64(d.timeIntervalSince1970 * 1000)
                guard ms < lastCut else { break }
                out.append(ms)
            }
            return out
        }
        let utcMid = midnights(TimeZone(identifier: "UTC")!)
        let localMid = midnights(.current)
        let utcHits = utcMid.filter { IntervalSegmenter.cutsSession($0, nonIdleTs: active) }.count
        let localHits = localMid.filter { IntervalSegmenter.cutsSession($0, nonIdleTs: active) }.count

        // —— 帧数分布 ——
        let counts = normal.map(\.count).sorted()
        func pct(_ p: Double) -> Int { counts.isEmpty ? 0 : counts[min(counts.count - 1, Int(Double(counts.count - 1) * p))] }
        let buckets: [(String, (Int) -> Bool)] = [
            ("<1k", { $0 < 1000 }), ("1k–5k", { $0 >= 1000 && $0 < 5000 }),
            ("5k–10k", { $0 >= 5000 && $0 < 10000 }), ("≥10k", { $0 >= 10000 }),
        ]
        let hours = normal.map { Double($0.end - $0.start) / 3_600_000 }.sorted()

        print("")
        print("[segment-replay] summary")
        print("  intervals: \(normal.count) gap + \(ivs.count - normal.count) backfill · sealed up to \(fmt(lastCut)) · gap intervals contiguous: \(contiguous ? "yes" : "NO")")
        print("  frames before last cut: \(one + zero + multi + lateWaiting) · exactly one interval: \(one) · none: \(zero) · more than one: \(multi) · late, waiting for next backfill: \(lateWaiting)")
        print("  frames after last cut (not sealed yet): \(unsealed)")
        print("  Tier-1 sessions cut: \(cutHits) of \(cuts.count) interval cut(s)  (baseline: UTC midnight \(utcHits)/\(utcMid.count), local midnight \(localHits)/\(localMid.count))")
        print("  frames per interval: min \(counts.first ?? 0) · median \(pct(0.5)) · p90 \(pct(0.9)) · max \(counts.last ?? 0) · over 5000: \(counts.filter { $0 > 5000 }.count)")
        print("  distribution: " + buckets.map { b in "\(b.0) \(counts.filter(b.1).count)" }.joined(separator: " · "))
        if let h0 = hours.first, let h1 = hours.last {
            print(String(format: "  interval length: min %.1f h · median %.1f h · max %.1f h", h0, hours[(hours.count - 1) / 2], h1))
        }
        // 每个本地日的区间数(按截止点所在的本地日计;首尾两天可能不完整)。
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "MM-dd"
        var perDay: [String: Int] = [:]
        for d in midnights(.current).map({ $0 - 1 }) + [lastCut - 1] {
            perDay[dayFmt.string(from: Date(timeIntervalSince1970: Double(d) / 1000))] = 0
        }
        for iv in normal { perDay[dayFmt.string(from: Date(timeIntervalSince1970: Double(iv.end - 1) / 1000)), default: 0] += 1 }
        let dayCounts = perDay.values.sorted()
        if let lo = dayCounts.first, let hi = dayCounts.last {
            print(String(format: "  intervals per local day (by cut): min %d · median %d · mean %.2f · max %d over %d day(s)",
                         lo, dayCounts[(dayCounts.count - 1) / 2],
                         Double(dayCounts.reduce(0, +)) / Double(dayCounts.count), hi, dayCounts.count))
            print("  histogram: " + Dictionary(grouping: dayCounts, by: { $0 }).sorted { $0.key < $1.key }
                .map { "\($0.key)/day×\($0.value.count)" }.joined(separator: " "))
            let days = perDay.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            for chunk in stride(from: 0, to: days.count, by: 10) {
                print("    " + days[chunk..<min(chunk + 10, days.count)].joined(separator: " · "))
            }
        }
        let sealHours = normal.map { Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double($0.sealedAt) / 1000)) }
        print("  sealed at local hour: " + Dictionary(grouping: sealHours, by: { $0 }).sorted { $0.key < $1.key }
            .map { "\(String(format: "%02d", $0.key)):xx×\($0.value.count)" }.joined(separator: " "))
    }
}
