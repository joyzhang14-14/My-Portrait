import Foundation

/// Sleep-consolidation budget pass.
///
/// Cognitive premise: the brain has a roughly fixed weekly capacity to
/// consolidate memories into long-term storage. A wild week and a quiet
/// week produce a similar number of deeply-encoded events; the wild week's
/// big things crowd out smaller ones.
///
/// Algorithm (per §design):
///   1. Take all events whose latest occurrence is in the past 7 days.
///   2. Separate three groups:
///        protected (rawImpact ≥ peakProtection) — final = raw, untouched.
///        frozen    (rebalanceCount ≥ maxRebalances) — leave impact alone.
///        rebalancable (everything else)
///   3. Sum rawImpact of the rebalancable group.
///   4. If sum > budget:  scale = budget / sum
///                        final = rawImpact × scale
///      If sum ≤ budget:  scale = 1.0
///                        final = rawImpact     (no compression)
///   5. Increment rebalanceCount on each touched file.
///
/// Triggering policy:
///   - Don't run more than once per UTC day. (Weekly is the spec; daily
///     would re-shuffle recent events constantly.)
///   - Cap per-event re-touches at 5; after that the event's final impact
///     is permanently the most-recent post-budget value.
///
/// Pure-function module — file I/O is the caller's job (Backfill or the
/// dedicated "rebalance" UI button).
enum MemoryBudget {
    struct Params {
        /// Total weekly impact budget.
        var weeklyBudget: Double = 50

        /// Events with rawImpact at or above this never get scaled down.
        var peakProtection: Double = 4.5

        /// After this many touches, an event's impact is frozen.
        var maxRebalances: Int = 5

        /// How wide a window the rebalance considers (days). 7 = past week.
        var windowDays: Int = 7

        static let `default` = Params()
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
            if file.rawImpact >= params.peakProtection {
                bucketed.append(.init(url: url, file: file, kind: .protected))
                protectedCount += 1
                continue
            }
            if file.rebalanceCount >= params.maxRebalances {
                bucketed.append(.init(url: url, file: file, kind: .frozen))
                frozenCount += 1
                continue
            }
            bucketed.append(.init(url: url, file: file, kind: .rebalancable))
            rebalancableRawSum += file.rawImpact
        }

        // Compute scale. Quiet week → 1.0 (no scaling).
        let scale: Double = (rebalancableRawSum > params.weeklyBudget && rebalancableRawSum > 0)
            ? params.weeklyBudget / rebalancableRawSum
            : 1.0

        var touched = 0
        for b in bucketed {
            switch b.kind {
            case .outside:
                plans.append(.init(url: b.url,
                                   oldImpact: b.file.impact,
                                   newImpact: b.file.impact,
                                   kind: .outsideWindow))
            case .protected:
                // Force final = raw in case a prior pass had scaled it.
                let target = b.file.rawImpact
                let needsWrite = abs(b.file.impact - target) > 0.0001
                plans.append(.init(url: b.url,
                                   oldImpact: b.file.impact,
                                   newImpact: needsWrite ? target : b.file.impact,
                                   kind: .protected))
            case .frozen:
                plans.append(.init(url: b.url,
                                   oldImpact: b.file.impact,
                                   newImpact: b.file.impact,
                                   kind: .frozen))
            case .rebalancable:
                let newImpact = b.file.rawImpact * scale
                let kind: Plan.Kind = (scale < 1.0) ? .rebalanced : .restored
                plans.append(.init(url: b.url,
                                   oldImpact: b.file.impact,
                                   newImpact: newImpact,
                                   kind: kind))
                touched += 1
            }
        }

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
        case .rebalanced, .restored:
            file.impact = plan.newImpact
            file.rebalanceCount += 1
        }
    }
}

// MARK: - Disk orchestration

/// Scan events on disk, rebalance the week, write changes back, recompute
/// weights, and append a journal entry. Returns a one-line status string
/// suitable for the UI.
func MemoryBudget_applyToDisk(
    params: MemoryBudget.Params = .default,
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
    lines.append("\n## Weekly memory budget (\(timeFmt.string(from: now)))")
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
