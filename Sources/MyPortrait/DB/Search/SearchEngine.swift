import Foundation

/// 搜索引擎抽象。UI 通过它做查询，不直接碰 SQL / FTS / 向量库。
///
/// 当前实现：`FTSSearchEngine`（Phase 2：纯字面 FTS5）
/// 未来实现：`HybridSearchEngine`（Phase 4：FTS + bge-m3 向量 + RRF 融合排序）
///
/// 在 AppEnvironment 里把 FTS 版换 Hybrid 版时 **UI 零改动** —— 这是分离的价值。
public protocol SearchEngine: Sendable {

    /// 搜屏幕帧（OCR / AX 文本 + app / window / URL）。
    /// 返回按相关度倒序的结果，含 FTS snippet（高亮）。
    func searchFrames(query: String, limit: Int) async throws -> [FrameSearchResult]

    /// 搜语音转录。
    func searchTranscriptions(query: String, limit: Int) async throws -> [TranscriptionSearchResult]
}

public struct FrameSearchResult: Sendable, Hashable {
    public let frameId: Int64
    public let timestampMs: Int64
    public let appName: String
    public let windowName: String?
    public let browserUrl: String?
    /// 命中片段（高亮：`<b>matched</b>` 标记，UI 渲染 attributed string）。
    public let snippet: String
    /// 相关度分数：分数越高越相关。
    /// FTS 引擎用 `-bm25()`（SQLite bm25 返回负，越小越好；这里取负数让"大=好"）。
    /// 未来 Hybrid 引擎可能是 RRF 倒序排名分数。
    public let score: Double

    public init(
        frameId: Int64, timestampMs: Int64,
        appName: String, windowName: String?, browserUrl: String?,
        snippet: String, score: Double
    ) {
        self.frameId = frameId
        self.timestampMs = timestampMs
        self.appName = appName
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.snippet = snippet
        self.score = score
    }
}

public struct TranscriptionSearchResult: Sendable, Hashable {
    public let transcriptionId: Int64
    public let audioChunkId: Int64
    public let recordedAtMs: Int64
    public let snippet: String
    public let score: Double

    public init(
        transcriptionId: Int64, audioChunkId: Int64,
        recordedAtMs: Int64, snippet: String, score: Double
    ) {
        self.transcriptionId = transcriptionId
        self.audioChunkId = audioChunkId
        self.recordedAtMs = recordedAtMs
        self.snippet = snippet
        self.score = score
    }
}
