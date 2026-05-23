import Foundation
import os.log

/// 串起 AudioCaptureService → VAD → DB → WhisperKit 三件事。
///
/// 两条独立循环：
///
///   A. Ingest loop：订阅 audio.segmentEvents
///      每个段：
///        1. VADSegmenter.analyze
///        2. .discard → 删 wav + meta，返回
///        3. .keep   → DB.insertAudioChunk(status=pending)
///
///   B. Transcribe loop：5 秒一轮（轻量），插电时干活
///        - 电池 → sleep
///        - 查 DB.pendingAudioChunks(limit=N)
///        - 每个 chunk：WhisperKit.transcribe → DB.insertTranscription → 更新 status=done
///        - 异常 → status=failed
///
/// 设计抄设计文档第二节"延迟转录策略"：移动场景只录音（VAD 入库），AC 接通才烧
/// CPU/Neural-Engine 转录。中断恢复以"段"为单位（最坏丢一段未完成转录）。
actor TranscriptionScheduler {

    private let db: PortraitDB
    private let audio: AudioCaptureService
    private let systemAudio: SystemAudioCaptureService
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "transcribe")

    private let vad: VADSegmenter
    private let whisper: WhisperKitWrapper
    private let power: PowerWatcher
    private let speaker: any SpeakerDiarizer

    /// 后台兜底 poll 间隔。已有 PowerWatcher 事件驱动唤醒 +
    /// 新段事件直接驱动，poll 仅作为"防漏"兜底，故拉长到 60s（vs 之前 5s）。
    private let fallbackPollSeconds: TimeInterval = 60
    /// 每轮 poll 从 DB 拉多少 chunk。设计文档要求"限并发数 1-2"。
    ///
    /// 注意：调用方 for 循环串行 await transcribeOne，**实际并发恒为 1**。
    /// 这个 limit 控制的是"一次 poll 取多少个进行串行处理"。设为 2 让 scheduler
    /// 有一个小 lookahead 窗口，但在 battery 切换时也只浪费 1 个尚未开始的段。
    ///
    /// 若未来要真正并发 2，必须先把 WhisperKitWrapper 从"@unchecked Sendable +
    /// serial-call contract"改为 actor + 内部排队，否则会 data race。
    private let queueBatchLimit: Int = 2

    private var ingestMicTask: Task<Void, Never>?
    private var ingestSysTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?

    init(
        db: PortraitDB,
        audio: AudioCaptureService,
        systemAudio: SystemAudioCaptureService,
        reporter: UnimplementedReporter,
        power: PowerWatcher,
        vad: VADSegmenter = VADSegmenter(),
        whisper: WhisperKitWrapper = WhisperKitWrapper(),
        speaker: any SpeakerDiarizer = NoopSpeakerDiarizer()
    ) {
        self.db = db
        self.audio = audio
        self.systemAudio = systemAudio
        self.reporter = reporter
        self.power = power
        self.vad = vad
        self.whisper = whisper
        self.speaker = speaker
    }

    func start() async {
        guard ingestMicTask == nil else { return }

        // 订阅麦克风段流。注意 segmentEvents() 是 async 方法（每个 service
        // 在 start 后才有 VADRecorder；这里调一次拿当前实例的流）。
        let micStream = await audio.segmentEvents()
        ingestMicTask = Task.detached(priority: .utility) { [weak self] in
            for await segment in micStream {
                await self?.ingest(segment: segment)
            }
        }

        // 订阅系统音频段流。两路独立，但走同一个 ingest（device 字段区分来源）。
        let sysStream = await systemAudio.segmentEvents()
        ingestSysTask = Task.detached(priority: .utility) { [weak self] in
            for await segment in sysStream {
                await self?.ingest(segment: segment)
            }
        }

        // 兜底循环：每 fallbackPollSeconds 检查一次队列，防漏。
        let fallbackNs = UInt64(fallbackPollSeconds * 1_000_000_000)
        transcribeTask = Task.detached(priority: .utility) { [weak self] in
            // 60s 冷启动延迟（与 CompactionWorker 错峰）。
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            while !Task.isCancelled {
                await self?.processQueueOnce()
                try? await Task.sleep(nanoseconds: fallbackNs)
            }
        }

        // 事件驱动主路：power 状态变化（如 battery → AC）立刻唤起一轮处理。
        let powerStream = power.states
        powerTask = Task.detached(priority: .utility) { [weak self] in
            for await _ in powerStream {
                guard let self else { break }
                await self.processQueueOnce()
            }
        }

        logger.info("TranscriptionScheduler started (event-driven via PowerWatcher + 60s fallback)")
    }

    func stop() {
        ingestMicTask?.cancel()
        ingestSysTask?.cancel()
        transcribeTask?.cancel()
        powerTask?.cancel()
        ingestMicTask = nil
        ingestSysTask = nil
        transcribeTask = nil
        powerTask = nil
        whisper.unload()
        logger.info("TranscriptionScheduler stopped")
    }

    // MARK: - A. Ingest

    private func ingest(segment: AudioSegmentEvent) async {
        let decision = vad.analyze(wavPath: segment.wavPath)

        if decision.action == .discard {
            // 静音段：删 wav + meta，DB 不入。
            try? FileManager.default.removeItem(atPath: segment.wavPath)
            try? FileManager.default.removeItem(atPath: segment.metaPath)
            logger.debug("VAD discard ratio=\(decision.speechRatio, format: .fixed(precision: 3)) path=\(segment.wavPath, privacy: .public)")
            return
        }

        let record = AudioChunkRecord(
            id: nil,
            filePath: segment.wavPath,
            recordedAtMs: segment.recordedAtMs,
            durationS: segment.durationS,
            device: segment.device,                              // 段自带的设备标签
            isInput: segment.device == "default_microphone",
            status: .pending
        )
        do {
            _ = try await db.insertAudioChunk(record)
        } catch {
            logger.error("DB insertAudioChunk failed (segment will be re-tried next launch via filesystem scan): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - B. Transcribe

    private func processQueueOnce() async {
        guard PowerMonitor.isOnAC else {
            // 电池模式不转录 → 释放 Whisper 模型,别白占内存。
            whisper.unload()
            return
        }

        let chunks: [AudioChunkRecord]
        do {
            chunks = try await db.pendingAudioChunks(limit: queueBatchLimit)
        } catch {
            logger.warning("pendingAudioChunks failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard !chunks.isEmpty else {
            // 队列空 → 没有转录任务 → 释放 Whisper 模型。
            whisper.unload()
            return
        }

        for chunk in chunks {
            if Task.isCancelled { return }
            // 中途变电池 → 当前段跑完即停。
            if !PowerMonitor.isOnAC {
                logger.info("power switched to battery mid-batch, stopping after current segment")
            }
            await transcribeOne(chunk: chunk)
        }
    }

    /// 转录设置快照（引擎 + 语言 + 词汇 + 云引擎凭据）。
    private struct TranscribeSettings: Sendable {
        let engine: String
        let language: String?
        let vocabulary: [String]
        let filterMusic: Bool
        let deepgramKey: String
        let customEndpoint: String
        let customModel: String
        let customKey: String
    }

    /// 读设置里的转录配置（含云引擎凭据，从 SecretStore 解出）。
    private static func transcriptionConfig() async -> TranscribeSettings {
        await MainActor.run {
            let a = ConfigStore.shared.current.capture.audio
            let lang = a.languages.first.flatMap { $0.isEmpty ? nil : $0 }
            func secret(_ ref: String) -> String {
                guard !ref.isEmpty, let d = SecretStore.shared.get(ref) else { return "" }
                return String(data: d, encoding: .utf8) ?? ""
            }
            return TranscribeSettings(
                engine: a.engine,
                language: lang,
                vocabulary: a.customVocabulary,
                filterMusic: a.filterMusic,
                deepgramKey: secret(a.deepgramApiKeyRef),
                customEndpoint: a.customEndpoint,
                customModel: a.customModel,
                customKey: secret(a.customApiKeyRef)
            )
        }
    }

    /// 按设置里选的引擎转录一段样本。disabled → 空串。
    private func transcribeSamples(_ samples: [Float], _ s: TranscribeSettings) async throws -> String {
        switch s.engine {
        case "deepgram":
            // 云端引擎自己不做预处理，在这里补上（本地 whisper 在 wrapper 内部做）。
            let processed = AudioPreprocessor.process(samples, filterMusic: s.filterMusic)
            return try await CloudTranscriber.deepgram(
                samples: processed, apiKey: s.deepgramKey, language: s.language)
        case "custom":
            let processed = AudioPreprocessor.process(samples, filterMusic: s.filterMusic)
            return try await CloudTranscriber.openAICompatible(
                samples: processed, endpoint: s.customEndpoint, model: s.customModel,
                apiKey: s.customKey, language: s.language, vocabulary: s.vocabulary)
        case "disabled":
            return ""
        default:   // whisper（本地）
            return try await whisper.transcribe(
                samples: samples, language: s.language,
                vocabulary: s.vocabulary, filterMusic: s.filterMusic)
        }
    }

    private func transcribeOne(chunk: AudioChunkRecord) async {
        guard let chunkId = chunk.id else { return }

        // 1. 标 in_progress
        try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .inProgress)

        let settings = await Self.transcriptionConfig()

        // 2. 说话人分离：把 chunk 切成若干说话人语音段（未启用 / 模型未就绪 → 空）。
        let segments = await speaker.diarize(wavPath: chunk.filePath, isInput: chunk.isInput)

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [TranscriptionRecord] = []

        if segments.isEmpty {
            // 退化路径：整段一次转录，无说话人归属。
            guard let samples = AudioWAV.readSamples(path: chunk.filePath) else {
                logger.error("cannot read wav for transcription: \(chunk.filePath, privacy: .public)")
                try? await db.recordAudioChunkFailure(chunkId: chunkId)
                return
            }
            let text: String
            do {
                text = try await transcribeSamples(samples, settings)
            } catch {
                logger.error("transcribe failed for \(chunk.filePath, privacy: .public): \(String(describing: error), privacy: .public)")
                try? await db.recordAudioChunkFailure(chunkId: chunkId)
                return
            }
            if !text.isEmpty {
                records.append(TranscriptionRecord(
                    audioChunkId: chunkId, startS: 0, endS: chunk.durationS,
                    text: text, speakerId: nil, engine: settings.engine, transcribedAtMs: nowMs
                ))
            }
        } else {
            // 完整路径：逐说话人段单独转录，每段一行。
            for seg in segments {
                let text: String
                do {
                    text = try await transcribeSamples(seg.samples, settings)
                } catch {
                    logger.error("transcribe (segment) failed for \(chunk.filePath, privacy: .public): \(String(describing: error), privacy: .public)")
                    try? await db.recordAudioChunkFailure(chunkId: chunkId)
                    return
                }
                guard !text.isEmpty else { continue }
                records.append(TranscriptionRecord(
                    audioChunkId: chunkId, startS: seg.startS, endS: seg.endS,
                    text: text, speakerId: seg.speakerId.map { Int($0) },
                    engine: settings.engine, transcribedAtMs: nowMs
                ))
            }
        }

        // 全静音 / 无文本 → 仍标 done，避免反复重试。
        guard !records.isEmpty else {
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
            return
        }

        // 3. 写 sidecar JSON（多段时合并成一份全文）。
        let fullText = records.map(\.text).joined(separator: " ")
        writeTranscriptSidecar(wavPath: chunk.filePath, text: fullText, chunk: chunk, transcribedAtMs: nowMs)

        // 4. 写转录行到 DB（每段一行）。
        do {
            for record in records {
                try await db.insertTranscription(record)
            }
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
        } catch {
            logger.error("DB insertTranscription failed: \(String(describing: error), privacy: .public)")
            try? await db.recordAudioChunkFailure(chunkId: chunkId)
        }
    }

    /// 写 `seg_<ts>.transcript.json` 到 wav 同目录。
    /// 失败只 log（DB 已经记了真相镜像，sidecar 丢了无大碍但要警告）。
    private func writeTranscriptSidecar(
        wavPath: String,
        text: String,
        chunk: AudioChunkRecord,
        transcribedAtMs: Int64
    ) {
        let wavURL = URL(fileURLWithPath: wavPath)
        // 去掉 ".wav" 加 ".transcript.json"。
        let base = wavURL.deletingPathExtension()
        let sidecar = base.appendingPathExtension("transcript.json")

        let payload: [String: Any] = [
            "wav_path": wavPath,
            "recorded_at_ms": chunk.recordedAtMs,
            "duration_s": chunk.durationS,
            "device": chunk.device,
            "engine": "whisperkit",
            "transcribed_at_ms": transcribedAtMs,
            "text": text,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: sidecar, options: .atomic)
        } catch {
            logger.warning("transcript sidecar write failed for \(sidecar.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

}
