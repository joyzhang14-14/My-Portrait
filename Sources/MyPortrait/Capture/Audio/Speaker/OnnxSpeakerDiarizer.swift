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
            ConfigStore.shared.current.capture.audio.speakerIdEnabled
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

        // 局部 speaker id（chunk 内）→ DB 持久 speaker id。
        // 每个局部说话人用它「最长的那段」去解析 —— 段越长，CAM++ 向量越稳。
        var localToDB: [Int: Int64] = [:]
        for (local, segs) in Dictionary(grouping: speech, by: { $0.localSpeaker }) {
            guard let best = segs.max(by: { $0.samples.count < $1.samples.count })
            else { continue }
            if let id = await resolveSpeaker(
                embedding: best.embedding, speechSamples: best.samples.count
            ) {
                localToDB[local] = id
            }
        }

        var out: [DiarizedSegment] = []
        for s in speech {
            out.append(DiarizedSegment(
                startS: s.start, endS: s.end,
                speakerId: localToDB[s.localSpeaker], samples: s.samples
            ))
        }

        // 说话人识别完全靠声纹匹配 + Voice Training（读 30s 建干净声纹）。
        // 不再用「麦克风+单人 → 按名字自动命名」那条粗启发式（已删 audio.userName）。

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

    /// 最短入库语音时长。短于此的段 CAM++ 向量不够可靠，不写库（只做只读匹配）。
    /// 16kHz × 2s = 32000 样本。
    private static let minEnrollSamples = 32_000

    /// embedding → DB 持久 speaker id。
    ///
    /// 命中已有说话人 → 复用 id；只有足够长的段才把向量并进去（保持 centroid 干净）。
    /// 未命中 → 仅足够长的段才新建说话人；短段不够可靠，返回 nil（留空标签）。
    private func resolveSpeaker(embedding: [Float], speechSamples: Int) async -> Int64? {
        let longEnough = speechSamples >= Self.minEnrollSamples
        if let matched = try? await db.matchSpeaker(embedding: embedding) {
            if longEnough {
                try? await db.addEmbeddingToSpeaker(speakerId: matched, embedding: embedding)
            }
            return matched
        }
        guard longEnough else { return nil }
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
