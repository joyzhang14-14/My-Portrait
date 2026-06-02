import Foundation

/// Sleep-consolidation budget pass.
///
/// Cognitive premise: the brain consolidates memories nightly, with a
/// roughly fixed **daily** capacity. A wild day and a quiet day encode a
/// similar number of deep memories; the wild day's big things crowd out
/// smaller ones.
///
/// Algorithm:
///   1. Take all events whose latest occurrence is in the past `windowDays`.
///   2. Separate three groups:
///        protected (rawImpact ≥ peakProtection) — final = raw, untouched.
///        frozen    (rebalanceCount ≥ maxRebalances) — leave impact alone.
///        rebalancable (everything else)
///   3. Group the rebalancable events BY DAY.
///   4. Per day — greedy waterline:
///        if the day's rawImpact sum ≤ dailyBudget → keep every raw value.
///        else → sort the day's events high→low, hand out the budget in
///               order. Events that fit keep their full rawImpact; the one
///               that crosses the line gets the leftover; the rest floor to
///               the impact minimum. Big things keep their weight; the day's
///               trivia fades. (Linear scaling would crush a release event
///               as hard as an idle-browsing one — the wrong shape.)
///   5. Increment rebalanceCount on each touched file.
///
/// Pure-function module — file I/O is the caller's job.
enum MemoryBudget {
    struct Params {
        /// Per-day impact budget. Each day's rebalancable events are scaled
        /// so their rawImpact sum doesn't exceed this.
        var dailyBudget: Double = 50

        /// Events with rawImpact at or above this never get scaled down.
        var peakProtection: Double = 4.5

        /// After this many touches, an event's impact is frozen.
        var maxRebalances: Int = 5

        /// How wide a window the rebalance considers (days). 7 = past week.
        var windowDays: Int = 7

        static let `default` = Params()

        /// Pulled from the live ConfigStore, which the Settings UI mutates.
        @MainActor
        static var fromConfig: Params {
            let m = ConfigStore.shared.current.memory
            return Params(
                dailyBudget: m.dailyBudget,
                peakProtection: m.peakProtection,
                maxRebalances: m.maxRebalances,
                windowDays: m.windowDays
            )
        }
    }

    struct Plan {
        let url: URL
        let oldImpact: Double
        let newImpact: Double
        let kind: Kind

        enum Kind: String {
            case rebalanced       // scaled down by the week's pressure
            case restored         // restored to raw (quiet week)
            case protected        // raw ≥ peak; untouched
            case frozen           // rebalanceCount cap; untouched
            case outsideWindow    // older than windowDays; untouched
        }
    }

    struct Result {
        let weekStart: Date
        let weekEnd: Date
        let sumRawImpact: Double       // rebalancable group only
        let scale: Double              // 1.0 if no compression needed
        let touchedCount: Int          // # files with rebalanceCount incremented
        let protectedCount: Int
        let frozenCount: Int
        let plans: [Plan]              // every input file → its outcome
    }

    /// Rebalance one week's events. Caller passes (url, file) pairs; the
    /// returned plans tell which files need writing back. The function does
    /// NOT mutate input or write to disk — the caller does both.
    static func rebalance(
        events: [(URL, PortraitFile)],
        now: Date = Date(),
        params: Params = .default
    ) -> Result {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let today = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -(params.windowDays - 1), to: today) ?? today

        var plans: [Plan] = []
        var rebalancableRawSum: Double = 0
        var protectedCount = 0
        var frozenCount = 0

        // Pre-pass: categorise each event.
        struct Bucket {
            let url: URL
            let file: PortraitFile
            let kind: BucketKind
        }
        enum BucketKind { case rebalancable, protected, frozen, outside }

        var bucketed: [Bucket] = []
        for (url, file) in events {
            let lastOcc = file.occurrences.max() ?? file.created
            if lastOcc < weekStart {
                bucketed.append(.init(url: url, file: file, kind: .outside))
                continue
            }
            // event 必有 rawImpact / rebalanceCount;?? 0 仅类型系统防御。
            let raw = file.rawImpact ?? 0
            let rebal = file.rebalanceCount ?? 0
            if raw >= params.peakProtection {
                bucketed.append(.init(url: url, file: file, kind: .protected))
                protectedCount += 1
                continue
            }
            if rebal >= params.maxRebalances {
                bucketed.append(.init(url: url, file: file, kind: .frozen))
                frozenCount += 1
                continue
            }
            bucketed.append(.init(url: url, file: file, kind: .rebalancable))
            rebalancableRawSum += raw
        }

