import Foundation

/// writing_style 提炼链路的内存类型 —— 跨 Distiller / Agent / Store 用。
/// 不入 DB,运行时载体。

// MARK: - 模式

enum WritingStyleMode: String, Sendable {
    case manual    // UI Run 按钮触发 —— staged + pending review
    case auto      // scheduler 自动 —— 直接 commit portrait/writing_style/
}

// MARK: - Run 状态

enum WritingStyleRunStatus: String, Sendable {
    case processing
    case pendingReview     = "pending_review"
    case approved
    case autoCommitted     = "auto_committed"
    case rejectedForRerun  = "rejected_for_rerun"
    case failed
}

// MARK: - 输入给 LLM 的 record

/// 喂给 LLM 的一条 writing_record(裁剪后只留 writing_style 关心的字段)。
struct WritingStyleRecordInput: Sendable, Equatable {
    let id: Int64
    let startTs: Int64
    let app: String
    let url: String?
    let text: String
    let editLog: String              // JSON 原文,LLM 自己看时序
    let kind: String                 // long_form / short_form / other
    /// 写作时的语境(由 writing capture Pass 3 LLM 生成,在 writing_records 表
    /// 自带)。distiller 直接信它 + app + url 让下游 LLM 推断 voice,不再
    /// 额外抓 OCR。
    let contextSummary: String?
}

// MARK: - LLM 输出 / staged 行

/// LLM 单条决策。staged 时落 writing_style_staged 表,Approve 时按 action
/// 写 portrait/writing_style/<slug>.md。
struct WritingStyleDraft: Sendable, Equatable {
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

struct WritingStyleRunSummary: Sendable {
    let runId: String
    let mode: WritingStyleMode
    let status: WritingStyleRunStatus
    let recordsCount: Int            // 输入 record 数
    let draftsCount: Int             // LLM 返回 draft 数
    let errorMessage: String?
}

// MARK: - Staged 行(查 pending review 用)

struct WritingStyleStagedRow: Sendable, Identifiable, Equatable {
    let id: Int64
    let runId: String
    let createdAt: Int64
    let action: WritingStyleDraft.Action
    let slug: String
    let title: String
    let body: String
    let sourceRecordIds: [Int64]
    let existingSlug: String?
}

// MARK: - Run 行(查 pending review 列表用)

struct WritingStyleRunRow: Sendable, Identifiable, Equatable {
    let id: Int64
    let runId: String
    let mode: WritingStyleMode
    let status: WritingStyleRunStatus
    let startedAt: Int64
    let completedAt: Int64?
    let recordsCount: Int?
    let draftsCount: Int?
    let errorMessage: String?
}
