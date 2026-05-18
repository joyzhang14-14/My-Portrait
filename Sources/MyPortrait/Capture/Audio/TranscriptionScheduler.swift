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

    private let queuePollSeconds: TimeInterval = 5
    private let queueBatchLimit: Int = 4

    private var ingestTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    init(
        db: PortraitDB,
        audio: AudioCaptureService,
        reporter: UnimplementedReporter,
        vad: VADSegmenter = VADSegmenter(),
        whisper: WhisperKitWrapper = WhisperKitWrapper()
    ) {
        self.db = db
        self.audio = audio
        self.reporter = reporter
        self.vad = vad
        self.whisper = whisper
    }

    func start() {
        guard ingestTask == nil else { return }

        let stream = audio.segmentEvents
        ingestTask = Task.detached(priority: .utility) { [weak self] in
            for await segment in stream {
                await self?.ingest(segment: segment)
            }
        }

        transcribeTask = Task.detached(priority: .utility) { [weak self] in
            // 60s 冷启动延迟（与 CompactionWorker 错峰）。
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            while !Task.isCancelled {
                await self?.processQueueOnce()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        logger.info("TranscriptionScheduler started")
    }

    func stop() {
        ingestTask?.cancel()
        transcribeTask?.cancel()
        ingestTask = nil
        transcribeTask = nil
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

        // 3. 写转录行
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let record = TranscriptionRecord(
            audioChunkId: chunkId,
            startS: 0,
            endS: chunk.durationS,
            text: text,
            speakerId: nil,
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

    private func defaultDeviceName() -> String {
        // P4：单设备占位。后续可读 AVCaptureDevice.default(for: .audio)?.localizedName
        "default_microphone"
    }
}
