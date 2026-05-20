@preconcurrency import AVFoundation
import Foundation
import os.log

/// 麦克风常开录音。**实时 VAD 切段**（设计文档"VAD 分段：检测到静音超过
/// 阈值时切断当前音频，开始新一段"）。
///
/// 责任：
///   - 启 AVAudioEngine + 输入设备 tap
///   - 用 AVAudioConverter 把 native sample rate（48kHz 等）转 16kHz mono Float32
///   - 把样本喂给 VADRecorder，VADRecorder 负责状态机 + 写 wav + 发段事件
///
/// 跟 SystemAudioCaptureService 共用 VADRecorder（只是数据源不同：本类是 mic）。
///
/// 麦克风权限：start() 首次调用触发系统弹窗。
actor AudioCaptureService {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "audio")
    private let audioDir: URL

    // 引擎 + 转换
    private let engine = AVAudioEngine()
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // VAD/写盘后端
    private var vadRecorder: VADRecorder?

    private var samplesContinuation: AsyncStream<[Float]>.Continuation?
    private var samplesTask: Task<Void, Never>?

    /// 跟踪 inputNode 上 tap 是否真装过。**stop() 必须检查这个再调 removeTap**：
    /// 没装过 tap 就 removeTap，AudioToolbox 内部抛 `-10877`
    /// (`kAudioUnitErr_InvalidElement`)，紧接着 caulk.messenger 把这个错误投递
    /// 回我们进程时撞 dispatch_assert_queue → 整进程崩。
    /// 真凶在 Services.startManagedLifecycle：默认 settings 全 false，Combine
    /// sink 启动时会立刻 fire applyAudioCapture(enabled=false) 调 stop()，
    /// 但此时 start() 还没跑过，engine 上根本没 tap。
    private var tapInstalled: Bool = false

    private var permissionGranted: Bool = false

    init(reporter: UnimplementedReporter, audioDir: URL = Storage.audioQueueDir) {
        self.reporter = reporter
        self.audioDir = audioDir
    }

    /// 当前 VADRecorder 的段事件流。`stop()` 后 vadRecorder = nil，返回已 finish 的空流。
    /// Services 在 startManagedLifecycle 里 merge 这个与 SystemAudioCaptureService 的同名流。
    func segmentEvents() -> AsyncStream<AudioSegmentEvent> {
        if let r = vadRecorder { return r.segmentEvents }
        return AsyncStream { $0.finish() }
    }

    // MARK: - 生命周期

    func start() async {
        guard samplesTask == nil else { return }

        permissionGranted = await Self.requestMicrophonePermission()
        if !permissionGranted {
            logger.error("microphone permission denied — audio capture disabled")
            return
        }

        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("audio_queue dir create failed: \(String(describing: error), privacy: .public)")
            return
        }

        vadRecorder = VADRecorder(deviceLabel: "default_microphone", audioDir: audioDir)

        do {
            try configureEngineAndStartTap()
        } catch {
            logger.error("engine start failed: \(String(describing: error), privacy: .public)")
            return
        }

        logger.info("AudioCaptureService started (mic, VAD-segmented)")
    }

    func stop() async {
        // 先停 engine 再 removeTap（Apple 标准顺序），并且只在装过 tap 时才 remove。
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        samplesContinuation?.finish()
        samplesContinuation = nil
        samplesTask?.cancel()
        samplesTask = nil

        await vadRecorder?.flush()
        vadRecorder = nil

        logger.info("AudioCaptureService stopped")
    }

    // MARK: - 引擎配置 + tap

    private func configureEngineAndStartTap() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
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

        var c: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]> { cont in c = cont }
        samplesContinuation = c

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            Task { [weak self] in
                await self?.performConversion(buffer: buffer)
            }
        }
        tapInstalled = true

        try engine.start()

        let recorder = vadRecorder
        samplesTask = Task {
            for await samples in stream {
                await recorder?.feed(samples)
            }
        }
    }

    private func performConversion(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat, let cont = samplesContinuation else { return }

        let inputFrames = AVAudioFrameCount(buffer.frameLength)
        let outputCapacity = AVAudioFrameCount(
            Double(inputFrames) * 16_000 / buffer.format.sampleRate
        ) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var error: NSError?
        // AVAudioConverter 流式 API 要"喂一次再喂 nil"，要求闭包内有状态。
        // Swift 6 把 var 捕获算 data race，所以走 class 引用一层（@unchecked Sendable）。
        let state = InputBlockState()
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if state.consumed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            state.consumed = true
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
        cont.yield(samples)
    }

    // MARK: - 工具

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// `AVAudioConverter.convert(to:error:withInputFrom:)` 的闭包要在内部保持
/// "first call return buffer, then return endOfStream" 状态。Swift 6 strict
/// concurrency 不接受 var 捕获，所以借 class 引用作 token；调用是同步的所以
/// `@unchecked Sendable` 安全。
final class InputBlockState: @unchecked Sendable {
    var consumed: Bool = false
}

/// 一个录完的音频段（已写盘）。变长，由 VAD 决定起止。
/// `device` 区分来源：`default_microphone` / `system_loopback`。
public struct AudioSegmentEvent: Sendable {
    public let wavPath: String
    public let metaPath: String
    public let recordedAtMs: Int64
    public let durationS: TimeInterval
    public let device: String

    public init(
        wavPath: String, metaPath: String,
        recordedAtMs: Int64, durationS: TimeInterval, device: String
    ) {
        self.wavPath = wavPath
        self.metaPath = metaPath
        self.recordedAtMs = recordedAtMs
        self.durationS = durationS
        self.device = device
    }
}
