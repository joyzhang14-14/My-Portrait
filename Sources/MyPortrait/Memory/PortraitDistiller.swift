import Foundation

/// Distils event-layer files into portrait-layer entries.
///
/// Input:
///   - All non-archived events under ~/.portrait/events/<day>/*.md
///   - Existing portrait files under ~/.portrait/portrait/<cat>/*.md
///     (so the LLM can UPDATE an existing portrait entry instead of
///     duplicating it)
///
/// Output: writes / updates portrait files under
///         ~/.portrait/portrait/<category>/<slug>.md
///
/// Each portrait file represents a "fact about the user":
///   skills/swift_ui_development.md
///   habits/late_night_coding.md
///   interests/personal_ai_memory_research.md
///
/// MVP characteristics:
///   - Manual trigger from the Memories UI button
///   - One LLM call per category (9 calls per full run)
///   - LLM gets the events relevant to a category (by category field) +
///     the existing portrait files in that category
///   - LLM returns: list of {action: "create"|"update"|"noop",
///                            slug, title, body, derived_from_event_ids}
@MainActor
final class PortraitDistiller {
    struct Progress {
        let categoryIndex: Int
        let categoryCount: Int
        let category: String
        let written: Int
    }

    struct Result {
        let categoriesProcessed: Int
        let portraitFilesWritten: Int
        let portraitFilesUpdated: Int
        let llmFailedCategories: Int
        let elapsed: TimeInterval
    }

