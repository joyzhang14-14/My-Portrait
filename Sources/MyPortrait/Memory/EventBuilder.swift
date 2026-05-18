import Foundation

/// LLM-driven event clustering — the missing semantic layer between raw
/// Tier 1 sessions and the persistent event-level PortraitFiles.
///
/// Per design:
///   - An "event" is what the USER subjectively did, not which app was open.
///   - Events span apps within a day.
///   - Occurrence counting is per-day: same event multiple times in one day
///     counts as 1 occurrence; same event next day = +1 occurrence.
///
/// Schema change (2026-05-18):
///   - The single `category` field is removed.
///   - Replaced by `type` (experience | emotion) plus optional
///     `portrait_facets` (personality / background / social / speech_style /
///     habits / interests / skills) with per-facet thresholds. Most events
///     have an empty facet array — they're activity records, not portrait
///     signals.
@MainActor
final class EventBuilder {
    /// A facet of the user's portrait that an event reflects.
    struct PortraitFacet: Equatable, Hashable {
        let facet: String        // personality / background / social / ...
        let value: String        // short descriptor (e.g. "art-history")
    }

    /// A Tier 1 session enriched with OCR/transcript context, ready for LLM.
    struct EnrichedSession {
        let session: Tier1Merger.MergedEvent
        let ocrSnippet: String
        let transcriptSnippet: String
    }

    /// Reference to an event the LLM may want to join. Backfill builds this
    /// list from existing PortraitFiles in `events/` (recent N days).
    struct ActiveEvent {
        let id: String                  // stable id (relative path under events/)
        let title: String
        let summary: String
        let type: String                // "experience" / "emotion"
        let tags: [String]              // for theme matching
        let lastOccurredOn: Date
    }

    /// LLM decision for one session.
    enum Decision {
        case join(eventId: String)
        case new(title: String,
                 summary: String,
                 type: String,                 // "experience" / "emotion"
                 portraitFacets: [PortraitFacet],
                 tags: [String])
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

    /// Resolve assignments for one day's sessions.
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

        // ─── Dynamic blocks (raw Swift, NOT raw string) ───────────────────

