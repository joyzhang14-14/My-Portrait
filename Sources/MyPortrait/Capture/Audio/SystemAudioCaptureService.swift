
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log
// SwiftPM 走 import 模块;Xcode 走 bridging header(SWIFT_OBJC_BRIDGING_HEADER),
// 编译期 SWIFT_PACKAGE 由 SwiftPM 自动定义,bridging header 路径下不存在。
#if SWIFT_PACKAGE
import MyPortraitObjC
#endif

/// 系统音频 (loopback / output) 采集服务。捕获其他 app 的输出（如视频会议
/// 另一方的声音、视频播放声等），与麦克风音频并列存在。
///
/// 链路：
///   1. CATapDescription 描述要捕获什么（所有进程的 stereo 混合，排除自身）
///   2. AudioHardwareCreateProcessTap → 拿到 tap AudioObjectID
///   3. 用 tap UID + **当前默认输出设备 UID** 构造 aggregate device。
///      ⚠ aggregate 必须同时含一个真实输出设备 sub-device(并设为 main
///      sub-device)+ tap_auto_start,否则裸 global tap 的 delivery 路径是
///      哑的:callback 在跑但每个 buffer 全是 0 → VAD 当静音全丢 → 一条都采
///      不到。(对标 screenpipe `core/process_tap.rs` 的 build_capture。)
///   4. **设 AVAudioEngine.inputNode 的 underlying AudioUnit 用 aggregateID
///      作为 input device**（这一步是 macOS HAL 唯一支持的方式）
///   5. inputNode tap → AVAudioConverter 转 16kHz mono Float32 → VADRecorder
///
/// **自适应**（缺了就采不到,本服务最早的 bug 根因）：
///   - 监听 `kAudioHardwarePropertyDefaultOutputDevice` —— 默认输出设备一变
///     (扬声器→AirPods 等)就 teardown + rebuild,把 tap 重锚到新设备。
///     不重锚的话 aggregate 一直绑旧设备,切设备后只能采到静音。
///   - 静音看门狗 —— tap callback 在响、但连续 45s 全 0 振幅就重建一次。
///     修 "per-app 路由到耳机绕过了 aggregate 锚定的系统默认输出" 这种
///     tap 在跑却全 0 的场景。
///
/// VAD/写盘和 AudioCaptureService 共用 VADRecorder（设备标签 `system_loopback`）。
/// VADRecorder / forwardTask / segmentEvents 跨 rebuild 稳定存活,只有
/// tap+aggregate+engine 绑定那一层在重建。
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
    /// 当前 aggregate 锚定的输出设备 UID —— 用来判断默认输出有没有变。
    private var currentOutputUID: String = ""

    // AVFoundation
    //
    // **懒构造**：见 AudioCaptureService.engine 注释 ——
    // AVAudioEngine() 构造即拉起 caulk XPC 通道，是其他无关代码崩 dispatch_assert
    // 的根因之一。engine 实例跨 rebuild 复用(只重新绑定 inputNode device)。
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
    /// rebuild 守卫 —— 防设备监听与看门狗并发触发重复重建。
    private var rebuilding: Bool = false

    // 设备热插拔 + 看门狗
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var restartTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// 看门狗窗口内累计的 callback 次数 + 峰值振幅(performConversion 里更新,
    /// actor 隔离)。每 tick 读后清零。
    private var wdCallbacks: Int = 0
    private var wdPeak: Float = 0
    /// 连续静音的 tick 数(每 tick ≈ 500ms)+ 重建冷却剩余 tick 数。
    private var wdSilenceTicks: Int = 0
    private var wdCooldownTicks: Int = 0
    /// IO proc 连续无 callback 的 tick 数(蓝牙 A2DP→HFP 切换常把 IO proc 干停)。
    private var wdNoCallbackTicks: Int = 0

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

        // VADRecorder + 转发任务 —— **跨 rebuild 稳定存活**,不随 tap 重建。
        let recorder = VADRecorder(deviceLabel: "system_loopback", audioDir: audioDir)
        vadRecorder = recorder
        let cont = segmentEventCont
        forwardTask = Task {
            for await seg in recorder.segmentEvents { cont.yield(seg) }
        }

        do {
            try buildCapture()
        } catch {
            logger.error("system audio buildCapture failed: \(String(describing: error), privacy: .public)")
            forwardTask?.cancel()
            forwardTask = nil
            await vadRecorder?.flush()
            vadRecorder = nil
            cleanupCoreAudio()
            return
        }

        registerOutputDeviceListener()
        startSilenceWatchdog()

        isRunning = true
        logger.info("SystemAudioCaptureService started (tap=\(self.tapID), aggregate=\(self.aggregateID), output=\(self.currentOutputUID, privacy: .public))")
    }

    func stop() async {
        // engine 没构造 → 整条 start() 没跑过 → 直接退。同 AudioCaptureService.stop 注释。
        guard engine != nil else {
            logger.info("SystemAudioCaptureService stopped (was never started)")
            isRunning = false
            return
        }

        // 先把 isRunning 置否 —— 任何在途的设备监听/看门狗 tick 进到 rebuild
        // 都会因 guard isRunning 直接 no-op,避免 stop 的 await 挂起期间又重建。
        isRunning = false

        // 先停自适应,免得 teardown 过程中设备监听/看门狗又触发 rebuild。
        unregisterOutputDeviceListener()
        restartTask?.cancel()
        restartTask = nil
        stopSilenceWatchdog()

        // 拆 tap/aggregate/engine 绑定(严格按顺序,见 teardownCapture 注释)。
        teardownCapture()

        // 收尾稳定基础设施(跨 rebuild 存活的那层)。
        forwardTask?.cancel()
        forwardTask = nil
        await vadRecorder?.flush()
        vadRecorder = nil

        // 同 AudioCaptureService.stop:置 nil 触发 AVAudioEngine dealloc。
        // teardownCapture 已解绑 inputNode device,这步现在是安全的。还是包一层兜底。
        let deallocErr = MyPortraitObjCTryCatch {
            self.engine = nil
        }
        if let deallocErr {
            logger.error("SystemAudio stop: engine dealloc threw: \(deallocErr.localizedDescription, privacy: .public)")
        }

        isRunning = false
        logger.info("SystemAudioCaptureService stopped")
    }

    // MARK: - 私有 — 采集构建 / 重建

    /// 建一套全新的 tap + aggregate(锚到当前默认输出设备)+ engine 绑定 +
    /// installTap + engine.start。可重复调用(初次 start / 设备切换 / 看门狗触发)。
    /// 失败抛错并已自清 CoreAudio 资源。**不碰** vadRecorder / forwardTask /
    /// segmentEvents（那是 start() 的一次性基础设施）。
    private func buildCapture() throws {
        // 1. CATapDescription —— 全进程 stereo 混音,排除自身。
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.isExclusive = false

        // 2. Process tap
        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == kAudioHardwareNoError else {
            throw NSError(domain: "SystemAudio", code: Int(tapStatus), userInfo: [
                NSLocalizedDescriptionKey: "AudioHardwareCreateProcessTap failed: status=\(tapStatus)"
            ])
        }
        tapID = tap

        // 3. tap UID(aggregate 的 sub-tap list 要引用它)
        guard let uid = try? Self.readTapUID(tap: tap) else {
            cleanupCoreAudio()
            throw NSError(domain: "SystemAudio", code: -11, userInfo: [
                NSLocalizedDescriptionKey: "could not read tap UID"
            ])
        }

        // 4. 当前默认输出设备 UID —— aggregate 必须锚在一个真实输出设备上,
        //    否则裸 global tap 的 delivery 是哑的(callback 在跑但 buffer 全 0)。
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            cleanupCoreAudio()
            throw NSError(domain: "SystemAudio", code: -12, userInfo: [
                NSLocalizedDescriptionKey: "no default output device"
            ])
        }

        // 4b. 选 aggregate 的锚定设备。蓝牙通话(HFP)时默认输出在 SCO 语音
        //     通道上,锚它 tap 会哑 → 改锚稳定的内建输出(CATap 抓全进程渲染
        //     混音,锚哪只为给 IO 稳定时钟)。A2DP 音乐不切(只低采样率才切)。
        let anchorUID: String
        if Self.defaultOutputIsBluetoothCall(), let builtIn = Self.builtInOutputDeviceUID() {
            anchorUID = builtIn
            DiagLog.event("system_audio.anchor.builtin_for_bt_call",
                          ctx: ["output": outputUID, "anchor": builtIn])
        } else {
            anchorUID = outputUID
        }

        // 5. Aggregate device —— 同时含 [真实输出设备 sub-device] + [tap],
        //    main sub-device 指向输出设备,tap auto-start。
        let aggregateUID = "com.myportrait.aggregate.systemTap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyPortraitSystemTapDevice",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: anchorUID,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: anchorUID,
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var aggregate: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggStatus == kAudioHardwareNoError else {
            cleanupCoreAudio()
            throw NSError(domain: "SystemAudio", code: Int(aggStatus), userInfo: [
                NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice failed: status=\(aggStatus)"
            ])
        }
        aggregateID = aggregate

        // 6. 把 AVAudioEngine 的 input device 切到 aggregate
        //    真正录之前才构造 engine（懒构造,见 engine 字段注释）。engine 实例
        //    跨 rebuild 复用,只换它 inputNode 绑的 device。
        if engine == nil { engine = AVAudioEngine() }
        do {
            try bindAggregateToEngine(aggregateID: aggregate)
        } catch {
            cleanupCoreAudio()
            throw error
        }

        // 7. installTap + 转换 + start(喂稳定的 vadRecorder)
        do {
            try configureTapAndStart()
        } catch {
            unbindInputNodeToDefault()
            cleanupCoreAudio()
            throw error
        }

        currentOutputUID = outputUID
    }

    /// 拆掉当前这套 tap/aggregate/engine 绑定,保留 engine 实例 + vadRecorder +
    /// forwardTask + segmentEvents 供 rebuild 复用。
    ///
    /// ⚠ **必须严格按顺序拆**,任何一步反了就 SIGTRAP(同 stop() 原注释):
    ///   1. 先 stop engine + 摘 tap —— 让 audio thread 不再有新 callback 进来
    ///   2. finish/cancel 本次构建的 samples 流 —— inflight drain 干净
    ///   3. **engine.inputNode 解绑 aggregate device**(切回系统默认),这样
    ///      AUHAL 不再持有 aggregate IOProcID
    ///   4. cleanupCoreAudio 销毁 aggregate + tap
    /// 漏第 3 步 → engine 之后引用一个已销毁的 device → IOProcID destroy 断言 →
    /// SIGTRAP。整条用 ObjC try/catch 兜底 NSException。
    private func teardownCapture() {
        guard let engine else { return }

        let cleanupErr = MyPortraitObjCTryCatch {
            if engine.isRunning { engine.stop() }
            if self.tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
        }
        if let cleanupErr {
            logger.error("SystemAudio teardown: tap/engine stop threw: \(cleanupErr.localizedDescription, privacy: .public)")
        }

        samplesContinuation?.finish()
        samplesContinuation = nil
        samplesTask?.cancel()
        samplesTask = nil

        unbindInputNodeToDefault()
        cleanupCoreAudio()

        converter = nil
        targetFormat = nil
    }

    /// 把 engine.inputNode 从 aggregate 解绑回系统默认输入设备。**必须在销毁
    /// aggregate 之前**调,否则 engine 之后引用已销毁 device → IOProcID destroy
    /// 断言 → SIGTRAP。
    private func unbindInputNodeToDefault() {
        guard let engine else { return }
        let unbindErr = MyPortraitObjCTryCatch {
            if let au = engine.inputNode.audioUnit {
                // 0 = use default device
                var devID: AudioDeviceID = AudioObjectID(kAudioObjectUnknown)
                _ = AudioUnitSetProperty(
                    au,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
        }
        if let unbindErr {
            logger.error("SystemAudio unbind inputNode threw: \(unbindErr.localizedDescription, privacy: .public)")
        }
    }

    /// 重建采集(默认输出设备切换 / 静音看门狗触发)。teardown 当前这套 →
    /// buildCapture 新的。actor 串行化 + rebuilding 守卫防并发/重入。
    private func rebuild(reason: String) async {
        guard isRunning, !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }

        logger.info("rebuilding system audio capture (\(reason, privacy: .public))")
        teardownCapture()
        do {
            try buildCapture()
            wdSilenceTicks = 0
            logger.info("system audio re-anchored (output=\(self.currentOutputUID, privacy: .public), tap=\(self.tapID))")
        } catch {
            // 留在已拆状态;下次设备变化再试。记下这次想锚的设备,避免同一
            // 设备(如蓝牙握手未就绪)被反复重试(参照 screenpipe process_tap)。
            currentOutputUID = Self.defaultOutputDeviceUID() ?? currentOutputUID
            logger.error("system audio rebuild failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 私有 — 默认输出设备监听

    private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 当前默认输出设备的 UID(拿不到返回 nil)。
    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddress()
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var cfstr: Unmanaged<CFString>? = nil
        guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &cfstr) == noErr,
              let unmanaged = cfstr else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    /// 默认输出设备的 AudioObjectID(拿不到返回 nil)。
    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddress()
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// 读设备 transport type。
    private static func transportType(of id: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        return transport
    }

    /// 读设备名义采样率。HFP(蓝牙通话)≈8k/16k,A2DP(音乐)≈44.1k/48k。
    private static func nominalSampleRate(of id: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    /// 默认输出是不是「蓝牙 + 通话(HFP)模式」。这种情况通话音频走 HFP SCO
    /// 语音通道,绕过普通输出流,聚合设备锚它 → tap 哑。A2DP 音乐(高采样率)不算。
    private static func defaultOutputIsBluetoothCall() -> Bool {
        guard let id = defaultOutputDeviceID() else { return false }
        let t = transportType(of: id)
        let isBT = (t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE)
        guard isBT else { return false }
        let rate = nominalSampleRate(of: id)
        return rate > 0 && rate <= 24_000   // HFP 通话档
    }

    /// 找内建输出设备 UID —— 蓝牙通话时把聚合设备锚到它(稳定,不切 HFP)。
    /// CATap 抓的是全进程渲染混音,锚哪个真实设备只为给 IO 一个稳定时钟。
    private static func builtInOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else { return nil }

        for id in ids where transportType(of: id) == kAudioDeviceTransportTypeBuiltIn {
            // 必须有输出流
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var cfstr: Unmanaged<CFString>? = nil
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &cfstr) == noErr,
                  let unmanaged = cfstr else { continue }
            return unmanaged.takeRetainedValue() as String
        }
        return nil
    }

    /// 注册「默认输出设备变更」监听 —— 戴耳机 / 切扬声器时重锚 tap。
    private func registerOutputDeviceListener() {
        guard deviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { await self?.handleOutputDeviceChange() }
        }
        var addr = Self.defaultOutputAddress()
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        if status == noErr {
            deviceListenerBlock = block
        } else {
            logger.warning("failed to register output device-change listener: \(status)")
        }
    }

    private func unregisterOutputDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        var addr = Self.defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        deviceListenerBlock = nil
    }

    /// 设备变更回调。防抖:0.8 秒内的连续变更合并(拔插/蓝牙握手常爆发多个事件)。
    private func handleOutputDeviceChange() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reanchorIfOutputChanged()
        }
    }

    private func reanchorIfOutputChanged() async {
        guard isRunning else { return }
        let newUID = Self.defaultOutputDeviceUID() ?? ""
        guard newUID != currentOutputUID else { return }
        logger.info("default output changed (\(self.currentOutputUID, privacy: .public) → \(newUID, privacy: .public)) — re-anchoring system audio")
        await rebuild(reason: "output-device-change")
    }

    // MARK: - 私有 — 静音看门狗

    private func startSilenceWatchdog() {
        watchdogTask?.cancel()
        wdCallbacks = 0
        wdPeak = 0
        wdSilenceTicks = 0
        wdCooldownTicks = 0
        wdNoCallbackTicks = 0
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                await self.watchdogTick()
            }
        }
    }

    private func stopSilenceWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// 每 ~500ms 一跳。callback 在响、但连续 45s 全 0 振幅 → 重建一次(冷却 60s)。
    /// 修 "per-app 音频路由到耳机绕过了 aggregate 锚定的系统默认输出 → tap 在跑
    /// 但 buffer 全 0" 这种场景(对标 screenpipe process_tap 的 silence watchdog)。
    private func watchdogTick() async {
        if wdCooldownTicks > 0 { wdCooldownTicks -= 1 }

        let callbacks = wdCallbacks
        let peak = wdPeak
        wdCallbacks = 0
        wdPeak = 0

        // 真实音频:有 callback 且峰值高于阈值(0.002 只滤掉真零 buffer,
        // 不误伤轻声说话,正常通话峰值在 0.05–0.5)。
        let gotRealAudio = callbacks > 0 && peak > 0.002
        if gotRealAudio {
            wdSilenceTicks = 0
            wdNoCallbackTicks = 0
        } else if callbacks > 0 {
            // callback 在跑,只是 buffer 静音 → 累计静音窗口。
            wdSilenceTicks += 1
            wdNoCallbackTicks = 0
        } else {
            // callbacks == 0:IO proc 停了。蓝牙 A2DP→HFP 切换常把聚合设备的
            // IO proc 干停,而设备 UID 没变 → 设备监听不触发重锚 → 这里兜底。
            wdNoCallbackTicks += 1
        }

        // IO proc 连续无 callback ≥10s → rebuild(rebuild 里按当前是否蓝牙通话
        // 重选 anchor;rebuild 失败也无妨,冷却后再来)。
        if Double(wdNoCallbackTicks) * 0.5 >= 10, wdCooldownTicks == 0 {
            logger.warning("system audio: IO proc no callbacks 10s — rebuilding (bluetooth HFP switch?)")
            DiagLog.warn("system_audio.rebuild.io_proc_dead")
            wdNoCallbackTicks = 0
            wdSilenceTicks = 0
            wdCooldownTicks = 120
            await rebuild(reason: "io-proc-dead")
            return
        }

        let silentLongEnough = Double(wdSilenceTicks) * 0.5 >= 45
        guard silentLongEnough, wdCooldownTicks == 0 else { return }

        logger.warning("system audio: callbacks firing but silent for 45s — rebuilding (per-app routing bypass?)")
        wdSilenceTicks = 0
        wdCooldownTicks = 120  // 60s 冷却,避免没在通话(本就无音频)时反复重建
        await rebuild(reason: "silence-watchdog")
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

        // **不再预创建 converter** —— 用 kAudioOutputUnitProperty_CurrentDevice
        // 接系统音频时,`inputNode.outputFormat(forBus: 0)` 报的格式跟
        // tap 点实际能用的格式经常对不上(AVAudioEngine 内部 bug,user 反馈
        // 24000 Hz Float32 mono 报错"Failed to create tap due to format
        // mismatch")。改成 installTap 传 nil,由系统用真实 tap 格式;
        // converter 在第一帧 buffer 回调时按 buffer.format 动态建/重建。
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SystemAudio", code: -20)
        }
        targetFormat = target

        var c: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]> { cont in c = cont }
        samplesContinuation = c

        // format: nil → 用 tap 点真实格式,绕开 outputFormat(forBus:) 撒谎。
        //
        // ⚠ installTap / engine.start 在 aggregate device 真实流格式跟
        // AVAudioEngine 内部猜测对不上时,会抛 NSException (
        // "Failed to create tap due to format mismatch"),Swift try 接不到,
        // 直接杀进程。所以包一层 ObjC try/catch,失败 graceful 退出,actor
        // 继续活着,app 不崩。
        let installErr = MyPortraitObjCTryCatch {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
                [weak self] buffer, _ in
                guard let self else { return }
                Task { [weak self] in
                    await self?.performConversion(buffer: buffer)
                }
            }
        }
        if let installErr {
            throw NSError(domain: "SystemAudio", code: -30, userInfo: [
                NSLocalizedDescriptionKey: "installTap failed (caught ObjC exception): \(installErr.localizedDescription)"
            ])
        }
        tapInstalled = true

        if let startErr = MyPortraitObjCTryCatch({
            do { try engine.start() } catch {
                // Swift NSError —— 转抛之外,这里包成 NSException 让外层统一处理
                NSException(name: .internalInconsistencyException,
                            reason: error.localizedDescription,
                            userInfo: nil).raise()
            }
        }) {
            // engine.start 失败 → 就地摘掉刚装的 tap,不留给后续 teardown 补救。
            if tapInstalled {
                _ = MyPortraitObjCTryCatch { inputNode.removeTap(onBus: 0) }
                tapInstalled = false
            }
            throw NSError(domain: "SystemAudio", code: -31, userInfo: [
                NSLocalizedDescriptionKey: "engine.start failed: \(startErr.localizedDescription)"
            ])
        }

        let recorder = vadRecorder
        samplesTask = Task {
            for await samples in stream {
                await recorder?.feed(samples)
            }
        }
    }

    private func performConversion(buffer: AVAudioPCMBuffer) {
        // 看门狗:每次 tap callback 都记一笔(不管转换成没成),用来区分
        // "IO proc 没在跑" vs "在跑但全 0"。
        wdCallbacks += 1

        guard let targetFormat, let cont = samplesContinuation else { return }

        // **converter 按真实 buffer.format 懒建**(see configureTapAndStart
        // 注释)。如果第一帧来的 buffer.format 跟我们之前建的 converter
        // 输入格式不一样(macOS 偶发会变),重建一次。
        if converter == nil || converter?.inputFormat != buffer.format {
            guard let conv = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                return
            }
            converter = conv
        }
        guard let converter else { return }

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
                // ⚠ **必须 .noDataNow,不能 .endOfStream**。converter 被
                // 复用(`if converter == nil` 才重建);.endOfStream 会
                // 让它进入"流结束"内部状态,**之后所有 convert() 永远
                // 返回 0 帧**。整个系统音频 capture 只能出第一帧后哑火。
                // 跟麦克风 AudioCaptureService:233 / VoiceTrainer 同款修法。
                statusPtr.pointee = .noDataNow
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

        // 看门狗峰值振幅 —— 判 "callback 在跑但全 0"。
        var localPeak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > localPeak { localPeak = a }
        }
        if localPeak > wdPeak { wdPeak = localPeak }

        cont.yield(samples)
    }
}