        // 该事件归属的"天" = 最近一次 occurrence（无则 created）的 UTC 当日。
        func dayOf(_ file: PortraitFile) -> Date {
            cal.startOfDay(for: file.occurrences.max() ?? file.created)
        }

        // 按天分组 rebalancable，每天用"贪心水位线"压缩，而不是等比缩放：
        // 当天事件按 rawImpact 从高到低排，依次占用 daily budget——
        //   占满之前的（大事）保留原值；
        //   跨过水位线的那一个拿到 budget 剩余的零头（部分保留）；
        //   之后的（琐事）budget 已空 → 沉到 impact 地板。
        // 等比缩放会把重要事件压得跟琐事一样狠；水位线则"大事挤掉小事"。
        var rebalByDay: [Date: [(url: URL, raw: Double)]] = [:]
        for b in bucketed where b.kind == .rebalancable {
            rebalByDay[dayOf(b.file), default: []].append((b.url, b.file.rawImpact ?? 0))
        }
        var newImpactByURL: [URL: Double] = [:]
        var overBudgetDays: Set<Date> = []
        for (day, items) in rebalByDay {
            let daySum = items.reduce(0.0) { $0 + $1.raw }
            if daySum <= params.dailyBudget {
                // 安静的天：全保留原值。
                for it in items {
                    newImpactByURL[it.url] = PortraitFile.clampImpact(it.raw)
                }
            } else {
                overBudgetDays.insert(day)
                var remaining = params.dailyBudget
                for it in items.sorted(by: { $0.raw > $1.raw }) {
                    let give = min(it.raw, max(0, remaining))
                    newImpactByURL[it.url] = PortraitFile.clampImpact(give)
                    remaining -= give
                }
            }
        }

        var touched = 0
        var totalNewImpact: Double = 0   // rebalancable group 的 new 总和
        for b in bucketed {
            // MemoryBudget 只扫 events/，event 必有 impact；?? 0 是类型系统
            // 防御，运行时永远不触发。
            let cur = b.file.impact ?? 0
            switch b.kind {
            case .outside:
                plans.append(.init(url: b.url,
                                   oldImpact: cur,
                                   newImpact: cur,
                                   kind: .outsideWindow))
            case .protected:
                // Force final = raw in case a prior pass had scaled it.
                let target = PortraitFile.clampImpact(b.file.rawImpact ?? 0)
                let needsWrite = abs(cur - target) > 0.0001
                plans.append(.init(url: b.url,
                                   oldImpact: cur,
                                   newImpact: needsWrite ? target : cur,
                                   kind: .protected))
            case .frozen:
                plans.append(.init(url: b.url,
                                   oldImpact: cur,
                                   newImpact: cur,
                                   kind: .frozen))
            case .rebalancable:
                let newImpact = newImpactByURL[b.url]
                    ?? PortraitFile.clampImpact(b.file.rawImpact ?? 0)
                let kind: Plan.Kind = overBudgetDays.contains(dayOf(b.file))
                    ? .rebalanced : .restored
                plans.append(.init(url: b.url,
                                   oldImpact: cur,
                                   newImpact: newImpact,
                                   kind: kind))
                totalNewImpact += newImpact
                touched += 1
            }
        }

        // Result.scale 报整体有效比（new 总和 / raw 总和）—— 每天 scale 不同，
        // 单一数字只作概览。
        let scale: Double = rebalancableRawSum > 0
            ? totalNewImpact / rebalancableRawSum
            : 1.0

        return Result(
            weekStart: weekStart,
            weekEnd: today,
            sumRawImpact: rebalancableRawSum,
            scale: scale,
            touchedCount: touched,
            protectedCount: protectedCount,
            frozenCount: frozenCount,
            plans: plans
        )
    }

    /// Apply a single plan to an in-memory file. Caller is responsible for
    /// writing back to disk + running WeightCalculator afterwards.
    static func apply(_ plan: Plan, to file: inout PortraitFile) {
        switch plan.kind {
        case .outsideWindow, .frozen:
            return     // no change
        case .protected:
            file.impact = plan.newImpact
        case .rebalanced:
            file.impact = plan.newImpact
            file.rebalanceCount = (file.rebalanceCount ?? 0) + 1
        case .restored:
            // 把原始 impact 写回,但 restore 是 no-op 不算一次 rebalance —— 否则
            // 没真正压缩的天也累加 rebalanceCount,提前把 event 冻结。
            file.impact = plan.newImpact
        }
    }
}

