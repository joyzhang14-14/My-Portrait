import Foundation
import os.log

/// 说话人识别用的两个 ONNX 模型。port 自 screenpipe `speaker/models.rs`。
///
///   - segmentation：pyannote segmentation-3.0，找语音/非语音边界（当 VAD 用）。
///   - embedding：wespeaker CAM++（VoxCeleb 训练），抽 512 维音色向量。
///
/// 两个模型直接复用 screenpipe 仓库托管的副本。
enum SpeakerModel: Sendable {
    case segmentation
    /// 英文 wespeaker CAM++(VoxCeleb 训练,512 维)—— 历史默认。
    case embedding
    /// 中文 3D-Speaker CAM++(zh-cn 200k 说话人,192 维)。
    case embeddingZhCampp
    /// 中文 3D-Speaker ERes2NetV2(zh-cn 200k 说话人,192 维,略强)。
    case embeddingZhEres2
    /// Silero VAD v5 —— 语音活动检测（不属于说话人,但同样是可下载的音频 ONNX 模型）。
    case vadSilero

    var filename: String {
        switch self {
        case .segmentation:     return "segmentation-3.0.onnx"
        case .embedding:        return "wespeaker_en_voxceleb_CAM++.onnx"
        case .embeddingZhCampp: return "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
        case .embeddingZhEres2: return "3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx"
        case .vadSilero:        return "silero_vad.onnx"
        }
    }

    var url: String {
        switch self {
        case .segmentation, .embedding:
            let base = "https://github.com/screenpipe/screenpipe/raw/refs/heads/main/crates/screenpipe-audio/models/pyannote"
            return "\(base)/\(filename)"
        case .embeddingZhCampp, .embeddingZhEres2:
            // 注意 release tag 拼写就是 recongition(上游笔误)。
            return "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/\(filename)"
        case .vadSilero:
            return "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"
        }
    }

    /// config 里 `speaker_embedding_model` 字符串 → embedding 模型 case。
    /// 未知 / "en_campplus" / 旧 config 缺字段 → 英文 CAM++(保持历史默认)。
    static func embedding(forChoice choice: String) -> SpeakerModel {
        switch choice {
        case "zh_campplus":   return .embeddingZhCampp
        case "zh_eres2netv2": return .embeddingZhEres2
        default:              return .embedding
        }
    }

    /// 用户可选的说话人识别声纹模型(UI 单一数据源:Audio Capture 选用 / AI models 下载)。
    static let embeddingOptions: [EmbeddingOption] = [
        .init(id: "en_campplus",   label: "English CAM++",      detail: "wespeaker VoxCeleb · 512-dim · ~29 MB · default", model: .embedding),
        .init(id: "zh_campplus",   label: "Chinese CAM++",      detail: "3D-Speaker zh-cn · 192-dim · ~28 MB",            model: .embeddingZhCampp),
        .init(id: "zh_eres2netv2", label: "Chinese ERes2NetV2", detail: "3D-Speaker zh-cn · 192-dim · ~71 MB · stronger", model: .embeddingZhEres2),
    ]

    struct EmbeddingOption: Sendable, Identifiable {
        let id: String          // config 值
        let label: String       // UI 名字
        let detail: String      // 副标题
        let model: SpeakerModel
    }
}

/// 模型下载 / 磁盘缓存。原子写入 + 重试，port 自 screenpipe models.rs。
actor SpeakerModelStore {
    static let shared = SpeakerModelStore()

    /// 模型是否已经在磁盘上 —— **同步**查,UI 预检用(VoiceTrainer 启动
    /// 前判断 embedding 模型 ready 不,避免用户录满 30s 才发现模型还没下完)。
    nonisolated static func isOnDisk(_ model: SpeakerModel) -> Bool {
        let path = Storage.modelsDir.appendingPathComponent(model.filename).path
        return FileManager.default.fileExists(atPath: path)
    }

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "speaker-models")
    /// 内存缓存：filename → 已确认存在的本地路径。
    private var cached: [String: URL] = [:]

    /// 拿到模型本地路径。已缓存直接返回，否则下载（最多重试 3 次，指数退避）。
    func path(for model: SpeakerModel) async throws -> URL {
        let dir = Storage.modelsDir
        let dest = dir.appendingPathComponent(model.filename)

        if let c = cached[model.filename], FileManager.default.fileExists(atPath: c.path) {
            return c
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            cached[model.filename] = dest
            return dest
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 清理上次中断的临时文件。
        let tmp = dir.appendingPathComponent("\(model.filename).downloading")
        try? FileManager.default.removeItem(at: tmp)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await download(model, to: tmp, final: dest)
                cached[model.filename] = dest
                logger.info("speaker model ready: \(model.filename, privacy: .public)")
                return dest
            } catch {
                lastError = error
                logger.warning("speaker model download attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                if attempt < 3 {
                    let backoff = UInt64(1 << attempt) * 1_000_000_000   // 2s, 4s
                    try? await Task.sleep(nanoseconds: backoff)
                }
            }
        }
        throw lastError ?? NSError(domain: "MyPortrait.SpeakerModel", code: -1)
    }

    /// 启动时调一次,并行预下载 3 个 ONNX 小模型(segmentation ~5MB +
    /// embedding ~30MB + silero ~2MB,共 ~40MB)。已有缓存秒返。失败 swallow,
    /// 真用到再走 path(for:) 的重试逻辑兜底。让新用户在 onboarding voice
    /// training 步开始前模型就 ready,避免训完声音模型还没下完导致训练失败。
    func prefetchAll() async {
        await withTaskGroup(of: Void.self) { group in
            for model in [SpeakerModel.segmentation, .embedding, .vadSilero] {
                group.addTask { [weak self] in
                    _ = try? await self?.path(for: model)
                }
            }
        }
    }

    private func download(_ model: SpeakerModel, to tmp: URL, final dest: URL) async throws {
        guard let url = URL(string: model.url) else {
            throw NSError(domain: "MyPortrait.SpeakerModel", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "bad model URL"])
        }
        logger.info("downloading speaker model: \(model.filename, privacy: .public)")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "MyPortrait.SpeakerModel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "MyPortrait.SpeakerModel", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "empty download body"])
        }
        // 原子写入：先写 .downloading 临时文件，再 rename。
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
