import Foundation

/// Event-level backfill from existing screenpipe data.
///
/// Per-day loop:
///   1. Read frames for this day from the imported snapshot at
///      `~/.portrait/imported/screenpipe/db.sqlite` (resolved by `ScreenpipeDB`).
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

    struct Progress {
        let dayIndex: Int          // 1-based current day in the loop
        let dayCount: Int
        let day: Date              // which day is being processed
        let phase: String          // e.g. "LLM grouping", "writing files"
    }

    /// Default: last 14 days. Idempotent + resumable — days whose
    /// `events/<yyyy-MM-dd>/` directory already exists with files are
    /// skipped (assumption: previous run finished that day).
    static func run(
        daysBack: Int = 14,
        activeWindowDays: Int = 14,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> Result {
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
        let dayCount = daysBack
        var dayIndex = 0
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            dayIndex += 1
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }

            // Resumability: if events/<yyyy-MM-dd>/ already has files, skip
            // — assume the day was processed in a prior run. Users can
            // `rm -rf ~/.portrait/events/<day>` to force re-processing.
            let dayDir = PortraitPaths.eventsDayDir(for: day)
            if let existing = try? FileManager.default.contentsOfDirectory(atPath: dayDir.path),
               existing.contains(where: { $0.hasSuffix(".md") }) {
                progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "skipped (already processed)"))
                continue
            }

            progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "reading frames"))
            let frames = db.frames(on: day, limit: 5000)
            totals.rawFrameCount += frames.count
            if frames.isEmpty {
                progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "no frames"))
                continue
            }

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
            // semantic content. The previous filter (OCR short AND window
            // empty AND short duration) let long-running idle sessions
            // through; now we just check OCR substance. No OCR = nothing
            // for the LLM to summarise = no real event worth recording.
            let minOcrChars = 60
            // Up from 800 → 2000 so the LLM has real material to write
            // a meaningful summary from.
            let maxOcrChars = 2000
            var enriched: [EventBuilder.EnrichedSession] = []
            for s in sessions {
                let ocr = db.ocrText(forFrameIds: s.sourceFrameIds, maxChars: maxOcrChars)
                if ocr.count < minOcrChars {
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
                return EventBuilder.ActiveEvent(
                    id: entry.relativePath,
                    title: entry.file.eventTitle,
                    summary: entry.file.eventSummary,
                    type: entry.file.eventType.isEmpty ? "experience" : entry.file.eventType,
                    tags: entry.file.tags,
                    lastOccurredOn: last
                )
            }

            // Ask LLM for assignments.
            progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "LLM grouping \(enriched.count) sessions"))
            let assignments: [EventBuilder.Assignment]
            do {
                assignments = try await builder.assignDay(
                    date: day,
                    sessions: enriched,
                    activeEvents: active
                )
            } catch {
                totals.llmFailedDays += 1
                progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "LLM failed: \(error.localizedDescription)"))
                continue
            }

            // Index OCR length per session for impact baseline.
            var ocrLenByFrameId: [Int64: Int] = [:]
            for e in enriched {
                let key = e.session.sourceFrameIds.first ?? 0
                ocrLenByFrameId[key] = e.ocrSnippet.count
            }

            // Materialise.
            for a in assignments {
                let sessionFrameIds = a.session.sourceFrameIds
                switch a.decision {
                case .skip:
                    totals.emptySessionCount += 1
                    continue
                case .join(let eventId):
                    guard let entry = fileCache[eventId] else {
                        // LLM hallucinated an event id — fall back to NEW
                        // ONLY if there's enough OCR substance; otherwise skip.
                        let firstId = a.session.sourceFrameIds.first ?? 0
                        let ocrLen = ocrLenByFrameId[firstId] ?? 0
                        if ocrLen < 30 {
                            totals.emptySessionCount += 1
                            continue
                        }
                        try createNewEvent(
                            from: a,
                            session: a.session,
                            day: day,
                            ocrLen: ocrLen,
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
                    let firstId = a.session.sourceFrameIds.first ?? 0
                    let ocrLen = ocrLenByFrameId[firstId] ?? 0
                    try createNewEvent(
                        from: a,
                        session: a.session,
                        day: day,
                        ocrLen: ocrLen,
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
        ocrLen: Int,
        cache: inout [String: Entry],
        fallbackTitle: String? = nil
    ) throws {
        let title: String
        let summary: String
        let type: String
        let facets: [EventBuilder.PortraitFacet]
        let tags: [String]
        switch a.decision {
        case .new(let t, let s, let ty, let f, let tg):
            title = t.isEmpty ? (fallbackTitle ?? session.appName) : t
            summary = s
            type = ty
            facets = f
            tags = tg
        case .join, .skip:
            title = fallbackTitle ?? session.appName
            summary = ""
            type = "experience"
            facets = []
            tags = [session.appName.lowercased()]
        }

        let filename = makeFilename(title: title, day: day)
        // Events live under events/<yyyy-MM-dd>/ (NOT portrait/<cat>/).
        // Routing into portrait subdirs is now the Distiller's job, based on
        // event.type + event.portraitFacets.
        let url = PortraitPaths.eventsDayDir(for: day).appendingPathComponent(filename)
        let finalURL = uniqueURL(url)

        // `created` should be the moment the event FIRST happened (its first
        // session's first frame), not the time the file is written.
        var file = PortraitFile(
            created: session.firstSeen,
            impact: baselineImpact(for: session, ocrLen: ocrLen),
            body: renderBody(title: title, summary: summary, session: session),
            source: "screenpipe:event",
            tags: tags,
            firstOccurrence: day,
            eventTitle: title,
            eventSummary: summary,
            eventType: type,
            portraitFacets: facets,
            memberFrameIds: session.sourceFrameIds
        )
        // Ensure occurrence is truncated to day.
        file.occurrences = [PortraitFile.truncateToDay(day)]

        try PortraitFileIO.write(file, to: finalURL)

        let rel = finalURL.path
            .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
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

    /// Baseline impact = mostly OCR substance, lightly duration-modulated.
    /// LLM rescore will override this; the baseline just avoids ranking
    /// "long but empty" sessions above "short but content-rich" ones.
    private static func baselineImpact(for s: Tier1Merger.MergedEvent,
                                       ocrLen: Int) -> Double {
        let minutes = s.lastSeen.timeIntervalSince(s.firstSeen) / 60
        // Content score: 1 (almost nothing) → 5 (lots of OCR)
        let contentBase: Double
        switch ocrLen {
        case ..<50:    contentBase = 1
        case ..<200:   contentBase = 2
        case ..<500:   contentBase = 3
        case ..<1200:  contentBase = 4
        default:       contentBase = 5
        }
        // Long sessions with content nudge up slightly; long sessions
        // without content stay at the content score (no duration bonus).
        let durBoost: Double = (ocrLen >= 50 && minutes >= 30) ? 0.5 : 0
        return min(5, contentBase + durBoost)
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
            at: Storage.eventsDir,
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
                .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
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
        // Recompute weights for BOTH layers — events and portrait entries.
        for root in [Storage.eventsDir, Storage.portraitDir] {
            weightPassDir(root)
        }
    }

    nonisolated private static func weightPassDir(_ root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
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
