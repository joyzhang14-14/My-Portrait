import Foundation
import os.log

private let ocrTagLog = Logger(subsystem: "com.myportrait.memory", category: "ocr-to-tags")

/// 三源候选里"OCR"那一源:给一天的屏幕 OCR 文本拼一坨,LLM 抽 0-5 个
/// personality tag。evidence 用 "<date>" —— 那天的 OCR 看到了这个模式。
@MainActor
final class OCRToTagsAgent {

    enum AgentError: LocalizedError {
        case agentSpawn(String), agentTimeout, noJSONInResponse, malformedJSON(String)
        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):    return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:         return "LLM did not respond within timeout"
            case .noJSONInResponse:     return "LLM response contained no JSON object"
            case .malformedJSON(let m): return "LLM JSON parse failed: \(m)"
            }
        }
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .chatgpt, model: String = "gpt-5.4", perRunTimeout: TimeInterval = 90) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 给一天拉所有 frame id,聚合 OCR 文本(最多 30KB),LLM 抽 tag。
    /// 当天没 frame / OCR 全噪声 → 返回 []。
    func extract(forDay day: Date,
                 timeline: TimelineDB,
                 maxFrames: Int = 5000,
                 maxOCRChars: Int = 30_000) async throws -> [String] {
        try await extractWithRaw(forDay: day, timeline: timeline,
                                 maxFrames: maxFrames, maxOCRChars: maxOCRChars).tags
    }

    func extractWithRaw(
        forDay day: Date,
        timeline: TimelineDB,
        maxFrames: Int = 5000,
        maxOCRChars: Int = 30_000
    ) async throws -> (prompt: String, raw: String, tags: [String]) {
        let frames = timeline.frames(on: day, limit: maxFrames)
        let ids = frames.map(\.id)
        let ocrText = timeline.ocrText(forFrameIds: ids, maxChars: maxOCRChars)
        let dayStr = Self.formatDay(PortraitFile.truncateToDay(day))
        let prompt = Self.buildPrompt(date: dayStr, ocrText: ocrText)

        if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (prompt: prompt, raw: "(short-circuited: no OCR text)", tags: [])
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = OTTCoordinator()
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
            throw BudgetExhaustedError(processor: "OCRToTagsAgent", message: err)
        }

        let tags = try Self.parseTags(from: collected)
        return (prompt: prompt, raw: collected, tags: tags)
    }

    // MARK: - Prompt

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func formatDay(_ d: Date) -> String { dayFmt.string(from: d) }

    private static func buildPrompt(date: String, ocrText: String) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(ConfigStore.shared.current.personalInfo)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(MemoryPrompts.ocrToTags)
        lines.append("")
        lines.append("DATE: \(date)")
        lines.append("OCR (deduped, truncated):")
        lines.append(ocrText)
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    private static func parseTags(from response: String) throws -> [String] {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}") else {
            throw AgentError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError.malformedJSON("top-level not an object")
            }
            let tags = (obj["tags"] as? [String]) ?? []
            return tags
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.malformedJSON(error.localizedDescription)
        }
    }
}

// MARK: - PiAgent 事件流 Coordinator

private actor OTTCoordinator {
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
