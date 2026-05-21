import Foundation

/// Programmatic archival per design doc §6.7. **No LLM involvement.**
///
/// A file is archived when ALL of:
///   - impact < 2
///   - weight < 0.05
///   - days_since_last_access ≥ 90
///   - path does NOT start with "skills/"
///   - not pinned
///
/// Archiving = moving the file from
///     <portrait>/<category>/<...>/file.md
/// to
///     <portrait>/<category>/_archive/<...>/file.md
/// preserving any sub-path inside the category. The file's
/// `archived_at` field is set to `now`.
///
/// Every archival action is appended to today's journal.
enum Archiver {
    struct Rule {
        var maxWeight: Double = 0.05       // strict-less-than（与 EMA currentWeight 比较）
        var minDaysSinceAccess: Int = 90   // greater-or-equal
        var protectedCategoryPrefixes: [String] = ["skills"]
        var weightHalfLifeDays: Double = 180   // Phase 3 EMA 半衰期

        static let `default` = Rule()

        @MainActor
        static var fromConfig: Rule {
            let m = ConfigStore.shared.current.memory
            return Rule(
                maxWeight: m.archiveMaxWeight,
                minDaysSinceAccess: m.archiveMinDaysIdle,
                weightHalfLifeDays: Double(m.weightHalfLifeDays)
            )
        }
    }

    struct Plan {
        let source: URL
        let destination: URL
        let reason: String
    }

    struct Result {
        let archivedCount: Int
        let skippedCount: Int
        let plans: [Plan]
    }

    /// Scan the portrait tree and execute archival for every file that
    /// matches `Rule`. Returns a summary.
    @discardableResult
    static func run(rule: Rule = .default, now: Date = Date()) throws -> Result {
        try PortraitPaths.ensureSeedTree()

        var plans: [Plan] = []
        var skipped = 0

        let portraitRoot = Storage.portraitDir
        let fm = FileManager.default

        // Walk every .md file under portraitDir EXCEPT INDEX.md and anything
        // already inside an _archive/ subtree.
        guard let enumerator = fm.enumerator(
            at: portraitRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Result(archivedCount: 0, skippedCount: 0, plans: [])
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            // Skip files already in an _archive/ subtree.
            if url.pathComponents.contains("_archive") { continue }

            // Decide if this file qualifies.
            let file: PortraitFile
            do {
                file = try PortraitFileIO.read(from: url)
            } catch {
                // Malformed file → skip, don't crash the whole run.
                skipped += 1
                continue
            }

            // Already archived → skip.
            if file.archivedAt != nil { skipped += 1; continue }
            if file.pinned { skipped += 1; continue }

            // Check protected category prefix (relative path under portrait/).
            let relativePath = url.path.replacingOccurrences(of: portraitRoot.path + "/", with: "")
            if rule.protectedCategoryPrefixes.contains(where: { relativePath.hasPrefix($0 + "/") }) {
                skipped += 1; continue
            }

            // Rule check —— portrait 不再持有 impact（event-only），归档判定
            // 只看 weight（EMA 衰减后）+ days_idle + pin + protected-category。
            let days = file.daysSinceLastOccurrence(now: now)
            let curWeight = WeightEMA(halfLifeDays: rule.weightHalfLifeDays)
                .currentWeight(stored: file.weight,
                               daysSinceModified: file.daysSinceModified(now: now))
            let qualifies = curWeight < rule.maxWeight
                && days >= rule.minDaysSinceAccess

            if !qualifies { skipped += 1; continue }

            // Build destination: insert "_archive" right after the category.
            // e.g. habits/social/foo.md -> habits/_archive/social/foo.md
            let components = relativePath.split(separator: "/").map(String.init)
            guard let category = components.first else { continue }
            let tail = components.dropFirst().joined(separator: "/")
            let destRel = "\(category)/_archive/\(tail)"
            let destURL = portraitRoot.appendingPathComponent(destRel)

            let reason = "weight=\(formatted(curWeight)) days_idle=\(days)"
            plans.append(Plan(source: url, destination: destURL, reason: reason))
        }

        // Execute: stamp archived_at, write back, then move.
        for plan in plans {
            var file = try PortraitFileIO.read(from: plan.source)
            file.archivedAt = now
            try PortraitFileIO.write(file, to: plan.source)
            try fm.createDirectory(
                at: plan.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: plan.source, to: plan.destination)
        }

        try writeJournal(plans: plans, now: now)
        return Result(archivedCount: plans.count, skippedCount: skipped, plans: plans)
    }

    // MARK: - Journal append

    private static func writeJournal(plans: [Plan], now: Date) throws {
        guard !plans.isEmpty else { return }
        let url = PortraitPaths.todayJournalURL
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let header = "\n## Archive 归档 (\(plans.count), 程序触发, \(formatTime(now)))\n"
        var lines = [header]
        for p in plans {
            let rel = p.source.path.replacingOccurrences(of: Storage.portraitDir.path + "/", with: "")
            lines.append("- \(rel) → _archive/  (\(p.reason))")
        }
        let chunk = lines.joined(separator: "\n") + "\n"

        // Create the file with a top-level heading if it doesn't exist.
        if !fm.fileExists(atPath: url.path) {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            day.timeZone = TimeZone(identifier: "UTC")
            let head = "# 记忆维护日志 \(day.string(from: now))\n"
            try head.write(to: url, atomically: true, encoding: .utf8)
        }

        // Append.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = chunk.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private static func formatted(_ d: Double) -> String {
        if d.rounded() == d { return String(format: "%g", d) }
        return String(format: "%.3g", d)
    }

    nonisolated(unsafe) private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func formatTime(_ d: Date) -> String { timeFmt.string(from: d) }
}
