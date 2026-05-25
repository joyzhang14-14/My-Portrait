import Foundation
import os.log

private let pcLog = Logger(subsystem: "com.myportrait.memory", category: "personality-cluster")

/// 三源汇出来的 tag 候选语义聚类:把"systems-builder / systems-thinking /
/// systems-obsession / framework-design"这种表面不同但同义的 tag 归到一组,
/// 喂给下游 PersonalityMerger 时由 96 个候选 → 20 来个 cluster,merger 的
/// 决策空间小,不会偷懒一律 createNew。走 gpt-5.4-mini(轻量任务)。
@MainActor
final class PersonalityClusterAgent {

    enum AgentError: LocalizedError {
        case agentSpawn(String), agentTimeout, noJSONInResponse, malformedJSON(String)
        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):    return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:         return "LLM did not respond within timeout"
            case .noJSONInResponse:     return "LLM response contained no JSON array"
            case .malformedJSON(let m): return "LLM JSON parse failed: \(m)"
            }
        }
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .chatgpt, model: String = "gpt-5.4-mini", perRunTimeout: TimeInterval = 90) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 候选 → cluster。空候选 → 短路返回空。单候选 → 短路成一个 singleton
    /// cluster,不调 LLM。
    func cluster(candidates: [PersonalityTagCandidate]) async throws -> [PersonalityCluster] {
        try await clusterWithRaw(candidates: candidates).clusters
    }

    func clusterWithRaw(
        candidates: [PersonalityTagCandidate]
    ) async throws -> (prompt: String, raw: String, clusters: [PersonalityCluster]) {
        let prompt = Self.buildPrompt(candidates: candidates)

        if candidates.isEmpty {
            return (prompt: prompt, raw: "(short-circuited: no candidates)", clusters: [])
        }
        if candidates.count == 1 {
            let c = candidates[0]
            return (prompt: prompt, raw: "(short-circuited: single candidate)",
                    clusters: [PersonalityCluster(head: c.tag, members: [c])])
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = ClusterCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)
        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perRunTimeout * 1_000_000_000))
                    throw AgentError.agentTimeout
                }
                let r = try await group.next()!
                group.cancelAll()
                return r
            }
        } catch is CancellationError {
            throw AgentError.agentTimeout
        }

        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "PersonalityClusterAgent", message: err)
        }

        let clusters = try Self.parseClusters(from: collected, candidates: candidates)
        // 兜底:有任何候选没被 LLM 收进 cluster → 各自成 singleton(防丢)。
        let covered = Set(clusters.flatMap { $0.members.map(Self.identity) })
        var out = clusters
        for (i, c) in candidates.enumerated() where !covered.contains(Self.identity(c)) {
            pcLog.notice("orphan candidate idx=\(i) tag=\(c.tag, privacy: .public) — wrapping as singleton")
            out.append(PersonalityCluster(head: c.tag, members: [c]))
        }
        return (prompt: prompt, raw: collected, clusters: out)
    }

    // MARK: - Prompt

    private static func buildPrompt(candidates: [PersonalityTagCandidate]) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(ConfigStore.shared.current.personalInfo)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(MemoryPrompts.personalityCluster)
        lines.append("")
        lines.append("INDEXED TAGS:")
        for (i, c) in candidates.enumerated() {
            lines.append("  \(i). \(c.tag)  (source: \(c.source.rawValue))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    private static func parseClusters(
        from response: String,
        candidates: [PersonalityTagCandidate]
    ) throws -> [PersonalityCluster] {
        guard let first = response.firstIndex(of: "["),
              let last = response.lastIndex(of: "]") else {
            throw AgentError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        let arr: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AgentError.malformedJSON("top-level not an array of objects")
            }
            arr = parsed
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.malformedJSON(error.localizedDescription)
        }

        var out: [PersonalityCluster] = []
        var used = Set<Int>()
        for obj in arr {
            let head = (obj["head"] as? String) ?? ""
            guard !head.isEmpty else { continue }
            let memberIdxs = (obj["members"] as? [Any])?
                .compactMap { ($0 as? Int) ?? ((($0 as? String).flatMap { Int($0) })) } ?? []
            var members: [PersonalityTagCandidate] = []
            for idx in memberIdxs {
                guard candidates.indices.contains(idx) else { continue }
                // 重复 idx 跨 cluster 出现 → 第一个 wins,后续忽略。
                if used.contains(idx) { continue }
                used.insert(idx)
                members.append(candidates[idx])
            }
            guard !members.isEmpty else { continue }
            out.append(PersonalityCluster(head: head, members: members))
        }
        return out
    }

    /// 候选去重身份键 —— 同 tag+同源+同 evidence 视作同一候选。
    fileprivate static func identity(_ c: PersonalityTagCandidate) -> String {
        c.tag + "|" + c.source.rawValue + "|" + c.evidence.joined(separator: ",")
    }
}

// MARK: - PiAgent 事件流 Coordinator

private actor ClusterCoordinator {
    private var buffer: String = ""
    private var currentID: String?
    private var pending: CheckedContinuation<String, Never>?
    private var lastError: String?

    func startTurn(id: String) {
        buffer = ""; currentID = id; pending = nil; lastError = nil
    }
    func awaitTurn() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending = cont
        }
    }
    func consumeError() -> String? { lastError }
    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d): buffer.append(d)
        case .assistantFinalText(let t): if buffer.isEmpty { buffer = t }
        case .agentEnd:
            if let p = pending { pending = nil; p.resume(returning: buffer) }
        case .error(let msg):
            lastError = msg
            if let p = pending { pending = nil; p.resume(returning: buffer) }
        default: break
        }
    }
}
