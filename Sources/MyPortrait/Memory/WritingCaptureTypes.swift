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
