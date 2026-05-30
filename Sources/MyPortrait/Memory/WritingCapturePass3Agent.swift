import Foundation
import os.log

private let pass3Log = Logger(subsystem: "com.myportrait.memory", category: "writing-pass3")

// MARK: - Pass 3 输出类型

/// Pass 3 输出的一条 writing_record。
/// 字段跟 writing_records DB 表 schema 对齐(v20),但 id / prompt_id / raw_output
/// / worker_run_id / created_at 由 worker 落地时补,LLM 不输出。
struct WritingCaptureRecord: Codable, Sendable {
    let text: String
    let editLog: [EditEntry]

    /// 程序化构造(canvas window 合并后建一条 record 用)。
    init(
        text: String, editLog: [EditEntry], kind: String, source: String,
        confidence: Double, contextSummary: String?, app: String, url: String?,
        startTs: Int64, endTs: Int64,
        referenceTypingEventIds: [Int64], referenceFrameIds: [Int64],
        referenceKeystrokeRange: KeystrokeRange
    ) {
        self.text = text
        self.editLog = editLog
        self.kind = kind
        self.source = source
        self.confidence = confidence
        self.contextSummary = contextSummary
        self.app = app
        self.url = url
        self.startTs = startTs
        self.endTs = endTs
        self.referenceTypingEventIds = referenceTypingEventIds
        self.referenceFrameIds = referenceFrameIds
        self.referenceKeystrokeRange = referenceKeystrokeRange
    }

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

/// Pass 3 输出的一条 throwaway 记录。
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
/// `discarded` 字段从 Pass 4 接管后变成可选(老 prompt / 老缓存兼容)。
private struct Pass3Response: Codable {
    let records: [WritingCaptureRecord]
    let discarded: [WritingCaptureDiscarded]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([WritingCaptureRecord].self, forKey: .records)
        discarded = try c.decodeIfPresent([WritingCaptureDiscarded].self, forKey: .discarded) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case records
        case discarded
    }
}

// MARK: - Pass 3 Agent

