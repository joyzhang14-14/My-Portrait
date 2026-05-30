import Foundation

/// 文本 → 向量 的抽象。HybridSearchEngine 用 cosine 相似度做语义召回。
///
/// 实现按需要换：
///   - `BGEM3VectorEmbedder` — bge-m3 真推理，跨语言、1024 维（**当前激活路径**）
///   - `NLEmbeddingVectorEmbedder` — Apple NLEmbedding fallback（注：macOS 26 Apple
///     Intelligence entitlement 缺失会 crash，目前禁用）
protocol VectorEmbedder: Sendable {

    /// 向量维度。HybridSearchEngine 在做 brute-force cosine 时要求 query 向量
    /// 和 DB 内向量同维，否则崩。换模型 = 换 dim 时所有历史向量都要重算。
    var dimensions: Int { get }

    /// 模型标识（含版本号）。写入 DB 时打到 `frames.embedding_model` 列，
    /// 用于"换模型时让 EmbeddingWorker 知道哪些行该重算"。
    /// 例：`"bge-m3-v1"`, `"nl-en-512-v1"`。
    var modelIdentifier: String { get }

    /// 单条 embed。L2 归一化后输出（HybridSearchEngine 期望已归一）。
    func embed(_ text: String) async throws -> [Float]

    /// 批量 embed（实现优先级最高 —— 7000 条历史回灌时 batch=32 比逐条快 ~10×）。
    func embedBatch(_ texts: [String]) async throws -> [[Float]]

    /// 释放已加载的模型,回收内存。下次 embed 按需重新加载。
    /// 持大模型的实现（bge-m3 ~1.15GB）应复写;轻量实现保持默认 no-op。
    func unload() async
}

extension VectorEmbedder {
    /// 默认实现：批量退化为循环单个。具体 embedder **应当**复写以走真正的 batch path。
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for t in texts {
            results.append(try await embed(t))
        }
        return results
    }

    /// 默认 no-op —— 不持大模型的实现无需释放。
    func unload() async {}
}
