@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import os.log

/// 系统音频 (loopback / output) 采集服务 —— **ScreenCaptureKit (SCK) 实现**。
///
/// 捕获其他 app 的输出(视频会议另一方的声音、视频播放声等),与麦克风音频
/// 并列存在。
///
/// **为什么用 SCK 而不是 CoreAudio Process Tap:**
/// 老版本用 `AudioHardwareCreateProcessTap` + 聚合设备,聚合设备**必须锚定一个
/// 真实输出设备**才有交付。这导致两个死路:
///   - 蓝牙耳机打电话切 HFP 时,通话音频走蓝牙 SCO 语音通道,锚谁都是哑的;
///   - per-app 路由(Zoom→AirPods)绕过锚定的默认输出 → tap 在跑但全 0。
/// screenpipe 把 process tap 列为**实验性**路径,默认走 **ScreenCaptureKit**——
/// SCK 在「系统混音」层抓音频(路由到输出设备之前),**完全设备无关**:锚的是
/// 显示器不是输出设备,蓝牙怎么切都不影响。这才是正路。
///
/// 链路:
///   1. SCShareableContent 取一个显示器(音频系统级,锚哪个显示器都一样)
///   2. SCContentFilter(display:) + SCStreamConfiguration(capturesAudio = true,
///      excludesCurrentProcessAudio = true)
///   3. SCStream + SCStreamOutput(.audio) —— CMSampleBuffer 在采集 queue 上
///      转成 16kHz mono Float32,经 continuation → VADRecorder
///
/// VAD/写盘和 AudioCaptureService 共用 VADRecorder(设备标签 `system_loopback`)。
/// macOS 13+(My-Portrait 部署 15+)。需 Screen Recording 权限(截屏已申请)。
actor SystemAudioCaptureService {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "sysaudio")
    private let audioDir: URL

    // SCK
    private var stream: SCStream?
    private let output = SystemAudioStreamOutput()
    /// SCStream 音频回调用的串行 queue。
    private let sampleQueue = DispatchQueue(label: "com.myportrait.sysaudio.sck", qos: .userInitiated)
    private var restartTask: Task<Void, Never>?

    // VAD/写盘
    private var vadRecorder: VADRecorder?
    /// 采集 queue → VADRecorder 的有序通道(单生产者 FIFO,保证样本顺序)。
    private var samplesContinuation: AsyncStream<[Float]>.Continuation?
    private var samplesTask: Task<Void, Never>?

    private var isRunning: Bool = false

    /// start() 重入闸(同 AudioCaptureService.starting):buildStream 里两个长
    /// await(SCShareableContent 枚举 + startCapture)期间 isRunning 仍是 false,
    /// `guard !isRunning` 挡不住重入 —— 没这道闸,effective 快速 true→false→true
    /// 会放进第二个 start(),造出双 SCStream:先建好的那个引用被覆盖,永远没人
    /// stopCapture(持续抓系统音频),两路样本还交错灌进同一个 VADRecorder。
    /// 第一个 await 之前**同步**置位。
    private var starting: Bool = false
    /// stop() 落在 start() 的 await 窗口里时(starting=true,stream/infra 都是
    /// start 正在建的,不能拆),记下"要停",由 start() 收尾后自行补一次 stop()。
    private var stopRequestedWhileStarting: Bool = false

    /// 长期稳定的段事件流 —— 与 VADRecorder 生命周期解耦。见 AudioCaptureService 同名注释。
    nonisolated let segmentEventStream: AsyncStream<AudioSegmentEvent>
    private let segmentEventCont: AsyncStream<AudioSegmentEvent>.Continuation
    private var forwardTask: Task<Void, Never>?

    init(reporter: UnimplementedReporter, audioDir: URL = Storage.audioQueueDir) {
        self.reporter = reporter
        self.audioDir = audioDir
        var c: AsyncStream<AudioSegmentEvent>.Continuation!
        self.segmentEventStream = AsyncStream<AudioSegmentEvent> { c = $0 }
        self.segmentEventCont = c
    }

    /// 稳定的段事件流。capture 重建不影响这条流。
    func segmentEvents() -> AsyncStream<AudioSegmentEvent> {
        return segmentEventStream
    }

    // MARK: - 生命周期

    func start() async {
        guard !isRunning, !starting else { return }
        starting = true
        stopRequestedWhileStarting = false   // 清上一轮可能残留的标志
        defer { starting = false }

        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("audio_queue dir create failed: \(String(describing: error), privacy: .public)")
            return
        }

        // VADRecorder + 转发任务 —— 跨重建稳定存活。
        let recorder = VADRecorder(deviceLabel: "system_loopback", audioDir: audioDir)
        vadRecorder = recorder
        let evCont = segmentEventCont
        forwardTask = Task {
            for await seg in recorder.segmentEvents { evCont.yield(seg) }
        }

        // 采集 queue → recorder 的有序通道。
        var c: AsyncStream<[Float]>.Continuation!
        let sampleStream = AsyncStream<[Float]> { c = $0 }
        samplesContinuation = c
        output.continuation = c
        samplesTask = Task { [weak recorder] in
            for await samples in sampleStream { await recorder?.feed(samples) }
        }

        // 流停掉(系统原因 / 设备移除)时自动重建。
        output.onStopped = { [weak self] desc in
            Task { await self?.handleStreamStopped(desc) }
        }

        do {
            try await buildStream()
        } catch {
            logger.error("system audio buildStream failed: \(String(describing: error), privacy: .public)")
            await teardownInfra()
            return
        }

        isRunning = true
        logger.info("SystemAudioCaptureService started (ScreenCaptureKit)")

        // start 挂在 buildStream 期间有 stop() 进来过 → 这里补执行,
        // 否则开关已关而流还在跑。先解闸,stop() 的 starting 分支才不会误判。
        if stopRequestedWhileStarting {
            stopRequestedWhileStarting = false
            starting = false
            await stop()
        }
    }

    func stop() async {
        // start() 还挂在 buildStream 的 await 上:此刻无 stream 可关,infra
        // 是 start 正在用的,直接拆会撕掉它脚下的东西。记标志让 start()
        // 完成后自己调 stop() 收尾。
        if starting {
            stopRequestedWhileStarting = true
            return
        }
        guard isRunning || stream != nil else {
            isRunning = false
            return
        }
        isRunning = false

        restartTask?.cancel()
        restartTask = nil
        output.onStopped = nil
        output.continuation = nil

        // 同步摘下 stream 再 await —— stopCapture / teardown 的 await 是 actor
        // 重入窗口,start() 若插入会 buildStream 出新 stream,旧 stop 恢复后
        // 不能把新 stream 关掉。output.continuation 已同步置 nil,SCK 后续回调
        // 不再有样本落进来,先排干管线再异步关流是安全的。
        let doomedStream = stream
        stream = nil
        await teardownInfra()
        if let doomedStream { try? await doomedStream.stopCapture() }
        logger.info("SystemAudioCaptureService stopped")
    }

    /// 拆掉跨重建存活的那层(recorder / forwardTask / samplesTask / continuation)。
    /// **入口同步摘成 local copy 再排干** —— 每个 await 都是 actor 重入窗口,
    /// 交错的 start() 会重建这些字段;摘下后只拆本次 session 的对象,不会
    /// flush 错新 recorder / await 到永不结束的新 forwardTask。
    /// 排干顺序同 AudioCaptureService.stop():先等 samplesTask 喂完缓冲样本,
    /// 再 flush 当前段,最后等 forwardTask 把段事件转发完自然退出 —— 先 cancel
    /// 再 flush 会让 flush yield 的最后一段无人接收,wav 成孤儿永不转录。
    private func teardownInfra() async {
        let doomedCont = samplesContinuation
        let doomedSamplesTask = samplesTask
        let doomedForwardTask = forwardTask
        let doomedRecorder = vadRecorder
        samplesContinuation = nil
        samplesTask = nil
        forwardTask = nil
        vadRecorder = nil

        doomedCont?.finish()
        await doomedSamplesTask?.value
        await doomedRecorder?.flush()
        await doomedForwardTask?.value
    }

    // MARK: - SCK 采集

    private func buildStream() async throws {
        // 取一个显示器 —— 系统音频是系统级混音,锚哪个显示器结果一样。
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first
        else {
            throw NSError(domain: "SystemAudio", code: -40, userInfo: [
                NSLocalizedDescriptionKey: "no SCK display available"
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // 不录我们自己的播放(避免回环)。
        cfg.excludesCurrentProcessAudio = true
        // 视频部分我们不消费(只加 .audio output)。给个极小尺寸 + 低帧率压开销。
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        cfg.queueDepth = 5

        let s = SCStream(filter: filter, configuration: cfg, delegate: output)
        try s.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
    }

    private func handleStreamStopped(_ desc: String) async {
        guard isRunning else { return }
        logger.warning("SCK system-audio stream stopped: \(desc, privacy: .public) — restarting in 1s")
        stream = nil
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, await self.isRunning else { return }
            await self.rebuild()
        }
    }

    private func rebuild() async {
        guard isRunning else { return }
        if let s = stream {
            try? await s.stopCapture()
            stream = nil
        }
        do {
            try await buildStream()
            logger.info("SCK system-audio stream rebuilt")
        } catch {
            logger.error("SCK system-audio rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// SCStream 音频输出 —— CMSampleBuffer(SCK 一般 48k stereo Float32)→ 16kHz
/// mono Float32 → continuation(交给 actor 的 VADRecorder)。
///
/// 不是 actor:SCStreamOutput 要 NSObject,在 `sampleHandlerQueue` 串行回调。
/// 转换在 queue 上做完只交结果 [Float]。`continuation` / `onStopped` 在
/// startCapture **之前**由 actor 设好(之后只读),`converter` 只在 queue 上
/// 用 → queue-confined。故 `@unchecked Sendable` 成立。
final class SystemAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// 采集 queue → VADRecorder 的有序通道(actor 设)。
    var continuation: AsyncStream<[Float]>.Continuation?
    /// 流停掉回调(actor 设,用于自动重建)。
    var onStopped: (@Sendable (String) -> Void)?

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let samples = convert(sampleBuffer), !samples.isEmpty else { return }
        continuation?.yield(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(String(describing: error))
    }

    /// CMSampleBuffer → 16kHz mono Float32 [Float]。结果是拷贝,出闭包仍有效。
    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        var out: [Float]? = nil
        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                      let inFormat = AVAudioFormat(streamDescription: &asbd),
                      let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                                   bufferListNoCopy: abl.unsafePointer)
                else { return }
                out = self.toMono16k(inBuf)
            }
        } catch {
            return nil
        }
        return out
    }

    private func toMono16k(_ inBuf: AVAudioPCMBuffer) -> [Float]? {
        // converter 按真实输入格式懒建 / 变格式时重建。
        if converter == nil || converter?.inputFormat != inBuf.format {
            converter = AVAudioConverter(from: inBuf.format, to: target)
        }
        guard let converter else { return nil }

        let outCap = AVAudioFrameCount(
            Double(inBuf.frameLength) * 16_000 / inBuf.format.sampleRate) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return nil }

        var err: NSError?
        let state = ConvInputState()
        let status = converter.convert(to: outBuf, error: &err) { _, statusPtr in
            // ⚠ 复用 converter:必须 .noDataNow,不能 .endOfStream(否则之后永远
            // 返回 0 帧)。跟旧 process-tap 实现 + AudioCaptureService 同款修法。
            if state.consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        guard status != .error, err == nil, outBuf.frameLength > 0,
              let ch = outBuf.floatChannelData
        else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}

/// converter input block 的一次性消费 token(Swift 6 strict concurrency 不接受
/// var 捕获,用 class 引用)。
private final class ConvInputState: @unchecked Sendable {
    var consumed = false
}
