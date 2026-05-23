import Foundation
import os.log

private let pass2Log = Logger(subsystem: "com.myportrait.memory", category: "writing-pass2")

// MARK: - Pass 2 输出类型

/// Pass 2 输出的一条 writing_record。
/// 字段跟 writing_records DB 表 schema 对齐(v20),但 id / prompt_id / raw_output
/// / worker_run_id / created_at 由 worker 落地时补,LLM 不输出。
struct WritingCaptureRecord: Codable, Sendable {
    let text: String
    let editLog: [EditEntry]
    let source: String                       // ax_cleaned | canvas_fusion | merged
    let confidence: Double
    let contextSummary: String?              // ≤ 100 chars
    let app: String
    let url: String?
    let startTs: Int64
    let endTs: Int64
    let referenceTypingEventIds: [Int64]
    let referenceFrameIds: [Int64]
    let referenceKeystrokeRange: KeystrokeRange

    struct KeystrokeRange: Codable, Sendable, Equatable {
        let start: Int64
        let end: Int64
    }

    enum CodingKeys: String, CodingKey {
        case text
        case editLog                = "edit_log"
        case source
        case confidence
        case contextSummary         = "context_summary"
        case app
        case url
        case startTs                = "start_ts"
        case endTs                  = "end_ts"
        case referenceTypingEventIds = "reference_typing_event_ids"
        case referenceFrameIds      = "reference_frame_ids"
        case referenceKeystrokeRange = "reference_keystroke_range"
    }
}

/// Pass 2 输出的一条 throwaway 记录。
struct WritingCaptureDiscarded: Codable, Sendable, Equatable {
    let reason: String                       // "search_query: ..." | ...
    let sessionIds: [String]
    let preview: String

    enum CodingKeys: String, CodingKey {
        case reason
        case sessionIds = "session_ids"
        case preview
    }
}

/// LLM 返回的顶层 JSON。
private struct Pass2Response: Codable {
    let records: [WritingCaptureRecord]
    let discarded: [WritingCaptureDiscarded]
}

// MARK: - Pass 2 Agent

/// 写作采集 Pass 2 —— 多源融合 → writing_records。
///
/// 输入:Pass 1 context_timeline + 整天 raw_sessions(按 session_id 嵌套打包)
/// + merge_candidates。
/// 输出:records[] + discarded[]。
///
/// LLM 调用走 PiAgent(跟 Memory pipeline 同套路)。
///
/// 详见 `canvas-editor-capture-design-final.md` §3.3 Step 2 + §8.2。
@MainActor
final class WritingCapturePass2Agent {

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

    /// 一次 Pass 2 跑的完整产物 —— 给 worker / DB 存原始 prompt+raw 用。
    struct Output {
        let prompt: String
        let rawResponse: String
        let records: [WritingCaptureRecord]
        let discarded: [WritingCaptureDiscarded]
    }

    private let model: String
    private let perRunTimeout: TimeInterval

