import AVFoundation
import Foundation
import os.log

/// VAD 状态机 + wav 段写盘的共享实现。
///
/// 输入：16 kHz mono Float32 PCM 样本流（调用 `feed(_:)` 喂进来）。
/// 输出：写完一个段（满足 minSegmentFrames 且静音超阈值）就发 `AudioSegmentEvent`。
///
/// 抽出来的目的：AudioCaptureService（麦克风）和 SystemAudioCaptureService
/// （loopback）共用同一套 VAD + 写盘逻辑，只是数据源 + 设备标签不同。
///
/// 状态机（与之前 AudioCaptureService 内嵌的版本一致）：
///   - SILENT：累计 speech 帧；连续 ≥ speechEntryFrames 帧能量过阈 → 进 SPEECH，开 wav writer
///   - SPEECH：所有帧写盘；连续 ≥ silenceExitFrames 帧低于阈 → 关 writer + 发 event + 回 SILENT
///   - 任意状态：当前段超过 maxSegmentSeconds → 强制切段
actor VADRecorder {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "vad")

    // MARK: - 配置（不可变）

    /// 设备标签，写入 wav 段的 meta.json 和 AudioSegmentEvent.device。
    /// 例："default_microphone" 或 "system_loopback"。
    private let deviceLabel: String

    private let audioDir: URL

    /// VAD 参数
    private let sampleRate: Double = 16_000
    /// VAD 帧长 = Silero v5 固定 512 样本（≈32ms）。RMS 退化路径也用此帧长。
    private let frameSamples: Int = SileroVAD.frameSize
    /// Silero 语音概率阈值。系统音频混背景音乐，阈值更低（抄 screenpipe）。
    private let speechProbThreshold: Float
    private let silenceProbThreshold: Float = 0.35
    /// RMS 退化阈值（Silero 模型未就绪时用）。
    private let rmsSpeechThreshold: Float = 0.01
    private let rmsSilenceThreshold: Float = 0.005
    /// 连续 N 帧语音才进 SPEECH（3 × 32ms ≈ 96ms）。
    private let speechEntryFrames: Int = 3
    /// 连续 N 帧静音才退出 SPEECH（25 × 32ms ≈ 800ms）。
    private let silenceExitFrames: Int = 25
    private let minSegmentFrames: Int = 100
    private let maxSegmentSeconds: TimeInterval = 60

    private let targetFormat: AVAudioFormat

    // MARK: - 状态

    private enum State { case silent, speech }
    private var state: State = .silent
    private var consecutiveSpeechFrames: Int = 0
    private var consecutiveSilenceFrames: Int = 0

    /// 攒够 512 样本才送 VAD —— feed 进来的样本块大小不定。
    private var pendingSamples: [Float] = []
    /// Silero VAD。懒加载（首次需下载模型）；nil 时退化为 RMS。
    private var silero: SileroVAD?
    private var sileroLoadStarted = false

    private var currentWriter: AVAudioFile?
    private var currentWriterURL: URL?
    private var currentWriterStartedAt: Date?
    private var currentWriterFramesWritten: Int = 0

    // MARK: - 输出流

    nonisolated let segmentEvents: AsyncStream<AudioSegmentEvent>
    private let _segCont: AsyncStream<AudioSegmentEvent>.Continuation

    init(deviceLabel: String, audioDir: URL = Storage.audioQueueDir) {
        self.deviceLabel = deviceLabel
        self.audioDir = audioDir
        // 系统音频（loopback）常混背景音乐，Silero 置信度偏低 → 用更低的语音阈值。
        self.speechProbThreshold = (deviceLabel == "system_loopback") ? 0.15 : 0.5
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        var c: AsyncStream<AudioSegmentEvent>.Continuation!
        self.segmentEvents = AsyncStream<AudioSegmentEvent> { cont in c = cont }
        self._segCont = c
    }

    // MARK: - 公共 API

    /// 喂样本。调用方负责 16kHz mono Float32 转换。
    func feed(_ samples: [Float]) {
        ensureSileroLoading()
        pendingSamples.append(contentsOf: samples)
        while pendingSamples.count >= frameSamples {
            let frame = Array(pendingSamples.prefix(frameSamples))
            pendingSamples.removeFirst(frameSamples)
            processFrame(frame)
        }
    }

    /// 处理一个 512 样本帧：跑 VAD 决策 + 推进状态机。
    private func processFrame(_ frame: [Float]) {
        let (isSpeech, isSilent) = decide(frame)

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
            writeFrameToCurrentSegment(frame)

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

            // 强制切：超过 max。
            if let startedAt = currentWriterStartedAt,
               Date().timeIntervalSince(startedAt) >= maxSegmentSeconds
            {
                closeCurrentSegment(reason: "max_duration")
                openSegment()
                consecutiveSilenceFrames = 0
            }
        }
    }

    /// VAD 决策：Silero 就绪用神经网络概率，否则退化为 RMS 能量。
    private func decide(_ frame: [Float]) -> (isSpeech: Bool, isSilent: Bool) {
        if let silero, let prob = silero.probability(frame) {
            return (prob > speechProbThreshold, prob < silenceProbThreshold)
        }
        var sumSq: Float = 0
        for s in frame { sumSq += s * s }
        let rms = (sumSq / Float(frame.count)).squareRoot()
        return (rms > rmsSpeechThreshold, rms < rmsSilenceThreshold)
    }

    /// 懒加载 Silero VAD 模型（首次需后台下载）。失败则一直走 RMS 退化路径。
    private func ensureSileroLoading() {
        guard !sileroLoadStarted else { return }
        sileroLoadStarted = true
        Task {
            do {
                let path = try await SpeakerModelStore.shared.path(for: .vadSilero)
                self.silero = try SileroVAD(modelPath: path.path)
                self.logger.info("Silero VAD loaded")
            } catch {
                self.logger.warning("Silero VAD load failed, using RMS fallback: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 关闭当前段（如有）+ 关 events 流。capture service stop() 调。
    func flush() {
        if state == .speech {
            closeCurrentSegment(reason: "stop")
        }
        _segCont.finish()
    }

    // MARK: - 私有

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
        guard let writer = currentWriter else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(frame.count)) else { return }
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
        guard let _ = currentWriter,
              let wavURL = currentWriterURL,
              let startedAt = currentWriterStartedAt
        else { return }

        currentWriter = nil   // ARC dealloc 收 AVAudioFile

        let endedAt = Date()
        let durationS = endedAt.timeIntervalSince(startedAt)
        let framesWritten = currentWriterFramesWritten

        // 太短的段丢弃。
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
            durationS: durationS,
            device: deviceLabel
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
            "device": deviceLabel,
            "vad": silero != nil ? "silero" : "rms",
            "close_reason": closeReason,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("meta write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()
}
