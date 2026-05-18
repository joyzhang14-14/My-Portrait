import Foundation

/// 文本 → 向量 的抽象。
///
/// **当前状态**：协议在位 + bge-m3 模型下载逻辑在位（`BGEM3ModelManager`），
/// 但**推理还没接通** —— Phase 4 (Hybrid + RRF) 实现时再做。
///
/// Phase 4 实现方向（待选）：
/// 1. Apple MLX-Swift（推荐）：mlx-community/bge-m3 已转 MLX 格式，纯 Swift API
/// 2. CoreML：bge-m3 → coremltools 转换 → Core ML 跑
/// 3. ONNX Runtime：onnxruntime-swift 库
///
/// 向量维度：bge-m3 = 1024。HybridSearchEngine 会算 cosine 相似度做语义召回。
protocol VectorEmbedder: Sendable {

    /// 把文本编码成 dense 向量。
    /// `bge-m3` 输出 1024 维 Float32。
    func embed(_ text: String) async throws -> [Float]

    /// 批量版（同样 1 调用 ≤ 32 段，模型 batch 上限）。Phase 4 实现。
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

extension VectorEmbedder {
    /// 默认实现：批量退化为循环单个。Phase 4 可由具体 embedder 复写以走 model batch path。
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for t in texts {
            results.append(try await embed(t))
        }
        return results
    }
}
