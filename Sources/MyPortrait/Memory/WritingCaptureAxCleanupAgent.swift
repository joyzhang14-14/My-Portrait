import Foundation
import os.log

private let cleanupLog = Logger(subsystem: "com.myportrait.memory", category: "writing-ax-cleanup")

/// Pass 3 的 AX 文字补齐 —— **单一任务**:用 keystroke 修 AX 捕获的小瑕疵
/// (IME 拼音没上屏,如 "...什么dian" → "...什么店")。不转写、不切分、不分类、
/// 不增删 record —— 那些由确定性算法定死。专职单任务,LLM 更稳。
///
/// 输入:每条 record 的 {id, text, keystroke}。输出:{id: 修好的 text}。
/// 按 id 精确回填,LLM 漏某条 / 失败 → 该条保留原文(绝不丢)。
@MainActor
final class WritingCaptureAxCleanupAgent {

    struct Item: Encodable { let id: String; let text: String; let keystroke: String }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "sonnet", perRunTimeout: TimeInterval = 300) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    struct Fix: Sendable { let text: String; let confidence: Double }

    /// 返回 id → (修好的 text, LLM 判的 confidence)。只含 LLM 实际给出的;
    /// 调用方对缺的保留原文 + 默认 conf。
    func run(items: [Item]) async -> [String: Fix] {
        guard !items.isEmpty else { return [:] }
        let prompt = Self.buildPrompt(items: items)
        guard let agent = try? MemoryAgentFactory.make(provider: provider, model: model) else { return [:] }
        do { try await agent.start() } catch { return [:] }
        defer { agent.stop() }

        let coord = Coordinator()
        let consumer = Task { [events = agent.events] in
            for await ev in events { await coord.handle(ev) }
        }
        defer { consumer.cancel() }

        let reqID = UUID().uuidString
        await coord.startTurn(id: reqID)
        do { try agent.sendPrompt(prompt, id: reqID) } catch { return [:] }

        let collected: String = await withTaskGroup(of: String.self) { g in
            g.addTask { await coord.awaitTurn() }
            g.addTask {
                (try? await Task.sleep(nanoseconds: UInt64(self.perRunTimeout * 1_000_000_000))) ?? ()
                return ""
            }
            let r = await g.next() ?? ""
            g.cancelAll()
            return r
        }
        return Self.parse(collected)
    }

    static func buildPrompt(items: [Item]) -> String {
        var lines = [WritingCapturePrompts.axCleanup, ""]
        lines.append("items:")
        let enc = JSONEncoder()
        lines.append((try? enc.encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        return lines.joined(separator: "\n")
    }

    private struct Resp: Decodable {
        struct Fixed: Decodable { let id: String; let text: String; let confidence: Double? }
        let fixed: [Fixed]
    }

    static func parse(_ s: String) -> [String: Fix] {
        guard let json = WritingCapturePass3Agent.extractFirstBalancedJSONObject(s),
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(Resp.self, from: data)
        else { cleanupLog.warning("ax-cleanup parse fail"); return [:] }
        var out: [String: Fix] = [:]
        for f in r.fixed {
            let t = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                out[f.id] = Fix(text: f.text, confidence: min(1, max(0, f.confidence ?? 0.9)))
            }
        }
        return out
    }
}

// MARK: - 事件 coordinator(最小骨架)

private actor Coordinator {
    private var buffer = ""
    private var pending: CheckedContinuation<String, Never>?
    func startTurn(id: String) { buffer = ""; pending = nil }
    func awaitTurn() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in pending = c }
    }
    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d): buffer.append(d)
        case .assistantFinalText(let t): if buffer.isEmpty { buffer = t }
        case .agentEnd: if let p = pending { pending = nil; p.resume(returning: buffer) }
        case .error: if let p = pending { pending = nil; p.resume(returning: buffer) }
        default: break
        }
    }
}
