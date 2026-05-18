import Foundation
import GRDB
import os.log

/// `SearchEngine` 的 FTS 实现（Phase 2）。
///
/// 算法：
///   - `frames_fts` / `transcriptions_fts` 是 FTS5 contentless 视图，
///     `synchronize` 自动跟主表同步
///   - 用 `MATCH ?` 做字面匹配
///   - 用 `bm25(table)` 做相关度排序（负值，越小越相关）；snippet() 高亮
///   - 我们把 bm25 取负让 SearchEngine.FrameSearchResult.score "大=好"
///
/// 暂不实现：
///   - query 解析（用户输入"app:VSCode some text" 这种 DSL）
///   - 分页（offset）—— 大数据集再加
///   - 字段权重（app_name 命中 vs full_text 命中的权重）—— 用 bm25 default
final class FTSSearchEngine: SearchEngine, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "fts")
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - SearchEngine

    func searchFrames(query: String, limit: Int) async throws -> [FrameSearchResult] {
        let cleanQuery = Self.sanitizeFTSQuery(query)
        guard !cleanQuery.isEmpty else { return [] }

        return try await dbPool.read { db in
            // bm25 返回负数；取负后 ORDER BY score DESC 让"大=好"。
            // snippet(table, col=-1=all, '<b>', '</b>', '…', tokens=32)
            let sql = """
            SELECT
                f.id,
                f.timestamp_ms,
                f.app_name,
                f.window_name,
                f.browser_url,
                snippet(frames_fts, -1, '<b>', '</b>', '…', 32) AS sn,
                -bm25(frames_fts) AS score
            FROM frames_fts
            JOIN frames f ON f.rowid = frames_fts.rowid
            WHERE frames_fts MATCH ?
            ORDER BY score DESC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [cleanQuery, limit])
            return rows.compactMap { row -> FrameSearchResult? in
                guard let id: Int64 = row["id"],
                      let ts: Int64 = row["timestamp_ms"],
                      let app: String = row["app_name"]
                else { return nil }
                return FrameSearchResult(
                    frameId: id,
                    timestampMs: ts,
                    appName: app,
                    windowName: row["window_name"],
                    browserUrl: row["browser_url"],
                    snippet: row["sn"] ?? "",
                    score: row["score"] ?? 0
                )
            }
        }
    }

    func searchTranscriptions(query: String, limit: Int) async throws -> [TranscriptionSearchResult] {
        let cleanQuery = Self.sanitizeFTSQuery(query)
        guard !cleanQuery.isEmpty else { return [] }

        return try await dbPool.read { db in
            let sql = """
            SELECT
                t.id,
                t.audio_chunk_id,
                c.recorded_at_ms,
                snippet(transcriptions_fts, -1, '<b>', '</b>', '…', 32) AS sn,
                -bm25(transcriptions_fts) AS score
            FROM transcriptions_fts
            JOIN audio_transcriptions t ON t.rowid = transcriptions_fts.rowid
            JOIN audio_chunks c ON c.id = t.audio_chunk_id
            WHERE transcriptions_fts MATCH ?
            ORDER BY score DESC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [cleanQuery, limit])
            return rows.compactMap { row -> TranscriptionSearchResult? in
                guard let id: Int64 = row["id"],
                      let chunkId: Int64 = row["audio_chunk_id"],
                      let recorded: Int64 = row["recorded_at_ms"]
                else { return nil }
                return TranscriptionSearchResult(
                    transcriptionId: id,
                    audioChunkId: chunkId,
                    recordedAtMs: recorded,
                    snippet: row["sn"] ?? "",
                    score: row["score"] ?? 0
                )
            }
        }
    }

    // MARK: - 私有

    /// 把用户输入清成 FTS5 安全的查询。
    /// - 去掉首尾空白
    /// - 转义双引号 → 包成 phrase（"foo bar"）
    /// - 单字时直接传字面
    ///
    /// 后续可升级支持 OR / AND / NOT / prefix（`hello*`）等 FTS5 操作符。
    private static func sanitizeFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // 简单做法：把整个 query 包成一个 phrase（防注入 + 简化语义）。
        // 用户搜"hello world" → MATCH '"hello world"' → 必须连续出现。
        // 进阶语法（OR / 前缀星号）等下个迭代加。
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
