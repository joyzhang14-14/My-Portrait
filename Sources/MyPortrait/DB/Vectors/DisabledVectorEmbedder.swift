import Foundation

/// "永远 throw" 的 embedder。**临时占位**，等下面任一条件满足就在 Services
/// 里换掉：
///   - bge-m3 MLX 推理上线
///   - 拿到 Apple Intelligence entitlement，NLEmbedding 可用
///
/// HybridSearchEngine 看到 embed 抛错自动走 FTS-only 路径。所以这个 stub
/// **不会**让搜索功能消失，只是没有语义召回。
///
/// 之前默认值是 `NLEmbeddingVectorEmbedder`，结果 macOS 26 上 NLEmbedding 内部
/// 路由 Apple Intelligence 的 XPC，没 entitlement → `os_eligibility` lookup
/// fail → libdispatch queue assert → crash。换 stub 临时绕开。
struct DisabledVectorEmbedder: VectorEmbedder {
    func embed(_ text: String) async throws -> [Float] {
        throw DisabledEmbedderError.disabled
    }
}

enum DisabledEmbedderError: Error, CustomStringConvertible {
    case disabled
    var description: String {
        "DisabledEmbedderError.disabled (vector layer intentionally off — see Services.activeEmbedder comment)"
    }
}
