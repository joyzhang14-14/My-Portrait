import Foundation

/// LLM-driven impact scoring per design doc §6.2. Scores events that
/// Backfill wrote as `unscored`.
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
/// add a new HTTP path — the project's Codex / ChatGPT OAuth cronJob is the
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

    private let provider: Provider

    init(
        provider: Provider = .chatgpt,
        model: String = "gpt-5.4",
        batchSize: Int = 20,
        perBatchTimeout: TimeInterval = 90
    ) {
        self.provider = provider
        self.model = model
        self.batchSize = batchSize
        self.perBatchTimeout = perBatchTimeout
    }

    /// Rescore every non-archived `unscored` event under `root`. Returns
    /// counts + duration. `progress` is called on the main actor between
    /// batches.
    ///
    /// `root` defaults to the whole events tree; the scheduler passes a single
    /// day's directory (`events/<yyyy-MM-dd>/`) so the impact step is per-day.
    func rescoreAll(
        root: URL = Storage.eventsDir,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> Result {
        let napGuard = AppNapGuard.acquire(reason: "Impact rescoring")
        defer { napGuard.release() }
        return try await rescoreAllImpl(root: root, progress: progress)
    }

    private func rescoreAllImpl(
        root: URL, progress: ((Progress) -> Void)?
    ) async throws -> Result {
        let start = Date()

        // Collect every (url, file) under `root` that is NOT archived.
        // Backfill writes event files as `unscored`; this rescore gives them a
        // real impact. Sequentially to keep memory tiny.
        let candidates = try await collectCandidates(root: root)
        guard !candidates.isEmpty else {
            return Result(scoredCount: 0, failedCount: 0, elapsed: 0)
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
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
            } catch let e as BudgetExhaustedError {
                // 撞额度：中止整个 rescore，调度器据此标 budget_deferred。
                // 已写入的批次保留（幂等，下次只补未评分的）。
                throw e
            } catch ScorerError.agentTimeout {
                // 超时后该 agent 的事件流已错位:turn N 的迟到响应(事件不带
                // turn id)会 resume 下一轮的 waiter,把 batch N 的分数按
                // id→index 写进 batch N+1 的事件文件(off-by-one 写坏数据)。
                // 不能 continue 复用同一 agent —— 中止整轮,已写入的批次
                // 保留,调度器稍后重试只补未评分的。
                throw ScorerError.agentTimeout
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
                let clamped = PortraitFile.clampImpact(s.impact)
                file.impact = clamped
                file.rawImpact = clamped         // preserve LLM's original
                file.rebalanceCount = 0          // reset; MemoryBudget can re-touch
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

        // rebalance 不在这里跑 —— rescoreAll 被 runEventJob 按天调用（一次
        // event 处理调 N 次），放这里会让 rebalance 跑 N 遍、几次就把
        // rebalance_count 烧到 maxRebalances 冻结。改成 runEventJob 末尾
        // 整个跑完只调一次。

        return Result(
            scoredCount: scored,
            failedCount: failed,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    // MARK: - One batch round-trip

    private func sendBatch(
        prompt: String,
        agent: any ChatAgent,
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

        // 撞额度优先于解析失败：LLM 报额度错时 buffer 为空，解析会抛
        // noJSONInResponse 掩盖真因。先查 .error 文本。
        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "ImpactScorer", message: err)
        }

        return try Self.parseScores(from: collected)
    }

    // MARK: - Prompt + parse

    private static func buildPrompt(for batch: [(URL, PortraitFile)]) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(ConfigStore.shared.current.personalInfo)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(MemoryPrompts.impactScoring)
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
            let facets = f.portraitFacets.map { "\($0.facet):\($0.value)" }.joined(separator: ", ")
            lines.append("    meta: tags=[\(tags)] · duration≈\(durationMin)min · occurrences_days=\(f.occurrences.count) · portrait_facets=[\(facets)]")
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
            let evidence = entry["evidence"] as? String ?? entry["reason"] as? String
            return LLMScore(id: id, impact: impact, reason: evidence)
        }
    }

    // MARK: - Candidate collection

    nonisolated private func collectCandidates(root: URL) async throws -> [(URL, PortraitFile)] {
        await Task.detached(priority: .userInitiated) {
            Self.scanCandidates(root: root)
        }.value
    }

    nonisolated private static func scanCandidates(root: URL) -> [(URL, PortraitFile)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [(URL, PortraitFile)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
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
    private var lastError: String?

    func startTurn(id: String) {
        buffer = ""
        currentID = id
        pending = nil
        lastError = nil
    }

    func awaitTurn() async -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                pending = cont
            }
        } onCancel: {
            Task { await self.cancelTurn() }
        }
    }

    /// 被取消(如超时子任务触发 cancelAll)→ 用已收到的部分 buffer resume 等待者,
    /// 让 task group 能 drain、调用方抛错/返回,defer 里的 agent.stop() 才真去杀
    /// 卡住的子进程。否则 awaitTurn 的 continuation 永不 resume → 整条 pipeline
    /// 永久 hang(同 EventBuilder.ResponseCoordinator 的既有修法)。
    func cancelTurn() {
        if let p = pending {
            pending = nil
            p.resume(returning: buffer)
        }
    }

    /// 本轮 LLM `.error` 事件携带的错误文本（无错误返回 nil）。
    func consumeError() -> String? { lastError }

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
        case .error(let msg):
            lastError = msg
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
