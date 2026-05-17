import Foundation

/// Event-level backfill from existing screenpipe data.
///
/// Per-day loop:
///   1. Read frames for this day from `~/.screenpipe/db.sqlite`
///   2. Tier 1 merge (app+window+5min, rule-based) → coarse sessions
///   3. Enrich each session with OCR text from its member frames
///   4. EventBuilder (LLM, one call per day): for each session, decide
///      JOIN existing event or create NEW event
///   5. Materialise:
///      - JOIN  → load existing PortraitFile, append today's date to
///                occurrences (deduped per day), append frame ids
///      - NEW   → create a fresh PortraitFile with title + summary +
///                category from the LLM, today as first occurrence
///   6. After all days processed: WeightCalculator pass + Archiver
///
/// Notes:
///   - "Active events" passed to EventBuilder are PortraitFiles whose
///     last occurrence is within the last `activeWindowDays` (default 14).
///   - Re-runs are safe: if a session's frames already appear in an
///     existing file's `memberFrameIds`, it's skipped.
@MainActor
enum Backfill {
    struct Result {
        let daysScanned: Int
        let rawFrameCount: Int
        let tier1SessionCount: Int
        let emptySessionCount: Int   // dropped before reaching LLM
        let llmFailedDays: Int
        let newEventCount: Int
        let joinedSessionCount: Int
        let skippedSessionCount: Int
        let archiverResult: Archiver.Result
    }

    /// Default: last 14 days.
    static func run(daysBack: Int = 14, activeWindowDays: Int = 14) async throws -> Result {
        try PortraitPaths.ensureSeedTree()

        let db = ScreenpipeDB()
        guard db.exists else {
            throw NSError(
                domain: "Backfill", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "screenpipe DB not found at \(db.dbPath)"]
            )
        }

