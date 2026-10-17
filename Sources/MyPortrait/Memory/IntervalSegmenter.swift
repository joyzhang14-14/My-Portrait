import Foundation

/// event 链「区间」的封口规则(纯函数,不碰 DB)。台账与落库见 `EventIntervalStore`,
/// 回放统计见 `SegmentReplayCLI`。
///
/// 区间 = [上一截止点, 本截止点),UTC epoch ms 半开区间,首尾相接。
///   - 空档(`gap`):每 30 分钟检查一次。上一截止点之后,每个 ≥ 2h 的非空转帧空档都是一个
///     区间边界;空档已结束,或正在进行且已满 2h,就封口。一次检查可以按时间顺序封出多个区间,
///     结果只由帧历史决定,与检查时刻、睡眠无关。
///     截止点 = 空档起点之后第一个 ≥ 5 min 全帧空档的起点(那一帧 +1ms);屏幕常亮
///     一直有 idle 帧、找不到这样的空档时取空档起点那个非空转帧 +1ms。不晚于 now − 10 min。
///   - Run now(`run_now`):截止点 = now − 60 s。
///   - 补漏(`backfill`):上一截止点之前的晚到帧(帧 id 大于已封区间的最大帧 id),
///     按它们的时间范围单独成一个区间,靠帧 id 范围与原区间区分。
/// 非空转帧 = `capture_trigger` 不是 idle / manual。
enum IntervalSegmenter {

    /// 区间边界的非空转帧空档下限(portrait offload 规格 §15)。
    static let gapCutMs: Int64 = 2 * 3_600_000
    static let quietGapMs: Int64 = 5 * 60_000
    static let settleMs: Int64 = 10 * 60_000
    static let runNowLagMs: Int64 = 60_000
    /// Tier-1 session 的帧间距上限(与 event-local-lab 的 GAP_MS 一致)。
    static let sessionGapMs: Int64 = 5 * 60_000

    struct Frame: Sendable, Equatable {
        var id: Int64
        var ts: Int64
        var nonIdle: Bool
    }

    // MARK: - 空档封口

    /// 空档截止点,按时间顺序(可能为空)。`frames` = 上一截止点之后、此刻已入库的事件链帧,
    /// 按 ts 升序(含 idle 帧)。
    static func gapCuts(frames: [Frame], lastCut: Int64, nowMs: Int64) -> [Int64] {
        let active = frames.filter { $0.nonIdle && $0.ts >= lastCut && $0.ts <= nowMs }
        let horizon = nowMs - settleMs
        var cuts: [Int64] = []
        for (i, a) in active.enumerated() {
            let gapEnd = i + 1 < active.count ? active[i + 1].ts : nowMs
            guard gapEnd - a.ts >= gapCutMs else { continue }
            var cut = a.ts + 1
            let inGap = frames.filter { $0.ts >= a.ts && $0.ts < gapEnd }
            for (j, f) in inGap.enumerated() {
                guard f.ts + 1 <= horizon else { break }
                let next = j + 1 < inGap.count ? inGap[j + 1].ts : gapEnd
                if next - f.ts >= quietGapMs { cut = f.ts + 1; break }
            }
            cut = min(cut, horizon)
            if cut > (cuts.last ?? lastCut) { cuts.append(cut) }
        }
        return cuts
    }

    /// Run now 截止点;不比上一截止点晚 → nil。
    static func runNowCut(lastCut: Int64, nowMs: Int64) -> Int64? {
        let cut = nowMs - runNowLagMs
        return cut > lastCut ? cut : nil
    }

    /// 晚到帧 → 补漏区间 [最早帧, 最晚帧 +1ms) 与最大帧 id;没有晚到帧 → nil。
    static func backfillRange(_ late: [Frame]) -> (start: Int64, end: Int64, maxId: Int64)? {
        guard let lo = late.map(\.ts).min(), let hi = late.map(\.ts).max(),
              let maxId = late.map(\.id).max() else { return nil }
        return (lo, hi + 1, maxId)
    }

    // MARK: - 过渡起点 T0

