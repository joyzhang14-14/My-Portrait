import Foundation
import os.log

private let canvasLog = Logger(subsystem: "com.myportrait.memory", category: "writing-canvas")

/// Canvas 文档(Google Docs 等,AX 拿不到正文)的 Pass 3 替代路径。
///
/// 一个 canvas group = 一篇文档,但快照可能很多(整天编辑)。一次性喂给一个
/// LLM 会撑爆 prompt 卡死。改成:**按 token 预算把快照切成重叠窗口,每窗一个
/// subagent 并发跑,结果合并成一条 record**。
///
/// - 每窗 prompt 受 `windowCharBudget` 限制 → 永不卡、快
/// - 窗间重叠 1 帧 → 跨边界编辑不漏
/// - 合并:edits 按 ts 排序去重;最终 body 取各窗最长
///
/// 输出 `WritingCapturePass3Agent.Output`(records:[一条]),无缝接入现有
/// Pass 3 → Pass 4 → staging 流程。
@MainActor
final class WritingCaptureCanvasAgent {

    /// 一窗最多多少字(快照文本累加)。超过封窗。25k ≈ 安全且快。
    static let windowCharBudget = 25_000
    /// 一窗最多几张快照(再多 LLM 也看不细)。
    static let windowMaxFrames = 6

    private let provider: Provider
    private let model: String
    private let perWindowTimeout: TimeInterval

    init(provider: Provider = .claudeCode, model: String = "sonnet", perWindowTimeout: TimeInterval = 420) {
        self.provider = provider
        self.model = model
        self.perWindowTimeout = perWindowTimeout
    }

