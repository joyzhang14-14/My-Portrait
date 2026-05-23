import Foundation

/// Event-level backfill from captured timeline data.
///
/// Per-day loop:
///   1. Read frames for this day from `~/.portrait/portrait.sqlite`
///      (resolved by `TimelineDB`).
///   2. Tier 1 merge (app+window+5min, rule-based) → coarse sessions.
///   3. Enrich each session with OCR; drop sessions with < 60 chars of OCR.
///   4. EventBuilder (LLM, per-event clustering): one `DayClustering` with a
///      list of events (each owning ≥1 session) plus a `skipped` list.
///   5. Materialise:
///      - join_existing → load the existing PortraitFile, +1 occurrence,
///        append frame ids. Title / summary / facets are NOT changed.
///      - new event     → create a fresh PortraitFile from the LLM's
///        title + summary + type + facets.
///   6. After all days: WeightCalculator pass + Archiver.
///
/// Coverage is enforced inside EventBuilder — if the LLM leaves a session
/// uncovered the whole day throws and nothing is written for it. There is no
/// empty-shell fallback anymore.
@MainActor
enum Backfill {
    struct Result {
        let daysScanned: Int
        let rawFrameCount: Int
        let tier1SessionCount: Int
        let emptySessionCount: Int   // dropped (no OCR) or LLM-skipped
        let llmFailedDays: Int
        let newEventCount: Int
        let joinedSessionCount: Int
        let skippedSessionCount: Int
    }

    struct Progress {
        let dayIndex: Int          // 1-based current day in the loop
        let dayCount: Int
        let day: Date              // which day is being processed
        let phase: String
    }

    /// Default: last 14 days. Idempotent + resumable — days whose
    /// `events/<yyyy-MM-dd>/` directory already has files are skipped.
    ///
    /// `onlyDay` (non-nil) restricts the run to that single calendar day —
    /// used by the `--backfill-day` dev entry point.
    static func run(
        daysBack: Int = 14,
        activeWindowDays: Int = 14,
        onlyDay: Date? = nil,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> Result {
        try PortraitPaths.ensureSeedTree()

        let db = TimelineDB()
        guard db.exists else {
            throw NSError(
                domain: "Backfill", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timeline DB not found at \(db.dbPath)"]
            )
        }

        var totals = Counters()
        // UTC —— 跟 pendingDays / isRawReady / events/<date>/ 目录命名一致。
        // 本地日历会把 pendingDays 传来的 UTC 午夜 day 错位到相邻日。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let today = cal.startOfDay(for: Date())
        let onlyDayStart = onlyDay.map { cal.startOfDay(for: $0) }

        // Pre-load existing files once; we mutate this cache as the day-loop
        // creates / appends to events.
        var fileCache = try await loadAllFiles()
        let builder = EventBuilder()

        // Iterate oldest → newest so EventBuilder always has the most
        // relevant active events from prior days available.
        let dayCount = daysBack
        var dayIndex = 0
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            dayIndex += 1
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }

            // Single-day restriction.
            if let target = onlyDayStart, cal.startOfDay(for: day) != target { continue }

            // Resumability: events/<yyyy-MM-dd>/ already populated → skip.
            // Force a re-run with `rm -rf ~/.portrait/events/<day>`.
            let dayDir = PortraitPaths.eventsDayDir(for: day)
            if let existing = try? FileManager.default.contentsOfDirectory(atPath: dayDir.path),
               existing.contains(where: { $0.hasSuffix(".md") }) {
                progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "skipped (already processed)"))
                print("Day \(isoDay(day)): skipped — events/ already populated")
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

            // Enrich + drop OCR-poor sessions (no OCR → nothing to summarise).
            let minOcrChars = 60
            let maxOcrChars = 2000
            var enriched: [EventBuilder.EnrichedSession] = []
            for s in sessions {
                let ocr = db.ocrText(forFrameIds: s.sourceFrameIds, maxChars: maxOcrChars)
                if ocr.count < minOcrChars {
                    totals.emptySessionCount += 1
                    continue
                }
                enriched.append(EventBuilder.EnrichedSession(
                    session: s, ocrSnippet: ocr, transcriptSnippet: ""
                ))
            }
            let dropped = sessions.count - enriched.count
            print("Day \(isoDay(day)): \(sessions.count) sessions, \(enriched.count) enriched (OCR ≥ 60), \(dropped) dropped")
            if enriched.isEmpty { continue }

            // Active-events catalogue from the in-memory cache.
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

