import Accelerate
import Foundation
import MLX
import Qwen3ASR
import os.log

/// Qwen3-ASR（1.7B-8bit，MLX）包装。结构 + 并发契约镜像 `WhisperKitWrapper`。
///
/// 单实例懒加载 `Qwen3ASRModel`（首跑从 HuggingFace 下 ~2.3 GB 到
/// `~/Library/Caches/qwen3-speech/`）。模型 ID 固定 1.7B-8bit —— 实测中文 /
/// 中英混说质量明显优于 Whisper（修错字、简体、补标点）。
///
/// MLX 的 Metal 着色器库由 Xcode 构建时自动编译进 `.app`（命令行 `swift build`
/// 不编，故 CLI 跑会缺 metallib —— 真 app 不受影响）。
///
/// ## 并发契约
///
/// 同 `WhisperKitWrapper`：**调用方必须保证 `transcribe` 串行执行**。这里没有
/// 任何内部同步。调用方是 `TranscriptionScheduler`（actor），一次只处理一个
/// chunk —— 满足契约。
final class Qwen3ASRWrapper: @unchecked Sendable {

    /// 默认 1.7B-8bit（实测中文/中英混质量达标）。0.6B-4bit 更小更快、质量略逊。
    static let defaultModelId = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    /// 可选模型 variant（CaptureView 的 model picker + AIModelsView 下载行用）。
    static let allQwenModels: [(name: String, label: String, size: String)] = [
        ("aufklarer/Qwen3-ASR-1.7B-MLX-8bit", "Qwen3-ASR 1.7B (8-bit)", "~2.3 GB"),
        ("aufklarer/Qwen3-ASR-0.6B-MLX-4bit", "Qwen3-ASR 0.6B (4-bit)", "~0.6 GB"),
    ]

    /// 当前实例用的模型 id（从设置 `recording.audio.qwenModel` 传入）。
    private let modelId: String

    init(modelId: String = defaultModelId) {
        self.modelId = modelId.isEmpty ? Self.defaultModelId : modelId
        // MLX Metal buffer cache 上限。不设的话实时转录跨 chunk 累积到十几 GB
        // (用户实测撑爆 24G 内存)。跟 RetranscribeQwenCLI 同款兜底。
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
    }

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "qwen-asr")

    /// 近静音门限。RMS 低于此值直接判空，不喂模型（跟 Whisper 一致）。
    private static let minRMS: Float = 0.015

    /// 模型实例。首次 transcribe 懒加载。`nonisolated(unsafe)` —— 见"并发契约"。
    nonisolated(unsafe) private var model: Qwen3ASRModel?

    /// 某个模型 variant 的权重在不在磁盘 —— 给 Settings / AI models 页状态用。
    /// 缓存路径：`~/Library/Caches/qwen3-speech/models/<org>/<repo>/model.safetensors`。
    nonisolated static func isOnDisk(modelId: String) -> Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return false }
        var dir = caches.appendingPathComponent("qwen3-speech/models")
        for part in modelId.split(separator: "/") { dir.appendPathComponent(String(part)) }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    /// 从磁盘删除某个 Qwen 模型目录 —— Downloads 页 Uninstall 按钮用。
    /// 删的是 `.../qwen3-speech/models/<org>/<repo>/` 整个目录。
    nonisolated static func deleteFromDisk(modelId: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        var dir = caches.appendingPathComponent("qwen3-speech/models")
        for part in modelId.split(separator: "/") { dir.appendPathComponent(String(part)) }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 释放已加载的模型，回收内存（~3.3 GB）。下次 transcribe 自动重新加载。
    func unload() {
        guard model != nil else { return }
        model = nil
        // 只置 nil 不够 —— 权重 buffer 会留在 MLX 的 GPU buffer cache 里不还给系统
        // (实测残留 ~1.4G)。跟 transcribe() 一样显式清缓存,才真正 free。
        MLX.GPU.clearCache()
        logger.info("Qwen3-ASR model unloaded — freed memory")
    }

    /// 显式下载模型到磁盘（AI models 页 Download 按钮用）。
    /// 失败 swallow —— UI 轮询 isOnDisk 反映结果。
    static func downloadModel(modelId: String) async {
        _ = try? await Qwen3ASRModel.fromPretrained(modelId: modelId)
    }

    /// 懒加载模型。Qwen 走「手动下载」—— 模型不在磁盘**不偷偷下载**，直接抛错
    /// （用户须先去 AI models 页下载）。在磁盘则从 cache 加载（offlineMode 不触网）。
    private func ensureModel() async throws {
        guard model == nil else { return }
        guard Self.isOnDisk(modelId: modelId) else {
            logger.warning("Qwen3-ASR model not downloaded: \(self.modelId, privacy: .public) — download it in AI models first")
            throw Qwen3ASRError.modelNotDownloaded(modelId)
        }
        logger.info("loading Qwen3-ASR model: \(self.modelId, privacy: .public)")
        model = try await Qwen3ASRModel.fromPretrained(modelId: modelId, offlineMode: true)
        logger.info("Qwen3-ASR model loaded")
    }

    /// 样本 RMS 能量。
    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(samples, 1, &r, vDSP_Length(samples.count))
        return r
    }

    /// 自定义词汇 → Qwen3-ASR 的 `context` 偏置提示。
    /// 词条格式 "term" 或 "term · replacement"，取 "·" 前的词。
    private static func contextHint(from vocabulary: [String]) -> String? {
        let terms = vocabulary
            .map { $0.split(separator: "·").first.map(String.init) ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// 转录一段 16kHz mono float 样本，返回纯文本。
    /// 近静音（RMS < 阈值）直接判空；其余先归一化 +（可选）音乐过滤再喂模型。
    func transcribe(
        samples: [Float], language: String?, vocabulary: [String], filterMusic: Bool
    ) async throws -> String {
        try await ensureModel()
        guard Self.rms(samples) >= Self.minRMS else { return "" }   // RMS 门限走原始音频
        let processed = AudioPreprocessor.process(samples, filterMusic: filterMusic)
        // App Nap 防护：后台跑长段在 throttle 下能拖到分钟级。
        let napGuard = AppNapGuard.acquire(reason: "Qwen3-ASR transcription")
        defer { napGuard.release() }
        let text = autoreleasepool {
            let t = model!.transcribe(
                audio: processed, sampleRate: 16000,
                language: language, context: Self.contextHint(from: vocabulary)
            )
            // 清 Metal buffer cache —— 否则跨 chunk RSS 一路涨到十几 GB。
            MLX.GPU.clearCache()
            return t
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Qwen3ASRError: Error, CustomStringConvertible {
    case modelNotDownloaded(String)

    var description: String {
        switch self {
        case .modelNotDownloaded(let id):
            return "Qwen3ASRError.modelNotDownloaded(\(id)) — download it in AI models first"
        }
    }
}
