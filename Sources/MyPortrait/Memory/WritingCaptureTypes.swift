import Foundation

/// 写作采集 worker 的内存数据类型 —— Step 0 → Pass 1/2 之间传递的载体。
/// 不入 DB,只是运行时对象。详见 `canvas-editor-capture-design-final.md` §3.3。

// MARK: - 原始 OCR 帧(预压缩前)

/// 从 `frames` 表读出来的一帧,Step 0 dedupe 之前的形态。
struct WritingCaptureRawOcr: Sendable, Equatable {
    let id: Int64
    let tsMs: Int64
    let app: String
    let url: String?
    let windowTitle: String?
    let text: String
    /// "ocr" / "ax" / "unknown" / nil. 决定 chrome filter 是否生效 +
    /// session AX/typing 比例统计。
    let textSource: String?

    init(
        id: Int64, tsMs: Int64, app: String, url: String?,
        windowTitle: String? = nil, text: String,
        textSource: String? = nil
    ) {
        self.id = id
        self.tsMs = tsMs
        self.app = app
        self.url = url
        self.windowTitle = windowTitle
        self.text = text
        self.textSource = textSource
    }
}

// MARK: - 预压缩后的 OCR 帧

/// Step 0 Jaccard dedupe 后的 OCR 帧。`start_ts ~ end_ts` 是合并的时间区间
/// (从多个 raw 帧合来,文本相似度 > 50%,见 WritingCaptureStep0.ocrJaccardThreshold)。
struct WritingCaptureOcrFrame: Sendable, Equatable, Codable {
    let frameId: Int64        // 保留最早那帧的 id 当代表
    let startTs: Int64
    let endTs: Int64
    let app: String
    let url: String?
    let windowTitle: String?
    let text: String

    init(
        frameId: Int64, startTs: Int64, endTs: Int64,
        app: String, url: String?, windowTitle: String? = nil, text: String
    ) {
        self.frameId = frameId
        self.startTs = startTs
        self.endTs = endTs
        self.app = app
        self.url = url
        self.windowTitle = windowTitle
        self.text = text
    }
}

// MARK: - 一个 raw_session

/// 写作采集的基本处理单元 —— (app, url, 时间窗) 内的多源数据聚合。
/// Step 0 切分输出,Pass 3 喂给 LLM 当原料。
///
/// 注:不实现 Equatable —— TypingEvent / KeystrokeEntry 没有 Equatable
/// (避开 Codable 字段对比的歧义)。测试时按需对比具体字段。
struct WritingCaptureRawSession: Sendable {
    /// "sess_<6 char hex>" 形态。Step 0 生成,跨 session 唯一。
    let id: String
    let app: String
    let url: String?
    let startTs: Int64
    let endTs: Int64
    let typingEvents: [TypingEvent]
    let keystrokes: [KeystrokeEntry]
    /// OCR 帧 —— 已 Jaccard dedupe。
    let ocrFrames: [WritingCaptureOcrFrame]
    /// session 内最长文本长度(用于 throwaway 过滤的字数判定)。
    /// = max(typing_events.text 拼起来 长度, max ocr_frame.text 长度)
    let maxContentChars: Int
    /// session 内 **dedupe 前**的 OCR raw 帧里 text_source == "ax" 的数量。
    /// 给 Pass 1 决定单帧 cap 用 —— AX 稀缺(ax*10 < typingEvents 数)时
    /// OCR 是唯一文本来源,放开 cap。
    let axFrameCount: Int
    /// 自适应 chrome 词表(跨帧频率 >85% 的 token)。**纯 hint** —— 只在 OCR
    /// 路径喂给 CanvasAgent,让它检测正文编辑时忽略这些 UI 词。不参与路由。
    let chromeTokens: [String]
    /// 路由:"ax"(信 typing_events,走 Pass3Agent 清洗)| "ocr"(真内容在屏幕,
    /// 走 CanvasAgent 重建)。Step 0 给默认值,Pass 2 用三源裁决覆盖。
    let route: String

    init(
        id: String, app: String, url: String?,
        startTs: Int64, endTs: Int64,
        typingEvents: [TypingEvent], keystrokes: [KeystrokeEntry],
        ocrFrames: [WritingCaptureOcrFrame], maxContentChars: Int,
        axFrameCount: Int = 0,
        chromeTokens: [String] = [],
        route: String = "ax"
    ) {
        self.id = id
        self.app = app
        self.url = url
        self.startTs = startTs
        self.endTs = endTs
        self.typingEvents = typingEvents
        self.keystrokes = keystrokes
        self.ocrFrames = ocrFrames
        self.maxContentChars = maxContentChars
        self.axFrameCount = axFrameCount
        self.chromeTokens = chromeTokens
        self.route = route
    }
}

// MARK: - Step 0 输出

/// Step 0 算法预压缩的产物 —— 给 Pass 1 / Pass 3 用。
struct WritingCaptureStep0Output: Sendable {
    /// 切分 + dedupe 完的 sessions(throwaway 已过滤掉)。
    let rawSessions: [WritingCaptureRawSession]
    /// throwaway 丢掉的 session(还保留 id + 短预览给 discarded 列表用)。
    let throwawaySessions: [WritingCaptureThrowaway]
    /// Pass 3 合并候选集 —— 每组 = 同 app + 同 url + 间隔 < 30min 的 session_id 数组。
    /// 单 session 也会自己成一组([session_id])。
    let mergeCandidates: [[String]]
}

/// throwaway 短 session 的占位记录 —— 给 Pass 3 的 discarded 列表当材料。
struct WritingCaptureThrowaway: Sendable, Equatable {
    let id: String
    let app: String
    let url: String?
    let startTs: Int64
    let endTs: Int64
    let chars: Int             // 总字数(< 20)
    let preview: String        // ≤ 80 字符预览
}

/// 一个 (app, url) 组处理完的产物 —— records + 被丢掉的。
///
/// 原来叫 `WritingCapturePass3Agent.Output`,是云端 Pass 3 的返回类型;
/// 07-30 断云端时 Pass3Agent 整个删掉,但**确定性 AX 路也用这个载体**
/// (`WritingCaptureWorker.Pass3GroupResult`),所以提到这里当独立类型。
/// `prompt` / `rawResponse` 两个字段是云端遗留的调试字段,确定性路填空串。
struct WritingCaptureGroupOutput {
    let prompt: String
    let rawResponse: String
    let records: [WritingCaptureRecord]
    let discarded: [WritingCaptureDiscarded]
}

// MARK: - 07-30 从被删的云端 agent 文件搬来的共用类型
//
// 断掉云端路时删了 8 个 agent 文件,但下面三个类型是**整条链路的公共数据
// 形状**(DB schema / Store / UI 都在用),原本却定义在 agent 文件里。搬到
// 这里当独立类型 —— 它们跟 LLM 没关系,只是 Codable 数据结构。
//   - WritingCaptureContextSegment  ← WritingCapturePass1Agent.swift
//   - WritingCaptureRecord          ← WritingCapturePass3Agent.swift
//   - WritingCaptureDiscarded       ← WritingCapturePass3Agent.swift
//
// 注:Codable 的 decode 实现里那些「LLM 偶发省略某字段 → 兜底」的容忍逻辑
// 原样保留 —— DB 里已有的老 record 就是按这个形状写进去的,改了读不出来。

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
