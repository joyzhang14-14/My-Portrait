@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

/// 系统音频 (loopback / output) 采集服务。捕获其他 app 的输出（如视频会议
/// 另一方的声音、视频播放声等），与麦克风音频并列存在。
///
/// 链路：
///   1. CATapDescription 描述要捕获什么（所有进程的 stereo 混合，排除自身）
///   2. AudioHardwareCreateProcessTap → 拿到 tap AudioObjectID
///   3. 用 tap UID 构造 aggregate device（让标准音频 API 能读它）
///   4. **设 AVAudioEngine.inputNode 的 underlying AudioUnit 用 aggregateID
///      作为 input device**（这一步是 macOS HAL 唯一支持的方式）
///   5. inputNode tap → AVAudioConverter 转 16kHz mono Float32 → VADRecorder
///
/// VAD/写盘和 AudioCaptureService 共用 VADRecorder（设备标签 `system_loopback`）。
///
/// macOS 14.4+ 才有这个能力。
///
/// 失败模式：
///   - tap 建不起来（macOS 版本太老 / 系统未开权限）→ log，service 不启
///   - aggregate device 建不起来 → log + 释放 tap，不启
///   - AVAudioEngine 设设备失败 → log + 释放资源，不启
actor SystemAudioCaptureService {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "sysaudio")
    private let audioDir: URL

    // Core Audio 资源
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0

    // AVFoundation
    //
    // **懒构造**：见 AudioCaptureService.engine 注释 ——
    // AVAudioEngine() 构造即拉起 caulk XPC 通道，是其他无关代码崩 dispatch_assert
    // 的根因之一。
    private var engine: AVAudioEngine?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // VAD/写盘
    private var vadRecorder: VADRecorder?

    private var samplesContinuation: AsyncStream<[Float]>.Continuation?
    private var samplesTask: Task<Void, Never>?

    private var isRunning: Bool = false
    /// 见 AudioCaptureService.tapInstalled 注释 —— 防 -10877 + dispatch_assert 崩。
    private var tapInstalled: Bool = false

    /// 长期稳定的段事件流 —— 与 VADRecorder 生命周期解耦。见 AudioCaptureService 同名注释。
    nonisolated let segmentEventStream: AsyncStream<AudioSegmentEvent>
    private let segmentEventCont: AsyncStream<AudioSegmentEvent>.Continuation
    /// 把当前 VADRecorder 的段转发进 segmentEventStream 的任务。
    private var forwardTask: Task<Void, Never>?

    init(reporter: UnimplementedReporter, audioDir: URL = Storage.audioQueueDir) {
        self.reporter = reporter
        self.audioDir = audioDir
        var c: AsyncStream<AudioSegmentEvent>.Continuation!
        self.segmentEventStream = AsyncStream<AudioSegmentEvent> { c = $0 }
        self.segmentEventCont = c
    }

    /// 稳定的段事件流。VADRecorder 重建不影响这条流。
    func segmentEvents() -> AsyncStream<AudioSegmentEvent> {
        return segmentEventStream
    }

    // MARK: - 生命周期

    func start() async {
        guard !isRunning else { return }

        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("audio_queue dir create failed: \(String(describing: error), privacy: .public)")
            return
        }

        // 1. CATapDescription
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.isExclusive = false

        // 2. Process tap
        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == kAudioHardwareNoError else {
            logger.error("AudioHardwareCreateProcessTap failed: status=\(tapStatus)")
            return
        }
        tapID = tap

        // 3. Aggregate device 包住 tap
        let tapUIDStr = try? Self.readTapUID(tap: tap)
        guard let uid = tapUIDStr else {
            logger.error("could not read tap UID")
            cleanupCoreAudio()
            return
        }

        let aggregateUID = "com.myportrait.aggregate.systemTap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyPortraitSystemTapDevice",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var aggregate: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggStatus == kAudioHardwareNoError else {
            logger.error("AudioHardwareCreateAggregateDevice failed: status=\(aggStatus)")
            cleanupCoreAudio()
            return
        }
        aggregateID = aggregate

        // 4. 把 AVAudioEngine 的 input device 切到 aggregate
        //    真正录之前才构造 engine（懒构造，见 engine 字段注释）。
        if engine == nil { engine = AVAudioEngine() }
        do {
            try bindAggregateToEngine(aggregateID: aggregate)
        } catch {
            logger.error("bind aggregate to engine failed: \(String(describing: error), privacy: .public)")
            cleanupCoreAudio()
            return
        }

        // 5. VADRecorder + tap + 转换 + start
        let recorder = VADRecorder(deviceLabel: "system_loopback", audioDir: audioDir)
        vadRecorder = recorder
        let cont = segmentEventCont
        forwardTask = Task {
            for await seg in recorder.segmentEvents { cont.yield(seg) }
        }

        do {
            try configureTapAndStart()
        } catch {
            logger.error("engine start failed: \(String(describing: error), privacy: .public)")
            forwardTask?.cancel()
            forwardTask = nil
            await vadRecorder?.flush()
            vadRecorder = nil
            cleanupCoreAudio()
            return
        }

        isRunning = true
        logger.info("SystemAudioCaptureService started (tap=\(self.tapID), aggregate=\(self.aggregateID))")
    }

    func stop() async {
        // engine 没构造 → 整条 start() 没跑过 → 直接退。同 AudioCaptureService.stop 注释。
        guard let engine else {
            logger.info("SystemAudioCaptureService stopped (was never started)")
            isRunning = false
            return
        }

        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        samplesContinuation?.finish()
        samplesContinuation = nil
        samplesTask?.cancel()
        samplesTask = nil

        forwardTask?.cancel()
        forwardTask = nil
        await vadRecorder?.flush()
        vadRecorder = nil

        cleanupCoreAudio()

        // 同 AudioCaptureService.stop:置 nil 释放 AVAudioEngine,
        // 避免 AUHAL 持着音频硬件让系统以为还在录(蓝牙 HFP 降质)。
        self.engine = nil
        self.converter = nil
        self.targetFormat = nil

        isRunning = false
        logger.info("SystemAudioCaptureService stopped")
    }

    // MARK: - 私有 — Core Audio

    /// 读 tap 的 UID 属性 —— aggregate device 的 sub-tap list 引用要的就是它。
    private static func readTapUID(tap: AudioObjectID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var cfstr: Unmanaged<CFString>? = nil
        let status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &cfstr)
        guard status == kAudioHardwareNoError, let unmanaged = cfstr else {
            throw NSError(domain: "SystemAudio", code: Int(status))
        }
        return unmanaged.takeRetainedValue() as String
    }

    private func cleanupCoreAudio() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    // MARK: - 私有 — AVAudioEngine

    /// 把 engine.inputNode 的底层 AudioUnit 切到 aggregate device。
    /// 必须在 engine.start() **之前**完成。
    private func bindAggregateToEngine(aggregateID: AudioDeviceID) throws {
        guard let engine else {
            throw NSError(domain: "SystemAudio", code: -9, userInfo: [
                NSLocalizedDescriptionKey: "engine not constructed"
            ])
        }
        // 触发 audioUnit 懒构造：先 access inputNode.outputFormat 才能拿到 audioUnit。
        _ = engine.inputNode.outputFormat(forBus: 0)
        guard let au = engine.inputNode.audioUnit else {
            throw NSError(domain: "SystemAudio", code: -10, userInfo: [
                NSLocalizedDescriptionKey: "inputNode.audioUnit is nil"
            ])
        }
        var devID: AudioDeviceID = aggregateID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: "SystemAudio", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "AudioUnitSetProperty(CurrentDevice) failed"
            ])
        }
    }

    private func configureTapAndStart() throws {
        guard let engine else {
            throw NSError(domain: "SystemAudio", code: -8, userInfo: [
                NSLocalizedDescriptionKey: "engine not constructed"
            ])
        }
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SystemAudio", code: -20)
        }
        targetFormat = target

        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "SystemAudio", code: -21)
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
        // 见 AudioCaptureService.InputBlockState 注释 —— Swift 6 strict concurrency
        // 不接受 var 捕获，class 引用做 token。
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
}
