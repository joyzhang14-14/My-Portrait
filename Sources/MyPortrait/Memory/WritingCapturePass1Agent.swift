import Foundation
import os.log

private let pass1Log = Logger(subsystem: "com.myportrait.memory", category: "writing-pass1")

// MARK: - Pass 1 输出类型

/// Pass 1 输出的一个 context 段。沿时间轴标注用户在干啥。
struct WritingCaptureContextSegment: Codable, Sendable, Equatable {
    let startTs: Int64
    let endTs: Int64
    let app: String
    let url: String?
    let intentType: String          // "writing" | "search" | "reading" | "command" | "chat" | "other"
    let summary: String             // ≤ 100 chars

    enum CodingKeys: String, CodingKey {
        case startTs    = "start_ts"
        case endTs      = "end_ts"
        case app
        case url
        case intentType = "intent_type"
        case summary
    }
}

/// LLM 返回的顶层 JSON。
private struct Pass1Response: Codable {
    let timeline: [WritingCaptureContextSegment]
}

// MARK: - Pass 1 Agent

/// 写作采集 Pass 1 —— Context Timeline 提取。
///
/// 整天 OCR 帧 → LLM(默认 sonnet)→ 时间轴分段 [{start_ts, end_ts, app, url,
/// intent_type, summary}, ...]。Pass 3 拿这个 timeline 当 anchor 判合并 +
/// throwaway。
///
/// LLM 调用走 `PiAgent`(跟 Memory pipeline 同套路)。
///
/// 详见 `canvas-editor-capture-design-final.md` §3.3 Step 1 + §8.1。
@MainActor
final class WritingCapturePass1Agent {

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

    /// 一次 Pass 1 跑的完整产物 —— 给 worker / DB 存原始 prompt+raw 用。
    struct Output {
        let prompt: String
        let rawResponse: String
        let timeline: [WritingCaptureContextSegment]
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "sonnet", perRunTimeout: TimeInterval = 300) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 跑 Pass 1。
    /// - Parameters:
    ///   - ocrFrames: 时间窗内所有 raw_session 的 ocrFrames 拍平排好。
    ///   - typingEvents: 同时间窗的 typing_events,给 LLM 当"用户在哪段时间真打字"信号。
    ///   - keystrokes: 同时间窗的 keystroke_log,聚合成"key_activity per minute"塞进 prompt。
    /// - Returns: prompt + raw 响应 + 解析后的 timeline。
    func run(
        ocrFrames: [WritingCaptureOcrFrame],
        typingEvents: [TypingEvent] = [],
        keystrokes: [KeystrokeEntry] = []
    ) async throws -> Output {
        let prompt = Self.buildPrompt(
            ocrFrames: ocrFrames,
            typingEvents: typingEvents,
            keystrokes: keystrokes
        )

        // 空 OCR + 空 typing + 空 keystroke 短路 —— 没数据无法切 timeline
        if ocrFrames.isEmpty && typingEvents.isEmpty && keystrokes.isEmpty {
            return Output(prompt: prompt, rawResponse: "(short-circuited: no input data)", timeline: [])
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = Pass1Coordinator()
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
                throw BudgetExhaustedError(processor: "WritingCapturePass1Agent", message: err)
            }
            // 非 budget 错误(LLM 拒绝 / 鉴权失败 / 模型不存在 / 等):buffer
            // 通常是空,直接报出来才看得见。
            if collected.isEmpty {
                throw AgentError.agentSpawn("LLM error: \(err)")
            }
        }

