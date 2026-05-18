import AVFoundation
import Foundation
import os.log

/// 麦克风常开录音。每 30s 切一个 wav 段。
///
/// 设计简化（vs My-Orphies）：
///   - 不在 tap 回调里跑 VAD —— 段落写完后离线分析（足够准）
///   - 用 AVAudioRecorder（不是 AVAudioEngine）：API 简单、稳定、不用做格式转换
///   - 段长固定 30s，无重叠（重叠语义复杂、转录文本会重复）
///
/// 文件路径：
///   `~/.portrait/audio_queue/seg_YYYY-MM-DDTHH-mm-ss.wav`
///   `~/.portrait/audio_queue/seg_*.meta.json`
///
/// 16 kHz / mono / Float32 PCM（WhisperKit 原生格式，转录时无需转换）。
///
/// 麦克风权限：
///   首次启动时 `AVAudioApplication.requestRecordPermission` 触发系统弹窗。
///   拒绝 → service 启动失败，状态栏 reporter 不会响（不是 stub 错），但 log
///   会 ERROR；TranscriptionScheduler 看到没新段会闲置。
///
/// VAD 分析放到 [[VADSegmenter]] 完成；本类只负责录 + 切。
actor AudioCaptureService {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "audio")
    private let audioDir: URL
    private let segmentDurationSeconds: TimeInterval = 30.0

    private var recorder: AVAudioRecorder?
    private var rotationTask: Task<Void, Never>?
    private var permissionGranted: Bool = false

    /// 写完一个段（已写盘 + 已 VAD）后发出。TranscriptionScheduler 或 DB 入库逻辑订阅。
    nonisolated let segmentEvents: AsyncStream<AudioSegmentEvent>
    private let _segCont: AsyncStream<AudioSegmentEvent>.Continuation

    init(reporter: UnimplementedReporter, audioDir: URL = Storage.audioQueueDir) {
        self.reporter = reporter
        self.audioDir = audioDir
        var c: AsyncStream<AudioSegmentEvent>.Continuation!
        self.segmentEvents = AsyncStream<AudioSegmentEvent> { cont in c = cont }
        self._segCont = c
    }

    func start() async {
        guard rotationTask == nil else { return }

        // 1. 权限。
        let granted = await Self.requestMicrophonePermission()
        permissionGranted = granted
        if !granted {
            logger.error("microphone permission denied — audio capture disabled")
            return
        }

        // 2. 目录就绪。
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("audio_queue dir create failed: \(String(describing: error), privacy: .public)")
            return
        }

        // 3. 启动旋转循环。
        rotationTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runRotationLoop()
        }
        logger.info("AudioCaptureService started (segment=\(self.segmentDurationSeconds)s)")
    }

    func stop() async {
        rotationTask?.cancel()
        rotationTask = nil
        if let r = recorder, r.isRecording {
            r.stop()
        }
        recorder = nil
        _segCont.finish()
        logger.info("AudioCaptureService stopped")
    }

    // MARK: - 私有

    private func runRotationLoop() async {
        while !Task.isCancelled {
            // 启一个段。
            let now = Date()
            let segName = "seg_\(Self.tsFormatter.string(from: now))"
            let wavURL = audioDir.appendingPathComponent("\(segName).wav")
            let metaURL = audioDir.appendingPathComponent("\(segName).meta.json")

            do {
                let r = try Self.makeRecorder(url: wavURL)
                recorder = r
                guard r.record() else {
                    logger.error("recorder.record() returned false; aborting loop")
                    return
                }
            } catch {
                logger.error("recorder init failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // 等满 30s 或被 cancel。
            try? await Task.sleep(nanoseconds: UInt64(segmentDurationSeconds * 1_000_000_000))

            // 停止当前段。
            if let r = recorder, r.isRecording {
                r.stop()
            }
            recorder = nil

            if Task.isCancelled { return }

            // 写 meta + 发事件（VAD 判断在 scheduler 或下游做；保留所有段，由
            // VADSegmenter 决定保留/丢弃）。
            let endedAt = Date()
            let segment = AudioSegmentEvent(
                wavPath: wavURL.path,
                metaPath: metaURL.path,
                recordedAtMs: Int64(now.timeIntervalSince1970 * 1000),
                durationS: endedAt.timeIntervalSince(now)
            )
            writeMeta(at: metaURL, segment: segment)
            _segCont.yield(segment)
        }
    }

    private func writeMeta(at url: URL, segment: AudioSegmentEvent) {
        let meta: [String: Any] = [
            "wav_path": segment.wavPath,
            "recorded_at_ms": segment.recordedAtMs,
            "duration_s": segment.durationS,
            "sample_rate": 16_000,
            "channels": 1,
            "format": "pcm_f32le",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("meta write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func makeRecorder(url: URL) throws -> AVAudioRecorder {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioRecorder(url: url, settings: settings)
    }

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated(unsafe) private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()
}

/// 一个录完的音频段（已写盘）。
public struct AudioSegmentEvent: Sendable {
    public let wavPath: String
    public let metaPath: String
    public let recordedAtMs: Int64
    public let durationS: TimeInterval
}
