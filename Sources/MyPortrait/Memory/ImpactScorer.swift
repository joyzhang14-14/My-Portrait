import Foundation

/// LLM-driven impact scoring per design doc §6.2. Replaces the duration
/// baseline written by `Backfill.baselineImpact()`.
///
/// Architecture:
///   - One long-lived `PiAgent` per `rescoreAll(...)` invocation
///   - Sessions are batched (default 20 per request)
///   - Each batch is sent as a single prompt asking for strict JSON
///   - Response is collected from `text_delta` + `assistantFinalText`
///     events until `agent_end`, then parsed
///   - Each scored file is re-written with new impact + impact_source
///   - Weight is recomputed on each file after scoring
///
/// Reuses the existing infrastructure (`PiAgent`, `ChatGPTOAuth`) so we don't
/// add a new HTTP path — the project's Codex / ChatGPT OAuth pipe is the
/// canonical AI ingress.
@MainActor
final class ImpactScorer {
    struct Progress {
        let batchIndex: Int
        let batchCount: Int
        let scoredCount: Int
        let totalCount: Int
    }

    struct Result {
        let scoredCount: Int
        let failedCount: Int
        let elapsed: TimeInterval
    }

    enum ScorerError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):    return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:         return "LLM did not respond within timeout"
            case .noJSONInResponse:     return "LLM response contained no JSON array"
            case .malformedJSON(let m): return "LLM JSON parse failed: \(m)"
            }
        }
    }

    private let model: String
    private let batchSize: Int
    private let perBatchTimeout: TimeInterval

    init(
        model: String = "gpt-5.4",
        batchSize: Int = 20,
        perBatchTimeout: TimeInterval = 90
    ) {
        self.model = model
        self.batchSize = batchSize
        self.perBatchTimeout = perBatchTimeout
    }

    /// Rescore every non-archived portrait file. Returns counts + duration.
    /// `progress` is called on the main actor between batches.
    func rescoreAll(progress: ((Progress) -> Void)? = nil) async throws -> Result {
        let start = Date()

        // Collect every (url, file) under ~/.portrait/portrait/ that is NOT
        // archived. Sequentially to keep memory tiny.
        let candidates = try await collectCandidates()
        guard !candidates.isEmpty else {
            return Result(scoredCount: 0, failedCount: 0, elapsed: 0)
        }

        let agent = try PiAgent(model: model)
        do { try await agent.start() }
        catch { throw ScorerError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        // One concurrent consumer drains the event stream — we feed completed
        // batches back to the awaiter via continuations stashed in `pending`.
        let coordinator = Coordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        var scored = 0
        var failed = 0

        let batches = candidates.chunked(into: batchSize)
        for (i, batch) in batches.enumerated() {
            progress?(.init(batchIndex: i,
                            batchCount: batches.count,
                            scoredCount: scored,
                            totalCount: candidates.count))

            let prompt = Self.buildPrompt(for: batch)
            let scores: [LLMScore]
            do {
                scores = try await sendBatch(
                    prompt: prompt,
                    agent: agent,
                    coordinator: coordinator
                )
            } catch {
                failed += batch.count
                continue
            }

            // Apply scores back to files by index (LLM returns id=1..N).
            for s in scores {
                let idx = s.id - 1
                guard idx >= 0, idx < batch.count else { continue }
                let url = batch[idx].0
                var file = batch[idx].1
                file.impact = max(1.0, min(5.0, s.impact))
                file.impactSource = "llm:\(model)"
                WeightCalculator.recompute(&file)
                do {
                    try PortraitFileIO.write(file, to: url)
                    scored += 1
                } catch {
                    failed += 1
                }
            }
        }

        progress?(.init(batchIndex: batches.count,
                        batchCount: batches.count,
                        scoredCount: scored,
                        totalCount: candidates.count))

        return Result(
            scoredCount: scored,
            failedCount: failed,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    // MARK: - One batch round-trip

    private func sendBatch(
        prompt: String,
        agent: PiAgent,
        coordinator: Coordinator
    ) async throws -> [LLMScore] {
        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)

        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw ScorerError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perBatchTimeout * 1_000_000_000))
                    throw ScorerError.agentTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw ScorerError.agentTimeout
        }

        return try Self.parseScores(from: collected)
    }

    // MARK: - Prompt + parse

    private static func buildPrompt(for batch: [(URL, PortraitFile)]) -> String {
        var lines: [String] = []
        lines.append("You score the long-term IMPORTANCE of each user activity event for the user's PERSONAL PROFILE. Scale: 0.0-5.0 (float).")
        lines.append("")
        lines.append("ANCHORS — calibrate strictly. Most events should be 1-2.")
        lines.append("  0.0-0.9 - pointless. Examples: scrolling Finder, glancing at a dashboard, checking the time, idle background app,")
        lines.append("  1.0-1.9 — trivial / passive. Examples: brief tab switching, listening to music in background.")
        lines.append("  2.0-2.9 — routine engagement. Examples: checking and replying to a few messages, reading a short article, looking something up, normal browsing.")
        lines.append("  3.0-4.0 — focused activity worth noting later. Examples: an hour of real coding on a specific feature, a real conversation about something concrete, learning material on a topic the user actually cares about.")
        lines.append("  4.1-4.5 — a noteworthy, pivotal event the user might remember for a year. Examples: shipping a feature, deciding on a tech approach, an emotionally significant exchange, a meeting where a real decision was made, a breakthrough realization, a milestone.")
        lines.append("  4.9-5.0 — change of life. Examples: a life-changing relationship, a life-changing career opportunity, a life-changing event, a life-changing decision. Those who have experienced it will never forget it.")
        lines.append("")
        lines.append("RULES (read carefully):")
        lines.append("- Score from the EVENT SUMMARY content, NOT from the app or duration. Long sessions in Finder/Code/Safari that did nothing memorable are 1.")
        lines.append("- If summary describes a routine browsing/idle/glance pattern, ALWAYS 1-2 regardless of duration or app.")
        lines.append("- 4+ requires a concrete outcome, decision, milestone, or emotional weight visible in the summary.")
        lines.append("- Repeated days (high `occurrences_days`) only mildly raise the score (it's a habit, not necessarily important).")
        lines.append("- The `reason` field MUST quote or paraphrase a SPECIFIC fragment from the summary that justifies the score. If you cannot point to specifics, the score is ≤2.")
        lines.append("")
        lines.append("Output ONLY a JSON array. No prose, no markdown fences.")
        lines.append("[{\"id\":1, \"impact\":1.5, \"reason\":\"cites concrete fragment\"}, ...]")
        lines.append("")
        lines.append("Events:")
        for (i, item) in batch.enumerated() {
            let (_, f) = item
            let id = i + 1
            let durationMin = max(1, Int((f.occurrences.last ?? f.created).timeIntervalSince(f.occurrences.first ?? f.created) / 60))
            let title = f.eventTitle.isEmpty
                ? (f.body.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "untitled")
                : f.eventTitle
            let summary = f.eventSummary.isEmpty ? "(no summary)" : f.eventSummary
            let trimSummary = summary.count > 360
                ? String(summary.prefix(360)) + "…" : summary
            let tags = f.tags.joined(separator: ", ")
            lines.append("\(id). title: \(title)")
            lines.append("    summary: \(trimSummary.replacingOccurrences(of: "\n", with: " ⏎ "))")
            lines.append("    meta: tags=[\(tags)] · duration≈\(durationMin)min · occurrences_days=\(f.occurrences.count) · category=\(f.category)")
        }
        return lines.joined(separator: "\n")
    }

    private struct LLMScore {
        let id: Int
        let impact: Double
        let reason: String?
    }

    private static func parseScores(from response: String) throws -> [LLMScore] {
        // Find the first '[' and last ']' — accommodates models that wrap the
        // JSON in stray prose or ```json fences despite the instruction.
        guard let firstBracket = response.firstIndex(of: "["),
              let lastBracket = response.lastIndex(of: "]") else {
            throw ScorerError.noJSONInResponse
        }
        let jsonStr = String(response[firstBracket...lastBracket])
        guard let data = jsonStr.data(using: .utf8) else {
            throw ScorerError.malformedJSON("could not encode response as UTF-8")
        }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) }
        catch { throw ScorerError.malformedJSON(error.localizedDescription) }
        guard let arr = obj as? [[String: Any]] else {
            throw ScorerError.malformedJSON("top-level was not an array of objects")
        }
        return arr.compactMap { entry in
            guard let id = entry["id"] as? Int else { return nil }
            // Accept either Int (3) or Double (3.2) for impact.
            let impact: Double
            if let d = entry["impact"] as? Double { impact = d }
            else if let i = entry["impact"] as? Int { impact = Double(i) }
            else { return nil }
            let reason = entry["reason"] as? String
            return LLMScore(id: id, impact: impact, reason: reason)
        }
    }

    // MARK: - Candidate collection

    nonisolated private func collectCandidates() async throws -> [(URL, PortraitFile)] {
        await Task.detached(priority: .userInitiated) {
            Self.scanCandidates()
        }.value
    }

    nonisolated private static func scanCandidates() -> [(URL, PortraitFile)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [(URL, PortraitFile)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if let f = try? PortraitFileIO.read(from: url),
               f.archivedAt == nil {
                out.append((url, f))
            }
        }
        return out
    }
}

// MARK: - Coordinator (drives the AsyncStream → continuation bridge)

/// Owns the "what text has the model produced for the current turn" buffer
/// and the continuation the awaiter is blocked on. One per `rescoreAll` call.
private actor Coordinator {
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
            // Use as fallback if streaming produced nothing.
            if buffer.isEmpty { buffer = t }
        case .agentEnd:
            // Finish the awaiter.
            if let p = pending {
                pending = nil
                p.resume(returning: buffer)
            }
        case .error:
            if let p = pending {
                pending = nil
                // Surface as empty — caller's parser will throw noJSONInResponse.
                p.resume(returning: buffer)
            }
        default:
            break
        }
    }
}

// MARK: - Helpers

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}
