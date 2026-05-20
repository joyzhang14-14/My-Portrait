import Foundation
import os.log

/// `SearchEngine` 的 Hybrid 实现（Phase 4）。
///
/// 把字面匹配（FTS）和语义召回（向量）通过 RRF 融合排序。在 AppEnvironment 里
/// 把 `FTSSearchEngine` 换成 `HybridSearchEngine`，UI **不用改任何代码**。
///
/// 流程：
/// ```
///   query
///     │
///     ├─→ Layer 1: FTSSearchEngine.searchFrames(limit=200)
///     │        ↓
///     │   [frameId 列表，按 bm25 排序]
///     │
///     ├─→ Layer 2: embedder.embed(query) → [Float; 1024]
///     │        ↓
///     │   db.allFrameEmbeddings(limit=10000) → [(id, vec)]
///     │        ↓
///     │   VectorMath.cosineSimilarities → 排序 → top 200
///     │
///     └─→ Layer 3: RRF.fuse(两个列表, k=60) → 综合排序
///              ↓
///         按结果 ids 调 db.framesByIds 拿元数据 → 返回前 `limit` 个
/// ```
///
/// **降级**：embedder 抛错（如 `BGEM3VectorEmbedder` 推理未实现 → throw
/// notImplemented）时，跳过 Layer 2 + Layer 3，直接返回 FTS 结果。这样在
/// Phase 4 模型接通前 UI 用 Hybrid 也是可用的（实际上就是 FTS）。
final class HybridSearchEngine: SearchEngine, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "hybrid")
    private let db: PortraitDB
    private let fts: FTSSearchEngine
    private let embedder: any VectorEmbedder

    /// FTS / 向量各自的召回容量。RRF 看到的列表长度 = 每路 candidatesPerLayer。
    /// 200 是经验值；UI 一次显示 ≤ 50，足够了。
    private let candidatesPerLayer = 200

    /// 算 cosine 的全表向量上限。7000 行 × 1024 维 ≈ 28 MB；放 10000 作上限缓冲。
    /// 超过这个数应该走索引（HNSW / IVF），不在 P4 范围。
    private let maxEmbeddingsScan = 10_000

    init(db: PortraitDB, fts: FTSSearchEngine, embedder: any VectorEmbedder) {
        self.db = db
        self.fts = fts
        self.embedder = embedder
    }

    // MARK: - SearchEngine

    func searchFrames(query: String, limit: Int) async throws -> [FrameSearchResult] {
        // Layer 1: FTS
        let ftsHits = try await fts.searchFrames(query: query, limit: candidatesPerLayer)
        let ftsIds = ftsHits.map(\.frameId)

        // Layer 2: 向量召回。embedder throw → 走 FTS-only 降级。
        let semanticIds: [Int64]
        do {
            let queryVec = try await embedder.embed(query)
            semanticIds = try await semanticTopFrames(queryVector: queryVec)
        } catch {
            logger.info("embedder unavailable (Phase 4 inference not wired?); FTS-only fallback. Reason: \(String(describing: error), privacy: .public)")
            return Array(ftsHits.prefix(limit))
        }

        // Layer 3: RRF 融合
        let fused = RRF.fuse([ftsIds, semanticIds])
        let topIds = Array(fused.prefix(limit).map(\.id))

        // 拿元数据 + 保留 RRF 顺序
        let metadata = try await db.framesByIds(topIds)
        let metaById = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })

        // FTS snippet 优先（高亮信息）；没有就空串。
        let snippetById = Dictionary(uniqueKeysWithValues: ftsHits.map { ($0.frameId, $0.snippet) })

        return fused.prefix(limit).compactMap { entry -> FrameSearchResult? in
            guard let m = metaById[entry.id] else { return nil }
            return FrameSearchResult(
                frameId: m.id,
                timestampMs: m.timestampMs,
                appName: m.appName,
                windowName: m.windowName,
                browserUrl: m.browserUrl,
                snippet: snippetById[m.id] ?? (m.fullText ?? ""),
                score: entry.score
            )
        }
    }

    /// 转录搜索：FTS + 向量 + RRF 融合，结构跟 searchFrames 完全对称。
    /// embedder 抛错时降级 FTS-only。
    func searchTranscriptions(query: String, limit: Int) async throws -> [TranscriptionSearchResult] {
        let ftsHits = try await fts.searchTranscriptions(query: query, limit: candidatesPerLayer)
        let ftsIds = ftsHits.map(\.transcriptionId)

        let semanticIds: [Int64]
        do {
            let queryVec = try await embedder.embed(query)
            semanticIds = try await semanticTopTranscriptions(queryVector: queryVec)
        } catch {
            logger.info("embedder unavailable on transcriptions; FTS-only fallback: \(String(describing: error), privacy: .public)")
            return Array(ftsHits.prefix(limit))
        }

        let fused = RRF.fuse([ftsIds, semanticIds])
        let topIds = Array(fused.prefix(limit).map(\.id))

        let metadata = try await db.transcriptionsByIds(topIds)
        let metaById = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        // FTS snippet 优先（高亮）；纯向量召回的结果用 text 头 80 字。
        let snippetById = Dictionary(uniqueKeysWithValues: ftsHits.map { ($0.transcriptionId, $0.snippet) })

        return fused.prefix(limit).compactMap { entry -> TranscriptionSearchResult? in
            guard let m = metaById[entry.id] else { return nil }
            return TranscriptionSearchResult(
                transcriptionId: m.id,
                audioChunkId: m.audioChunkId,
                recordedAtMs: m.recordedAtMs,
                snippet: snippetById[m.id] ?? String(m.text.prefix(80)),
                score: entry.score
            )
        }
    }

    // MARK: - 私有

    private func semanticTopFrames(queryVector: [Float]) async throws -> [Int64] {
        let pairs = try await db.allFrameEmbeddings(model: embedder.modelIdentifier, limit: maxEmbeddingsScan)
        if pairs.isEmpty { return [] }

        // Cosine = dot（前提：bge-m3 输出已 L2 归一化；EmbeddingWorker 也会再保险归一）
        let scored = pairs.map { (pair: (id: Int64, vector: [Float])) -> (Int64, Float) in
            (pair.id, VectorMath.cosineSimilarity(queryVector, pair.vector))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(candidatesPerLayer)
            .map(\.0)
    }

    private func semanticTopTranscriptions(queryVector: [Float]) async throws -> [Int64] {
        let pairs = try await db.allTranscriptionEmbeddings(model: embedder.modelIdentifier, limit: maxEmbeddingsScan)
        if pairs.isEmpty { return [] }
        let scored = pairs.map { (pair: (id: Int64, vector: [Float])) -> (Int64, Float) in
            (pair.id, VectorMath.cosineSimilarity(queryVector, pair.vector))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(candidatesPerLayer)
            .map(\.0)
    }
}
