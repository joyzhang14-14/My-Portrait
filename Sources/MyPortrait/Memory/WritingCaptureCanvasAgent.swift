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

        // 合并:edits 排序去重
        var allEdits: [EditEntry] = results.flatMap { wr in
            wr.edits.map { EditEntry(ts: $0.ts, kind: $0.kind == "delete" ? "delete" : "commit", text: $0.text) }
        }
        allEdits.sort { $0.ts < $1.ts }
        allEdits = Self.dedupEdits(allEdits)
        // body:各窗只看到文档一个滚动片段(标题在早窗、结尾在晚窗)。取最长单窗会
        // 丢标题/结尾 —— 用一个 LLM 把各窗 body 拼成整篇(并集、去重叠、不发明)。
        // 单窗 / 合并失败 → 退回最长单窗(绝不空)。
        let bodies = results.map(\.bodyText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let longest = bodies.max(by: { $0.count < $1.count }) ?? ""
        let body: String
        if bodies.count <= 1 {
            body = longest
        } else {
            body = await Self.mergeBodies(bodies, provider: provider, model: model,
                                          timeout: perWindowTimeout) ?? longest
        }

        guard !body.isEmpty else {
            return WritingCapturePass3Agent.Output(
                prompt: "(canvas: empty body)", rawResponse: "", records: [], discarded: [])
        }

        // 击键覆盖闸门(跟 AX 分支同款)：OCR 重建出一大段文字,但本 session 里几乎
        // 没有击键 = 屏上显示的**别人内容**(AI 回复 / 文章 / 页面),不是用户写的 → 丢。
        // 真文章是一个字一个字敲的(击键 ≥ 字数);AI 回复零敲(几十击键产不出几百字)。
        // 实测:Notes 1917字/2890击键、Safari 2770字/5082击键(留);systempref AI 回复
        // 几百字/47击键(丢)。短文(≤20字)不卡,跟 AX 分支保持一致。
        let kc = session.keystrokes.filter { ($0.modifiers & 0x07) == 0 }.count
        if body.count > 20 && kc < body.count / 4 {
            canvasLog.info("canvas \(groupApp, privacy: .public): dropped — \(kc) keys vs \(body.count) chars (on-screen non-user content)")
            return WritingCapturePass3Agent.Output(
                prompt: "(canvas: dropped, keystroke coverage \(kc)/\(body.count))",
                rawResponse: "", records: [], discarded: [])
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

    // MARK: - 多窗 body 合并

    /// 把多窗 body 拼成整篇文档(并集去重叠,不发明)。失败 / 超时 → nil(调用方
    /// 退回最长单窗)。一篇文档一次调用,token / 延迟可控。
    static func mergeBodies(
        _ bodies: [String], provider: Provider, model: String, timeout: TimeInterval
    ) async -> String? {
        var lines = [WritingCapturePrompts.canvasMerge, "", "fragments:"]
        for (i, b) in bodies.enumerated() {
            lines.append("--- fragment \(i + 1) ---")
            lines.append(b)
        }
        let prompt = lines.joined(separator: "\n")
        guard let agent = try? MemoryAgentFactory.make(provider: provider, model: model) else { return nil }
        do { try await agent.start() } catch { return nil }
        defer { agent.stop() }

        let coord = CanvasWindowCoordinator()
        let consumer = Task { [events = agent.events] in
            for await ev in events { await coord.handle(ev) }
        }
        defer { consumer.cancel() }

        let reqID = UUID().uuidString
        await coord.startTurn(id: reqID)
        do { try agent.sendPrompt(prompt, id: reqID) } catch { return nil }

        let collected: String = await withTaskGroup(of: String.self) { g in
            g.addTask { await coord.awaitTurn() }
            g.addTask {
                (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) ?? ()
                return ""
            }
            let r = await g.next() ?? ""
            g.cancelAll()
            return r
        }
        guard let json = WritingCapturePass3Agent.extractFirstBalancedJSONObject(collected),
              let data = json.data(using: .utf8) else { return nil }
        struct Resp: Decodable {
            let bodyText: String?
            enum CodingKeys: String, CodingKey { case bodyText = "body_text" }
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data),
              let t = r.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
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