        var totals = Counters()
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())

        // Pre-load existing files once; we'll mutate the in-memory cache as
        // the day-loop creates / appends to events.
        var fileCache = try await loadAllFiles()
        let builder = EventBuilder()

        // Iterate from oldest day to newest so EventBuilder always has the
        // most relevant active events from prior days available.
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let frames = db.frames(on: day, limit: 5000)
            totals.rawFrameCount += frames.count
            if frames.isEmpty { continue }

            // Tier 1 merge.
            let rawEvents = frames.map { f in
                Tier1Merger.RawEvent(
                    timestamp: f.timestamp,
                    appName: f.appName,
                    windowName: f.windowName,
                    browserURL: f.browserUrl,
                    frameId: f.id
                )
            }
            let sessions = Tier1Merger.merge(rawEvents)
            totals.tier1SessionCount += sessions.count
            if sessions.isEmpty { continue }

            // Enrich each session with OCR text + drop the ones with no
            // semantic content (per user feedback: "如果什么内容都没有就别记
            // 了"). A session is "empty" when:
            //   - OCR text is shorter than `minOcrChars`, AND
            //   - window_name is empty (no app-side hint either), AND
            //   - duration is short (< 5 min — long sessions might still be
            //     worth noting even without OCR e.g. video playback)
            // Skipped sessions are counted but never reach the LLM.
            let minOcrChars = 30
            var enriched: [EventBuilder.EnrichedSession] = []
            for s in sessions {
                let ocr = db.ocrText(forFrameIds: s.sourceFrameIds, maxChars: 800)
                let durSec = s.lastSeen.timeIntervalSince(s.firstSeen)
                let meaningless = ocr.count < minOcrChars
                    && s.windowName.trimmingCharacters(in: .whitespaces).isEmpty
                    && durSec < 5 * 60
                if meaningless {
                    totals.emptySessionCount += 1
                    continue
                }
                enriched.append(EventBuilder.EnrichedSession(
                    session: s,
                    ocrSnippet: ocr,
                    transcriptSnippet: ""
                ))
            }
            if enriched.isEmpty { continue }

            // Build the active-events catalogue from the in-memory cache.
            let activeCutoff = cal.date(byAdding: .day, value: -activeWindowDays, to: day) ?? day
            let active: [EventBuilder.ActiveEvent] = fileCache.values.compactMap { entry in
                guard !entry.file.eventTitle.isEmpty,
                      let last = entry.file.occurrences.max(),
                      last >= activeCutoff else { return nil }
                let categoryPath = entry.relativePath
                    .split(separator: "/").first.map(String.init) ?? "habits"
                return EventBuilder.ActiveEvent(
                    id: entry.relativePath,
                    title: entry.file.eventTitle,
                    summary: entry.file.eventSummary,
                    category: categoryPath,
                    lastOccurredOn: last
                )
            }

            // Ask LLM for assignments.
            let assignments: [EventBuilder.Assignment]
            do {
                assignments = try await builder.assignDay(
                    date: day,
                    sessions: enriched,
                    activeEvents: active
                )
            } catch {
                totals.llmFailedDays += 1
                continue
            }

            // Materialise.
            for a in assignments {
                let sessionFrameIds = a.session.sourceFrameIds
                switch a.decision {
                case .join(let eventId):
                    guard let entry = fileCache[eventId] else {
                        // LLM hallucinated an event id — fall back to NEW with
                        // a best-effort placeholder title.
                        try createNewEvent(
                            from: a,
                            session: a.session,
                            day: day,
                            cache: &fileCache,
                            fallbackTitle: "\(a.session.appName) — \(a.session.windowName)"
                        )
                        totals.newEventCount += 1
                        continue
                    }
                    // Skip if frames already accounted for (re-run safety).
                    if !sessionFrameIds.isEmpty,
                       entry.file.memberFrameIds.contains(where: sessionFrameIds.contains) {
                        totals.skippedSessionCount += 1
                        continue
                    }
                    var updated = entry.file
                    updated.recordOccurrence(on: day)
                    updated.memberFrameIds.append(contentsOf: sessionFrameIds)
                    try PortraitFileIO.write(updated, to: entry.url)
                    fileCache[eventId] = .init(url: entry.url,
                                               relativePath: entry.relativePath,
                                               file: updated)
                    totals.joinedSessionCount += 1
                case .new:
                    try createNewEvent(
                        from: a,
                        session: a.session,
                        day: day,
                        cache: &fileCache
                    )
                    totals.newEventCount += 1
                }
            }
        }

        // Weight pass across the whole tree.
        try await weightPass()

        // Archiver pass.
        let archiveResult = try Archiver.run()

        return Result(
            daysScanned: daysBack,
            rawFrameCount: totals.rawFrameCount,
            tier1SessionCount: totals.tier1SessionCount,
            emptySessionCount: totals.emptySessionCount,
            llmFailedDays: totals.llmFailedDays,
            newEventCount: totals.newEventCount,
            joinedSessionCount: totals.joinedSessionCount,
            skippedSessionCount: totals.skippedSessionCount,
            archiverResult: archiveResult
        )
    }

    // MARK: - File materialisation

    private struct Entry {
        let url: URL
        let relativePath: String
        var file: PortraitFile
    }

    private struct Counters {
        var rawFrameCount = 0
        var tier1SessionCount = 0
        var emptySessionCount = 0
        var llmFailedDays = 0
        var newEventCount = 0
        var joinedSessionCount = 0
        var skippedSessionCount = 0
    }

    /// Build and write a new PortraitFile from a NEW assignment.
    private static func createNewEvent(
        from a: EventBuilder.Assignment,
        session: Tier1Merger.MergedEvent,
        day: Date,
        cache: inout [String: Entry],
        fallbackTitle: String? = nil
    ) throws {
        let (title, summary, category, tags): (String, String, String, [String])
        switch a.decision {
        case .new(let t, let s, let c, let tg):
            title = t.isEmpty ? (fallbackTitle ?? session.appName) : t
            summary = s
            category = c
            tags = tg
        case .join:
            title = fallbackTitle ?? session.appName
            summary = ""
            category = "habits"
            tags = [session.appName.lowercased()]
        }

        let safeCategory = PortraitPaths.seedCategories.contains(category)
            ? category : "habits"
        let filename = makeFilename(title: title, day: day)
        let url = PortraitPaths.categoryDir(safeCategory).appendingPathComponent(filename)
        let finalURL = uniqueURL(url)

        var file = PortraitFile(
            created: session.firstSeen,
            impact: baselineImpact(for: session),
            body: renderBody(title: title, summary: summary, session: session),
            source: "screenpipe:event",
            tags: tags,
            firstOccurrence: day,
            eventTitle: title,
            eventSummary: summary,
            memberFrameIds: session.sourceFrameIds
        )
        // Ensure occurrence is truncated to day.
        file.occurrences = [PortraitFile.truncateToDay(day)]

        try PortraitFileIO.write(file, to: finalURL)

        let rel = finalURL.path
            .replacingOccurrences(of: Storage.portraitDir.path + "/", with: "")
        cache[rel] = Entry(url: finalURL, relativePath: rel, file: file)
    }

    // MARK: - Title/file helpers

    private static func makeFilename(title: String, day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: day)
        let slug = slugify(title)
        return "\(stamp)_\(slug).md"
    }

    private static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var lastWasSep = false
        for scalar in lower.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasSep = false
            } else if !lastWasSep {
                out.append("_")
                lastWasSep = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        // Cap filename slug length to keep paths sane.
        if trimmed.count > 60 { return String(trimmed.prefix(60)) }
        return trimmed.isEmpty ? "event" : trimmed
    }

    private static func uniqueURL(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...100 {
            let candidate = dir.appendingPathComponent("\(base)_\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url    // give up; will overwrite
    }

    private static func renderBody(title: String, summary: String, session: Tier1Merger.MergedEvent) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        if !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        let durMin = max(1, Int(session.lastSeen.timeIntervalSince(session.firstSeen) / 60))
        lines.append("- First app: **\(session.appName)**")
        if !session.windowName.isEmpty { lines.append("- First window: \(session.windowName)") }
        if let u = session.browserURL, !u.isEmpty { lines.append("- URL: \(u)") }
        lines.append("- Initial session duration: \(durMin) min")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func baselineImpact(for s: Tier1Merger.MergedEvent) -> Double {
        let dur = s.lastSeen.timeIntervalSince(s.firstSeen)
        let minutes = dur / 60
        switch minutes {
        case ..<1:    return 1
        case ..<5:    return 2
        case ..<30:   return 3
        case ..<120:  return 4
        default:      return 5
        }
    }

    // MARK: - Tree I/O

    nonisolated private static func loadAllFiles() async -> [String: Entry] {
        await Task.detached(priority: .userInitiated) {
            scanAllFilesSync()
        }.value
    }

    nonisolated private static func scanAllFilesSync() -> [String: Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var out: [String: Entry] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            let rel = url.path
                .replacingOccurrences(of: Storage.portraitDir.path + "/", with: "")
            out[rel] = Entry(url: url, relativePath: rel, file: f)
        }
        return out
    }

    nonisolated private static func weightPass() async throws {
        await Task.detached(priority: .userInitiated) {
            weightPassSync()
        }.value
    }

    /// Sync helper — NSEnumerator iteration isn't usable from `async` bodies
    /// under Swift 6 strict concurrency, so isolate it here.
    nonisolated private static func weightPassSync() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                WeightCalculator.recompute(&f)
                try PortraitFileIO.write(f, to: url)
            } catch {
                continue
            }
        }
    }
}
