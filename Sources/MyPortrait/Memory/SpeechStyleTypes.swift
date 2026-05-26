import Foundation

/// speech_style 提炼链路的内存类型 —— 跨 Distiller / Agent / Store 用。
/// 不入 DB,运行时载体。

// MARK: - 模式

enum SpeechStyleMode: String, Sendable {
    case manual    // UI Run 按钮触发 —— staged + pending review
    case auto      // scheduler 自动 —— 直接 commit portrait/speech_style/
}

// MARK: - Run 状态

enum SpeechStyleRunStatus: String, Sendable {
    case processing
    case pendingReview     = "pending_review"
    case approved
    case autoCommitted     = "auto_committed"
    case rejectedForRerun  = "rejected_for_rerun"
    case failed
}

// MARK: - 输入给 LLM 的 record

/// 喂给 LLM 的一条 writing_record(裁剪后只留 speech_style 关心的字段)。
struct SpeechStyleRecordInput: Sendable, Equatable {
    let id: Int64
    let startTs: Int64
    let app: String
    let url: String?
    let text: String
    let editLog: String              // JSON 原文,LLM 自己看时序
    let kind: String                 // long_form / short_form / other
    let contextSummary: String?
    /// midpoint OCR snippet —— 这条 record 时间窗中间那帧的屏幕 OCR 文本,
    /// 截到 ~200 字。给 LLM 当语境辅助:消除"短消息归到 chat 还是 prompt"
    /// 这种歧义。可选 —— 只对短文本 record enrich,长 record 自身够看。
    var ocrContext: String? = nil
}

// MARK: - LLM 输出 / staged 行

/// LLM 单条决策。staged 时落 speech_style_staged 表,Approve 时按 action
/// 写 portrait/speech_style/<slug>.md。
struct SpeechStyleDraft: Sendable, Equatable {
    enum Action: String, Sendable {
        case create
        case update
        case noop
    }
    let action: Action
    let slug: String                 // snake_case, ≤ 40 字
    let title: String                // 人可读
    let body: String                 // markdown 正文
    let sourceRecordIds: [Int64]     // 这条 draft 引用的 writing_record id
    let existingSlug: String?        // update 时 = 现有 slug;create/noop 留空
}

// MARK: - 一次 Run 摘要

struct SpeechStyleRunSummary: Sendable {
    let runId: String
    let mode: SpeechStyleMode
    let status: SpeechStyleRunStatus
    let recordsCount: Int            // 输入 record 数
    let draftsCount: Int             // LLM 返回 draft 数
    let errorMessage: String?
}

// MARK: - Staged 行(查 pending review 用)

struct SpeechStyleStagedRow: Sendable, Identifiable, Equatable {
    let id: Int64
    let runId: String
    let createdAt: Int64
    let action: SpeechStyleDraft.Action
    let slug: String
    let title: String
    let body: String
    let sourceRecordIds: [Int64]
    let existingSlug: String?
}

// MARK: - Run 行(查 pending review 列表用)

struct SpeechStyleRunRow: Sendable, Identifiable, Equatable {
    let id: Int64
    let runId: String
    let mode: SpeechStyleMode
    let status: SpeechStyleRunStatus
    let startedAt: Int64
    let completedAt: Int64?
    let recordsCount: Int?
    let draftsCount: Int?
    let errorMessage: String?
}
