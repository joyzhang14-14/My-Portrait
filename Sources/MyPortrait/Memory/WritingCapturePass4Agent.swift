import Foundation
import os.log

private let pass4Log = Logger(subsystem: "com.myportrait.memory", category: "writing-pass4")

// MARK: - Pass 4 输入 / 输出类型

/// Pass 4 收到的一条 candidate record —— 纯内容审查,不带 keystroke。
/// keystroke 对应度的把关在算法层(edit_log 过滤 / canvas 零对应)已做完,
/// Pass 4 只看内容语义 + context + 历史拒绝 + 规则,判断该不该留。
struct WritingCapturePass4InputRecord: Encodable, Sendable {
    /// Worker 临时分配的 record_id —— "g<group>_r<idx>" 形态,Pass 4 用此引用回。
    let recordId: String
    let text: String
    let kind: String
    let source: String
    let app: String
    let url: String?
    /// 这条 record 时间窗内用户的物理击键数(±10s,非快捷键)。> 0 = 用户**亲手
    /// 敲的**(不是屏上显示的页面/标题文字);判"是不是用户自己的字"的硬证据。
    let keystrokeCount: Int
    /// Pass 1 给这条 record 的场景背景(用户在哪、在干啥)。
    let contextSummary: String?
    /// **仅 canvas_fusion 记录带**:用户在这段里实际敲出的原始字符(IME 级 —— CJK
    /// 是拼音/罗马字键,不是最终汉字)。canvas 是屏幕 OCR 重建,可能误抓屏上别人的
    /// 内容(歌词/UI/AI 回复);给 Pass 4 判「这段击键能不能产出这段文本」。非 canvas
    /// 为 nil(text 本来就来自击键、上游已把过关,省 token)。
    let keystrokeText: String?

    enum CodingKeys: String, CodingKey {
        case recordId       = "record_id"
        case text, kind, source, app, url
        case keystrokeCount = "keystroke_count"
        case contextSummary = "context_summary"
        case keystrokeText  = "keystroke_text"
    }
}

/// Pass 4 输出的丢弃条目。
struct WritingCapturePass4Discarded: Decodable, Sendable, Equatable {
    let recordId: String
    let reason: String
    let preview: String

    enum CodingKeys: String, CodingKey {
        case recordId   = "record_id"
        case reason
        case preview
    }

    init(recordId: String, reason: String, preview: String) {
        self.recordId = recordId
        self.reason = reason
        self.preview = preview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordId = try c.decode(String.self, forKey: .recordId)
        reason = try c.decode(String.self, forKey: .reason)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }
}

/// LLM 返回的顶层 JSON。
private struct Pass4Response: Decodable {
    let kept: [String]
    let discarded: [WritingCapturePass4Discarded]
}

// MARK: - Pass 4 Agent

/// 写作采集 Pass 4 —— 最终丢弃阀门。
///
/// 输入:Pass 3 该 group 的 candidate records + 每条的 keystroke / AX 证据。
/// 输出:`kept`(留下的 record_id 集) + `discarded`(LLM 给的原因)。
///
/// 整套 fanout 模式跟 Pass 3 一致(per-group 并发),provider/model 跟随
/// `resolvedProviderLight` / `resolvedModelLight`(用户切 provider 时一起切)。
@MainActor
final class WritingCapturePass4Agent {

