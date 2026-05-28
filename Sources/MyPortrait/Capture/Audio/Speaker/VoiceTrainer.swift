import AVFoundation
import Foundation
import Observation
import os.log

/// 声纹训练 —— **embedding-based,跟转录 / 电源 / 全局 audio capture 完全解耦**。
///
/// 设计:
/// 1. UI 点 "Start training" → `start()` 起一个独立的 `AVAudioEngine` 自己
///    监听麦克风,把样本累积到内存 buffer(转 16kHz mono Float32)
/// 2. 30s 倒计时跑完 / 用户点 Done → `assign(name:)` 停 engine、把整段
///    buffer 喂给 `SpeakerEmbeddingExtractor`(wespeaker CAM++)算出 512 维
///    embedding,直接写进 speakers + speaker_embeddings 表
/// 3. 之后 diarizer / matchSpeaker 自然会用这条 centroid 把新音频匹配回
///    用户名下
///
/// 老版本是"等 transcription + diarization 跑完投票",依赖 Whisper +
/// pyannote + 聚类全链路,任何一环挂(电源没接 / 模型没下完 / 阈值不匹配)
/// 训练就 timeout。新版本只需:**麦克风权限 + wespeaker CAM++ 模型 ready**。
///
/// 单例:capture buffer 要在 UI dismiss 倒计时 sheet 后仍存活(用户可能
/// 关掉 Speakers 设置页才看到 success/failure),所以不挂在 View 上。
@MainActor
@Observable
final class VoiceTrainer {

    static let shared = VoiceTrainer()

    enum Phase: Equatable {
        case idle
        case recording                 // mic 在收
        case processing                // 算 embedding + 写 DB
        case success(name: String)
        case failure(String)
    }

    private(set) var phase: Phase = .idle