        let activeBlock: String
        if activeEvents.isEmpty {
            activeBlock = "Active events from recent days: (none)"
        } else {
            var rows: [String] = ["Active events from recent days:"]
            for e in activeEvents {
                let last = relativeDay(from: e.lastOccurredOn, on: date)
                let tagStr = e.tags.isEmpty ? "—" : e.tags.joined(separator: ",")
                let trim = e.summary.count > 140
                    ? String(e.summary.prefix(140)) + "…" : e.summary
                rows.append("  [\(e.id)] \(e.title)  | type=\(e.type) | tags=[\(tagStr)] | last=\(last)")
                rows.append("    summary: \(trim.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
            activeBlock = rows.joined(separator: "\n")
        }

        var sessionRows: [String] = ["Sessions to assign (id=1..\(sessions.count)):"]
        for (i, item) in sessions.enumerated() {
            let id = i + 1
            let s = item.session
            let timeRange = "\(timeOfDay(s.firstSeen))–\(timeOfDay(s.lastSeen))"
            let durMin = max(1, Int((s.lastSeen.timeIntervalSince(s.firstSeen) / 60).rounded()))
            var line = "\(id). [\(timeRange), \(durMin)min] \(s.appName)"
            if !s.windowName.isEmpty { line += " — \(s.windowName)" }
            if let u = s.browserURL, !u.isEmpty { line += " (url: \(u))" }
            sessionRows.append(line)
            if !item.ocrSnippet.isEmpty {
                let snippet = item.ocrSnippet.replacingOccurrences(of: "\n", with: " ⏎ ")
                let trim = snippet.count > 500 ? String(snippet.prefix(500)) + "…" : snippet
                sessionRows.append("    ocr: \(trim)")
            }
            if !item.transcriptSnippet.isEmpty {
                let trim = item.transcriptSnippet.count > 200
                    ? String(item.transcriptSnippet.prefix(200)) + "…"
                    : item.transcriptSnippet
                sessionRows.append("    audio: \(trim)")
            }
        }
        let sessionBlock = sessionRows.joined(separator: "\n")

        // ─── Static prompt body (raw string, no escape gymnastics) ────────

        let staticBody = #"""
        You are clustering raw activity sessions into SEMANTIC EVENTS for a personal portrait system.

        OUTPUT SCHEMA
        -------------
        Respond with ONLY a JSON array, one object per input session, in the SAME ORDER as the sessions below.
        No prose, no markdown fences.

        Three decision shapes:

        join an existing event:
          {"id": 1, "decision": "join", "event_id": "<id from active list>", "reason": "..."}

        start a new event:
          {
            "id": 1,
            "decision": "new",
            "title": "...",
            "summary": "...",
            "type": "experience",
            "portrait_facets": [],
            "tags": ["..."],
            "reason": "..."
          }

        skip (no real content):
          {"id": 1, "decision": "skip", "reason": "no OCR / idle"}

        EVENT FIELDS
        ------------
        title            ≤ 60 chars, grounded in OCR, describes what the user was actually DOING.
        summary          3–5 sentences. Must cite specific topics, names, decisions, or actions visible
                         in the OCR. Do NOT write filler like "the user was using X app". Write what
                         the user was working on, with detail.
        type             REQUIRED. Exactly one of:
                           "experience"  ← default. Use for 99% of events.
                           "emotion"     ← ONLY when the OCR shows a clear emotional signal
                                            (frustration, joy, conflict, anxiety, etc.).
                                            Merely being on an app is NOT emotion.
        portrait_facets  Optional. Default []. Most events should have an empty array.
                         Each facet is an object: {"facet": "<facet name>", "value": "<short descriptor>"}.
                         Only attach a facet when the event reflects a STABLE signal about who the user is.

                         Facet vocabulary + per-facet thresholds:
                           personality   — character trait visible in tone/decisions/reactions. RARE.
                           background    — STRICTLY demographic / biographical facts:
                                           age, location, education, family, ethnicity, occupation history.
                                           "Background music" or "background app" is NOT background.
                                           Listening to music is NOT background — it might be `interests`.
                           social        — specific people in the user's life (with name or clear identity).
                           speech_style  — vocabulary, tone, language preference, idioms.
                           habits        — recurring behaviour. ONLY attach if the same behaviour has
                                           occurred 3+ days. A single occurrence is NOT a habit.
                           interests     — topics/domains the user repeatedly engages with by choice.
                           skills        — capability the user is practicing or demonstrating, with evidence.

        tags             1–5 lowercase keywords drawn from the OCR (project names, libraries, people, topics).
        reason           ≤ 20 words.
                           join: which active event and why this session continues it.
                           new : one phrase explaining why this isn't a continuation.
                           skip: why no real content (e.g. "brief glance, no interaction").

        CLUSTERING RULES
        ----------------
        - An EVENT is what the user was DOING (subject + intent), not which app was open.
        - Events span apps. Messages → YouTube link sent in chat → Messages back = ONE event.
        - Prefer JOIN over NEW when the subject matter is the SAME thread of work / conversation / topic,
          even if the app differs.
        - DO NOT JOIN if the subject matter clearly differs. Reading Wikipedia about Python and
          reading Wikipedia about art history are TWO events even though both are "Wikipedia reading".
        - If a candidate event in the active list is OLDER than 14 days AND the current session is not
          an obvious continuation of the exact same thread (same project, same file, same conversation),
          prefer NEW over JOIN.
        - Choose `skip` when a session is clearly idle/transient or has no meaningful content.
        - The summary MUST be grounded in the OCR. If no OCR supports a summary, choose `skip`.

        WRITING STYLE
        -------------
        - THIRD PERSON. Always refer to the user as "the user" or "they"/"their".
            ❌ "You opened Cursor and edited App.swift"
            ✅ "The user opened Cursor and edited App.swift"

        EXAMPLES (illustrative — your real input is below)
        --------
        Example A — join (continuation of yesterday's work on the same file):
          Input session: 09:12–10:48 Cursor — App.swift
            ocr: "AppDelegate ... NSWindow ... titleBar ... fullSizeContentView ..."
          Active list contains:
            [evt_2026-05-17_001] Wiring custom NSWindow chrome | type=experience | tags=[swift,nswindow] | last=yesterday
          Decision:
          {"id": 3, "decision": "join", "event_id": "evt_2026-05-17_001",
           "reason": "same NSWindow chrome thread, App.swift"}

        Example B — new (different topic, with a facet):
          Input: 14:30–15:10 Safari — Wikipedia: Cubism
            ocr: "Pablo Picasso ... 1907 Les Demoiselles d'Avignon ... African art ..."
          Decision:
          {"id": 5, "decision": "new",
           "title": "Reading about Cubism on Wikipedia",
           "summary": "The user read the Wikipedia article on Cubism, focusing on Picasso's 1907 Les Demoiselles d'Avignon and the early years of the movement. They scrolled through references to Braque and the African art influence section.",
           "type": "experience",
           "portrait_facets": [{"facet": "interests", "value": "art-history"}],
           "tags": ["wikipedia", "cubism", "art-history"],
           "reason": "new art-history topic; no related active event"}

        Example C — skip (idle):
          Input: 11:00–11:01 Finder
            ocr: "Macintosh HD ... Users ... Downloads"
          Decision:
          {"id": 8, "decision": "skip", "reason": "brief Finder glance, no meaningful interaction"}
        """#

        // ─── Stitch (header + dynamic data + sessions) ────────────────────

        return staticBody
            + "\n\nDate being processed: " + dayStr
            + "\n\n" + activeBlock
            + "\n\n" + sessionBlock
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
                let rawType = ((entry["type"] as? String) ?? "experience").lowercased()
                let type = (rawType == "emotion") ? "emotion" : "experience"
                let tags = (entry["tags"] as? [String]) ?? []
                let facets: [PortraitFacet] = ((entry["portrait_facets"] as? [[String: Any]]) ?? []).compactMap { f in
                    guard let facet = f["facet"] as? String, !facet.isEmpty,
                          let value = f["value"] as? String, !value.isEmpty else { return nil }
                    return PortraitFacet(facet: facet.lowercased(), value: value)
                }
                out.append((.new(title: title,
                                 summary: summary,
                                 type: type,
                                 portraitFacets: facets,
                                 tags: tags),
                            reason))
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

    /// "today" / "yesterday" / "Nd ago" — easier for the LLM to reason about
    /// recency than absolute dates.
    nonisolated private static func relativeDay(from past: Date, on reference: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let pastDay = cal.startOfDay(for: past)
        let refDay = cal.startOfDay(for: reference)
        let days = cal.dateComponents([.day], from: pastDay, to: refDay).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}

// MARK: - Coordinator

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
