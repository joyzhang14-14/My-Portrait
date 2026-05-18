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

    private var ingestTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?

    init(
        db: PortraitDB,
        audio: AudioCaptureService,
        reporter: UnimplementedReporter,
        power: PowerWatcher,
        vad: VADSegmenter = VADSegmenter(),
        whisper: WhisperKitWrapper = WhisperKitWrapper(),
        speaker: any SpeakerDiarizer = NoopSpeakerDiarizer()
    ) {
        self.db = db
        self.audio = audio
        self.reporter = reporter
        self.power = power
        self.vad = vad
        self.whisper = whisper
        self.speaker = speaker
    }

    func start() {
        guard ingestTask == nil else { return }

        let stream = audio.segmentEvents
        ingestTask = Task.detached(priority: .utility) { [weak self] in
            for await segment in stream {
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
        ingestTask?.cancel()
        transcribeTask?.cancel()
        powerTask?.cancel()
        ingestTask = nil
        transcribeTask = nil
        powerTask = nil
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
            device: defaultDeviceName(),
            isInput: true,
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
            // 电池模式：什么都不干。
            return
        }

        let chunks: [AudioChunkRecord]
        do {
            chunks = try await db.pendingAudioChunks(limit: queueBatchLimit)
        } catch {
            logger.warning("pendingAudioChunks failed: \(String(describing: error), privacy: .public)")
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

    private func transcribeOne(chunk: AudioChunkRecord) async {
        guard let chunkId = chunk.id else { return }

        // 1. 标 in_progress
        try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .inProgress)

        // 2. 转录
        let text: String
        do {
            text = try await whisper.transcribe(wavPath: chunk.filePath)
        } catch {
            logger.error("whisper transcribe failed for \(chunk.filePath, privacy: .public): \(String(describing: error), privacy: .public)")
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .failed)
            return
        }

        // 3. 说话人识别（stub 永远返回 nil；真实实现替换 SpeakerDiarizer 即可）。
        let speakerId = await speaker.diarize(wavPath: chunk.filePath)

        // 4. 写 sidecar JSON 到文件系统（设计文档"真相在文件系统"）。
        //    路径 = wav 同目录 + 同名 + .transcript.json
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        writeTranscriptSidecar(wavPath: chunk.filePath, text: text, chunk: chunk, transcribedAtMs: nowMs)

        // 5. 写转录行到 DB（索引镜像）。
        let record = TranscriptionRecord(
            audioChunkId: chunkId,
            startS: 0,
            endS: chunk.durationS,
            text: text,
            speakerId: speakerId,
            engine: "whisperkit",
            transcribedAtMs: nowMs
        )
        do {
            try await db.insertTranscription(record)
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .done)
        } catch {
            logger.error("DB insertTranscription failed: \(String(describing: error), privacy: .public)")
            try? await db.updateAudioChunkStatus(chunkId: chunkId, status: .failed)
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

    private func defaultDeviceName() -> String {
        // P4：单设备占位。后续可读 AVCaptureDevice.default(for: .audio)?.localizedName
        "default_microphone"
    }
}
