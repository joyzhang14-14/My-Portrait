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
        // **必须显式传 inputNode.outputFormat 给 installTap**:
        //
        // 1.0.113 之前用 `format: nil` —— AVFAudio 按 audio unit **原生格式**
        // 交付 buffer,在 macOS 26 上通常是 Int16/PCM,**不是 Float32**。
        // 我们的 copyToFloat 检查 buf.floatChannelData(只有 Float32 格式才
        // 非 nil),非 Float 直接返回 nil,所有音频静默丢弃 → buffer 永远
        // 空 → "Recording was too short (got 0s, need ≥3s)"。
        //
        // AVAudioEngine.inputNode 的 outputFormat 自带 Float32 deinterleaved
        // 保证 —— AVFAudio 用它自己的 converter 把硬件 PCM 转 Float32 后
        // 再交付给我们,floatChannelData 拿到的就是真数据。
        //
        // (SystemAudioCaptureService 不能用这条路,那边是 aggregate device
        // tap,outputFormat 跟实际 tap 流不匹配是它专属 bug;但 mic 普通
        // inputNode 走这条路是 Apple 文档的标准做法。)
        let tapFormat = input.outputFormat(forBus: 0)
        // ⚠ tap callback 跑在 AVFAudio RealtimeMessenger 队列上,**不是 main**。
        // 1.0.112 和 1.0.113 都崩在这里(_swift_task_checkIsolatedSwift →
        // _dispatch_assert_queue_fail SIGTRAP)。
        //
        // 失败的尝试:
        //   (1) [weak self] guard let self ← self 是 @MainActor 触发 isolation check
        //   (2) 闭包内联写,改成不捕获 self,放 .shared 进 Task → 仍崩,因为
        //       闭包是在 @MainActor `start()` 里定义的,**继承 MainActor 上下文**
        //   (3) 显式 typed `@Sendable` 闭包 local 变量 → 仍崩,@Sendable 标识
        //       跨线程发送性,**跟 isolation 是两码事**
        //
        // 唯一可靠解:把回调实现挪到独立的 `nonisolated static func`,在
        // 类型层面强制 nonisolated,start() 只传函数引用进去。
        VoiceTrainer.diagCount = 0
        VoiceTrainer.diagLog("start: installTap tapFormat=\(tapFormat) targetFormat=\(target)")
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat, block: VoiceTrainer.tapCallback)

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
        guard let target = targetFormat else {
            Self.diagLog("append: targetFormat nil — bail")
            return
        }
        guard let raw, !raw.isEmpty else {
            Self.diagLog("append: raw nil/empty — bail")
            return
        }
        let preCount = buffer.count
        defer {
            if Self.diagCount % 50 == 1 {
                Self.diagLog("append: bufferGrew \(preCount)→\(buffer.count) (+\(buffer.count - preCount))")
            }
        }

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
                // ⚠ **必须 .noDataNow,不能 .endOfStream**。
                // .endOfStream 会让 AVAudioConverter 进入"流结束"内部状态,
                // 缓存的 converter 后续 convert() 调用永远返回 0 帧 ——
                // 现象就是 buffer 第一次涨到 ~1600 后停滞不前。
                // .noDataNow = "这次没数据了但流还活着",converter 可复用。
                statusPtr.pointee = .noDataNow
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

    /// tap callback —— **必须 nonisolated**,见 start() 里的注释。
    /// 在 audio thread 跑,只做最少的事:抽取 [Float] + 跨 actor 跳到 main
    /// 调单例累积。这个函数本身 isolation = nonisolated,不会触发 Swift 6
    /// runtime 的 isolation check 杀进程。
    nonisolated private static func tapCallback(_ buf: AVAudioPCMBuffer, _ time: AVAudioTime) {
        let frameCount = AVAudioFrameCount(buf.frameLength)
        guard frameCount > 0 else {
            diagLog("tap: frameCount=0 skip")
            return
        }
        let format = buf.format
        let rawSamples = copyToFloat(buf)
        if rawSamples == nil {
            diagLog("tap: copyToFloat NIL — format=\(format)")
        } else {
            // 每 50 个 callback 打一条,免得 30s 录音狂刷 log
            diagCount &+= 1
            if diagCount % 50 == 1 {
                diagLog("tap: ok #\(diagCount) frames=\(frameCount) rawCount=\(rawSamples?.count ?? -1) format=\(format)")
            }
        }
        Task { @MainActor in
            VoiceTrainer.shared.appendCapturedSamples(rawSamples, sourceFormat: format)
        }
    }

    /// 把 PCMBuffer 的 channel 0 拷贝出 [Float]。tap callback 在 audio thread,
    /// PCMBuffer 不 Sendable,只能复制出 value type 跨 actor。
    nonisolated private static func copyToFloat(_ buf: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buf.frameLength)
        guard frames > 0, let ch = buf.floatChannelData else { return nil }
        let ptr = ch[0]
        return Array(UnsafeBufferPointer(start: ptr, count: frames))
    }

    // MARK: - Diagnostic logging (临时,排查 buffer 永远空)

    /// 累积计数,仅每 N 帧打一条,避免日志风暴。
    nonisolated(unsafe) static var diagCount: Int = 0

    nonisolated static func diagLog(_ msg: String) {
        NSLog("[voice-training] \(msg)")
    }
}

/// AVAudioConverter inputBlock 用的"已 consume"标记 —— class 给闭包做引用 token,
/// 避开 Swift 6 strict concurrency 不让 var 被 escape 捕获。
private final class ConsumeOnce {
    var done = false
}
