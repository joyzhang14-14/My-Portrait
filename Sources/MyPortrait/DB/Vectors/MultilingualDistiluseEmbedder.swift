import Foundation
import MLX
import MLXNN
import Tokenizers
import mlx_embeddings
import os.log

/// `VectorEmbedder` 的多语言 Distiluse 真推理实现。
///
/// 通过 [mzbac/mlx.embeddings](https://github.com/mzbac/mlx.embeddings) 加载
/// `sentence-transformers/distiluse-base-multilingual-cased-v2`（约 ~135 MB），
/// 跑 DistilBert forward pass，**mean pooling + L2 归一化**。
///
/// **选型路径**：
///   - bge-m3：XLMRobertaTokenizer（sentencepiece），swift-transformers 0.1.24 不支持
///   - paraphrase-multilingual-Distiluse-L12-v2：同样 XLM-R 基底，tokenizer 错路由到
///     BPETokenizer 然后报 "requires merges"
///   - **distiluse-base-multilingual-cased-v2**：DistilBert + 多语言 WordPiece，
///     `tokenizer_class: DistilBertTokenizer` → swift-transformers 直接 alias 到
///     BertTokenizer，开箱即用 ✅
///
/// **多语言能力**：50+ 语言对齐训练（含中、英、日、韩、法、德、西、俄等）。
/// 维度 512，足够 ~10k 文档的语义召回。
///
/// **完全本地**：模型一次性下到 HF cache，推理在本进程跑，不走 Apple Intelligence。
///
/// **首次启动**：会下载 ~135 MB 模型，几秒。后续启动直接读 cache。
actor MultilingualDistiluseEmbedder: VectorEmbedder {

    nonisolated let dimensions: Int = 512
    nonisolated let modelIdentifier: String = "distiluse-multi-v2"

    /// HuggingFace 原始 repo。mzbac/mlx.embeddings 的 loadSynchronous 直接读
    /// safetensors，跟原始 DistilBertModel safetensors 兼容
    /// （fp32 → MLXArray 转换内部完成）。
    private static let huggingFaceRepo = "sentence-transformers/distiluse-base-multilingual-cased-v2"

    private let logger = Logger(subsystem: "com.myportrait.db", category: "distiluse")
    private let reporter: UnimplementedReporter
    private var container: ModelContainer?
    private var loadFailed: Bool = false

    init(reporter: UnimplementedReporter) {
        self.reporter = reporter
        // **MLX scheduler 预热**：第一次访问 MLX singleton 会触发一串 C++ 单例 +
        // std::thread 构造；在某些 cooperative thread QoS 下直接 terminate
        // （C++ 异常，不会被 Swift 抓住，整进程崩）。
        // 在主线程（Services.init 是 @MainActor）先 touch 一下 MLX，
        // 让 scheduler 在"正常"线程上初始化。之后再从任何 QoS 调都 OK。
        eval(MLXArray(0))
    }

    // MARK: - VectorEmbedder

    func embed(_ text: String) async throws -> [Float] {
        let batch = try await embedBatch([text])
        guard let v = batch.first else {
            throw DistiluseError.emptyResult
        }
        return v
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        if loadFailed {
            throw DistiluseError.modelLoadFailed
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
        logger.info("loading Distiluse model: \(Self.huggingFaceRepo, privacy: .public)")
        let started = Date()
        do {
            let config = ModelConfiguration(id: Self.huggingFaceRepo)
            let c = try await loadModelContainer(configuration: config) { progress in
                let p = progress.fractionCompleted
                if [0.0, 0.05, 0.25, 0.5, 0.75, 1.0].contains(where: { abs($0 - p) < 0.005 }) {
                    Logger(subsystem: "com.myportrait.db", category: "distiluse")
                        .info("Distiluse download progress: \(Int(p * 100))%")
                }
            }
            container = c
            logger.info("Distiluse ready (load took \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s)")
            return c
        } catch {
            loadFailed = true
            logger.error("Distiluse load failed: \(String(describing: error), privacy: .public)")
            throw DistiluseError.modelLoadFailed
        }
    }

    /// 同步 forward pass。**所有 MLXArray 操作在 ModelContainer.perform 闭包内完成，
    /// 最终 `eval` 后转 `[[Float]]` 才返回**——MLXArray 不 Sendable。
    ///
    /// 用 mzbac 暴露的 `output.textEmbeds`，它就是 mean-pool + L2-normalize 后的结果
    /// （Distiluse 官方推荐 mean pooling，跟 sentence-transformers 一致）。
    private static func forward(
        model: EmbeddingModel,
        tokenizer: Tokenizer,
        texts: [String]
    ) -> [[Float]] {
        // 截到 512 token，原模型支持 512，超长 OCR 不丢失意义太多。
        let maxSequenceLength = 512
        let tokenized: [[Int]] = texts.map { text in
            let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
            return Array(tokens.prefix(maxSequenceLength))
        }
        let maxLen = max(2, tokenized.map(\.count).max() ?? 2)
        // BertTokenizer 的 pad_token_id = 0（不是 XLMR 的 1）。
        let padId = 0

        let padded = stacked(tokenized.map { tokens -> MLXArray in
            let pad = Array(repeating: padId, count: max(0, maxLen - tokens.count))
            return MLXArray(tokens + pad)
        })
        let attentionMask = padded .!= MLXArray(padId)
        let tokenTypeIds = MLXArray.zeros(like: padded)

        let output = model(
            padded,
            positionIds: nil,
            tokenTypeIds: tokenTypeIds,
            attentionMask: attentionMask
        )

        // mzbac 的 textEmbeds = mean(last_hidden_state * attention_mask) / sum(mask),
        // 然后 L2 normalize —— 这就是 sentence-transformers Distiluse 的标准 pipeline。
        // BertModel 总会填这个字段；optional 是为了 transformer 系其他模型留口子。
        guard let embeds = output.textEmbeds else {
            return Array(repeating: Array(repeating: 0, count: 512), count: texts.count)
        }
        eval(embeds)

        let batchSize = embeds.dim(0)
        let dim = embeds.dim(1)
        let flat: [Float] = embeds.asArray(Float.self)
        return (0..<batchSize).map { b in
            Array(flat[(b * dim)..<((b + 1) * dim)])
        }
    }
}

public enum DistiluseError: Error, CustomStringConvertible {
    case modelLoadFailed
    case emptyResult

    public var description: String {
        switch self {
        case .modelLoadFailed: return "DistiluseError.modelLoadFailed"
        case .emptyResult: return "DistiluseError.emptyResult"
        }
    }
}
