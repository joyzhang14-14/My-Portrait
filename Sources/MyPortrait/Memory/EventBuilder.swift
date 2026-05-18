import Foundation

/// LLM-driven event clustering — the missing semantic layer between raw
/// Tier 1 sessions and the persistent event-level PortraitFiles.
///
/// Per design conversation:
///   - An "event" is what the USER subjectively did (chat with John about a
///     song), not what the OS recorded (Messages-then-Safari-then-Messages).
///   - Events span apps within a day.
///   - Occurrence counting is per-day: same event multiple times in one day
///     counts as 1 occurrence; same event next day = +1 occurrence.
///
/// Workflow (one call per day):
///   Input → all Tier 1 sessions for the day + OCR/transcript snippets
///         + recent active events (titles + summaries from past N days)
///   LLM   → for each session: {decision: "join:<existing_id>" or
///                                       "new:{title, summary, category, tags}"}
///   Output → assignments that Backfill materialises into PortraitFile writes
@MainActor
final class EventBuilder {
    /// A Tier 1 session enriched with OCR/transcript context, ready for LLM.
    struct EnrichedSession {
        let session: Tier1Merger.MergedEvent
        let ocrSnippet: String        // deduped OCR text from member frames
        let transcriptSnippet: String // audio transcripts overlapping the window
    }

    /// Reference to an event the LLM may want to join. Backfill builds this
    /// list from existing PortraitFiles in `portrait/` (recent N days).
    struct ActiveEvent {
        let id: String                // stable id (file path under portrait/)
        let title: String
        let summary: String
        let category: String
        let lastOccurredOn: Date
    }

    /// LLM decision for one session.
    enum Decision {
        case join(eventId: String)
        case new(title: String, summary: String, category: String, tags: [String])
        case skip
    }

    /// Returned 1:1 with input sessions (same order).
    struct Assignment {
        let session: Tier1Merger.MergedEvent
        let decision: Decision
        let reason: String?
    }

