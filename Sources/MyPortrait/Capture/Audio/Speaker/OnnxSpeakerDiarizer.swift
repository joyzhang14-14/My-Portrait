import AVFoundation
import Foundation
import os.log

/// `SpeakerDiarizer` 的真实实现。复刻 screenpipe 的说话人分离：
///   1. pyannote segmentation-3.0 找语音段边界
///   2. wespeaker CAM++ 抽 512 维音色向量
///   3. 跟 DB 里的持久说话人做余弦匹配（命中 → 复用 id，未命中 → 新建）
///
/// actor 隔离 —— ONNX 推理与 FbankExtractor（持 FFTSetup）天然串行，满足
/// 模型的串行调用契约。
actor OnnxSpeakerDiarizer: SpeakerDiarizer {

    private let db: PortraitDB
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "speaker")

    private var segModel: SpeakerSegmentationModel?
    private var embModel: SpeakerEmbeddingExtractor?
    /// 模型加载失败后不再反复重试（下载失败 / 文件损坏）。
    private var loadFailed = false

    init(db: PortraitDB) {
        self.db = db
    }

    func diarize(wavPath: String, isInput: Bool) async -> [DiarizedSegment] {
        // 设置里的 speaker_id_enabled 开关 —— 关掉直接退化。
        let enabled = await MainActor.run {
            ConfigStore.shared.current.recording.audio.speakerIdEnabled
        }
        guard enabled else { return [] }

        guard let (seg, emb) = await ensureModels() else { return [] }
        guard let samples = Self.readWav16k(wavPath) else {
            logger.warning("diarize: cannot read wav \(wavPath, privacy: .public)")
            return []
        }

        let manager = EmbeddingManager()
        let speech = SpeakerSegmenter.segments(
            samples: samples, sampleRate: 16000,
            segmentation: seg, embedding: emb, manager: manager
        )
        guard !speech.isEmpty else { return [] }

        // 局部 speaker id（chunk 内）→ DB 持久 speaker id，每个解析一次。
        var localToDB: [Int: Int64] = [:]
        var out: [DiarizedSegment] = []
        for s in speech {
            let dbId: Int64?
            if let cached = localToDB[s.localSpeaker] {
                dbId = cached
            } else {
                dbId = await resolveSpeaker(embedding: s.embedding)
                if let id = dbId { localToDB[s.localSpeaker] = id }
            }
            out.append(DiarizedSegment(
                startS: s.start, endS: s.end, speakerId: dbId, samples: s.samples
            ))
        }

        // 麦克风输入 + 全程单一说话人 → 多半是用户本人，自动命名。
        if isInput, localToDB.count == 1, let onlyId = localToDB.values.first {
            let userName = await MainActor.run {
                ConfigStore.shared.current.recording.audio.userName
            }
            let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? await db.nameSpeakerIfUnnamed(speakerId: onlyId, name: trimmed)
            }
        }

        return out
    }

    // MARK: - 私有

    private func ensureModels() async -> (SpeakerSegmentationModel, SpeakerEmbeddingExtractor)? {
        if let s = segModel, let e = embModel { return (s, e) }
        guard !loadFailed else { return nil }
        do {
            let segPath = try await SpeakerModelStore.shared.path(for: .segmentation)
            let embPath = try await SpeakerModelStore.shared.path(for: .embedding)
            let s = try SpeakerSegmentationModel(modelPath: segPath.path)
            let e = try SpeakerEmbeddingExtractor(modelPath: embPath.path, fbank: FbankExtractor())
            segModel = s
            embModel = e
            logger.info("speaker models loaded")
            return (s, e)
        } catch {
            logger.error("speaker model load failed: \(String(describing: error), privacy: .public)")
            loadFailed = true
            return nil
        }
    }

    /// embedding → DB 持久 speaker id。命中已有说话人则追加样本，否则新建。
    private func resolveSpeaker(embedding: [Float]) async -> Int64? {
        if let matched = try? await db.matchSpeaker(embedding: embedding) {
            try? await db.addEmbeddingToSpeaker(speakerId: matched, embedding: embedding)
            return matched
        }
        return try? await db.enrollSpeaker(embedding: embedding)
    }

    /// 读 wav → 16kHz mono float 样本。AVAudioFile 的 processingFormat 总是
    /// Float32 deinterleaved，采样率取文件本身（采集管线全程 16kHz）。
    private static func readWav16k(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        guard let ch = buf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}