    /// 一窗 subagent 的返回。
    private struct WindowResult: Decodable, Sendable {
        let edits: [EditFragment]
        let bodyText: String
        struct EditFragment: Decodable, Sendable {
            let ts: Int64
            let kind: String
            let text: String
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                ts = (try? c.decode(Int64.self, forKey: .ts)) ?? 0
                kind = (try? c.decode(String.self, forKey: .kind)) ?? "commit"
                text = (try? c.decode(String.self, forKey: .text)) ?? ""
            }
            enum CodingKeys: String, CodingKey { case ts, kind, text }
        }
        enum CodingKeys: String, CodingKey { case edits; case bodyText = "body_text" }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            edits = (try? c.decode([EditFragment].self, forKey: .edits)) ?? []
            bodyText = (try? c.decode(String.self, forKey: .bodyText)) ?? ""
        }
    }

    /// 跑一个 canvas group → 一条 record(包在 Pass3 Output 里)。
    func run(
        groupApp: String,
        groupUrl: String?,
        session: WritingCaptureRawSession,
        contextSummary: String?
    ) async throws -> WritingCapturePass3Agent.Output {
        let snaps = session.ocrFrames.sorted { $0.startTs < $1.startTs }
        guard !snaps.isEmpty else {
            return WritingCapturePass3Agent.Output(
                prompt: "(canvas: no frames)", rawResponse: "", records: [], discarded: [])
        }

        let windows = Self.splitWindows(snaps)
        canvasLog.info("canvas \(groupApp, privacy: .public): \(snaps.count) snaps → \(windows.count) windows")

        // 各窗并发跑(限 5 道闸,防一篇文档瞬间 spawn 太多 LLM 子进程)。
        let chromeTokens = session.chromeTokens
        var results: [WindowResult] = []
        let concurrency = 5
        var next = 0
        await withTaskGroup(of: WindowResult?.self) { tg in
            var inFlight = 0
            while inFlight < concurrency && next < windows.count {
                let win = windows[next]; next += 1
                tg.addTask { try? await self.runWindow(snaps: win, chromeTokens: chromeTokens) }
                inFlight += 1
            }
            while let r = await tg.next() {
                if let r { results.append(r) }
                inFlight -= 1
                if next < windows.count {
                    let win = windows[next]; next += 1
                    tg.addTask { try? await self.runWindow(snaps: win, chromeTokens: chromeTokens) }
                    inFlight += 1
                }
            }
        }

        // 合并:edits 排序去重;body 取最长
        var allEdits: [EditEntry] = results.flatMap { wr in
            wr.edits.map { EditEntry(ts: $0.ts, kind: $0.kind == "delete" ? "delete" : "commit", text: $0.text) }
        }
        allEdits.sort { $0.ts < $1.ts }
        allEdits = Self.dedupEdits(allEdits)
        let body = results.map(\.bodyText).max(by: { $0.count < $1.count }) ?? ""

        guard !body.isEmpty else {
            return WritingCapturePass3Agent.Output(
                prompt: "(canvas: empty body)", rawResponse: "", records: [], discarded: [])
        }

        let record = WritingCaptureRecord(
            text: body,
            editLog: allEdits,
            kind: body.count >= 100 ? "long_form" : "other",
            source: "canvas_fusion",
            confidence: 0.8,
            contextSummary: contextSummary,
            app: groupApp,
            url: groupUrl,
            startTs: snaps.first!.startTs,
            endTs: snaps.last!.endTs,
            referenceTypingEventIds: [],
            referenceFrameIds: snaps.map(\.frameId),
            referenceKeystrokeRange: WritingCaptureRecord.KeystrokeRange(start: nil, end: nil)
        )
        return WritingCapturePass3Agent.Output(
            prompt: "(canvas window fanout: \(windows.count) windows)",
            rawResponse: "",
            records: [record],
            discarded: []
        )
    }

    // MARK: - 窗口切分

    /// 按 token 预算 + 帧数上限切窗,窗间重叠 1 帧。
    static func splitWindows(_ snaps: [WritingCaptureOcrFrame]) -> [[WritingCaptureOcrFrame]] {
        guard snaps.count > 1 else { return snaps.isEmpty ? [] : [snaps] }
        var windows: [[WritingCaptureOcrFrame]] = []
        var cur: [WritingCaptureOcrFrame] = []
        var curChars = 0
        for f in snaps {
            if !cur.isEmpty &&
                (curChars + f.text.count > windowCharBudget || cur.count >= windowMaxFrames) {
                windows.append(cur)
                cur = [cur.last!]              // 重叠上一窗最后一帧
                curChars = cur[0].text.count
            }
            cur.append(f)
            curChars += f.text.count
        }
        // 余下:>1 帧才成窗(单帧无法 diff);若全程没切过窗,这就是唯一一窗。
        if cur.count > 1 || windows.isEmpty { windows.append(cur) }
        return windows
    }

    /// 去重:相邻同 kind + text 高度相似(包含关系)合一条。
    static func dedupEdits(_ edits: [EditEntry]) -> [EditEntry] {
        var out: [EditEntry] = []
        for e in edits {
            if let last = out.last, last.kind == e.kind,
               (last.text.contains(e.text) || e.text.contains(last.text)) {
                // 保留更长的
                if e.text.count > last.text.count { out[out.count - 1] = e }
                continue
            }
            out.append(e)
        }
        return out
    }

    // MARK: - 一窗 LLM 调用

    private func runWindow(
        snaps: [WritingCaptureOcrFrame], chromeTokens: [String]
    ) async throws -> WindowResult? {
        let prompt = Self.buildWindowPrompt(snaps: snaps, chromeTokens: chromeTokens)
        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        try await agent.start()
        defer { agent.stop() }

        let coord = CanvasWindowCoordinator()
        let consumer = Task { [events = agent.events] in
            for await ev in events { await coord.handle(ev) }
        }
        defer { consumer.cancel() }

        let reqID = UUID().uuidString
        await coord.startTurn(id: reqID)
        try agent.sendPrompt(prompt, id: reqID)

        let collected: String = try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask { await coord.awaitTurn() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.perWindowTimeout * 1_000_000_000))
                return ""    // 超时返回空,这窗丢弃,不阻塞其他窗
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
        guard let json = WritingCapturePass3Agent.extractFirstBalancedJSONObject(collected),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowResult.self, from: data)
    }

    static func buildWindowPrompt(
        snaps: [WritingCaptureOcrFrame], chromeTokens: [String]
    ) -> String {
        var lines = [WritingCapturePrompts.canvasWindow, ""]
        lines.append("chrome_tokens:")
        let ctData = try? JSONSerialization.data(withJSONObject: chromeTokens)
        lines.append(ctData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        lines.append("")
        lines.append("snapshots:")
        let payload = snaps.map { ["ts": $0.startTs, "text": $0.text] as [String: Any] }
        let snData = try? JSONSerialization.data(withJSONObject: payload)
        lines.append(snData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        return lines.joined(separator: "\n")
    }
}

private actor CanvasWindowCoordinator {
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
