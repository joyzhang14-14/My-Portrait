import AVFoundation
import Foundation
import os.log

/// 麦克风常开录音。**实时 VAD 切段**（设计文档"VAD 分段：检测到静音超过
/// 阈值时切断当前音频，开始新一段"）。
///
/// 设计：AVAudioEngine + inputNode tap。输入设备原生采样率经 AVAudioConverter
/// 转 16 kHz / mono / Float32（WhisperKit 原生格式）。tap 回调里把 [Float]
/// 喂进 AsyncStream，actor 内部的 processing task 跑状态机。
///
/// 状态机：
///   - SILENT：累计 speech 帧；连续 ≥ speechEntryFrames 帧能量过阈 → 进 SPEECH，开 wav writer
///   - SPEECH：所有帧写盘；连续 ≥ silenceExitFrames 帧低于阈 → 关 writer + 发 event + 回 SILENT
///   - 任意状态：当前段超过 maxSegmentSeconds → 强制切段
///
/// 输出契约与旧版（AVAudioRecorder 30s 轮换）完全一致：
///   - 文件：`~/.portrait/audio_queue/seg_<ISO>.wav`
///   - meta：`seg_<ISO>.meta.json`（采样率、duration、format）
///   - AudioSegmentEvent 通过 `segmentEvents` AsyncStream 推给下游
///
/// 麦克风权限：start() 首次调用触发系统弹窗。
actor AudioCaptureService {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "audio")
    private let audioDir: URL

    // MARK: - VAD 参数（抄 My-Orphies 经验值）

    private let sampleRate: Double = 16_000
    private let frameSamples: Int = 160          // 10ms @ 16kHz
    private let rmsSpeechThreshold: Float = 0.01
    private let rmsSilenceThreshold: Float = 0.005
    private let speechEntryFrames: Int = 3       // ~30ms 连续语音 → 进 SPEECH
    private let silenceExitFrames: Int = 80      // ~800ms 静音 → 切段
    private let minSegmentFrames: Int = 100      // ~1s 最短段（更短的丢弃）
    private let maxSegmentSeconds: TimeInterval = 60  // 设计文档建议；超过强制切

    // MARK: - 引擎

    private let engine = AVAudioEngine()
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // 用一个共享 stream 桥接 audio thread 回调 → actor 处理。
    private var samplesContinuation: AsyncStream<[Float]>.Continuation?
    private var samplesTask: Task<Void, Never>?

    // MARK: - 状态机

    private enum State { case silent, speech }
    private var state: State = .silent
    private var consecutiveSpeechFrames: Int = 0
    private var consecutiveSilenceFrames: Int = 0

    // 当前 SPEECH 段的写盘上下文。
    private var currentWriter: AVAudioFile?
    private var currentWriterURL: URL?
    private var currentWriterStartedAt: Date?
    private var currentWriterFramesWritten: Int = 0

    private var permissionGranted: Bool = false

    /// 写完一个段（已写盘 + 含 meta）后发出。TranscriptionScheduler 订阅。
    nonisolated let segmentEvents: AsyncStream<AudioSegmentEvent>
    private let _segCont: AsyncStream<AudioSegmentEvent>.Continuation

    init(reporter: UnimplementedReporter, audioDir: URL = Storage.audioQueueDir) {
        self.reporter = reporter
        self.audioDir = audioDir
        var c: AsyncStream<AudioSegmentEvent>.Continuation!
        self.segmentEvents = AsyncStream<AudioSegmentEvent> { cont in c = cont }
        self._segCont = c
    }

    // MARK: - 生命周期

    func start() async {
        guard samplesTask == nil else { return }

        // 1. 权限
        permissionGranted = await Self.requestMicrophonePermission()
        if !permissionGranted {
            logger.error("microphone permission denied — audio capture disabled")
            return
        }

        // 2. 目录
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("audio_queue dir create failed: \(String(describing: error), privacy: .public)")
            return
        }

        // 3. 配置引擎 + tap
        do {
            try configureEngineAndStartTap()
        } catch {
            logger.error("engine start failed: \(String(describing: error), privacy: .public)")
            return
        }

        logger.info("AudioCaptureService started (VAD-segmented, 16kHz mono Float32)")
    }

    func stop() async {
        // 1. 停 tap + engine（不再产生 samples）
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        // 2. 关闭 sample stream
        samplesContinuation?.finish()
        samplesContinuation = nil
        samplesTask?.cancel()
        samplesTask = nil

        // 3. 关闭当前正在录的段（如有）
        if state == .speech {
            closeCurrentSegment(reason: "stop")
        }

        // 4. 关闭 events 流
        _segCont.finish()

        logger.info("AudioCaptureService stopped")
    }

    // MARK: - 引擎配置 + tap

    private func configureEngineAndStartTap() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioCaptureService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create 16kHz target format"])
        }
        targetFormat = target

        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "AudioCaptureService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }
        converter = conv

        // Stream 桥：tap callback → actor。
        var c: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]> { cont in c = cont }
        samplesContinuation = c

        let frameSizeOnTap: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: frameSizeOnTap, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.convertAndForward(buffer: buffer, into: c)
        }

        try engine.start()

        // 启动处理任务
        samplesTask = Task { [weak self] in
            for await samples in stream {
                await self?.processSamples(samples)
            }
        }
    }

    /// tap callback 内调用。把 input format → 16kHz mono Float32，yield 进 stream。
    /// 不在 actor 上下文中 —— 严格只动 converter（线程绑定它自己的状态）+ continuation（Sendable）。
    private nonisolated func convertAndForward(
        buffer: AVAudioPCMBuffer,
        into continuation: AsyncStream<[Float]>.Continuation
    ) {
        // converter / targetFormat 都是 actor-isolated 字段，从 nonisolated 回调里
        // 直接访问需要 unsafe 通道。这两个字段在 configureEngineAndStartTap 之后
        // 不再变（直到 stop），且只在该回调里读 —— 用 atomic-snapshot 不会冲突。
        // 但为了让编译器满意，我们走 actor-isolated helper。
        Task { [weak self] in
            guard let self else { return }
            await self.performConversion(buffer: buffer, into: continuation)
        }
    }

    private func performConversion(
        buffer: AVAudioPCMBuffer,
        into continuation: AsyncStream<[Float]>.Continuation
    ) {
        guard let converter, let targetFormat else { return }

        let inputFrames = AVAudioFrameCount(buffer.frameLength)
        let outputCapacity = AVAudioFrameCount(
            Double(inputFrames) * sampleRate / buffer.format.sampleRate
        ) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, output.frameLength > 0,
              let channelData = output.floatChannelData
        else {
            return
        }

        let count = Int(output.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        continuation.yield(samples)
    }

    // MARK: - VAD 状态机

    private func processSamples(_ samples: [Float]) async {
        var i = 0
        while i + frameSamples <= samples.count {
            // RMS over this 10ms frame
            var sumSq: Float = 0
            for j in 0..<frameSamples {
                let s = samples[i + j]
                sumSq += s * s
            }
            let rms = (sumSq / Float(frameSamples)).squareRoot()

            let isSpeech = rms > rmsSpeechThreshold
            let isSilent = rms < rmsSilenceThreshold

            switch state {
            case .silent:
                if isSpeech {
                    consecutiveSpeechFrames += 1
                    if consecutiveSpeechFrames >= speechEntryFrames {
                        openSegment()
                        state = .speech
                        consecutiveSilenceFrames = 0
                    }
                } else {
                    consecutiveSpeechFrames = 0
                }

            case .speech:
                // 始终写当前帧
                let frameSamples = Array(samples[i..<(i + self.frameSamples)])
                writeFrameToCurrentSegment(frameSamples)

                if isSilent {
                    consecutiveSilenceFrames += 1
                    if consecutiveSilenceFrames >= silenceExitFrames {
                        closeCurrentSegment(reason: "silence")
                        state = .silent
                        consecutiveSpeechFrames = 0
                    }
                } else {
                    consecutiveSilenceFrames = 0
                }

                // 强制切段：超过 max。
                if let startedAt = currentWriterStartedAt,
                   Date().timeIntervalSince(startedAt) >= maxSegmentSeconds
                {
                    closeCurrentSegment(reason: "max_duration")
                    // 立刻开新段继续（用户还在持续说话）。
                    openSegment()
                    consecutiveSilenceFrames = 0
                }
            }

            i += frameSamples
        }
    }

    // MARK: - 段文件生命周期

    private func openSegment() {
        let now = Date()
        let segName = "seg_\(Self.tsFormatter.string(from: now))"
        let wavURL = audioDir.appendingPathComponent("\(segName).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            currentWriter = file
            currentWriterURL = wavURL
            currentWriterStartedAt = now
            currentWriterFramesWritten = 0
        } catch {
            logger.error("open writer failed for \(wavURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            currentWriter = nil
            currentWriterURL = nil
            currentWriterStartedAt = nil
        }
    }

    private func writeFrameToCurrentSegment(_ frame: [Float]) {
        guard let writer = currentWriter, let format = targetFormat else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)) else { return }
        buf.frameLength = AVAudioFrameCount(frame.count)
        if let channels = buf.floatChannelData {
            for i in 0..<frame.count { channels[0][i] = frame[i] }
        }
        do {
            try writer.write(from: buf)
            currentWriterFramesWritten += frame.count
        } catch {
            logger.warning("write frame failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func closeCurrentSegment(reason: String) {
        guard let writer = currentWriter,
              let wavURL = currentWriterURL,
              let startedAt = currentWriterStartedAt
        else { return }

        // AVAudioFile 关闭：丢弃引用即可（ARC 调 dealloc 完成）。
        _ = writer
        currentWriter = nil

        let endedAt = Date()
        let durationS = endedAt.timeIntervalSince(startedAt)
        let framesWritten = currentWriterFramesWritten

        // 太短的段丢弃（< minSegmentFrames 帧 ≈ < 1s）。
        if framesWritten < minSegmentFrames {
            try? FileManager.default.removeItem(at: wavURL)
            currentWriterURL = nil
            currentWriterStartedAt = nil
            currentWriterFramesWritten = 0
            return
        }

        let metaURL = wavURL.deletingPathExtension().appendingPathExtension("meta.json")
        let segment = AudioSegmentEvent(
            wavPath: wavURL.path,
            metaPath: metaURL.path,
            recordedAtMs: Int64(startedAt.timeIntervalSince1970 * 1000),
            durationS: durationS
        )
        writeMeta(at: metaURL, segment: segment, closeReason: reason)
        _segCont.yield(segment)

        currentWriterURL = nil
        currentWriterStartedAt = nil
        currentWriterFramesWritten = 0
    }

    private func writeMeta(at url: URL, segment: AudioSegmentEvent, closeReason: String) {
        let meta: [String: Any] = [
            "wav_path": segment.wavPath,
            "recorded_at_ms": segment.recordedAtMs,
            "duration_s": segment.durationS,
            "sample_rate": Int(sampleRate),
            "channels": 1,
            "format": "pcm_f32le",
            "vad": "rms",
            "close_reason": closeReason,    // "silence" / "max_duration" / "stop"
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("meta write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 工具

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

/// 一个录完的音频段（已写盘）。变长，由 VAD 决定起止。
public struct AudioSegmentEvent: Sendable {
    public let wavPath: String
    public let metaPath: String
    public let recordedAtMs: Int64
    public let durationS: TimeInterval
}
