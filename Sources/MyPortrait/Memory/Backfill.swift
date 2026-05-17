import Foundation

/// Orchestrates the MVP memory pipeline against existing screenpipe data:
///   1. Read raw frames from `~/.screenpipe/db.sqlite` for the last N days
///   2. Convert to Tier1Merger events, merge into sessions
///   3. Heuristically classify each session into a portrait category
///   4. Write one .md file per session under `~/.portrait/portrait/<cat>/...`
///   5. Run WeightCalculator across the tree
///   6. Run Archiver (will be a no-op for fresh data — useful smoke test)
///
/// Designed to be idempotent-ish: re-running picks up new frames since the
/// last run via the `source: "screenpipe_frame_<id>"` field to avoid
/// re-writing files we already produced.
enum Backfill {
    struct Result {
        let daysScanned: Int
        let rawFrameCount: Int
        let mergedSessionCount: Int
        let writtenFileCount: Int
        let skippedExisting: Int
        let archiverResult: Archiver.Result
    }

    /// Default: last 14 days (the user mentioned their screenpipe data covers ~2 weeks).
    static func run(daysBack: Int = 14) throws -> Result {
        try PortraitPaths.ensureSeedTree()

        let db = ScreenpipeDB()
        guard db.exists else {
            throw NSError(
                domain: "Backfill", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "screenpipe DB not found at \(db.dbPath)"]
            )
        }

        // 1. Collect frames across N days, day by day (avoids one giant query).
        let cal = Calendar(identifier: .gregorian)
        var rawEvents: [Tier1Merger.RawEvent] = []
        let today = cal.startOfDay(for: Date())
        for offset in 0..<daysBack {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let frames = db.frames(on: day, limit: 5000)
            for f in frames {
                rawEvents.append(.init(
                    timestamp: f.timestamp,
                    appName: f.appName,
                    windowName: f.windowName,
                    browserURL: f.browserUrl,
                    frameId: f.id
                ))
            }
        }

        // 2. Tier 1 merge.
        let sessions = Tier1Merger.merge(rawEvents)

        // 3 + 4. Write per session.
        var written = 0
        var skipped = 0
        let existingSources = try existingSourceTags()

        for session in sessions {
            // Synthesise a stable source key so re-runs don't duplicate.
            let firstId = session.sourceFrameIds.first ?? 0
            let lastId = session.sourceFrameIds.last ?? 0
            let sourceKey = "screenpipe:\(firstId)-\(lastId)"
            if existingSources.contains(sourceKey) {
                skipped += 1
                continue
            }

            let category = classify(appName: session.appName, url: session.browserURL)
            let filename = makeFilename(for: session)
            let dest = PortraitPaths.categoryDir(category).appendingPathComponent(filename)

            // Avoid clobbering if filename collides with an existing file
            // for a different source — append the firstId.
            let finalDest: URL
            if FileManager.default.fileExists(atPath: dest.path) {
                finalDest = PortraitPaths.categoryDir(category)
                    .appendingPathComponent(makeFilename(for: session, suffix: "_\(firstId)"))
            } else {
                finalDest = dest
            }

            let body = renderBody(for: session)
            let impact = baselineImpact(for: session)
            var file = PortraitFile(
                created: session.firstSeen,
                impact: impact,
                body: body,
                source: sourceKey,
                tags: tags(for: session, category: category),
                firstOccurrence: session.firstSeen
            )
            // Backfill: the session's other timestamps are real "occurrences",
            // so preload them (Tier 1's job, executed retroactively).
            file.occurrences = session.occurrences

            try PortraitFileIO.write(file, to: finalDest)
            written += 1
        }

        // 5. Weight pass over the whole tree.
        try weightPass()

        // 6. Archiver pass (likely 0 archives on fresh data — sanity check).
        let archiveResult = try Archiver.run()

        return Result(
            daysScanned: daysBack,
            rawFrameCount: rawEvents.count,
            mergedSessionCount: sessions.count,
            writtenFileCount: written,
            skippedExisting: skipped,
            archiverResult: archiveResult
        )
    }

    // MARK: - Classification (crude rule-based, MVP only)

    private static func classify(appName: String, url: String?) -> String {
        let lower = appName.lowercased()
        // Code editors / dev tools → skills (programming sub-tree later)
        if ["xcode", "cursor", "visual studio code", "code", "terminal",
            "iterm", "iterm2", "myportrait"].contains(lower) {
            return "skills"
        }
        // Communication → social
        if ["messages", "imessage", "slack", "discord", "zoom", "wechat",
            "telegram", "wework"].contains(lower) {
            return "social"
        }
        // Browser / media / reading → interests
        if ["safari", "chrome", "firefox", "arc", "edge",
            "spotify", "music", "youtube", "bilibili"].contains(lower) {
            return "interests"
        }
        // Notes / writing → habits (could be split later)
        if ["obsidian", "notes", "notion", "bear", "craft"].contains(lower) {
            return "habits"
        }
        // Default bucket.
        return "habits"
    }

    private static func tags(for session: Tier1Merger.MergedEvent, category: String) -> [String] {
        var t = [session.appName]
        if let u = session.browserURL, !u.isEmpty,
           let host = URL(string: u)?.host {
            t.append(host)
        }
        t.append(category)
        return t
    }

    /// Cheap impact baseline for backfill — proportional to session length
    /// capped at 5. The LLM-driven emotion Agent will refine this later.
    private static func baselineImpact(for s: Tier1Merger.MergedEvent) -> Double {
        let dur = s.lastSeen.timeIntervalSince(s.firstSeen)
        let minutes = dur / 60
        // <1min → 1, 1-5 → 2, 5-30 → 3, 30-120 → 4, >120 → 5
        switch minutes {
        case ..<1:    return 1
        case ..<5:    return 2
        case ..<30:   return 3
        case ..<120:  return 4
        default:      return 5
        }
    }

    private static func renderBody(for s: Tier1Merger.MergedEvent) -> String {
        var lines: [String] = []
        let title = s.windowName.isEmpty ? s.appName : "\(s.appName) — \(s.windowName)"
        lines.append("# \(title)")
        lines.append("")
        let durationMin = max(1, Int(s.lastSeen.timeIntervalSince(s.firstSeen) / 60))
        lines.append("- App: **\(s.appName)**")
        if !s.windowName.isEmpty { lines.append("- Window: \(s.windowName)") }
        if let u = s.browserURL, !u.isEmpty { lines.append("- URL: \(u)") }
        lines.append("- Duration: \(durationMin) min")
        lines.append("- Occurrences: \(s.occurrences.count)")
        lines.append("")
        lines.append("_(Backfilled from screenpipe — Agent-generated summary will replace this body.)_")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func makeFilename(for s: Tier1Merger.MergedEvent, suffix: String = "") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: s.firstSeen)
        let appSlug = slug(s.appName)
        return "\(stamp)_\(appSlug)\(suffix).md"
    }

    private static func slug(_ s: String) -> String {
        let lower = s.lowercased()
        let kept = lower.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber { return c }
            return "_"
        }
        return String(kept).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - Source dedup

    /// Walk the portrait tree once and collect every existing file's `source`
    /// field so we can skip re-writing them on subsequent backfill runs.
    private static func existingSourceTags() throws -> Set<String> {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if let f = try? PortraitFileIO.read(from: url), let s = f.source {
                out.insert(s)
            }
        }
        return out
    }

    // MARK: - Weight pass

    /// Recompute weights for every file in the tree.
    private static func weightPass() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                WeightCalculator.recompute(&f)
                try PortraitFileIO.write(f, to: url)
            } catch {
                // skip malformed
                continue
            }
        }
    }
}