    /// T0 = processing_log 里从最早一行起连续 event+impact complete 的 UTC 日的结束时刻;
    /// 遇到第一个没完成的日就取它的开始。没有日期行 → 最早一帧所在 UTC 日的开始;
    /// 连帧都没有 → now。
    static func originCut(days: [(date: String, complete: Bool)], firstFrameMs: Int64?,
                          nowMs: Int64) -> Int64 {
        var t0: Int64?
        for d in days.sorted(by: { $0.date < $1.date }) {
            guard let start = utcDayStartMs(d.date) else { continue }
            if !d.complete { return start }
            t0 = start + 86_400_000
        }
        if let t0 { return t0 }
        if let f = firstFrameMs { return f - ((f % 86_400_000) + 86_400_000) % 86_400_000 }
        return nowMs
    }

    private static func utcDayStartMs(_ day: String) -> Int64? {
        ProcessingLogStore.day(from: day).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    // MARK: - 本地日(钉死偏移)

    private static func dayFormatter(_ tzOffsetMin: Int) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60) ?? TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// 本机此刻的 UTC 偏移(分钟)。
    static func currentOffsetMin(_ tz: TimeZone = .current, at date: Date = Date()) -> Int {
        tz.secondsFromGMT(for: date) / 60
    }

    static func localDay(_ ms: Int64, tzOffsetMin: Int) -> String {
        dayFormatter(tzOffsetMin).string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// 本地日 [00:00, 24:00) 的 UTC ms(偏移固定,恰好 24h)。
    static func dayWindow(_ day: String, tzOffsetMin: Int) -> (start: Int64, end: Int64)? {
        guard let d = dayFormatter(tzOffsetMin).date(from: day) else { return nil }
        let s = Int64(d.timeIntervalSince1970 * 1000)
        return (s, s + 86_400_000)
    }

    /// [startMs, endMs) 碰到的本地日,升序。
    static func touchedDays(startMs: Int64, endMs: Int64, tzOffsetMin: Int) -> [String] {
        guard endMs > startMs, var w = dayWindow(localDay(startMs, tzOffsetMin: tzOffsetMin),
                                                 tzOffsetMin: tzOffsetMin) else { return [] }
        var out: [String] = []
        while w.start < endMs {
            out.append(localDay(w.start, tzOffsetMin: tzOffsetMin))
            w = (w.end, w.end + 86_400_000)
        }
        return out
    }

    /// 一组帧归哪个本地日(event-local-lab `attribute_day`):帧多的本地日 → 平手比
    /// 各段(Tier-1 session 的 [首帧, 末帧])在各天占的时长之和 → 再平手取最早一帧那天。
    static func attributeDay(frameTs: [Int64], spans: [(start: Int64, end: Int64)], tzOffsetMin: Int) -> String? {
        guard let first = frameTs.min() else { return nil }
        var cnt: [String: Int] = [:]
        for t in frameTs { cnt[localDay(t, tzOffsetMin: tzOffsetMin), default: 0] += 1 }
        let top = cnt.values.max() ?? 0
        var cands = cnt.filter { $0.value == top }.keys.sorted()
        if cands.count == 1 { return cands[0] }
        var dur: [String: Int64] = [:]
        for d in cands {
            guard let w = dayWindow(d, tzOffsetMin: tzOffsetMin) else { continue }
            dur[d] = spans.reduce(0) { $0 + max(0, min($1.end, w.end) - max($1.start, w.start)) }
        }
        let topDur = dur.values.max() ?? 0
        cands = cands.filter { dur[$0] == topDur }
        if cands.count == 1 { return cands[0] }
        return localDay(first, tzOffsetMin: tzOffsetMin)
    }

    // MARK: - 统计

    /// 切点前后 5 分钟内两侧都有非空转帧 = 切断了一个 Tier-1 session。`nonIdleTs` 升序。
    static func cutsSession(_ cut: Int64, nonIdleTs: [Int64]) -> Bool {
        let i = lowerBound(nonIdleTs, cut)
        let before = i > 0 && nonIdleTs[i - 1] >= cut - sessionGapMs
        let after = i < nonIdleTs.count && nonIdleTs[i] < cut + sessionGapMs
        return before && after
    }

    /// 升序数组里第一个 ≥ x 的下标。
    static func lowerBound(_ a: [Int64], _ x: Int64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