    enum DistillError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):     return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:          return "LLM did not respond within timeout"
            case .noJSONInResponse:      return "LLM response contained no JSON"
            case .malformedJSON(let m):  return "LLM JSON parse failed: \(m)"
            }
        }
    }

    private let model: String
    private let perCategoryTimeout: TimeInterval

    init(model: String = "gpt-5.4", perCategoryTimeout: TimeInterval = 120) {
        self.model = model
        self.perCategoryTimeout = perCategoryTimeout
    }

    /// Run a full distillation pass across all 9 categories.
    func distill(progress: ((Progress) -> Void)? = nil) async throws -> Result {
        try PortraitPaths.ensureSeedTree()
        let start = Date()

        // 1. Group events by category from disk.
        let eventsByCategory = await collectEventsByCategory()

        // 2. Snapshot existing portrait files (for UPDATE decisions).
        let portraitByCategory = await collectPortraitByCategory()

        let agent = try PiAgent(model: model)
        do { try await agent.start() }
        catch { throw DistillError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = DistillerCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        var written = 0
        var updated = 0
        var failed = 0
        let categories = PortraitPaths.seedCategories

        for (idx, category) in categories.enumerated() {
            let events = eventsByCategory[category] ?? []
            // Skip categories with no events AND no existing portraits.
            // Nothing to distill from.
            let existing = portraitByCategory[category] ?? []
            if events.isEmpty && existing.isEmpty {
                progress?(.init(categoryIndex: idx, categoryCount: categories.count, category: category, written: 0))
                continue
            }

            do {
                let decisions = try await runCategory(
                    category: category,
                    events: events,
                    existing: existing,
                    agent: agent,
                    coordinator: coordinator
                )
                for decision in decisions {
                    switch decision.action {
                    case "create":
                        try writeNewPortrait(category: category, decision: decision)
                        written += 1
                    case "update":
                        if try updateExistingPortrait(category: category, decision: decision) {
                            updated += 1
                        } else {
                            // Slug not found → treat as create.
                            try writeNewPortrait(category: category, decision: decision)
                            written += 1
                        }
                    default:
                        break    // "noop" — nothing to do
                    }
                }
            } catch let e as BudgetExhaustedError {
                // 撞额度：中止整轮 distill，调度器据此标 budget_deferred。
                // 已写入 / 更新的分类保留（update 幂等，下次重跑覆盖）。
                throw e
            } catch {
                failed += 1
            }

            progress?(.init(categoryIndex: idx + 1, categoryCount: categories.count, category: category, written: written))
        }

        return Result(
            categoriesProcessed: categories.count,
            portraitFilesWritten: written,
            portraitFilesUpdated: updated,
            llmFailedCategories: failed,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    // MARK: - One category round-trip

    private struct ParsedDecision {
        let action: String          // create | update | noop
        let slug: String            // file basename, no extension
        let title: String
        let body: String
        let derivedFromEventIds: [String]
    }

    private func runCategory(
        category: String,
        events: [EventEntry],
        existing: [PortraitEntry],
        agent: PiAgent,
        coordinator: DistillerCoordinator
    ) async throws -> [ParsedDecision] {
        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)

        let prompt = Self.buildPrompt(
            category: category,
            events: events,
            existing: existing
        )

        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw DistillError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perCategoryTimeout * 1_000_000_000))
                    throw DistillError.agentTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw DistillError.agentTimeout
        }

        // 撞额度优先于解析失败：抛 BudgetExhaustedError 让上层走 budget_deferred。
        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "PortraitDistiller", message: err)
        }

        return try Self.parseDecisions(from: collected)
    }

    // MARK: - Prompt

    nonisolated private static func buildPrompt(
        category: String,
        events: [EventEntry],
        existing: [PortraitEntry]
    ) -> String {
        var lines: [String] = []
        lines.append(MemoryPrompts.distillIntro)
        lines.append("Target portrait category: **\(category)**")
        lines.append("")
        lines.append("Definitions:")
        lines.append(MemoryPrompts.distillDefinition(for: category))
        lines.append("")

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"

        // Existing entries — FULL body (weighted merge needs the whole text,
        // not an excerpt) + last-updated date so the LLM can tell which source
        // events post-date the settled entry.
        if existing.isEmpty {
            lines.append("Existing portrait entries in this category: (none)")
        } else {
            lines.append("Existing portrait entries you may UPDATE — these are SETTLED knowledge (slug | title | last updated):")
            for p in existing {
                let full = p.body.count > 1200
                    ? String(p.body.prefix(1200)) + "…" : p.body
                lines.append("  - \(p.slug) | \(p.title) | last updated \(dayFmt.string(from: p.lastUpdated))")
                lines.append("    body: \(full.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("")

        // Source events — impact + weight + created date. `created` lets the
        // LLM judge which events are NEW relative to a settled entry.
        if events.isEmpty {
            lines.append("No new events tagged with this category were captured.")
        } else {
            lines.append("Source events (id | title | impact | weight | created | day-occurrences):")
            for e in events {
                let summary = e.summary.isEmpty ? "(no summary)" : e.summary
                let trim = summary.count > 180 ? String(summary.prefix(180)) + "…" : summary
                lines.append("  - [\(e.id)] \(e.title)  | impact=\(String(format: "%.1f", e.impact)), weight=\(String(format: "%.2f", e.weight)), created=\(dayFmt.string(from: e.created)), days=\(e.occurrenceDays)")
                lines.append("    summary: \(trim.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("")

        // Output spec.
        lines.append(MemoryPrompts.distillOutputSpec)
        return lines.joined(separator: "\n")
    }

    // MARK: - Response parsing

    nonisolated private static func parseDecisions(from response: String) throws -> [ParsedDecision] {
        guard let firstBracket = response.firstIndex(of: "["),
              let lastBracket = response.lastIndex(of: "]") else {
            throw DistillError.noJSONInResponse
        }
        let jsonStr = String(response[firstBracket...lastBracket])
        guard let data = jsonStr.data(using: .utf8) else {
            throw DistillError.malformedJSON("could not encode response as UTF-8")
        }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) }
        catch { throw DistillError.malformedJSON(error.localizedDescription) }
        guard let arr = obj as? [[String: Any]] else {
            throw DistillError.malformedJSON("top-level was not an array of objects")
        }

        var out: [ParsedDecision] = []
        for (idx, entry) in arr.enumerated() {
            let action = (entry["action"] as? String) ?? "noop"
            let slug = (entry["slug"] as? String) ?? ""
            let title = (entry["title"] as? String) ?? ""
            let body = (entry["body"] as? String) ?? ""
            let derived = (entry["derived_from"] as? [String]) ?? []
            guard !slug.isEmpty else {
                if action == "noop" {
                    out.append(ParsedDecision(action: "noop", slug: "", title: "", body: "", derivedFromEventIds: []))
                    continue
                }
                throw DistillError.malformedJSON("entry \(idx + 1) action=\(action) missing slug")
            }
            out.append(ParsedDecision(
                action: action,
                slug: slug,
                title: title,
                body: body,
                derivedFromEventIds: derived
            ))
        }
        return out
    }

    // MARK: - Disk writes

    private func writeNewPortrait(category: String, decision: ParsedDecision) throws {
        let dir = PortraitPaths.categoryDir(category)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(decision.slug + ".md")
        // If slug collides with existing file, fall through to update.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try updateExistingPortrait(category: category, decision: decision)
            return
        }
        // Portrait files use `category` as the routing label (kept for human
        // readability inside the file). For type, "experiences" / "emotions"
        // map back to the underlying event types; other categories are
        // facet-driven portrait entries (treated as `experience` by default).
        let portraitType: String = (category == "emotions") ? "emotion" : "experience"
        var file = PortraitFile(
            created: Date(),
            impact: 3,                    // distilled-portrait baseline
            body: renderBody(decision: decision),
            source: "distilled",
            tags: [category, "portrait"],
            firstOccurrence: Date(),
            eventTitle: decision.title,
            eventSummary: decision.body,
            eventType: portraitType,
            portraitFacets: [],
            category: category,
            memberFrameIds: []
        )
        WeightCalculator.recompute(&file)
        try PortraitFileIO.write(file, to: url)
    }

    /// Returns true if file existed and was updated; false if not found.
    @discardableResult
    private func updateExistingPortrait(category: String, decision: ParsedDecision) throws -> Bool {
        let url = PortraitPaths.categoryDir(category).appendingPathComponent(decision.slug + ".md")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var file = try PortraitFileIO.read(from: url)
        file.eventTitle = decision.title
        file.eventSummary = decision.body
        file.body = renderBody(decision: decision)
        file.recordOccurrence(on: Date())    // mark as "still relevant today"
        WeightCalculator.recompute(&file)
        try PortraitFileIO.write(file, to: url)
        return true
    }

    private func renderBody(decision: ParsedDecision) -> String {
        var lines: [String] = []
        lines.append("# \(decision.title)")
        lines.append("")
        lines.append(decision.body)
        if !decision.derivedFromEventIds.isEmpty {
            lines.append("")
            lines.append("**Derived from events:**")
            for eid in decision.derivedFromEventIds.prefix(20) {
                lines.append("- [[\(eid)]]")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - On-disk inventory

    /// One event we'll show to the LLM.
    private struct EventEntry: Sendable {
        let id: String                  // relative path under events/
        let title: String
        let summary: String
        let impact: Double
        let weight: Double              // decayed importance — recency-aware
        let created: Date               // 用于让 LLM 判断"新证据"
        let occurrenceDays: Int
    }

    private struct PortraitEntry: Sendable {
        let slug: String
        let title: String
        let body: String                // 完整 body（加权合并需要看全文，不是摘要）
        let lastUpdated: Date           // 上次蒸馏更新 —— 判定"此后的新事件"基准
        let category: String
    }

    nonisolated private func collectEventsByCategory() async -> [String: [EventEntry]] {
        await Task.detached(priority: .userInitiated) {
            Self.scanEventsSync()
        }.value
    }

    nonisolated private func collectPortraitByCategory() async -> [String: [PortraitEntry]] {
        await Task.detached(priority: .userInitiated) {
            Self.scanPortraitsSync()
        }.value
    }

    nonisolated private static func scanEventsSync() -> [String: [EventEntry]] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.eventsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var out: [String: [EventEntry]] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            if f.eventTitle.isEmpty && f.eventSummary.isEmpty { continue }
            let rel = url.path
                .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
            let entry = EventEntry(
                id: rel,
                title: f.eventTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : f.eventTitle,
                summary: f.eventSummary,
                impact: f.impact,
                weight: f.weight,
                created: f.created,
                occurrenceDays: f.occurrences.count
            )

            // New routing:
            //   - type=experience → portrait/experiences/
            //   - type=emotion    → portrait/emotions/
            //   - every facet     → portrait/<facet name>/
            // (Same event can feed multiple portrait categories.)
            switch f.eventType.lowercased() {
            case "emotion":     out["emotions", default: []].append(entry)
            default:            out["experiences", default: []].append(entry)
            }
            for facet in f.portraitFacets {
                let name = facet.facet.lowercased()
                // Defensive — skip facets that look like routes already
                // handled by type, or facets outside the 9 known buckets.
                guard name != "experiences", name != "emotions" else { continue }
                out[name, default: []].append(entry)
            }
        }
        // Sort each category's events by impact desc; cap to prevent context bloat.
        for (k, v) in out {
            out[k] = Array(v.sorted { $0.impact > $1.impact }.prefix(50))
        }
        return out
    }

    nonisolated private static func scanPortraitsSync() -> [String: [PortraitEntry]] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var out: [String: [PortraitEntry]] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            let slug = url.deletingPathExtension().lastPathComponent
            let title = f.eventTitle.isEmpty ? slug : f.eventTitle
            let entry = PortraitEntry(
                slug: slug,
                title: title,
                body: f.body,
                lastUpdated: f.lastOccurrence ?? f.created,
                category: f.category
            )
            out[f.category, default: []].append(entry)
        }
        return out
    }
}

// MARK: - Coordinator (mirrors EventBuilder's pattern)

private actor DistillerCoordinator {
    private var buffer: String = ""
    private var currentID: String?
    private var pending: CheckedContinuation<String, Never>?
    private var lastError: String?

    func startTurn(id: String) {
        buffer = ""
        currentID = id
        pending = nil
        lastError = nil
    }

    func awaitTurn() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending = cont
        }
    }

    /// 本轮 LLM `.error` 事件携带的错误文本（无错误返回 nil）。
    func consumeError() -> String? { lastError }

    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d):
            buffer.append(d)
        case .assistantFinalText(let t):
            if buffer.isEmpty { buffer = t }
        case .agentEnd:
            if let p = pending {
                pending = nil
                p.resume(returning: buffer)
            }
        case .error(let msg):
            lastError = msg
            if let p = pending {
                pending = nil
                p.resume(returning: buffer)
            }
        default:
            break
        }
    }
}
