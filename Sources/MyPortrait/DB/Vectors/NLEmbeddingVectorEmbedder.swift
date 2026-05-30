import Foundation
import NaturalLanguage
import os.log

/// `VectorEmbedder` 的 **Apple NLEmbedding** 实现。
///
/// 零额外依赖：用 macOS 系统自带的 `NLEmbedding.sentenceEmbedding(for:)`，
/// Apple 在 OS 里捆了句向量模型，无需下载，无需 MLX，开箱即用。
///
/// **跟 bge-m3 的取舍**：
///
/// | 项 | NLEmbedding | bge-m3 |
/// |---|---|---|
/// | 维度 | 512（英语）/ 300（中文）/ 等 | 1024 |
/// | 模型质量 | 中等（2018 时代模型） | SOTA（2024） |
/// | 多语言 | 每种语言独立向量空间，**不跨语言** | 跨语言对齐（"force"≈"力"） |
/// | 依赖 | 0 | MLX-Swift + ~2 GB 模型 + tokenizer 集成 |
/// | 集成代价 | 这一个文件 | 单独 session 真机调试 |
///
/// 当前激活路径已切到 **`BGEM3VectorEmbedder`**（bge-m3 真推理已实现，见
/// `Services.activeEmbedder`）。本类作为 fallback 保留，VectorEmbedder 协议这一层
/// 零变化；因 macOS 26 Apple Intelligence entitlement 缺失会 crash，目前禁用。
///
/// **限制 / 已知**：
///   - 英语句向量是 512 维；中文是 300 维。HybridSearchEngine 用 cosine，**所有
///     embedding 必须同维**。当前实现固定使用 `.english`，**对中文 OCR/转录召回有限**。
///   - Apple 不提供多语言对齐的统一模型；要真正 cross-lingual 需要 bge-m3。
public actor NLEmbeddingVectorEmbedder: VectorEmbedder {

    nonisolated let dimensions: Int
    nonisolated let modelIdentifier: String

    private let logger = Logger(subsystem: "com.myportrait.db", category: "embed")
    private let language: NLLanguage
    private var cached: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.language = language
        // 注：实际维度从 NLEmbedding.dimension 拿；这里 hardcode 英文 512 维。
        // 换语言时（中文 300、法文 ?）这个值也要换。
        switch language {
        case .english: self.dimensions = 512
        case .simplifiedChinese: self.dimensions = 300
        default: self.dimensions = 512
        }
        self.modelIdentifier = "nl-\(language.rawValue)-v1"
    }

    public func embed(_ text: String) async throws -> [Float] {
        let model = try loadedModel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NLEmbeddingError.emptyInput
        }

        // sentence-level embedding API。返回 `[Double]`，转 `[Float]` 给 cosine 用。
        guard let vec = model.vector(for: trimmed) else {
            // 模型对该文本无法生成向量（极端长 / 完全 OOV / 字符不在词汇表里）。
            throw NLEmbeddingError.unsupportedInput(prefix: String(trimmed.prefix(40)))
        }
        return vec.map { Float($0) }
    }

    private func loadedModel() throws -> NLEmbedding {
        if let cached { return cached }
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
            throw NLEmbeddingError.modelUnavailable(language: language)
        }
        cached = model
        logger.info("NLEmbedding loaded: lang=\(self.language.rawValue, privacy: .public), dim=\(model.dimension)")
        return model
    }
}

public enum NLEmbeddingError: Error, CustomStringConvertible {
    case emptyInput
    case unsupportedInput(prefix: String)
    case modelUnavailable(language: NLLanguage)

    public var description: String {
        switch self {
        case .emptyInput:
            return "NLEmbeddingError.emptyInput"
        case .unsupportedInput(let p):
            return "NLEmbeddingError.unsupportedInput(prefix=\(p))"
        case .modelUnavailable(let l):
            return "NLEmbeddingError.modelUnavailable(\(l.rawValue))"
        }
    }
}