/// 写作采集 Pass 3 —— 多源融合 → writing_records。
///
/// 输入:Pass 1 context_timeline + 整天 raw_sessions(按 session_id 嵌套打包)
/// + merge_candidates。
/// 输出:records[] + discarded[]。
///
/// LLM 调用走 PiAgent(跟 Memory pipeline 同套路)。
///
/// 详见 `canvas-editor-capture-design-final.md` §3.3 Step 2 + §8.2。
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

    /// 一次 Pass 3 跑的完整产物 —— 给 worker / DB 存原始 prompt+raw 用。
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

    /// 跑 Pass 3 —— **每个 (app, url) group 一次调用**(并发由 worker 在
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
        rawSessions: [WritingCaptureRawSession],
        includeAxText: Bool = true,
        userLanguages: [String] = [],
        userRejections: [UserRejectionRow] = []
    ) async throws -> Output {
        let prompt = Self.buildPrompt(
            contextTimeline: contextTimeline,
            groupApp: groupApp,
            groupUrl: groupUrl,
            rawSessions: rawSessions,
            includeAxText: includeAxText,
            userLanguages: userLanguages,
            userRejections: userRejections
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

        let (records, discarded) = try Self.parse(from: collected)
        return Output(prompt: prompt, rawResponse: collected,
                      records: records, discarded: discarded)
    }

    // MARK: - Prompt

    /// Pass 3 单帧 OCR 截多少字。Step 0 已经做 10s window + 50% Jaccard
    /// 减帧,Pass 3 不再砍字,canvas 路径用满 OCR(单 group ~50-150K chars,
    /// 仍在 200K context 内)。0 = 不截。
    static let pass3OcrTextMaxChars = 0

    /// Pass 3 单 session 最多塞几帧 OCR。同上,Step 0 已减帧,Pass 3 不再
    /// 采样。0 = 不限制。
    static let pass3OcrFramesPerSessionCap = 0

    /// Pass 3 单 session 最多塞多少 keystroke。
    static let pass3KeystrokesPerSessionCap = 100

    /// AX 路径 session 的判定阈值:typing_events.text 总长 > 这个,认为
    /// AX 数据完整,Pass 3 不需要 OCR 重建。
    static let pass3AxPathTypingThreshold = 50

    /// 把一个 raw_session 处理成 prompt 友好的 shape:
    /// - typing_events.text 总长 > `pass3AxPathTypingThreshold` 字 → AX 路径,
    ///   **完全丢 OCR**(typing_events.text 就是 ground truth,不需要 OCR 重建)
    /// - 否则(canvas 路径)→ OCR 截字 + 均匀采样
    /// keystroke 一律均匀采样。
    static func prepareSessionForPrompt(
        _ s: WritingCaptureRawSession, includeAxText: Bool = true
    ) -> WritingCaptureRawSession {
        let typingTotal = s.typingEvents.map { $0.text.count }.reduce(0, +)
        // 实验模式 --no-ax:强制走 canvas 路径,保留 OCR(否则 AX 路径会丢 OCR,
        // 加上后面 payload 把 typing 也清空 → LLM 啥都拿不到)
        let isAxPath = includeAxText && typingTotal > pass3AxPathTypingThreshold

        let trimmedFrames: [WritingCaptureOcrFrame]
        if isAxPath {
            trimmedFrames = []
        } else {
            // 截字:cap=0 表示不截
            let truncated: [WritingCaptureOcrFrame]
            if pass3OcrTextMaxChars > 0 {
                truncated = s.ocrFrames.map { f -> WritingCaptureOcrFrame in
                    WritingCaptureOcrFrame(
                        frameId: f.frameId,
                        startTs: f.startTs, endTs: f.endTs,
                        app: f.app, url: f.url,
                        text: String(f.text.prefix(pass3OcrTextMaxChars))
                    )
                }
            } else {
                truncated = s.ocrFrames
            }
            // 采样:cap=0 表示不采样
            trimmedFrames = pass3OcrFramesPerSessionCap > 0
                ? sampleEvenly(truncated, cap: pass3OcrFramesPerSessionCap)
                : truncated
        }
        let sampledKeys = sampleEvenly(s.keystrokes, cap: pass3KeystrokesPerSessionCap)
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
        rawSessions: [WritingCaptureRawSession],
        includeAxText: Bool = true,
        userLanguages: [String] = [],
        userRejections: [UserRejectionRow] = []
    ) -> String {
        let prepared = rawSessions.map {
            prepareSessionForPrompt($0, includeAxText: includeAxText)
        }.map {
            RawSessionPayload($0, includeAxText: includeAxText)
        }
        // 用户填的语言塞进 meta;Pass 3 prompt 据此判 record.text 是不是
        // 有意义文本(拼音残留 / 乱码 → discard)
        let langsStr = userLanguages.isEmpty ? nil : userLanguages.joined(separator: ", ")
        let meta: [String: String?] = [
            "app": groupApp,
            "url": groupUrl,
            "session_count": "\(rawSessions.count)",
            "ax_text_included": includeAxText ? "true" : "false",
            "user_languages": langsStr
        ]
        var lines: [String] = [WritingCapturePrompts.pass3Fusion]
        if !includeAxText {
            lines.append("")
            lines.append("⚠ EXPERIMENTAL MODE: AX text (typing_events with editor content) is NOT provided.")
            lines.append("Reconstruct what the user wrote using ONLY keystroke_text, keystroke_log, ocr_frames, app, url, and context_timeline. typing_events array will be empty.")
        }
        lines.append("")
        lines.append("context_timeline:")
        lines.append(encodeJSON(contextTimeline) ?? "[]")
        lines.append("")
        lines.append("group_meta:")
        lines.append(encodeJSONAny(meta) ?? "{}")
        lines.append("")
        if !userRejections.isEmpty {
            // 用户历史拒过的 record(最近 90 天 / 100 条),给 LLM 当 few-shot:
            // 看到新 candidate 跟这些"形态/类别"相似,就丢 discarded。
            let payload = userRejections.map { r -> [String: String?] in
                [
                    "text": String(r.text.prefix(300)),
                    "app": r.app,
                    "kind": r.kind,
                    "reason_category": r.reasonCategory,
                    "reason_text": r.reasonText
                ]
            }
            lines.append("user_rejected_examples:")
            lines.append((try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            lines.append("")
        }
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
            let parsed = try JSONDecoder().decode(Pass3Response.self, from: data)

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
    /// keystroke_text:把 keystrokes 的 char 按 ts 升序拼成一条字符串(跳过
    /// 修饰键-only / backspace / Cmd-X 等 shortcut)。**最强证据**:用户真实
    /// 敲了什么。AX/OCR 跟它对不上 → 大概率 paste/load/program-write。
    /// 注意:中文 IME 这里是 latin pinyin(CGEventKeyboardGetUnicodeString
    /// 限制),不是合成的汉字。
    let keystrokeText: String
    let keystrokeCount: Int
    let typingEvents: [TypingEventPayload]
    let keystrokeLog: [KeystrokePayload]
    let ocrFrames: [WritingCaptureOcrFrame]
    /// 自适应 chrome 词表(canvas session 才非空)。提示 LLM 检测编辑时忽略。
    let chromeTokens: [String]

    enum CodingKeys: String, CodingKey {
        case sessionId    = "session_id"
        case app
        case url
        case startTs      = "start_ts"
        case endTs        = "end_ts"
        case keystrokeText  = "keystroke_text"
        case keystrokeCount = "keystroke_count"
        case typingEvents   = "typing_events"
        case keystrokeLog   = "keystroke_log"
        case ocrFrames      = "ocr_frames"
        case chromeTokens   = "chrome_tokens"
    }

    init(_ s: WritingCaptureRawSession, includeAxText: Bool = true) {
        self.sessionId = s.id
        self.app = s.app
        self.url = s.url
        self.startTs = s.startTs
        self.endTs = s.endTs
        self.keystrokeText = Self.assembleKeystrokeText(s.keystrokes)
        self.keystrokeCount = s.keystrokes.count
        // AX-less 实验模式:typing_events 不喂(里面带 AX 抓到的编辑器文本 +
        // editLog),只剩 keystroke + OCR + 上下文。
        self.typingEvents = includeAxText ? s.typingEvents.map(TypingEventPayload.init) : []
        self.keystrokeLog = s.keystrokes.map(KeystrokePayload.init)
        self.ocrFrames = s.ocrFrames
        self.chromeTokens = s.chromeTokens
    }

    /// 把 keystrokes 拼成一条「真实敲了什么」的字符串。
    /// - 含修饰键(cmd/opt/ctrl)的 char 跳过(shortcut,不是输入)
    /// - backspace 不拼(它的删字效果用 `<BS>` 标记便于 LLM 看清)
    /// - 普通字符按 ts 升序串联
    /// 中文用户输入"你好"会得到拼音 "nihao"(IME 不暴露合成字)。
    static func assembleKeystrokeText(_ keys: [KeystrokeEntry]) -> String {
        var out = ""
        for k in keys.sorted(by: { $0.tsMs < $1.tsMs }) {
            // 任何带 cmd/opt/ctrl 的击键当 shortcut,不算输入字符
            let m = k.modifiers
            if (m & 0x01) != 0 || (m & 0x02) != 0 || (m & 0x04) != 0 { continue }
            if k.isBackspace != 0 {
                out += "<BS>"
                continue
            }
            if let c = k.char, !c.isEmpty {
                out += c
            }
        }
        return out
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
/// `shortcut` 派生自 (char, modifiers):⌘V/⌘X/⌘C/⌘Z/⌘⇧Z → paste/cut/copy/undo/redo。
/// 历史 keystroke_log 也能用,无需 DB 改动。
private struct KeystrokePayload: Encodable {
    let ts: Int64
    let char: String?
    let bs: Bool
    let mods: String?
    let shortcut: String?

    init(_ k: KeystrokeEntry) {
        self.ts = k.tsMs
        self.char = k.char
        self.bs = k.isBackspace != 0
        self.mods = KeystrokeEntry.modifiersString(k.modifiers)
        self.shortcut = Self.deriveShortcut(char: k.char, modifiers: k.modifiers)
    }

    /// (char, modifiers) → shortcut 名。char 大小写无关。
    /// modifiers: 0x01=cmd, 0x08=shift。
    static func deriveShortcut(char: String?, modifiers: Int) -> String? {
        guard let c = char?.lowercased(), modifiers & 0x01 != 0 else { return nil }
        let hasShift = modifiers & 0x08 != 0
        // 排除 cmd+opt / cmd+ctrl 复合(非 std shortcut)
        if modifiers & 0x02 != 0 || modifiers & 0x04 != 0 { return nil }
        switch c {
        case "v": return "paste"
        case "x": return "cut"
        case "c": return "copy"
        case "z": return hasShift ? "redo" : "undo"
        default:  return nil
        }
    }
}

// MARK: - 内部 Coordinator

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