        let timeline = try Self.parse(from: collected)
        return Output(prompt: prompt, rawResponse: collected, timeline: timeline)
    }

    // MARK: - Prompt

    /// 单帧 OCR text 默认 cap —— chrome filter 已砍 menubar / dock / 极小字体,
    /// 2000 字够 Pass 1 infer 上下文。原始数据完整保留在 frames 表里,
    /// 截断只在 LLM 输入这一层。
    ///
    /// 注意:per-session 决策权在 Worker —— 当 session AX 数 *10 < typing event 数
    /// (AX 对该 session 几乎没拿到数据),Worker 会传 cap=nil 放开此值。
    static let pass1OcrTextMaxChars = 2000

    /// Pass 1 最多喂给 LLM 多少帧。Pass 1 只要 "时段-意图" 时间轴,不需要
    /// 每帧。重写作日 5000+ 帧实测会撑爆 200K context。100 帧均匀采样足以
    /// 覆盖一天大部分时段,Step 0 的 10s + 50% Jaccard 已大幅减帧。
    static let pass1FrameCap = 100

    /// 把 ocrFrames 沿时间均匀采样到 ≤ `pass1FrameCap` 帧。
    /// 跨度大就大跨度采,小就全留。
    ///
    /// **不在这截字**:per-session cap 由 Worker 在 flatten 时按
    /// `axFrameCount * 10 < typingEvents.count` 决定(放开或 2000)。
    static func prepareFramesForPrompt(
        _ ocrFrames: [WritingCaptureOcrFrame]
    ) -> [WritingCaptureOcrFrame] {
        guard ocrFrames.count > pass1FrameCap else { return ocrFrames }
        // 均匀采样:第 i 帧 = 全集第 floor(i * total / cap) 个
        var sampled: [WritingCaptureOcrFrame] = []
        sampled.reserveCapacity(pass1FrameCap)
        let total = ocrFrames.count
        for i in 0..<pass1FrameCap {
            let idx = (i * total) / pass1FrameCap
            sampled.append(ocrFrames[idx])
        }
        return sampled
    }

    /// 拼 prompt:静态 system 指令 + user 数据块。
    /// 三块输入:ocr_frames(已 dedupe + 采样),typing_summary(轻量,
    /// 帮 LLM 知道哪段时间真在打字),keystroke_activity(per minute 聚合)。
    static func buildPrompt(
        ocrFrames: [WritingCaptureOcrFrame],
        typingEvents: [TypingEvent] = [],
        keystrokes: [KeystrokeEntry] = []
    ) -> String {
        var lines: [String] = [WritingCapturePrompts.pass1ContextTimeline]
        lines.append("")
        lines.append("ocr_frames:")
        let prepared = prepareFramesForPrompt(ocrFrames)
        if let data = try? JSONEncoder.pass1Encoder.encode(prepared),
           let json = String(data: data, encoding: .utf8) {
            lines.append(json)
        } else {
            lines.append("[]")
        }
        lines.append("")
        lines.append("typing_summary:")
        lines.append(encodeTypingSummary(typingEvents))
        lines.append("")
        lines.append("keystroke_activity:")
        lines.append(encodeKeystrokeActivity(keystrokes))
        return lines.joined(separator: "\n")
    }

    /// typing summary —— 给 LLM "哪段时间在某 app 真打了多少字" 信号。
    /// 不喂 text(那是 Pass 3 的事),只喂 {ts, app, url, chars}。
    static func encodeTypingSummary(_ events: [TypingEvent]) -> String {
        struct Row: Encodable {
            let ts: Int64
            let app: String
            let url: String?
            let chars: Int
        }
        let rows = events.map { e in
            Row(ts: e.startedAt, app: e.bundleId,
                url: e.url.isEmpty ? nil : e.url,
                chars: e.text.count)
        }
        return (try? JSONEncoder.pass1Encoder.encode(rows))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// keystroke activity —— 按 (1 分钟 bucket, app) 聚合 keystroke 数量。
    /// LLM 看这个能判:某分钟某 app 有多少键击 → 用户在干啥。
    /// 不喂 char(隐私 + 量大),只喂 count。
    static func encodeKeystrokeActivity(_ keys: [KeystrokeEntry]) -> String {
        struct Row: Encodable {
            let tsMinute: Int64
            let app: String
            let count: Int
            enum CodingKeys: String, CodingKey {
                case tsMinute = "ts_minute"
                case app, count
            }
        }
        // 按 (minute bucket, app) 聚合
        var bucket: [String: (Int64, String, Int)] = [:]
        for k in keys {
            let minute = (k.tsMs / 60_000) * 60_000
            let key = "\(minute)|\(k.bundleId)"
            if var v = bucket[key] {
                v.2 += 1
                bucket[key] = v
            } else {
                bucket[key] = (minute, k.bundleId, 1)
            }
        }
        let rows = bucket.values
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { Row(tsMinute: $0.0, app: $0.1, count: $0.2) }
        return (try? JSONEncoder.pass1Encoder.encode(rows))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    // MARK: - JSON 解析

    /// 从 LLM 响应里抓首个**括号平衡**的 JSON object,解析成 timeline。
    /// claude --print 偶发吐两条 result(响应变成 {A}{B}),不能用 last `}`。
    static func parse(from response: String) throws -> [WritingCaptureContextSegment] {
        guard let jsonStr = WritingCapturePass3Agent.extractFirstBalancedJSONObject(response) else {
            let preview = String(response.prefix(500))
            throw AgentError.malformedJSON("noJSONInResponse — raw[:500]=\(preview)")
        }
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            let parsed = try JSONDecoder.pass1Decoder.decode(Pass1Response.self, from: data)
            // 校验 intent_type 合法 + summary 长度
            let valid = Set(["writing", "search", "reading", "command", "chat", "other"])
            for seg in parsed.timeline {
                if !valid.contains(seg.intentType) {
                    throw AgentError.malformedJSON("invalid intent_type: \(seg.intentType)")
                }
            }
            return parsed.timeline
        } catch let e as AgentError {
            throw e
        } catch {
            // DEBUG: dump raw response on decode failure
            try? response.write(toFile: "/tmp/claude-agent-last-response.txt", atomically: false, encoding: .utf8)
            throw AgentError.malformedJSON("\(error.localizedDescription) — full response dumped /tmp/claude-agent-last-response.txt")
        }
    }
}

// MARK: - 内部 Coordinator

/// 串 PiAgent 事件流 —— 跟 PersonalityClusterAgent 的 ClusterCoordinator 同模板。
private actor Pass1Coordinator {
    private var buffer: String = ""
    private var currentID: String?
    private var pending: CheckedContinuation<String, Never>?
    private var lastError: String?

    func startTurn(id: String) {
        buffer = ""; currentID = id; pending = nil; lastError = nil
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

// MARK: - JSON coder helper

private extension JSONEncoder {
    /// 编码 ocrFrames 时用,跟 WritingCaptureOcrFrame 的 CodingKeys 一致。
    /// snake_case + 紧凑(节省 token)。
    static var pass1Encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        // 不开 prettyPrinted,省 token
        return e
    }
}

private extension JSONDecoder {
    /// 解码 Pass 1 响应 —— LLM 已经按指定 schema 输出 snake_case 字段。
    /// 直接靠 Codable 的 CodingKeys 映射,不开自动转换避免歧义。
    static var pass1Decoder: JSONDecoder {
        let d = JSONDecoder()
        // WritingCaptureContextSegment 自己声明了 CodingKeys
        return d
    }
}