    /// 训练用的目标采样率(wespeaker CAM++ 训练时就是 16kHz)。
    private static let targetSampleRate: Double = 16_000

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "voice-training")
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var buffer: [Float] = []
    /// 后台 Task 占位,防并发触发。
    private var assignTask: Task<Void, Never>?

    private init() {}

    var isRunning: Bool {
        if case .recording = phase { return true }
        if case .processing = phase { return true }
        return false
    }

    /// 开始捕音。UI 在倒计时开始时调一次。idempotent —— 重复调返回 false。
    /// 失败原因(没麦克风权限 / engine 起不来)写进 phase。
    @discardableResult
    func start() -> Bool {
        guard case .idle = phase else { return false }

        // 预检 wespeaker embedding 模型在磁盘上没。新用户首启,后台 prefetchAll
        // 还没跑完时,这里能立刻提示用户"模型还在下",避免录满 30s 才在
        // assign() 阶段才发现模型缺失浪费时间。
        if !SpeakerModelStore.isOnDisk(.embedding) {
            phase = .failure("AI voice model still downloading — wait a few seconds and try again.")
            logger.warning("voice training blocked: embedding model not on disk yet")
            return false
        }

        buffer.removeAll(keepingCapacity: true)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            phase = .failure("Couldn't construct audio format.")
            return false
        }
        targetFormat = target

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // 用 nil → 系统选 tap 点真实格式,跟 SystemAudioCaptureService 同一
        // 套路绕开 outputFormat(forBus:) 撒谎。converter 在每帧 buffer 回调
        // 里按真实 buffer.format 懒建。
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
            // ⚠ tap callback 跑在 AVFAudio RealtimeMessenger 队列上,**不是 main**。
            // Swift 6 runtime 现在严格检查:闭包不能捕获 @MainActor 隔离的 self,
            // 也不能 `[weak self] guard let self` —— 那一访问就 SIGTRAP
            // (_dispatch_assert_queue_fail in _swift_task_checkIsolatedSwift)。
            // 解法:完全不捕获 self。只调 nonisolated static 把音频 copy 成
            // 值类型,然后 Task @MainActor 里通过 .shared 拿单例处理累积。
            let frameCount = AVAudioFrameCount(buf.frameLength)
            guard frameCount > 0 else { return }
            let format = buf.format
            let rawSamples = VoiceTrainer.copyToFloat(buf)
            Task { @MainActor in
                VoiceTrainer.shared.appendCapturedSamples(rawSamples, sourceFormat: format)
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            // 按钮层 micGranted 已经拦住未授权,这里跑到大概率是 (a) 用户
            // 跨进程刚撤销权限 / (b) 硬件被独占(蓝牙在 HFP)/ (c) AUHAL 撞
            // bug。给一句通用的下一步提示,别假设是权限问题误导。
            let detail = error.localizedDescription
            phase = .failure("Couldn't start microphone (\(detail)). Check System Settings → Privacy → Microphone, then try again.")
            logger.error("voice training: engine.start() failed: \(String(describing: error), privacy: .public)")
            return false
        }
        self.engine = engine
        phase = .recording
        logger.info("voice training: capture started")
        return true
    }

    /// 倒计时结束 / 用户点 Done。停 engine,算 embedding,写 DB。
    /// 不接 `start()` 调过直接进 failure。
    func assign(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failure("Please enter your name first.")
            stopEngine()
            return
        }
        guard case .recording = phase else {
            phase = .failure("Recording wasn't running.")
            return
        }

        stopEngine()
        phase = .processing

        let samples = buffer
        buffer.removeAll(keepingCapacity: false)
        let minSamples = Int(Self.targetSampleRate * 3.0)  // 至少 3s 有效音频
        guard samples.count >= minSamples else {
            phase = .failure("Recording was too short (got \(samples.count / Int(Self.targetSampleRate))s, need ≥3s).")
            return
        }

        assignTask = Task { [weak self] in
            guard let self else { return }
            do {
                let modelPath = try await SpeakerModelStore.shared.path(for: .embedding).path
                let fbank = FbankExtractor()
                let extractor = try SpeakerEmbeddingExtractor(modelPath: modelPath, fbank: fbank)
                // SpeakerEmbeddingExtractor.embed 不 Sendable,但只在 detached task
                // 内部使用,出来只带 [Float] / Int64,所以可以 detached + 立刻回 MainActor
                let result: (Int64, [Float])? = await Task.detached {
                    guard let embedding = extractor.embed(samples), !embedding.isEmpty else { return nil }
                    let id = TimelineDB().upsertVoiceTrainedSpeaker(name: trimmed, embedding: embedding)
                    return id.map { ($0, embedding) }
                }.value

                guard let (speakerId, _) = result else {
                    self.phase = .failure("Couldn't extract voice embedding — try again with more speech.")
                    return
                }
                self.logger.info("voice training: trained speaker \(speakerId) ('\(trimmed, privacy: .public)') with \(samples.count) samples")
                self.phase = .success(name: trimmed)
            } catch {
                self.logger.error("voice training: \(String(describing: error), privacy: .public)")
                self.phase = .failure("Voice model not available yet — wait for first-launch models to finish downloading.")
            }
            self.assignTask = nil
        }
    }

    /// 用户取消(关 sheet 等)。停 engine + 清 buffer + 回 idle。
    func cancel() {
        stopEngine()
        buffer.removeAll(keepingCapacity: false)
        assignTask?.cancel()
        assignTask = nil
        phase = .idle
    }

    /// 完全 reset,回 idle。跟 cancel 等价,语义上分开 UI 用。
    func reset() { cancel() }

    // MARK: - Internals

    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.converter = nil
        }
    }

    /// tap callback 来的原始 buffer(任意采样率 / 通道)→ 转 16kHz mono Float
    /// → append 到 self.buffer。converter 按真实 sourceFormat 懒建/重建。
    private func appendCapturedSamples(_ raw: [Float]?, sourceFormat: AVAudioFormat) {
        guard let target = targetFormat else { return }
        guard let raw, !raw.isEmpty else { return }

        // 短路:source 已经是 16k mono float → 直接 append。
        if sourceFormat.commonFormat == target.commonFormat
            && sourceFormat.sampleRate == target.sampleRate
            && sourceFormat.channelCount == target.channelCount {
            buffer.append(contentsOf: raw)
            return
        }

        // raw 永远是 mono float(tap 回调 copyToFloat 已经把 channel 0 抠出来),
        // 所以 converter 输入恒定是 (sourceFormat.sampleRate, 1ch, Float32)。
        // **converter 按 monoSrc 缓存复用** —— 不能每帧重建,resampler 内部
        // 状态丢失会在拼接处出 click,30s 训练里累积上百次跳变让 embedding
        // 不稳。之前 bug:用 sourceFormat(多通道)去比 monoSrc(单通道),
        // 永远不等,等同每帧重建。
        guard let monoSrc = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }

        if converter == nil || converter?.inputFormat != monoSrc {
            converter = AVAudioConverter(from: monoSrc, to: target)
        }
        guard let converter,
              let srcBuf = AVAudioPCMBuffer(pcmFormat: monoSrc, frameCapacity: AVAudioFrameCount(raw.count)) else {
            return
        }
        srcBuf.frameLength = AVAudioFrameCount(raw.count)
        if let dst = srcBuf.floatChannelData?[0] {
            raw.withUnsafeBufferPointer { srcPtr in
                dst.update(from: srcPtr.baseAddress!, count: raw.count)
            }
        }

        let ratio = target.sampleRate / monoSrc.sampleRate
        let outFrames = AVAudioFrameCount(Double(raw.count) * ratio) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return }

        var error: NSError?
        let consumed = ConsumeOnce()
        let status = converter.convert(to: outBuf, error: &error) { _, statusPtr in
            if consumed.done {
                statusPtr.pointee = .endOfStream
                return nil
            }
            consumed.done = true
            statusPtr.pointee = .haveData
            return srcBuf
        }
        guard status != .error, error == nil, outBuf.frameLength > 0,
              let ch = outBuf.floatChannelData
        else { return }
        let count = Int(outBuf.frameLength)
        buffer.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: count))
    }

    /// 把 PCMBuffer 的 channel 0 拷贝出 [Float]。tap callback 在 audio thread,
    /// PCMBuffer 不 Sendable,只能复制出 value type 跨 actor。
    nonisolated private static func copyToFloat(_ buf: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buf.frameLength)
        guard frames > 0, let ch = buf.floatChannelData else { return nil }
        let ptr = ch[0]
        return Array(UnsafeBufferPointer(start: ptr, count: frames))
    }
}

/// AVAudioConverter inputBlock 用的"已 consume"标记 —— class 给闭包做引用 token,
/// 避开 Swift 6 strict concurrency 不让 var 被 escape 捕获。
private final class ConsumeOnce {
    var done = false
}
