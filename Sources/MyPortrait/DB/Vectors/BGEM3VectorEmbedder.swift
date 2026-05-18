import Foundation

/// `VectorEmbedder` 的 bge-m3 实现 — **当前是 stub**。
///
/// 模型下载 + 协议接通完成。**推理还没接** —— Phase 4 实现：
///   - 选 MLX-Swift / CoreML / ONNX Runtime 之一加载 model.safetensors
///   - 加载 tokenizer.json + sentencepiece 给 input 分词
///   - 跑 forward pass 拿 last_hidden_state
///   - mean pooling 得到 1024 维向量
///   - L2 归一化（cosine similarity 用）
///
/// 调用 `embed(_:)` 会先 `await modelManager.ensureDownloaded()`（保证模型在磁盘），
/// 然后 throw `notImplemented` 让 reporter 状态栏冒红点。Phase 4 替换 throw 即可。
actor BGEM3VectorEmbedder: VectorEmbedder {

    private let modelManager: BGEM3ModelManager
    private let reporter: UnimplementedReporter

    init(modelManager: BGEM3ModelManager, reporter: UnimplementedReporter) {
        self.modelManager = modelManager
        self.reporter = reporter
    }

    func embed(_ text: String) async throws -> [Float] {
        // 1. 模型必须先在磁盘上。
        try await modelManager.ensureDownloaded()

        // 2. Phase 4：加载模型 → tokenize → forward → mean pool → normalize。
        throw reporter.notImplemented("BGEM3VectorEmbedder.embed[inference]")
    }
}