            // LLM per-event clustering.
            progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "LLM clustering \(enriched.count) sessions"))
            let clustering: EventBuilder.DayClustering
            do {
                clustering = try await builder.clusterDay(
                    date: day, sessions: enriched, activeEvents: active
                )
            } catch let e as BudgetExhaustedError {
                // 撞额度不是"失败"——上抛让调度器标 budget_deferred 而非 failed，
                // 不计入 retry_count。整个 Backfill 中止。
                throw e
            } catch {
                totals.llmFailedDays += 1
                print("Day \(isoDay(day)): LLM clustering FAILED — \(error.localizedDescription) — nothing written")
                progress?(.init(dayIndex: dayIndex, dayCount: dayCount, day: day, phase: "LLM failed: \(error.localizedDescription)"))
                continue
            }

            // Materialise. `sessionIndices` are 1-based into `enriched`.
            for ev in clustering.events {
                let members = ev.sessionIndices.compactMap { idx -> EventBuilder.EnrichedSession? in
                    let i = idx - 1
                    guard i >= 0, i < enriched.count else { return nil }
                    return enriched[i]
                }
                if members.isEmpty { continue }
                let frameIds = members.flatMap { $0.session.sourceFrameIds }

                if let je = ev.joinExisting, let entry = fileCache[je] {
                    // Re-run safety: frames already accounted for.
                    if !frameIds.isEmpty,
                       entry.file.memberFrameIds.contains(where: frameIds.contains) {
                        totals.skippedSessionCount += 1
                        continue
                    }
                    // Cross-day join: +1 occurrence, append frames. Title /
                    // summary / facets stay frozen at first creation.
                    var updated = entry.file
                    updated.recordOccurrence(on: day)
                    updated.memberFrameIds.append(contentsOf: frameIds)
                    // 事件又活了 → 清空 distilledInto,让下次 distill 重新看到
                    // 它(增量 distill 的"改过"通道)。
                    updated.distilledInto = []
                    try PortraitFileIO.write(updated, to: entry.url)
                    fileCache[je] = .init(url: entry.url,
                                          relativePath: entry.relativePath,
                                          file: updated)
                    totals.joinedSessionCount += 1
                } else {
                    try createNewEvent(cluster: ev, members: members,
                                       day: day, cache: &fileCache)
                    totals.newEventCount += 1
                }
            }
            totals.skippedSessionCount += clustering.skippedIndices.count
        }

        // Weight pass across the events tree.
        try await weightPass()

        // 归档不在这里跑 —— 它动的是 portrait/ 文件，挪到了
        // PortraitDistiller.distill 之后。

        return Result(
            daysScanned: daysBack,
            rawFrameCount: totals.rawFrameCount,
            tier1SessionCount: totals.tier1SessionCount,
            emptySessionCount: totals.emptySessionCount,
            llmFailedDays: totals.llmFailedDays,
            newEventCount: totals.newEventCount,
            joinedSessionCount: totals.joinedSessionCount,
            skippedSessionCount: totals.skippedSessionCount
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

    /// Build and write a new PortraitFile from a clustered event.
    private static func createNewEvent(
        cluster: EventBuilder.ClusteredEvent,
        members: [EventBuilder.EnrichedSession],
        day: Date,
        cache: inout [String: Entry]
    ) throws {
        let frameIds = members.flatMap { $0.session.sourceFrameIds }

        let filename = makeFilename(title: cluster.title, day: day)
        // Events live under events/<yyyy-MM-dd>/. Routing into portrait
        // subdirs is the Distiller's job, based on type + portraitFacets.
        let url = PortraitPaths.eventsDayDir(for: day).appendingPathComponent(filename)
        let finalURL = uniqueURL(url)

        // `created` = the event's day (UTC startOfDay), aligned with
        // `occurrences`. Using a raw session timestamp instead can land on
        // the next calendar day (UTC) and make created > last occurrence.
        //
        // No placeholder impact — a new event is `unscored` until the LLM
        // (ImpactScorer) gives it a real score. impact starts at the 1.0
        // floor so an unscored event never outranks a scored one.
        var file = PortraitFile(
            created: PortraitFile.truncateToDay(day),
            impact: 1.0,
            body: renderBody(title: cluster.title, summary: cluster.summary),
            source: "timeline:event",
            tags: cluster.tags,
            firstOccurrence: day,
            eventTitle: cluster.title,
            eventSummary: cluster.summary,
            eventType: cluster.type,
            portraitFacets: cluster.portraitFacets,
            memberFrameIds: frameIds
        )
        file.occurrences = [PortraitFile.truncateToDay(day)]
        file.impactSource = "unscored"

        try PortraitFileIO.write(file, to: finalURL)
        let rel = finalURL.path
            .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
        cache[rel] = Entry(url: finalURL, relativePath: rel, file: file)
    }

    // MARK: - Title/file helpers

    private static func makeFilename(title: String, day: Date) -> String {
        let stamp = isoDay(day)
        let slug = slugify(title)
        return "\(stamp)_\(slug).md"
    }

    private static func isoDay(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: day)
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

    private static func renderBody(title: String, summary: String) -> String {
        "# \(title)\n\n\(summary)\n"
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
            if url.pathComponents.contains("_quarantine") { continue }
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
        // 只对 events/ 跑 WeightCalculator —— portrait 不再走 event 的
        // impact×decay 公式。portrait 的 weight 由 P5 EMA 写入路径管理；
        // P5 接入前 portrait weight 保持 P3 迁移后的 1.0 不被覆盖。
        weightPassDir(Storage.eventsDir)
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
            if url.pathComponents.contains("_quarantine") { continue }
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
