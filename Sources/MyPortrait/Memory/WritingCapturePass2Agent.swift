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

    // LLM 偶发对 delete 类目省略 text 字段 → 自定义 decode 容忍。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        // edit_log:逐条 decode,缺 text 默认 "" 兜底
        var rawArray = try c.nestedUnkeyedContainer(forKey: .editLog)
        var entries: [EditEntry] = []
        while !rawArray.isAtEnd {
            let raw = try rawArray.decode(EditEntryTolerant.self)
            entries.append(EditEntry(ts: raw.ts, kind: raw.kind, text: raw.text ?? ""))
        }
        editLog = entries
        kind = try c.decode(String.self, forKey: .kind)
        source = try c.decode(String.self, forKey: .source)
        confidence = try c.decode(Double.self, forKey: .confidence)
        contextSummary = try c.decodeIfPresent(String.self, forKey: .contextSummary)
        app = try c.decode(String.self, forKey: .app)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        startTs = try c.decode(Int64.self, forKey: .startTs)
        endTs = try c.decode(Int64.self, forKey: .endTs)
        referenceTypingEventIds = try c.decode([Int64].self, forKey: .referenceTypingEventIds)
        referenceFrameIds = try c.decode([Int64].self, forKey: .referenceFrameIds)
        // 老 record 偶发整段缺 reference_keystroke_range —— 默认 null/null
        if let r = try c.decodeIfPresent(KeystrokeRange.self, forKey: .referenceKeystrokeRange) {
            referenceKeystrokeRange = r
        } else {
            referenceKeystrokeRange = KeystrokeRange(start: nil, end: nil)
        }
    }

    private struct EditEntryTolerant: Decodable {
        let ts: Int64
        let kind: String
        let text: String?
    }

    let kind: String                         // long_form | short_form | other (v26)
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
        // canvas_fusion 等无 keystroke 的 record,LLM 可能输出 null —— 容忍
        let start: Int64?
        let end: Int64?
    }

    enum CodingKeys: String, CodingKey {
        case text
        case editLog                = "edit_log"
        case kind
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
    let reason: String
    let sessionIds: [String]
    let preview: String                      // LLM 偶发省略 → "" 兜底

    enum CodingKeys: String, CodingKey {
        case reason
        case sessionIds = "session_ids"
        case preview
    }

    init(reason: String, sessionIds: [String], preview: String) {
        self.reason = reason
        self.sessionIds = sessionIds
        self.preview = preview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decode(String.self, forKey: .reason)
        sessionIds = try c.decode([String].self, forKey: .sessionIds)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
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

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "sonnet", perRunTimeout: TimeInterval = 1200) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 跑 Pass 2 —— **每个 (app, url) group 一次调用**(并发由 worker 在
    /// 外层 fan out)。LLM 自己看 group 内 sessions 怎么分 record / 哪些丢。
    /// - Parameters:
    ///   - contextTimeline: Pass 1 整天的 timeline(给 LLM 看上下文)
    ///   - groupApp: 这个 group 的 app(bundle_id)
    ///   - groupUrl: 这个 group 的 url(可空)
    ///   - rawSessions: 这个 group 里的所有 sessions(已按 app+url 分组)
    func run(
        contextTimeline: [WritingCaptureContextSegment],
        groupApp: String,
        groupUrl: String?,
        rawSessions: [WritingCaptureRawSession]
    ) async throws -> Output {
        let prompt = Self.buildPrompt(
            contextTimeline: contextTimeline,
            groupApp: groupApp,
            groupUrl: groupUrl,
            rawSessions: rawSessions
        )

        // 空 session 短路 —— 整天没 raw,直接返回空。
        if rawSessions.isEmpty {
            return Output(
                prompt: prompt, rawResponse: "(short-circuited: no raw sessions)",
                records: [], discarded: []
            )
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
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

        if let err = await coordinator.consumeError() {
            if BudgetSignal.isExhausted(err) {
                throw BudgetExhaustedError(processor: "WritingCapturePass2Agent", message: err)
            }
            if collected.isEmpty {
                throw AgentError.agentSpawn("LLM error: \(err)")
            }
        }

        let (records, discarded) = try Self.parse(from: collected)
        return Output(prompt: prompt, rawResponse: collected,
                      records: records, discarded: discarded)
    }

    // MARK: - Prompt

    /// Pass 2 单帧 OCR 截多少字。原始数据完整保留在 frames 表,截断只在
    /// LLM 输入这一层。300 字够 LLM 看出 session 内容意图。
    static let pass2OcrTextMaxChars = 200

    /// Pass 2 单 session 最多塞几帧 OCR。重写作日 60+ sessions 全塞会
    /// 撑爆 200K context,10 帧 / session 是经验值。
    static let pass2OcrFramesPerSessionCap = 10

    /// Pass 2 单 session 最多塞多少 keystroke。
    static let pass2KeystrokesPerSessionCap = 100

    /// AX 路径 session 的判定阈值:typing_events.text 总长 > 这个,认为
    /// AX 数据完整,Pass 2 不需要 OCR 重建。
    static let pass2AxPathTypingThreshold = 50

    /// 把一个 raw_session 处理成 prompt 友好的 shape:
    /// - typing_events.text 总长 > `pass2AxPathTypingThreshold` 字 → AX 路径,
    ///   **完全丢 OCR**(typing_events.text 就是 ground truth,不需要 OCR 重建)
    /// - 否则(canvas 路径)→ OCR 截字 + 均匀采样
    /// keystroke 一律均匀采样。
    static func prepareSessionForPrompt(_ s: WritingCaptureRawSession) -> WritingCaptureRawSession {
        let typingTotal = s.typingEvents.map { $0.text.count }.reduce(0, +)
        let isAxPath = typingTotal > pass2AxPathTypingThreshold

        let trimmedFrames: [WritingCaptureOcrFrame]
        if isAxPath {
            trimmedFrames = []
        } else {
            let truncated = s.ocrFrames.map { f -> WritingCaptureOcrFrame in
                WritingCaptureOcrFrame(
                    frameId: f.frameId,
                    startTs: f.startTs, endTs: f.endTs,
                    app: f.app, url: f.url,
                    text: String(f.text.prefix(pass2OcrTextMaxChars))
                )
            }
            trimmedFrames = sampleEvenly(truncated, cap: pass2OcrFramesPerSessionCap)
        }
        let sampledKeys = sampleEvenly(s.keystrokes, cap: pass2KeystrokesPerSessionCap)
        return WritingCaptureRawSession(
            id: s.id, app: s.app, url: s.url,
            startTs: s.startTs, endTs: s.endTs,
            typingEvents: s.typingEvents,
            keystrokes: sampledKeys,
            ocrFrames: trimmedFrames,
            maxContentChars: s.maxContentChars
        )
    }

    /// 通用均匀采样:`[A B C D E ...]` cap=3 → 第 0, ⌊1×n/3⌋, ⌊2×n/3⌋ 个。
    private static func sampleEvenly<T>(_ xs: [T], cap: Int) -> [T] {
        guard xs.count > cap else { return xs }
        var out: [T] = []
        out.reserveCapacity(cap)
        let total = xs.count
        for i in 0..<cap { out.append(xs[(i * total) / cap]) }
        return out
    }

    /// 拼 per-group prompt:静态 system 指令 + context_timeline + group_meta +
    /// raw_sessions(per-session prep:OCR 截字 + keystroke 采样)。
    /// 不做 noise 过滤 —— LLM 自己判。
    static func buildPrompt(
        contextTimeline: [WritingCaptureContextSegment],
        groupApp: String,
        groupUrl: String?,
        rawSessions: [WritingCaptureRawSession]
    ) -> String {
        let prepared = rawSessions.map(prepareSessionForPrompt).map(RawSessionPayload.init)
        let meta: [String: String?] = [
            "app": groupApp,
            "url": groupUrl,
            "session_count": "\(rawSessions.count)"
        ]
        var lines: [String] = [WritingCapturePrompts.pass2Fusion]
        lines.append("")
        lines.append("context_timeline:")
        lines.append(encodeJSON(contextTimeline) ?? "[]")
        lines.append("")
        lines.append("group_meta:")
        lines.append(encodeJSONAny(meta) ?? "{}")
        lines.append("")
        lines.append("raw_sessions:")
        lines.append(encodeJSON(prepared) ?? "[]")
        return lines.joined(separator: "\n")
    }

    /// `Encodable` 对 `[String: String?]` 通过 JSONSerialization 编码避开
    /// Codable 的 Optional 编码歧义。
    private static func encodeJSONAny(_ v: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
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
    /// 从响应文本里抽出**第一个**完整 JSON object(括号平衡 + string-aware),
    /// 忽略后面可能跟着的第二个对象(claude --print 偶发吐两条 result)。
    /// 返回 nil 表示找不到任何完整对象。
    static func extractFirstBalancedJSONObject(_ s: String) -> String? {
        let chars = Array(s)
        var i = 0
        // 找第一个 {
        while i < chars.count && chars[i] != "{" { i += 1 }
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
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(chars[start...i]) }
                }
            }
            i += 1
        }
        return nil
    }

    static func parse(
        from response: String
    ) throws -> (records: [WritingCaptureRecord], discarded: [WritingCaptureDiscarded]) {
        // 找首个**括号平衡**的 JSON object,而不是 first { ~ last }。
        // claude --print 偶发吐两条 result 消息,响应变成 {A}{B},last } 抓
        // 到第二个对象末尾,整体不是合法 JSON。
        guard let jsonStr = Self.extractFirstBalancedJSONObject(response) else {
            let preview = String(response.prefix(500))
            throw AgentError.malformedJSON("noJSONInResponse — raw[:500]=\(preview)")
        }
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            let parsed = try JSONDecoder().decode(Pass2Response.self, from: data)

            // 校验 source / kind 合法 + confidence 范围
            let validSources = Set(["ax_cleaned", "canvas_fusion", "merged"])
            let validKinds = Set(["long_form", "short_form", "other"])
            for r in parsed.records {
                if !validSources.contains(r.source) {
                    throw AgentError.malformedJSON("invalid source: \(r.source)")
                }
                if !validKinds.contains(r.kind) {
                    throw AgentError.malformedJSON("invalid kind: \(r.kind)")
                }
                if r.confidence < 0 || r.confidence > 1 {
                    throw AgentError.malformedJSON("confidence out of range: \(r.confidence)")
                }
            }
            // discarded.reason 现在自由文本(LLM 描述),不再强制 enum 前缀。

            return (parsed.records, parsed.discarded)
        } catch let e as AgentError {
            throw e
        } catch {
            // DEBUG: dump raw response on decode failure
            try? response.write(toFile: "/tmp/claude-agent-last-response.txt", atomically: false, encoding: .utf8)
            throw AgentError.malformedJSON("\(error.localizedDescription) — full response dumped /tmp/claude-agent-last-response.txt")
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
/// `mods` 是修饰键人类可读字符串("cmd" / "cmd+shift" / nil)—— DB 里是 packed
/// Int(见 KeystrokeEntry.modifiersString),给 LLM 时翻译成字符串可读。
private struct KeystrokePayload: Encodable {
    let ts: Int64
    let char: String?
    let bs: Bool
    let mods: String?

    init(_ k: KeystrokeEntry) {
        self.ts = k.tsMs
        self.char = k.char
        self.bs = k.isBackspace != 0
        self.mods = KeystrokeEntry.modifiersString(k.modifiers)
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
