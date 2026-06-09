import Foundation
import os.log

private let pass2Log = Logger(subsystem: "com.myportrait.memory", category: "writing-pass2")

/// Pass 2 —— 切割 + AX 真伪判断(judgment only,不转写)。
///
/// 只跑**非 canvas session**(有 AX typing_events 的)。对一个 session:
///   1. 把 typing_events 切成单元(一条消息 / 一篇连续编辑)
///   2. 判每条 typing_event 文本本身有没有意义(garbage 直接 block,不下传)
///
/// 输出喂给 Worker,重建成"一单元一 mini-session",再交 Pass 3 转写。
/// 判断活,轻量模型(haiku / 本地)可胜任。
@MainActor
final class WritingCapturePass2Agent {

    struct Result: Sendable {
        /// session 级:真内容在 AX 还是 OCR。"ocr" → 整 session 走重建路径。
        let primarySource: String   // "ax" | "ocr"
        /// primary=ax 时的单元(每个 = 一组 typing_event id)。
        let units: [[Int64]]
        /// 被 block 的 typing_event id + 原因(autofill / 垃圾)。
        let dropped: [(id: Int64, reason: String)]
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "haiku", perRunTimeout: TimeInterval = 300) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    /// 判一个 session。typing_events 为空 → 直接返回空(调用方应跳过)。
    /// LLM 失败 → fallback:每条 event 各自一单元,全留(不丢用户数据)。
    func run(session s: WritingCaptureRawSession) async throws -> Result {
        let events = s.typingEvents
        guard !events.isEmpty else { return Result(primarySource: "ax", units: [], dropped: []) }
        let ids = events.compactMap { $0.id }
        // fallback:LLM 失败 → 当 ax,每条各自一单元,全留(不丢用户数据)。
        let fallback = Result(primarySource: "ax", units: ids.map { [$0] }, dropped: [])

        let prompt = Self.buildPrompt(session: s)

        guard let agent = try? MemoryAgentFactory.make(provider: provider, model: model) else {
            return fallback
        }
        do { try await agent.start() }
        catch { pass2Log.warning("pass2 spawn fail, fallback"); return fallback }
        defer { agent.stop() }

        let coord = Pass2Coordinator()
        let consumer = Task { [events = agent.events] in
            for await ev in events { await coord.handle(ev) }
        }
        defer { consumer.cancel() }

        let reqID = UUID().uuidString
        await coord.startTurn(id: reqID)
        do { try agent.sendPrompt(prompt, id: reqID) }
        catch { return fallback }

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

        guard let parsed = Self.parse(collected, validIds: Set(ids)) else {
            pass2Log.warning("pass2 parse fail, fallback (keep all as singletons)")
            return fallback
        }
        return parsed
    }

    // MARK: - Prompt

    static func buildPrompt(session s: WritingCaptureRawSession) -> String {
        struct EventPayload: Encodable { let id: Int64; let ts: Int64; let text: String }
        let events = s.typingEvents.compactMap { e -> EventPayload? in
            guard let id = e.id else { return nil }
            return EventPayload(id: id, ts: e.startedAt, text: e.text)
        }
        var lines = [WritingCapturePrompts.pass2Segment, ""]
        let meta: [String: String?] = ["app": s.app, "url": s.url]
        lines.append("session_meta:")
        lines.append((try? JSONSerialization.data(withJSONObject: meta.compactMapValues { $0 }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        lines.append("")
        lines.append("typing_events:")
        let enc = JSONEncoder()
        lines.append((try? enc.encode(events)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        lines.append("")
        // keystroke 裁判:autofill = 有意义文本但 ~0 击键。
        lines.append("keystroke_text: " + Self.assembleKeystrokeText(s.keystrokes))
        lines.append("keystroke_count: \(s.keystrokes.count)")
        lines.append("")
        // OCR 摘要(交叉验证),截断防爆 prompt
        let ocrExcerpt = s.ocrFrames.map { $0.text }.joined(separator: " ⏎ ")
        lines.append("ocr_excerpt: " + String(ocrExcerpt.prefix(2000)))
        return lines.joined(separator: "\n")
    }

    /// keystroke → "用户真敲了什么" 串(跳过 modifier-only / shortcut / backspace
    /// 拼 <BS>)。跟 Pass 3 同规则。
    static func assembleKeystrokeText(_ keys: [KeystrokeEntry]) -> String {
        var out = ""
        for k in keys.sorted(by: { $0.tsMs < $1.tsMs }) {
            let m = k.modifiers
            if (m & 0x01) != 0 || (m & 0x02) != 0 || (m & 0x04) != 0 { continue }
            if k.isBackspace != 0 { out += "<BS>"; continue }
            if let c = k.char, !c.isEmpty {
                out += (c == "\n" || c == "\r") ? "<CR>" : c   // Return/submit 标记,给切分判断用
            }
        }
        return String(out.prefix(2000))
    }

    // MARK: - 解析

    private struct Response: Decodable {
        struct RUnit: Decodable { let eventIds: [Int64]
            enum CodingKeys: String, CodingKey { case eventIds = "event_ids" } }
        struct Drop: Decodable { let eventId: Int64; let reason: String?
            enum CodingKeys: String, CodingKey { case eventId = "event_id"; case reason } }
        let primarySource: String?
        let units: [RUnit]?
        let dropped: [Drop]?
        enum CodingKeys: String, CodingKey {
            case primarySource = "primary_source"; case units; case dropped }
    }

    /// 解析 + 完整性补救。primary=ocr → units 空(OCR 路径整 session 重建)。
    /// primary=ax → 漏网 id 默认各自成单元保留(不丢用户数据)。
    static func parse(_ response: String, validIds: Set<Int64>) -> Result? {
        guard let json = WritingCapturePass3Agent.extractFirstBalancedJSONObject(response),
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let primary = r.primarySource == "ocr" ? "ocr" : "ax"
        let droppedIds = Set((r.dropped ?? []).map(\.eventId)).intersection(validIds)
        let dropped = (r.dropped ?? []).filter { droppedIds.contains($0.eventId) }
            .map { (id: $0.eventId, reason: $0.reason ?? "") }
        if primary == "ocr" {
            return Result(primarySource: "ocr", units: [], dropped: dropped)
        }
        var seen = Set<Int64>()
        var units: [[Int64]] = []
        for u in (r.units ?? []) {
            let kept = u.eventIds.filter { validIds.contains($0) && !droppedIds.contains($0) && !seen.contains($0) }
            kept.forEach { seen.insert($0) }
            if !kept.isEmpty { units.append(kept) }
        }
        for id in validIds where !seen.contains(id) && !droppedIds.contains(id) {
            units.append([id]); seen.insert(id)
        }
        return Result(primarySource: "ax", units: units, dropped: dropped)
    }
}

private actor Pass2Coordinator {
    private var buffer = ""
    private var pending: CheckedContinuation<String, Never>?
    func startTurn(id: String) { buffer = ""; pending = nil }
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
