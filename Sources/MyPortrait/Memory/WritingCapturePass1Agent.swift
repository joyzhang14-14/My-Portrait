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
/// 整天 OCR 帧 → LLM(gpt-5.4-mini)→ 时间轴分段 [{start_ts, end_ts, app, url,
/// intent_type, summary}, ...]。Pass 2 拿这个 timeline 当 anchor 判合并 +
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

    private let model: String
    private let perRunTimeout: TimeInterval

    init(model: String = "gpt-5.4-mini", perRunTimeout: TimeInterval = 120) {
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 跑 Pass 1。
    /// - Parameter ocrFrames: 一天里所有 raw_session 的 ocrFrames 拍平拼起来,按 ts 排好。
    /// - Returns: prompt + raw 响应 + 解析后的 timeline。
    func run(ocrFrames: [WritingCaptureOcrFrame]) async throws -> Output {
        let prompt = Self.buildPrompt(ocrFrames: ocrFrames)

        // 空 OCR 短路 —— 整天没 OCR 数据,直接返回空 timeline。
        if ocrFrames.isEmpty {
            return Output(prompt: prompt, rawResponse: "(short-circuited: no ocr frames)", timeline: [])
        }

        let agent = try PiAgent(model: model)
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

        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "WritingCapturePass1Agent", message: err)
        }

        let timeline = try Self.parse(from: collected)
        return Output(prompt: prompt, rawResponse: collected, timeline: timeline)
    }

    // MARK: - Prompt

    /// 拼 prompt:静态 system 指令 + user 数据块。
    static func buildPrompt(ocrFrames: [WritingCaptureOcrFrame]) -> String {
        var lines: [String] = [WritingCapturePrompts.pass1ContextTimeline]
        lines.append("")
        lines.append("ocr_frames:")
        // 直接 JSON 序列化数组 —— LLM 见过这种 format。
        if let data = try? JSONEncoder.pass1Encoder.encode(ocrFrames),
           let json = String(data: data, encoding: .utf8) {
            lines.append(json)
        } else {
            lines.append("[]")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    /// 从 LLM 响应里抓 JSON object,解析成 timeline。
    static func parse(from response: String) throws -> [WritingCaptureContextSegment] {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}") else {
            throw AgentError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
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
            throw AgentError.malformedJSON(error.localizedDescription)
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