    enum AgentError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)
        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):    return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:         return "LLM did not respond within timeout"
            case .noJSONInResponse:     return "LLM response contained no JSON object"
            case .malformedJSON(let m): return "LLM JSON parse failed: \(m)"
            }
        }
    }

    struct Output {
        let prompt: String
        let rawResponse: String
        let kept: Set<String>
        let discarded: [WritingCapturePass4Discarded]
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "sonnet", perRunTimeout: TimeInterval = 600) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 跑 Pass 4 —— **每个 (app, url) group 一次调用**(并发由 worker 在
    /// 外层 fan out)。`userRejections`:用户历史拒绝的 record,当 few-shot。
    func run(
        records: [WritingCapturePass4InputRecord],
        userRejections: [UserRejectionRow] = []
    ) async throws -> Output {
        // pass4-1 分派:整组都是 canvas_fusion(屏幕 OCR 重建)→ 走 canvas 专属 prompt
        // (只判击键能否支撑文本);否则走通用内容审查。group 是 (app,url) 级、source
        // 同质,故按整组判;主 prompt 完全不动、不被撑长。
        let isCanvasGroup = !records.isEmpty && records.allSatisfy { $0.source == "canvas_fusion" }
        let prompt = isCanvasGroup
            ? Self.buildCanvasPrompt(records: records)
            : Self.buildPrompt(records: records, userRejections: userRejections)

        // 空输入短路 —— Pass 3 该组没出 record,无需调用 LLM。
        if records.isEmpty {
            return Output(
                prompt: prompt, rawResponse: "(short-circuited: no records)",
                kept: [], discarded: []
            )
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = Pass4Coordinator()
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
                throw BudgetExhaustedError(processor: "WritingCapturePass4Agent", message: err)
            }
            if collected.isEmpty {
                throw AgentError.agentSpawn("LLM error: \(err)")
            }
        }

        let (kept, discarded) = try Self.parse(from: collected, allIds: records.map(\.recordId))
        return Output(prompt: prompt, rawResponse: collected, kept: kept, discarded: discarded)
    }

    // MARK: - Prompt

    static func buildPrompt(
        records: [WritingCapturePass4InputRecord],
        userRejections: [UserRejectionRow] = []
    ) -> String {
        var lines: [String] = [WritingCapturePrompts.pass4ContentReview]
        lines.append("")
        if !userRejections.isEmpty {
            // 用户历史拒过的 record(few-shot):看到新 candidate 跟这些形态/类别
            // 相似就丢。
            let payload = userRejections.map { r -> [String: String?] in
                ["text": String(r.text.prefix(300)), "app": r.app,
                 "kind": r.kind, "reason": r.reasonText ?? r.reasonCategory]
            }
            lines.append("user_rejected_examples:")
            lines.append((try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            lines.append("")
        }
        lines.append("records:")
        lines.append(encodeJSON(records) ?? "[]")
        return lines.joined(separator: "\n")
    }

    /// pass4-1:canvas_fusion 专属 prompt —— 只判「击键(keystroke_text)能否支撑这段
    /// 文本」。短、独立,不掺进通用内容审查 prompt。
    static func buildCanvasPrompt(records: [WritingCapturePass4InputRecord]) -> String {
        var lines: [String] = [WritingCapturePrompts.pass4CanvasSupport, "", "records:"]
        lines.append(encodeJSON(records) ?? "[]")
        return lines.joined(separator: "\n")
    }

    private static func encodeJSON<T: Encodable>(_ v: T) -> String? {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .useDefaultKeys  // 显式 CodingKey 已 snake_case
        guard let data = try? enc.encode(v) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - JSON 解析

    /// 容错 + 完整性补救:
    ///   - LLM 漏 id → 默认 kept(保守:不丢用户东西)
    ///   - id 同时在 kept + discarded → 取 discarded(LLM 明确说丢)
    ///   - 不存在的 id → 忽略
    static func parse(
        from response: String,
        allIds: [String]
    ) throws -> (kept: Set<String>, discarded: [WritingCapturePass4Discarded]) {
        guard let jsonStr = WritingCapturePass3Agent.extractFirstBalancedJSONObject(response) else {
            let preview = String(response.prefix(500))
            throw AgentError.malformedJSON("noJSONInResponse — raw[:500]=\(preview)")
        }
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        let parsed: Pass4Response
        do {
            parsed = try JSONDecoder().decode(Pass4Response.self, from: data)
        } catch {
            try? response.write(
                toFile: "/tmp/claude-agent-last-response.txt",
                atomically: false, encoding: .utf8
            )
            throw AgentError.malformedJSON(
                "\(error.localizedDescription) — full response dumped /tmp/claude-agent-last-response.txt"
            )
        }
        let allIdSet = Set(allIds)
        let discardedSet = Set(parsed.discarded.map(\.recordId))
        var kept = Set<String>()
        for id in allIdSet {
            if discardedSet.contains(id) { continue }       // LLM 明确丢
            kept.insert(id)                                  // 默认留下
        }
        let filteredDiscarded = parsed.discarded.filter { allIdSet.contains($0.recordId) }
        return (kept, filteredDiscarded)
    }
}

// MARK: - 事件 coordinator(跟 Pass 3 同款最小骨架)

private actor Pass4Coordinator {
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
