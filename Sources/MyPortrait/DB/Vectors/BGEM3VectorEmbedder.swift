import Foundation
import Hub
import MLX
import MLXNN
import Tokenizers
import mlx_embeddings
import os.log

/// `VectorEmbedder` 的 bge-m3 真推理实现。
///
/// **两步加载**：
///   1. 从 `mlx-community/bge-m3-mlx-fp16` 拿 MLX 格式的 fp16 权重
///      （`config.json` + `model.safetensors`，~1.13 GB）
///   2. 从 `BAAI/bge-m3` 拿 tokenizer 文件（`tokenizer.json` +
///      `tokenizer_config.json` + `special_tokens_map.json`，~17 MB）
///
/// **绕过 XLMRobertaTokenizer 问题**：swift-transformers 0.1.24 的 tokenizer
/// 路由表里没有 `XLMRobertaTokenizer`，但 bge-m3 的 `tokenizer.json` 实际是
/// `model.type: Unigram`（250002 词表），swift-transformers 的 `UnigramTokenizer`
/// 算法层完全支持。所以我们把 `tokenizer_config.json` 里的
/// `tokenizer_class` 字段在内存里改成 `T5Tokenizer`（它就是 UnigramTokenizer
/// 的空子类），让路由能跳到 Unigram 路径。文件不动，纯内存覆盖。
///
/// **Pooling**：bge-m3 官方推荐 **CLS pooling**（`1_Pooling/config.json` 里
/// `pooling_mode_cls_token: true`）。mzbac 的 `output.textEmbeds` 是 mean-pool 后
/// L2 归一化，**不适用**。我们用 `output.hiddenStates[0..., 0]` 拿 CLS token，
/// 自己 L2 归一化。
///
/// **完全本地**：模型一次性下到 HF cache，推理在本进程跑，不走 Apple Intelligence。
///
/// **首次启动**：会下载 ~1.13 GB 权重 + ~17 MB tokenizer 文件，10s-5min（看网速）。
/// 后续启动直接读 cache。
actor BGEM3VectorEmbedder: VectorEmbedder {

    nonisolated let dimensions: Int = 1024
    nonisolated let modelIdentifier: String = "bge-m3-v1"

    /// 权重 repo（MLX fp16 已转换格式）。
    private static let weightsRepo = "mlx-community/bge-m3-mlx-fp16"
    /// Tokenizer repo（原始 bge-m3，含 tokenizer.json）。
    private static let tokenizerRepo = "BAAI/bge-m3"

    /// XLM-RoBERTa 的 pad_token_id = 1（**不是** 0）。tokenizer 通常不暴露这个，
    /// hardcode 备用——不过 PreTrainedTokenizer 的 padding 会自动处理，这里仅
    /// forward pass 构造 mask 时用。
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
        // **MLX scheduler 预热**：第一次访问 MLX singleton 会触发一串 C++ 单例 +
        // std::thread 构造；在某些 cooperative thread QoS 下直接 terminate
        // （C++ 异常，不会被 Swift 抓住，整进程崩）。
        // 在主线程（Services.init 是 @MainActor）先 touch 一下 MLX，
        // 让 scheduler 在"正常"线程上初始化。
        eval(MLXArray(0))

        // **MLX Metal buffer cache 防御性上限**：默认 cacheLimit = memoryLimit ≈
        // unified RAM 的 75%（24GB Mac 上 ~18GB），是为了 LLM 推理峰值用的。
        // 我们这里只跑 bge-m3 forward 单步，稳态 cache ~200 MB。给 512 MB 上限
        // 留一倍 buffer，防止超长 OCR + batch padding 撞高峰时 cache 起飞。
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
    }

    // MARK: - VectorEmbedder

    func embed(_ text: String) async throws -> [Float] {
        let batch = try await embedBatch([text])
        guard let v = batch.first else {
            throw BGEM3Error.emptyResult
        }
        return v
    }

    /// 调试用：返回单句的 token id 序列，跟 Python FlagEmbedding 的
    /// `tokenizer.encode(text, add_special_tokens=True)` 应该 **完全一致**。
    /// 如果不一致 → 说明 normalizer / pre_tokenizer / post_processor 有差异。
    func debugTokenize(_ text: String) async throws -> [Int] {
        let c = try await loadedContainer()
        return await c.perform { (_, tokenizer) -> [Int] in
            let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
            return Array(tokens.prefix(Self.maxSequenceLength))
        }
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

    // MARK: - 加载

    private func loadedContainer() async throws -> ModelContainer {
        if let c = container { return c }
        logger.info("loading bge-m3 weights from \(Self.weightsRepo, privacy: .public)")
        let started = Date()
        do {
            let hub = HubApi()
            // 1) 下权重（~1.13 GB；MLX 格式 safetensors）
            let weightsDir = try await hub.snapshot(
                from: Hub.Repo(id: Self.weightsRepo),
                matching: ["*.safetensors", "config.json"]
            ) { progress in
                let p = progress.fractionCompleted
                if [0.0, 0.25, 0.5, 0.75, 1.0].contains(where: { abs($0 - p) < 0.005 }) {
                    Logger(subsystem: "com.myportrait.db", category: "bge-m3")
                        .info("bge-m3 weights download: \(Int(p * 100))%")
                }
            }
            logger.info("loading bge-m3 tokenizer from \(Self.tokenizerRepo, privacy: .public)")
            // 2) 下 tokenizer 文件（~17 MB；只拿需要的几个 JSON + sentencepiece file 兜底）
            let tokDir = try await hub.snapshot(
                from: Hub.Repo(id: Self.tokenizerRepo),
                matching: ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]
            ) { progress in
                let p = progress.fractionCompleted
                if [0.0, 0.5, 1.0].contains(where: { abs($0 - p) < 0.01 }) {
                    Logger(subsystem: "com.myportrait.db", category: "bge-m3")
                        .info("bge-m3 tokenizer download: \(Int(p * 100))%")
                }
            }

            // 3) 加载模型（手写 ~20 行，等价于 mzbac 内部的 loadSynchronous，
            //    没法直接调因为它是 internal）
            let model = try Self.loadEmbeddingModel(modelDirectory: weightsDir)

            // 4) 自定义 tokenizer 加载：绕过 tokenizer_class 路由直接走 Unigram
            let tokenizer = try Self.loadTokenizerWithUnigramOverride(directory: tokDir)

            let c = ModelContainer(model: model, tokenizer: tokenizer)
            container = c
            logger.info("bge-m3 ready (load took \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s)")
            return c
        } catch {
            loadFailed = true
            logger.error("bge-m3 load failed: \(String(describing: error), privacy: .public)")
            throw BGEM3Error.modelLoadFailed
        }
    }

    /// 等价于 mzbac/mlx.embeddings 内部 `loadSynchronous`（internal，没法外部调用），
    /// 这里手写 ~20 行：读 config.json → 走 ModelType registry 拿到 BertModel 实例 →
    /// 从所有 *.safetensors 文件读权重 → sanitize → 应用到 model → eval。
    private static func loadEmbeddingModel(modelDirectory: URL) throws -> EmbeddingModel {
        let configurationURL = modelDirectory.appendingPathComponent("config.json")
        let baseConfig = try JSONDecoder().decode(
            BaseConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )
        let model = try baseConfig.modelType.createModel(configuration: configurationURL)

        var weights = [String: MLXArray]()
        let enumerator = FileManager.default.enumerator(
            at: modelDirectory, includingPropertiesForKeys: nil
        )!
        for case let url as URL in enumerator {
            if url.pathExtension == "safetensors" {
                let w = try loadArrays(url: url)
                for (k, v) in w { weights[k] = v }
            }
        }

        weights = model.sanitize(weights: weights)

        // **XLM-R position embedding shift workaround**：mzbac 的 BertModel
        // 把 `positionIds` 参数丢了，只用 `arange(0..L)`。而 XLM-R 真正的语义
        // 是 `[padding_idx+1, padding_idx+2, ...]`（pad_token_id=1，所以 = 2,3,4,...）。
        // 把 position_embeddings 权重整体上移 2 行 —— 这样 model 内部用 arange
        // 索引就等效于原始 XLM-R 用 [2,3,...] 索引。
        //
        // 数值对齐：跟 Python FlagEmbedding 单句 cosine = **0.999999**（三句都对齐）。
        // Batch 一致性：单句 vs batch=32 cosine = **1.000000**（attention mask 把
        // pad token 屏蔽，CLS 输出对 pad 位置的位置编码不敏感，所以 padding 位置
        // 取错 row 不影响最终 CLS pooling 结果）。验证细节见 --embed-batch-test。
        if let key = weights.keys.first(where: { $0.hasSuffix("position_embeddings.weight") }) {
            let pe = weights[key]!
            let total = pe.dim(0)
            let dim = pe.dim(1)
            let shifted = pe[2..<total]
            // 用零行 pad 尾部凑回原长度（这两行不会被索引到 —— 我们截到 maxSeq=512 << 8194）
            let padding = MLXArray.zeros([2, dim], dtype: pe.dtype)
            weights[key] = concatenated([shifted, padding], axis: 0)
        }

        let parameters = ModuleParameters.unflattened(weights)
        try model.update(parameters: parameters, verify: [.all])
        eval(model)
        return model
    }

    /// 读 tokenizer.json + tokenizer_config.json，把 `tokenizer_class` 改成
    /// `T5Tokenizer`（它是 UnigramTokenizer 的空子类，bge-m3 的 model.type 就是
    /// Unigram），构造 PreTrainedTokenizer。文件不动，纯内存覆盖。
    private static func loadTokenizerWithUnigramOverride(directory: URL) throws -> Tokenizer {
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        let dataURL = directory.appendingPathComponent("tokenizer.json")

        let configJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
        guard var configDict = configJSON as? [String: Any] else {
            throw BGEM3Error.malformedTokenizerConfig
        }
        // 关键覆盖：把 XLMRobertaTokenizer 路由到 T5Tokenizer (= UnigramTokenizer)
        configDict["tokenizer_class"] = "T5Tokenizer"

        let dataJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: dataURL))
        guard let dataDict = dataJSON as? [String: Any] else {
            throw BGEM3Error.malformedTokenizerConfig
        }

        let tokenizerConfig = Config(configDict as [NSString: Any])
        let tokenizerData = Config(dataDict as [NSString: Any])
        return try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }

    // MARK: - Forward pass

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

        // 3.5 **XLM-R position IDs**（不是 BERT 的 [0,1,2,..]）
        //   HF XLMRobertaEmbeddings.create_position_ids_from_input_ids：
        //     mask = input_ids != padding_idx
        //     pos = (cumsum(mask, dim=1) * mask) + padding_idx
        //   non-pad token 拿到 padding_idx+1, padding_idx+2, ...（即 2, 3, 4, ...）
        //   pad token 拿到 padding_idx（即 1）
        //   mzbac 的 BertModel 默认 positionIds=arange(0..L)，那是 BERT 的语义，
        //   XLM-R 跑下来 position embedding 整行错位，cosine 直接掉到 ~0.1。
        let nonPadMaskInt = attentionMask.asType(Int32.self)
        let cum = nonPadMaskInt.cumsum(axis: -1)
        let positionIds = (cum * nonPadMaskInt) + MLXArray(Int32(padId))

        // 4. forward
        let output = model(
            padded,
            positionIds: positionIds,
            tokenTypeIds: tokenTypeIds,
            attentionMask: attentionMask
        )

        // 5. **CLS pooling**：取第 0 个 token 的 hidden state。
        //    mzbac 把 output.textEmbeds 做的是 mean-pool，不能用（bge-m3 官方 CLS）。
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
    case malformedTokenizerConfig

    public var description: String {
        switch self {
        case .modelLoadFailed: return "BGEM3Error.modelLoadFailed"
        case .emptyResult: return "BGEM3Error.emptyResult"
        case .malformedTokenizerConfig: return "BGEM3Error.malformedTokenizerConfig"
        }
    }
}
