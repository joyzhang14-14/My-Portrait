import Foundation
import os.log

private let pttLog = Logger(subsystem: "com.myportrait.memory", category: "portrait-to-tags")

/// 从其他 portrait 板块(社交/技能/兴趣/等,**不含 personality**)抽
/// personality tag —— 三源里"其他 portrait"那一源。
///
/// 一次 LLM round-trip 喂全部非-personality portrait 文件;LLM 给每个
/// portrait 回 0-3 个 tag。slug + tag 形成 PersonalityTagCandidate(source:
/// .portraits, evidence: [portraitRelPath])。
@MainActor
final class PortraitToTagsAgent {

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

    struct PortraitInput: Sendable {
        let relativePath: String   // 例如 "skills/swift_macos.md"
        let title: String          // primary_label ?? eventTitle
        let bodyExcerpt: String    // 截断到 ~400 字
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .chatgpt, model: String = "gpt-5.4", perRunTimeout: TimeInterval = 120) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 扫 portrait/ 下所有非 personality / 非归档 / 非隔离的文件,产 PortraitInput。
    static func collectPortraits() -> [PortraitInput] {
        let fm = FileManager.default
        let root = Storage.portraitDir
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [PortraitInput] = []
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive")
                || url.pathComponents.contains("_quarantine") { continue }
            // personality 自己不参与(避免自循环)。
            if url.pathComponents.contains("personality") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            if f.archivedAt != nil { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let title = f.primaryLabel ?? (f.eventTitle.isEmpty ? rel : f.eventTitle)
            // body 截断:取 frontmatter 之后的纯正文,再裁 ~400 字。
            let body = f.eventSummary.isEmpty ? Self.stripFrontmatter(f.body) : f.eventSummary
            let excerpt = body.count > 400 ? String(body.prefix(400)) + "…" : body
            out.append(PortraitInput(relativePath: rel, title: title, bodyExcerpt: excerpt))
        }
        return out
    }

    /// 一次 LLM round-trip:返回 [(portraitRelPath, [tag])]。
    /// 空列表(没 portrait)→ 短路返回空。
    func extract(portraits: [PortraitInput]) async throws -> [(path: String, tags: [String])] {
        try await extractWithRaw(portraits: portraits).result
    }

    func extractWithRaw(
        portraits: [PortraitInput]
    ) async throws -> (prompt: String, raw: String, result: [(path: String, tags: [String])]) {
        let prompt = Self.buildPrompt(portraits: portraits)
        if portraits.isEmpty {
            return (prompt: prompt, raw: "(short-circuited: no portraits)", result: [])
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = PTTCoordinator()
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
            throw BudgetExhaustedError(processor: "PortraitToTagsAgent", message: err)
        }

        let parsed = try Self.parseResult(from: collected)
        return (prompt: prompt, raw: collected, result: parsed)
    }

    // MARK: - Prompt

    private static func buildPrompt(portraits: [PortraitInput]) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(ConfigStore.shared.current.personalInfo)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(MemoryPrompts.portraitToTags)
        lines.append("")
        lines.append("PORTRAITS:")
        for p in portraits {
            lines.append("  - [\(p.relativePath)] \(p.title)")
            lines.append("      body: \(p.bodyExcerpt.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    private static func parseResult(from response: String) throws -> [(path: String, tags: [String])] {
        guard let first = response.firstIndex(of: "["),
              let last = response.lastIndex(of: "]") else {
            throw AgentError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AgentError.malformedJSON("top-level not an array of objects")
            }
            var out: [(String, [String])] = []
            for obj in arr {
                guard let path = obj["portrait"] as? String, !path.isEmpty else { continue }
                let tags = (obj["tags"] as? [String]) ?? []
                out.append((path, tags))
            }
            return out
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.malformedJSON(error.localizedDescription)
        }
    }

    // MARK: - 工具

    /// 去掉 markdown `# 标题` + 前导空白。
    private static func stripFrontmatter(_ body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - PiAgent 事件流 Coordinator

private actor PTTCoordinator {
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
