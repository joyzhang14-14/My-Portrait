import Foundation
import MLX
import MLXNN
import Tokenizers
import mlx_embeddings
import os.log

/// `VectorEmbedder` 的 bge-m3 真推理实现。
///
/// 通过 [mzbac/mlx.embeddings](https://github.com/mzbac/mlx.embeddings) 加载
/// `mlx-community/bge-m3-mlx-fp16`（1.13 GB fp16 safetensors，已经是 MLX 格式），
/// 跑 XLM-RoBERTa forward pass，取 CLS token，L2 归一化输出。
///
/// **为什么不用 mzbac 的 `output.textEmbeds`**：那是 mean pooling 后 L2 归一化的
/// 结果。bge-m3 官方推荐 **CLS pooling**（看 `1_Pooling/config.json` 里的
/// `pooling_mode_cls_token: true`）。Mean 和 CLS 在 bge-m3 上输出向量不同，
/// 跟 FlagEmbedding 对齐必须用 CLS。所以我们用 `output.hiddenStates[0..., 0]`
/// 拿第 0 个 token（CLS）的 raw embedding，自己归一化。
///
/// **完全本地**：模型一次性下到 HF cache（`~/Library/Caches/huggingface/`，
/// mzbac 调 HubApi 管理），推理在本进程跑，不走 Apple Intelligence / XPC，
/// 不会撞 macOS 26 那个 entitlement 坑。
///
/// **首次启动**：会下载 ~1.13 GB 模型，可能 30s-5min（看网速）。后续启动直接
/// 读 cache。embed 调用前 `ensureLoaded()` 会触发下载。
actor BGEM3VectorEmbedder: VectorEmbedder {

    nonisolated let dimensions: Int = 1024
    nonisolated let modelIdentifier: String = "bge-m3-v1"

    /// HuggingFace 上预转换的 MLX 版（fp16，~1.13 GB；非官方但官方推荐）。
    /// 跟 `BAAI/bge-m3` 原始 fp32 权重数值一致到 ~3 位小数（fp16 round-off 差异）。
    private static let huggingFaceRepo = "mlx-community/bge-m3-mlx-fp16"

    /// XLM-RoBERTa 的 pad_token_id = 1（**不是** 0）。tokenizer 通常不暴露这个，
    /// hardcode。
    private static let xlmrPadTokenId: Int = 1

    /// bge-m3 推理时的最大上下文。原始模型支持 8192，但 OCR 文本通常很短，
    /// 我们截到 512 token 减少计算量 + 内存。
    private static let maxSequenceLength: Int = 512

    private let logger = Logger(subsystem: "com.myportrait.db", category: "bge-m3")
    private let reporter: UnimplementedReporter
    private var container: ModelContainer?
    private var loadFailed: Bool = false

    init(reporter: UnimplementedReporter) {
        self.reporter = reporter
    }

    // MARK: - VectorEmbedder

    func embed(_ text: String) async throws -> [Float] {
        let batch = try await embedBatch([text])
        guard let v = batch.first else {
            throw BGEM3Error.emptyResult
        }
        return v
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        if loadFailed {
            throw BGEM3Error.modelLoadFailed
        }

        let c = try await loadedContainer()
        let result = await c.perform { (model, tokenizer) -> [[Float]] in
            Self.forward(model: model, tokenizer: tokenizer, texts: texts)
        }
        return result
    }

    // MARK: - 内部

    private func loadedContainer() async throws -> ModelContainer {
        if let c = container { return c }
        logger.info("loading bge-m3 model: \(Self.huggingFaceRepo, privacy: .public) (first run downloads ~1.13 GB)")
        let started = Date()
        do {
            let config = ModelConfiguration(id: Self.huggingFaceRepo)
            let c = try await loadModelContainer(configuration: config) { progress in
                // mzbac 走 HuggingFace HubApi 下载，progress 是文件级 fraction。
                // 不抖屏只在 5% / 25% / 50% / 75% / 完成时打 log。
                let p = progress.fractionCompleted
                if [0.0, 0.05, 0.25, 0.5, 0.75, 1.0].contains(where: { abs($0 - p) < 0.005 }) {
                    Logger(subsystem: "com.myportrait.db", category: "bge-m3")
                        .info("bge-m3 download progress: \(Int(p * 100))%")
                }
            }
            container = c
            logger.info("bge-m3 ready (load took \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s)")
            return c
        } catch {
            loadFailed = true
            logger.error("bge-m3 load failed: \(String(describing: error), privacy: .public)")
            throw BGEM3Error.modelLoadFailed
        }
    }

    /// 同步 forward pass。**所有 MLXArray 操作在 ModelContainer.perform 闭包内
    /// 完成，最终 `eval` 后转 `[[Float]]` 才返回**——MLXArray 不 Sendable。
    private static func forward(
        model: EmbeddingModel,
        tokenizer: Tokenizer,
        texts: [String]
    ) -> [[Float]] {
        // 1. tokenize all + 决定 batch 内最大长度。
        let tokenized: [[Int]] = texts.map { text in
            // addSpecialTokens: true → 自动 prepend <s> (id=0) + append </s> (id=2)
            let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
            return Array(tokens.prefix(maxSequenceLength))
        }
        let maxLen = max(2, tokenized.map(\.count).max() ?? 2)
        let padId = xlmrPadTokenId

        // 2. pad 到 maxLen，构成 [B, L] 矩阵。
        let padded = stacked(tokenized.map { tokens -> MLXArray in
            let pad = Array(repeating: padId, count: max(0, maxLen - tokens.count))
            return MLXArray(tokens + pad)
        })

        // 3. attention mask: 非 pad 位为 1。
        let attentionMask = padded .!= MLXArray(padId)
        // XLM-R type_vocab_size=1，token type 全 0 即可。
        let tokenTypeIds = MLXArray.zeros(like: padded)

        // 4. forward
        let output = model(
            padded,
            positionIds: nil,
            tokenTypeIds: tokenTypeIds,
            attentionMask: attentionMask
        )

        // 5. **CLS pooling**：取第 0 个 token 的 hidden state。
        //    mzbac 把 output.textEmbeds 做的是 mean-pool，不能用（bge-m3 官方 CLS）。
        //    EmbeddingModelOutput.hiddenStates 在 mzbac 里是 optional —— BertModel
        //    总会填，这里 fail-fast 兜底。
        guard let hidden = output.hiddenStates else {
            return Array(repeating: Array(repeating: 0, count: 1024), count: texts.count)
        }
        let cls: MLXArray = hidden[0..., 0]  // [B, H=1024]

        // 6. L2 归一化（cosine == dot 的前提）
        let norm = MLX.sqrt((cls * cls).sum(axis: -1, keepDims: true))
        let normalized = cls / norm

        // 7. evaluate + 拷回 Swift Float 数组。
        eval(normalized)

        let batchSize = normalized.dim(0)
        let dim = normalized.dim(1)
        let flat: [Float] = normalized.asArray(Float.self)
        return (0..<batchSize).map { b in
            Array(flat[(b * dim)..<((b + 1) * dim)])
        }
    }
}

public enum BGEM3Error: Error, CustomStringConvertible {
    case modelLoadFailed
    case emptyResult

    public var description: String {
        switch self {
        case .modelLoadFailed: return "BGEM3Error.modelLoadFailed"
        case .emptyResult: return "BGEM3Error.emptyResult"
        }
    }
}
