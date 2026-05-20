import Accelerate
import Foundation
import WhisperKit
import os.log

/// WhisperKit 包装。
///
/// 单实例持有 WhisperKit pipeline，首次调用懒加载模型（首跑从 HuggingFace 下载，
/// 体积按模型大小 100 MB ~ 1.5 GB 不等）。模型名由设置 `recording.audio.whisperModel`
/// 决定（默认 `openai_whisper-base`）。
///
/// 转录质量参数抄 screenpipe：
///   - 转录前 RMS 门限：近静音直接判空，不喂 Whisper（防幻听）
///   - DecodingOptions：suppressBlank + 压缩比 / logprob / no_speech 阈值
///   - 温度回退：低置信时升温重试
///   - 语言提示 / 自定义词汇 prompt 偏置
///
/// ## 并发契约
///
/// **调用方必须保证 `transcribe` 串行执行**。这里没有任何内部同步：WhisperKit
/// 不 Sendable。调用方是 `TranscriptionScheduler`（actor），其 `processQueueOnce`
/// 一次只处理一个 chunk —— 满足契约。
final class WhisperKitWrapper: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "whisper")
    private let modelName: String

    /// 近静音门限。RMS 低于此值直接判空，不喂 Whisper（抄 screenpipe 的 0.015）。
    private static let minRMS: Float = 0.015

    /// pipeline。首次 transcribe 调用懒构造。
    /// `nonisolated(unsafe)` —— 见类文档"并发契约"。
    nonisolated(unsafe) private var pipe: WhisperKit?

    init(modelName: String = "openai_whisper-base") {
        self.modelName = modelName.isEmpty ? "openai_whisper-base" : modelName
    }

    /// 懒加载 WhisperKit pipeline（首跑下载模型）。
    private func ensurePipe() async throws {
        guard pipe == nil else { return }
        logger.info("loading WhisperKit model: \(self.modelName, privacy: .public) (first run may download)")
        do {
            pipe = try await WhisperKit(model: modelName)
        } catch {
            logger.error("WhisperKit model load failed: \(String(describing: error), privacy: .public)")
            throw WhisperError.loadFailed(underlying: error)
        }
        logger.info("WhisperKit model loaded")
    }

    private static func joinText(_ results: [TranscriptionResult]) -> String {
        results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 样本 RMS 能量。
    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(samples, 1, &r, vDSP_Length(samples.count))
        return r
    }

    /// 抄 screenpipe 的幻听防护参数构造 DecodingOptions。
    private func decodeOptions(language: String?, promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,                       // nil = 自动检测
            temperature: 0.0,
            temperatureFallbackCount: 5,              // 低置信时升温回退重试
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            promptTokens: promptTokens,               // 自定义词汇偏置
            suppressBlank: true,                      // 抑制空白 token
            compressionRatioThreshold: 2.4,           // 重复输出 → 丢弃
            logProbThreshold: -1.0,                   // 低置信片段 → 丢弃
            noSpeechThreshold: 0.6                    // 模型判无语音 → 丢弃
        )
    }

    /// 自定义词汇 → prompt 偏置 token（模型加载后才有 tokenizer）。
    /// 词条格式 "term" 或 "term · replacement"，取 "·" 前的词。
    private func promptTokens(for vocabulary: [String]) -> [Int]? {
        let terms = vocabulary
            .map { $0.split(separator: "·").first.map(String.init) ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty, let tok = pipe?.tokenizer else { return nil }
        return tok.encode(text: " " + terms.joined(separator: ", "))
    }

    /// 转录一段 16kHz mono float 样本，返回纯文本。
    /// 近静音（RMS < 阈值）直接判空，不喂 Whisper；其余先做归一化 +（可选）音乐过滤。
    func transcribe(
        samples: [Float], language: String?, vocabulary: [String], filterMusic: Bool
    ) async throws -> String {
        try await ensurePipe()
        guard Self.rms(samples) >= Self.minRMS else { return "" }   // RMS 门限走原始音频
        let processed = AudioPreprocessor.process(samples, filterMusic: filterMusic)
        let results = try await pipe!.transcribe(
            audioArray: processed,
            decodeOptions: decodeOptions(language: language, promptTokens: promptTokens(for: vocabulary))
        )
        return Self.joinText(results)
    }
}

enum WhisperError: Error, CustomStringConvertible {
    case loadFailed(underlying: Error)

    var description: String {
        switch self {
        case .loadFailed(let e):
            return "WhisperError.loadFailed(\(String(describing: e)))"
        }
    }
}
