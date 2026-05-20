import Foundation
import WhisperKit
import os.log

/// WhisperKit 包装。
///
/// 单实例持有 WhisperKit pipeline，首次调用懒加载模型（首跑从 HuggingFace 下载
/// 100 MB ~ 1.5 GB 不等，按 model 大小）。
///
/// 默认 `openai_whisper-base`（多语言，~150 MB）。
/// 想要更高质量 → `openai_whisper-small` (500 MB) / `medium` (1.5 GB)。
///
/// ## 并发契约
///
/// **调用方必须保证 `transcribe` 串行执行**。这里没有任何内部同步：WhisperKit
/// 不 Sendable，actor / OSAllocatedUnfairLock 包装都会触发 Swift 6 strict
/// concurrency 错误。
///
/// 在 My-Portrait 里调用方是 `TranscriptionScheduler`（actor），其 `processQueueOnce`
/// 一次只处理一个 chunk —— 满足契约。任何新调用点都要遵守这一点。
final class WhisperKitWrapper: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "whisper")
    private let modelName: String

    /// pipeline。首次 transcribe 调用懒构造。
    /// `nonisolated(unsafe)` —— 见类文档"并发契约"。
    nonisolated(unsafe) private var pipe: WhisperKit?

    init(modelName: String = "openai_whisper-base") {
        self.modelName = modelName
    }

    /// 懒加载 WhisperKit pipeline（首跑下载模型）。
    private func ensurePipe() async throws {
        guard pipe == nil else { return }
        logger.info("loading WhisperKit model: \(self.modelName, privacy: .public) (first run may download ~150 MB)")
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

    /// 转录一个 wav 文件，返回纯文本。
    func transcribe(wavPath: String) async throws -> String {
        try await ensurePipe()
        let results = try await pipe!.transcribe(audioPath: wavPath)
        return Self.joinText(results)
    }

    /// 转录一段 16kHz mono float 样本，返回纯文本。
    /// 说话人分离后逐段转录走这条路（避免落临时 wav 文件）。
    func transcribe(samples: [Float]) async throws -> String {
        try await ensurePipe()
        let results = try await pipe!.transcribe(audioArray: samples)
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