    init(model: String = "gpt-5.4-mini", perRunTimeout: TimeInterval = 240) {
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 跑 Pass 2。
    /// - Parameters:
    ///   - contextTimeline: Pass 1 输出
    ///   - rawSessions: Step 0 的 rawSessions(不含 throwaway)
    ///   - mergeCandidates: Step 0 算的合并候选集
    func run(
        contextTimeline: [WritingCaptureContextSegment],
        rawSessions: [WritingCaptureRawSession],
        mergeCandidates: [[String]]
    ) async throws -> Output {
        let prompt = Self.buildPrompt(
            contextTimeline: contextTimeline,
            rawSessions: rawSessions,
            mergeCandidates: mergeCandidates
        )

        // 空 session 短路 —— 整天没 raw,直接返回空。
        if rawSessions.isEmpty {
            return Output(
                prompt: prompt, rawResponse: "(short-circuited: no raw sessions)",
                records: [], discarded: []
            )
        }

        let agent = try PiAgent(model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = Pass2Coordinator()
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
            throw BudgetExhaustedError(processor: "WritingCapturePass2Agent", message: err)
        }

        let (records, discarded) = try Self.parse(from: collected)
        return Output(prompt: prompt, rawResponse: collected,
                      records: records, discarded: discarded)
    }

    // MARK: - Prompt

    /// 拼 prompt:静态 system 指令 + user 数据块(context_timeline / raw_sessions /
    /// merge_candidates)。
    static func buildPrompt(
        contextTimeline: [WritingCaptureContextSegment],
        rawSessions: [WritingCaptureRawSession],
        mergeCandidates: [[String]]
    ) -> String {
        var lines: [String] = [WritingCapturePrompts.pass2Fusion]
        lines.append("")
        lines.append("context_timeline:")
        lines.append(encodeJSON(contextTimeline) ?? "[]")
        lines.append("")
        lines.append("raw_sessions:")
        lines.append(encodeJSON(rawSessions.map(RawSessionPayload.init)) ?? "[]")
        lines.append("")
        lines.append("merge_candidates:")
        lines.append(encodeJSON(mergeCandidates) ?? "[]")
        return lines.joined(separator: "\n")
    }

    private static func encodeJSON<T: Encodable>(_ v: T) -> String? {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? enc.encode(v) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - JSON 解析

    /// 从 LLM 响应里抓 JSON object,解析成 (records, discarded)。
    /// 校验 source 合法 + discarded.reason 前缀合法。
    static func parse(
        from response: String
    ) throws -> (records: [WritingCaptureRecord], discarded: [WritingCaptureDiscarded]) {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}") else {
            throw AgentError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            let parsed = try JSONDecoder().decode(Pass2Response.self, from: data)

            // 校验 source 合法
            let validSources = Set(["ax_cleaned", "canvas_fusion", "merged"])
            for r in parsed.records {
                if !validSources.contains(r.source) {
                    throw AgentError.malformedJSON("invalid source: \(r.source)")
                }
                if r.confidence < 0 || r.confidence > 1 {
                    throw AgentError.malformedJSON("confidence out of range: \(r.confidence)")
                }
            }

            // 校验 discarded.reason 前缀合法
            let validPrefixes = [
                "search_query:", "short_response:", "shell_command:",
                "address_bar:", "filler_text:", "repeated_input:",
                "no_intent:", "other:"
            ]
            for d in parsed.discarded {
                if !validPrefixes.contains(where: { d.reason.hasPrefix($0) }) {
                    throw AgentError.malformedJSON(
                        "discarded.reason missing valid prefix: '\(d.reason.prefix(40))'")
                }
            }

            return (parsed.records, parsed.discarded)
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.malformedJSON(error.localizedDescription)
        }
    }
}

// MARK: - 给 prompt 用的 raw_session payload

/// 把 WritingCaptureRawSession 编码成 LLM prompt 用的 JSON shape。
/// 直接用 RawSession 不行 —— typingEvents / keystrokes 不是 Codable,且字段名
/// 要 snake_case + 选定子集。这里手工建一个 payload struct。
private struct RawSessionPayload: Encodable {
    let sessionId: String
    let app: String
    let url: String?
    let startTs: Int64
    let endTs: Int64
    let typingEvents: [TypingEventPayload]
    let keystrokeLog: [KeystrokePayload]
    let ocrFrames: [WritingCaptureOcrFrame]

    enum CodingKeys: String, CodingKey {
        case sessionId    = "session_id"
        case app
        case url
        case startTs      = "start_ts"
        case endTs        = "end_ts"
        case typingEvents = "typing_events"
        case keystrokeLog = "keystroke_log"
        case ocrFrames    = "ocr_frames"
    }

    init(_ s: WritingCaptureRawSession) {
        self.sessionId = s.id
        self.app = s.app
        self.url = s.url
        self.startTs = s.startTs
        self.endTs = s.endTs
        self.typingEvents = s.typingEvents.map(TypingEventPayload.init)
        self.keystrokeLog = s.keystrokes.map(KeystrokePayload.init)
        self.ocrFrames = s.ocrFrames
    }
}

/// 一条 typing_event 给 LLM 看的 shape。
/// id / ts(=startedAt)/ text / edit_log(已经是 JSON 字符串,直接透传)
private struct TypingEventPayload: Encodable {
    let id: Int64
    let ts: Int64                    // 用 startedAt
    let text: String
    let editLog: String              // raw JSON string from DB

    enum CodingKeys: String, CodingKey {
        case id, ts, text
        case editLog = "edit_log"
    }

    init(_ e: TypingEvent) {
        self.id = e.id ?? -1
        self.ts = e.startedAt
        self.text = e.text
        self.editLog = e.editLog
    }
}

/// 一条 keystroke 给 LLM 看的 shape。
private struct KeystrokePayload: Encodable {
    let ts: Int64
    let char: String?
    let bs: Bool

    init(_ k: KeystrokeEntry) {
        self.ts = k.tsMs
        self.char = k.char
        self.bs = k.isBackspace != 0
    }
}

// MARK: - 内部 Coordinator

private actor Pass2Coordinator {
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