// MARK: - Disk orchestration

/// Scan events on disk, rebalance the week, write changes back, recompute
/// weights, and append a journal entry. Returns a one-line status string
/// suitable for the UI.
@MainActor
func MemoryBudget_applyToDisk(
    params: MemoryBudget.Params = .fromConfig,
    now: Date = Date()
) -> String {
    let fm = FileManager.default
    let root = Storage.eventsDir
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return "Rebalance: no events directory."
    }

    // Load every event file (only events; portrait files don't participate).
    var loaded: [(URL, PortraitFile)] = []
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension == "md" else { continue }
        guard url.lastPathComponent != "INDEX.md" else { continue }
        if url.pathComponents.contains("_archive") { continue }
        guard let f = try? PortraitFileIO.read(from: url) else { continue }
        loaded.append((url, f))
    }
    if loaded.isEmpty {
        return "Rebalance: no events to rebalance."
    }

    let result = MemoryBudget.rebalance(events: loaded, now: now, params: params)

    // Apply changes + weight recompute.
    var written = 0
    var fileByURL: [URL: PortraitFile] = Dictionary(uniqueKeysWithValues: loaded)
    for plan in result.plans {
        guard plan.kind != .outsideWindow, plan.kind != .frozen else { continue }
        guard var file = fileByURL[plan.url] else { continue }
        MemoryBudget.apply(plan, to: &file)
        WeightCalculator.recompute(&file)
        do {
            try PortraitFileIO.write(file, to: plan.url)
            fileByURL[plan.url] = file
            written += 1
        } catch {
            continue
        }
    }

    // Journal append (mirrors the Archiver convention).
    writeJournal(result: result, now: now)

    let scaleStr = String(format: "%.2f", result.scale)
    let sumStr = String(format: "%.1f", result.sumRawImpact)
    return "Rebalanced: sum=\(sumStr) → scale=\(scaleStr), touched=\(result.touchedCount), protected=\(result.protectedCount), frozen=\(result.frozenCount)"
}

private func writeJournal(result: MemoryBudget.Result, now: Date) {
    let url = PortraitPaths.todayJournalURL
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let dayFmt = DateFormatter()
    dayFmt.dateFormat = "yyyy-MM-dd"
    dayFmt.timeZone = TimeZone(identifier: "UTC")

    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "HH:mm:ss 'UTC'"
    timeFmt.timeZone = TimeZone(identifier: "UTC")

    var lines: [String] = []
    lines.append("\n## Daily memory budget (\(timeFmt.string(from: now)))")
    lines.append("- Window: \(dayFmt.string(from: result.weekStart)) → \(dayFmt.string(from: result.weekEnd))")
    lines.append("- Sum raw impact (rebalancable): \(String(format: "%.2f", result.sumRawImpact))")
    lines.append("- Scale applied: \(String(format: "%.3f", result.scale))")
    lines.append("- Touched: \(result.touchedCount), protected: \(result.protectedCount), frozen: \(result.frozenCount)")
    if result.scale < 1.0 {
        lines.append("- Top scaled events:")
        let scaled = result.plans
            .filter { $0.kind == .rebalanced && abs($0.oldImpact - $0.newImpact) > 0.05 }
            .sorted { $0.oldImpact > $1.oldImpact }
            .prefix(8)
        for p in scaled {
            let rel = p.url.path.replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
            lines.append("  - \(rel): \(String(format: "%.2f", p.oldImpact)) → \(String(format: "%.2f", p.newImpact))")
        }
    }
    let chunk = lines.joined(separator: "\n") + "\n"

    if !fm.fileExists(atPath: url.path) {
        let head = "# 记忆维护日志 \(dayFmt.string(from: now))\n"
        try? head.write(to: url, atomically: true, encoding: .utf8)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        if let data = chunk.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