    enum BuilderError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)
        case sizeMismatch(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):     return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:          return "LLM did not respond within timeout"
            case .noJSONInResponse:      return "LLM response contained no JSON"
            case .malformedJSON(let m):  return "LLM JSON parse failed: \(m)"
            case .sizeMismatch(let e, let g):
                return "LLM returned \(g) assignments, expected \(e)"
            }
        }
    }

    private let model: String
    private let perDayTimeout: TimeInterval

    init(model: String = "gpt-5.4", perDayTimeout: TimeInterval = 120) {
        self.model = model
        self.perDayTimeout = perDayTimeout
    }

    /// Resolve assignments for one day's sessions. Caller (Backfill) supplies
    /// the enriched sessions and the active-event catalogue.
    /// Returns assignments in the same order as `sessions`.
    func assignDay(
        date: Date,
        sessions: [EnrichedSession],
        activeEvents: [ActiveEvent]
    ) async throws -> [Assignment] {
        guard !sessions.isEmpty else { return [] }

        let agent = try PiAgent(model: model)
        do { try await agent.start() }
        catch { throw BuilderError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = ResponseCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        let prompt = Self.buildPrompt(date: date,
                                      sessions: sessions,
                                      activeEvents: activeEvents)

        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)
        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw BuilderError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perDayTimeout * 1_000_000_000))
                    throw BuilderError.agentTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw BuilderError.agentTimeout
        }

        let decisions = try Self.parseDecisions(from: collected, expected: sessions.count)
        return zip(sessions, decisions).map { (enriched, parsed) in
            Assignment(session: enriched.session,
                       decision: parsed.decision,
                       reason: parsed.reason)
        }
    }

    // MARK: - Prompt construction

    nonisolated private static func buildPrompt(
        date: Date,
        sessions: [EnrichedSession],
        activeEvents: [ActiveEvent]
    ) -> String {
        let dayStr = isoDay(date)
        var lines: [String] = []
        lines.append("You are clustering raw activity sessions into SEMANTIC EVENTS.")
        lines.append("")
        lines.append("Rules:")
        lines.append("- An EVENT is what the user was DOING (subject + intent), not which app was open.")
        lines.append("- Events span apps. Switching from Messages to a YouTube link sent in chat and back is ONE event.")
        lines.append("- Each session below either JOINS an existing active event (if it's a continuation), STARTS a NEW event, or is SKIPPED if there's no meaningful content.")
        lines.append("- Prefer joining over creating when intent matches even if app differs.")
        lines.append("- **The summary MUST be grounded in the OCR text below. Do NOT make up content from app/window names alone.** If you have no OCR to support a real summary, choose `skip` instead of `new`.")
        lines.append("- `skip` is correct for sessions that are clearly idle/transient (app open in background, no real interaction).")
        lines.append("- A NEW event gets:")
        lines.append("    title:    ≤60 chars, grounded in OCR, describes what the user was actually DOING")
        lines.append("    summary:  3-5 sentences. MUST reference specific topics, names, decisions, or actions visible in the OCR. Do not write filler like \"the user was using X app\". Write what the user was working on, with detail. Third person.")
        lines.append("    category: one of personality, social, background, experiences, interests, speech_style, habits, skills, emotions")
        lines.append("    tags:     1-5 lowercase keywords drawn from the OCR (project names, libraries, people, topics)")
        lines.append("")
        lines.append("Date being processed: \(dayStr)")
        lines.append("")

        // Active events block — what the LLM can join to.
        if activeEvents.isEmpty {
            lines.append("Active events from recent days: (none)")
        } else {
            lines.append("Active events from recent days (id → title — summary, last on YYYY-MM-DD):")
            for e in activeEvents {
                let last = isoDay(e.lastOccurredOn)
                let trimSummary = e.summary.count > 140
                    ? String(e.summary.prefix(140)) + "…" : e.summary
                lines.append("  \(e.id) → \(e.title) — \(trimSummary)  [last: \(last), cat: \(e.category)]")
            }
        }
        lines.append("")

        // Sessions block.
        lines.append("Sessions to assign (id=1..\(sessions.count)):")
        for (i, item) in sessions.enumerated() {
            let id = i + 1
            let s = item.session
            let timeRange = "\(timeOfDay(s.firstSeen))–\(timeOfDay(s.lastSeen))"
            let durMin = max(1, Int(s.lastSeen.timeIntervalSince(s.firstSeen) / 60))
            var line = "\(id). [\(timeRange), \(durMin)min] \(s.appName)"
            if !s.windowName.isEmpty { line += " — \(s.windowName)" }
            if let u = s.browserURL, !u.isEmpty { line += " (url: \(u))" }
            lines.append(line)
            if !item.ocrSnippet.isEmpty {
                let snippet = item.ocrSnippet
                    .replacingOccurrences(of: "\n", with: " ⏎ ")
                let trim = snippet.count > 280 ? String(snippet.prefix(280)) + "…" : snippet
                lines.append("    ocr: \(trim)")
            }
            if !item.transcriptSnippet.isEmpty {
                let trim = item.transcriptSnippet.count > 200
                    ? String(item.transcriptSnippet.prefix(200)) + "…"
                    : item.transcriptSnippet
                lines.append("    audio: \(trim)")
            }
        }
        lines.append("")

        // Strict output spec.
        lines.append("Respond with ONLY a JSON array of \(sessions.count) objects in the SAME ORDER as the sessions above. No prose, no markdown fences.")
        lines.append("Each object:")
        lines.append("  - join an existing event:  {\"id\":1, \"decision\":\"join\", \"event_id\":\"<id from active list>\", \"reason\":\"...\"}")
        lines.append("  - start a new event:       {\"id\":1, \"decision\":\"new\", \"title\":\"...\", \"summary\":\"...\", \"category\":\"...\", \"tags\":[\"...\"], \"reason\":\"...\"}")
        lines.append("  - skip (no real content):  {\"id\":1, \"decision\":\"skip\", \"reason\":\"no OCR / idle\"}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Response parsing

    nonisolated private static func parseDecisions(
        from response: String,
        expected: Int
    ) throws -> [(decision: Decision, reason: String?)] {
        guard let firstBracket = response.firstIndex(of: "["),
              let lastBracket = response.lastIndex(of: "]") else {
            throw BuilderError.noJSONInResponse
        }
        let jsonStr = String(response[firstBracket...lastBracket])
        guard let data = jsonStr.data(using: .utf8) else {
            throw BuilderError.malformedJSON("could not encode response as UTF-8")
        }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) }
        catch { throw BuilderError.malformedJSON(error.localizedDescription) }
        guard let arr = obj as? [[String: Any]] else {
            throw BuilderError.malformedJSON("top-level was not an array of objects")
        }
        guard arr.count == expected else {
            throw BuilderError.sizeMismatch(expected: expected, got: arr.count)
        }

        var out: [(Decision, String?)] = []
        out.reserveCapacity(arr.count)
        for (idx, entry) in arr.enumerated() {
            let reason = entry["reason"] as? String
            let kind = (entry["decision"] as? String)?.lowercased() ?? ""
            switch kind {
            case "join":
                guard let eid = entry["event_id"] as? String, !eid.isEmpty else {
                    throw BuilderError.malformedJSON("entry \(idx + 1) missing event_id for join")
                }
                out.append((.join(eventId: eid), reason))
            case "new":
                let title = (entry["title"] as? String) ?? "Untitled"
                let summary = (entry["summary"] as? String) ?? ""
                let category = (entry["category"] as? String) ?? "habits"
                let tags = (entry["tags"] as? [String]) ?? []
                out.append((.new(title: title, summary: summary, category: category, tags: tags), reason))
            case "skip":
                out.append((.skip, reason))
            default:
                throw BuilderError.malformedJSON("entry \(idx + 1) unknown decision \(kind)")
            }
        }
        return out
    }

    // MARK: - Formatters

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    nonisolated(unsafe) private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()
    nonisolated private static func isoDay(_ d: Date) -> String { dayFmt.string(from: d) }
    nonisolated private static func timeOfDay(_ d: Date) -> String { timeFmt.string(from: d) }
}

// MARK: - Coordinator (reuse the pattern from ImpactScorer)

/// Mirrors ImpactScorer.Coordinator — owns the running buffer + the awaiter
/// continuation for one turn. Separate type to keep the two scorers
/// independent.
private actor ResponseCoordinator {
    private var buffer: String = ""
    private var currentID: String?
    private var pending: CheckedContinuation<String, Never>?

    func startTurn(id: String) {
        buffer = ""
        currentID = id
        pending = nil
    }

    func awaitTurn() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending = cont
        }
    }

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
        case .error:
            if let p = pending {
                pending = nil
                p.resume(returning: buffer)
            }
        default:
            break
        }
    }
}
