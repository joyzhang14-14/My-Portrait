import Foundation
import os.log

private let ssAgentLog = Logger(subsystem: "com.myportrait.memory", category: "writing-style-agent")

/// writing_style 提炼 Agent —— 把一批 records + 现存 portrait/writing_style/
/// 文件喂 LLM,返回 [WritingStyleDraft] 决策列表。
///
/// LLM 走 PiAgent / ClaudeCodeAgent(跟 PortraitDistiller 同套路)。
@MainActor
final class WritingStyleAgent {

    enum AgentError: LocalizedError {
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

    struct Output {
        let prompt: String
        let rawResponse: String
        let drafts: [WritingStyleDraft]
    }

    /// 现存 portrait/writing_style/<slug>.md 的轻量摘要 —— 喂 LLM 当 "已有
    /// 条目" 让它判 update vs create。
    struct ExistingEntry: Sendable {
        let slug: String
        let title: String
        let bodyExcerpt: String       // 截到 ~400 字
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode,
         model: String = "sonnet",
         perRunTimeout: TimeInterval = 300) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    func run(
        records: [WritingStyleRecordInput],
        existing: [ExistingEntry]
    ) async throws -> Output {
        let prompt = Self.buildPrompt(records: records, existing: existing)

        if records.isEmpty {
            return Output(prompt: prompt, rawResponse: "(no records)", drafts: [])
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = WritingStyleCoordinator()
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

        if let err = await coordinator.consumeError() {
            if BudgetSignal.isExhausted(err) {
                throw BudgetExhaustedError(processor: "WritingStyleAgent", message: err)
            }
            if collected.isEmpty {
                throw AgentError.agentSpawn("LLM error: \(err)")
            }
        }

        let drafts = try Self.parse(from: collected)
        return Output(prompt: prompt, rawResponse: collected, drafts: drafts)
    }

    // MARK: - Prompt

    /// 单条 record.text 最多喂多少字 —— 长 long_form 文档不必整段进 prompt,
    /// 1500 字够 LLM 看出风格。截断只在 LLM 输入这一层,DB 原文不变。
    nonisolated static let recordTextMaxChars = 1500
    /// 单条 record.edit_log 最多保留多少 entry —— 删改密集的 long_form 一次
    /// 上千个 entry,LLM 看不出 signal,取头尾各 30 个即可。
    nonisolated static let editLogMaxEntries = 60

    /// 现存条目 body 最多展示多少字给 LLM 当上下文。
    nonisolated static let existingBodyExcerptChars = 400

    static func buildPrompt(
        records: [WritingStyleRecordInput],
        existing: [ExistingEntry]
    ) -> String {
        var lines: [String] = [WritingStylePrompts.distill]
        lines.append("")
        lines.append("EXISTING ENTRIES (under portrait/writing_style/, may be empty):")
        if existing.isEmpty {
            lines.append("(none yet)")
        } else {
            for e in existing {
                lines.append("---")
                lines.append("[slug=\(e.slug)] \(e.title)")
                lines.append(e.bodyExcerpt)
            }
            lines.append("---")
        }
        lines.append("")
        lines.append("WRITING RECORDS (\(records.count) total):")
        for r in records {
            lines.append("---")
            lines.append("[id=\(r.id)] app=\(r.app)\(r.url.map { " url=\($0)" } ?? "") kind=\(r.kind) ts=\(r.startTs)")
            if let cs = r.contextSummary, !cs.isEmpty {
                lines.append("context: \(cs)")
            }
            // OCR snippet 已删 —— context_summary 是 writing capture Pass 3
            // LLM 生成的语境,已经描述当时在干什么,distiller 直接信它就够。
            lines.append("text:")
            lines.append(truncate(r.text, max: recordTextMaxChars))
            lines.append("edit_log:")
            lines.append(truncateEditLog(r.editLog, maxEntries: editLogMaxEntries))
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…[truncated]"
    }

    /// edit_log 是 JSON 字符串。如果 entry 数 > max,只留头尾各一半 +
    /// 中间放个 "…N entries omitted…" 占位。失败就原样返回。
    private static func truncateEditLog(_ json: String, maxEntries: Int) -> String {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return json
        }
        if arr.count <= maxEntries { return json }
        let half = maxEntries / 2
        let head = Array(arr.prefix(half))
        let tail = Array(arr.suffix(maxEntries - half))
        var merged: [Any] = head
        merged.append([
            "kind": "_omitted_",
            "text": "…\(arr.count - maxEntries) entries omitted…",
            "ts": 0
        ] as [String: Any])
        merged.append(contentsOf: tail)
        guard let out = try? JSONSerialization.data(withJSONObject: merged),
              let s = String(data: out, encoding: .utf8) else { return json }
        return s
    }

    // MARK: - Parse

    /// LLM 顶层返回 JSON array(不是 wrapping object)。先抽第一个平衡 array。
    /// 套用 Pass3 的 extractFirstBalancedJSONObject 思路,改成 `[ ]`。
    static func parse(from response: String) throws -> [WritingStyleDraft] {
        guard let jsonStr = extractFirstBalancedJSONArray(response) else {
            let preview = String(response.prefix(500))
            throw AgentError.malformedJSON("noJSONInResponse — raw[:500]=\(preview)")
        }
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            let parsed = try JSONDecoder().decode([RawDecision].self, from: data)
            return try parsed.map { raw in
                guard let act = WritingStyleDraft.Action(rawValue: raw.action) else {
                    throw AgentError.malformedJSON("invalid action: \(raw.action)")
                }
                let slugClean = raw.slug.lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !slugClean.isEmpty, slugClean.count <= 60 else {
                    throw AgentError.malformedJSON("invalid slug: \(raw.slug)")
                }
                return WritingStyleDraft(
                    action: act,
                    slug: slugClean,
                    title: raw.title,
                    body: raw.body,
                    sourceRecordIds: raw.source_record_ids ?? [],
                    existingSlug: raw.existing_slug
                )
            }
        } catch let e as AgentError {
            throw e
        } catch {
            try? response.write(toFile: "/tmp/writing-style-last-response.txt",
                                atomically: false, encoding: .utf8)
            throw AgentError.malformedJSON("\(error.localizedDescription) — full response dumped /tmp/writing-style-last-response.txt")
        }
    }

    private struct RawDecision: Decodable {
        let action: String
        let slug: String
        let title: String
        let body: String
        let source_record_ids: [Int64]?
        let existing_slug: String?
    }

    /// 从 LLM 响应里抽第一个**括号平衡 + string-aware** 的 JSON array。
    /// 跟 WritingCapturePass3Agent.extractFirstBalancedJSONObject 同套路,
    /// 改成方括号。
    static func extractFirstBalancedJSONArray(_ s: String) -> String? {
        let chars = Array(s)
        var i = 0
        while i < chars.count && chars[i] != "[" { i += 1 }
        guard i < chars.count else { return nil }
        let start = i
        var depth = 0
        var inString = false
        var escape = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "[" { depth += 1 }
                else if c == "]" {
                    depth -= 1
                    if depth == 0 { return String(chars[start...i]) }
                }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Coordinator

private actor WritingStyleCoordinator {
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
