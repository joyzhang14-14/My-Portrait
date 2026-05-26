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
    case embedding
    /// Silero VAD v5 —— 语音活动检测（不属于说话人,但同样是可下载的音频 ONNX 模型）。
    case vadSilero

    var filename: String {
        switch self {
        case .segmentation: return "segmentation-3.0.onnx"
        case .embedding:    return "wespeaker_en_voxceleb_CAM++.onnx"
        case .vadSilero:    return "silero_vad.onnx"
        }
    }

    var url: String {
        switch self {
        case .segmentation, .embedding:
            let base = "https://github.com/screenpipe/screenpipe/raw/refs/heads/main/crates/screenpipe-audio/models/pyannote"
            return "\(base)/\(filename)"
        case .vadSilero:
            return "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"
        }
    }
}

/// 模型下载 / 磁盘缓存。原子写入 + 重试，port 自 screenpipe models.rs。
actor SpeakerModelStore {
    static let shared = SpeakerModelStore()

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
