import Foundation
import os.log

private let pass3Log = Logger(subsystem: "com.myportrait.memory", category: "writing-pass3")

// MARK: - Pass 3 输入 / 输出类型

/// Pass 3 收到的一条 candidate record(已由 Worker 从 Pass 2 records 加上
/// 每条的 keystroke / AX 证据)。
struct WritingCapturePass3InputRecord: Encodable, Sendable {
    /// Worker 临时分配的 record_id —— Pass 2 的 records 数组里没显式 id,
    /// Worker fanout 时按 "g<group>_r<idx>" 形态生成,Pass 3 用此引用回。
    let recordId: String
    let text: String
    let kind: String
    let source: String
    let app: String
    let url: String?
    let startTs: Int64
    let endTs: Int64

    /// 用户在 [startTs, endTs] 真实敲键拼成的字符串(跳过 modifier-only /
    /// shortcut)。
    let keystrokeText: String
    /// 同窗口的 raw 键击总数。
    let keystrokeCount: Int
    /// 同窗口里 typing_events.text 拼接(空字符串表示没有 AX)。
    let typingEventsText: String
    /// 同窗口里出现过 ⌘V > 100 字 的 paste 事件。
    let hasPasteEvent: Bool
    /// 同窗口里出现过 ⌘X 的 cut 事件(用户剪了自己的内容)。
    let hasCutEvent: Bool
    /// keystroke 形态像 IME pinyin / 假名:大量 ASCII 小写字母 + 偶发数字
    /// (IME 候选选择)+ record.text 含 CJK。
    let imeLikely: Bool

    enum CodingKeys: String, CodingKey {
        case recordId           = "record_id"
        case text, kind, source, app, url
        case startTs            = "start_ts"
        case endTs              = "end_ts"
        case keystrokeText      = "keystroke_text"
        case keystrokeCount     = "keystroke_count"
        case typingEventsText   = "typing_events_text"
        case hasPasteEvent      = "has_paste_event"
        case hasCutEvent        = "has_cut_event"
        case imeLikely          = "ime_likely"
    }
}

/// Pass 3 输出的丢弃条目。
struct WritingCapturePass3Discarded: Decodable, Sendable, Equatable {
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
private struct Pass3Response: Decodable {
    let kept: [String]
    let discarded: [WritingCapturePass3Discarded]
}

// MARK: - Pass 3 Agent

/// 写作采集 Pass 3 —— 最终丢弃阀门。
///
/// 输入:Pass 2 该 group 的 candidate records + 每条的 keystroke / AX 证据。
/// 输出:`kept`(留下的 record_id 集) + `discarded`(LLM 给的原因)。
///
/// 整套 fanout 模式跟 Pass 2 一致(per-group 并发),provider/model 跟随
/// `resolvedProviderLight` / `resolvedModelLight`(用户切 provider 时一起切)。
@MainActor
final class WritingCapturePass3Agent {

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
        let discarded: [WritingCapturePass3Discarded]
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "sonnet", perRunTimeout: TimeInterval = 600) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 跑 Pass 3 —— **每个 (app, url) group 一次调用**(并发由 worker 在
    /// 外层 fan out)。
    func run(records: [WritingCapturePass3InputRecord]) async throws -> Output {
        let prompt = Self.buildPrompt(records: records)

        // 空输入短路 —— Pass 2 该组没出 record,无需调用 LLM。
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

        let coordinator = Pass3Coordinator()
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
                throw BudgetExhaustedError(processor: "WritingCapturePass3Agent", message: err)
            }
            if collected.isEmpty {
                throw AgentError.agentSpawn("LLM error: \(err)")
            }
        }

        let (kept, discarded) = try Self.parse(from: collected, allIds: records.map(\.recordId))
        return Output(prompt: prompt, rawResponse: collected, kept: kept, discarded: discarded)
    }

    // MARK: - Prompt

    static func buildPrompt(records: [WritingCapturePass3InputRecord]) -> String {
        var lines: [String] = [WritingCapturePrompts.pass3KeystrokeSupport]
        lines.append("")
        lines.append("records:")
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
    ) throws -> (kept: Set<String>, discarded: [WritingCapturePass3Discarded]) {
        guard let jsonStr = WritingCapturePass2Agent.extractFirstBalancedJSONObject(response) else {
            let preview = String(response.prefix(500))
            throw AgentError.malformedJSON("noJSONInResponse — raw[:500]=\(preview)")
        }
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        let parsed: Pass3Response
        do {
            parsed = try JSONDecoder().decode(Pass3Response.self, from: data)
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

// MARK: - 事件 coordinator(跟 Pass 2 同款最小骨架)

private actor Pass3Coordinator {
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
