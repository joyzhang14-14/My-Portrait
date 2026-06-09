@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log
#if canImport(MyPortraitObjC)
import MyPortraitObjC   // ObjC try/catch wrapper:SwiftPM 当独立 module 要 import;
                       // Xcode 走 bridging header 时 canImport 为 false,helper 全局可见。
#endif

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
    //
    // **AVAudioEngine 必须懒构造**：仅仅 `AVAudioEngine()` 这一步就会拉起
    // Audio Toolbox + caulk.messenger XPC 通道。caulk 通道一旦活着，进程里
    // 其他无关代码（比如 SCK 走 caulk 的 reply、Combine sink 走它的 worker）
    // 撞错队列时就会触发 dispatch_assert_queue_fail 把整个进程 abort 掉。
    // 实测：audio toggle 一直 OFF + screen toggle 切换也会崩，唯一不崩的姿势
    // 就是 **从来不构造 AVAudioEngine**。
    private var engine: AVAudioEngine?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // VAD/写盘后端
    private var vadRecorder: VADRecorder?

    private var samplesContinuation: AsyncStream<[Float]>.Continuation?
    private var samplesTask: Task<Void, Never>?

    /// start() 第一行的 `await requestMicrophonePermission` 是 actor 让位点;
    /// 在它返回前 samplesTask 还是 nil → 另一个 restart 入队时 guard 会以为
    /// "没在跑"放它进去 → 跑到 installTap 时撞 `nullptr == Tap()` 崩。
    /// 在第一个 await 之前**同步**置位这个 flag,作为重入闸。
    private var starting: Bool = false

    /// 跟踪 inputNode 上 tap 是否真装过。**stop() 必须检查这个再调 removeTap**：
    /// 没装过 tap 就 removeTap，AudioToolbox 内部抛 `-10877`
    /// (`kAudioUnitErr_InvalidElement`)，紧接着 caulk.messenger 把这个错误投递
    /// 回我们进程时撞 dispatch_assert_queue → 整进程崩。
    /// 真凶在 Services.startManagedLifecycle：默认 settings 全 false，Combine
    /// sink 启动时会立刻 fire applyAudioCapture(enabled=false) 调 stop()，
    /// 但此时 start() 还没跑过，engine 上根本没 tap。
    private var tapInstalled: Bool = false

    private var permissionGranted: Bool = false

    /// 诊断：tap 缓冲转换计数，确认麦克风数据是否真在流动。
    private var conversionCount: Int = 0

    /// 默认输入设备变更监听 block（热插拔）。非 nil = 已注册。
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// 设备变更后的防抖重启任务。
    private var restartTask: Task<Void, Never>?
    /// follow-system 模式下最近一次实际生效的系统默认输入 UID。用来过滤
    /// AVAudioEngine 自建聚合设备(CADefaultDeviceAggregate)反复建毁引发的设备列表
    /// 抖动 —— 那不是真默认设备变更,不该触发重启。否则正常使用时聚合设备自发抖动
    /// → 触发重启 → 重启失败/被打断 → 引擎卡在停止态(麦克风灯灭)。
    private var lastDefaultInputUID: String?

    /// 长期稳定的段事件流 —— 与 VADRecorder 生命周期解耦。VADRecorder 每次
    /// start/stop、设备热插拔都会换新实例，但消费方订阅这条稳定流即可，不会断。
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

    /// 稳定的段事件流。Services 在 startManagedLifecycle 里 merge 这个与
    /// SystemAudioCaptureService 的同名流。VADRecorder 重建不影响这条流。
    func segmentEvents() -> AsyncStream<AudioSegmentEvent> {
        return segmentEventStream
    }

    // MARK: - 生命周期

    func start() async {
        guard samplesTask == nil, !starting else { return }
        starting = true
        defer { starting = false }

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

        let recorder = VADRecorder(deviceLabel: "default_microphone", audioDir: audioDir)
        vadRecorder = recorder
        let cont = segmentEventCont
        forwardTask = Task {
            for await seg in recorder.segmentEvents { cont.yield(seg) }
        }

        do {
            try configureEngineAndStartTap()
        } catch {
            logger.error("engine start failed: \(String(describing: error), privacy: .public)")
            return
        }

        registerDeviceChangeListener()
        logger.notice("AudioCaptureService started (mic, VAD-segmented)")
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        unregisterDeviceChangeListener()

        // engine 没构造 → 整条 start() 流水线没跑过，下面所有字段都是 nil → 直接退。
        // 关键防御：避免 lazy 触发 engine 构造（构造本身就会拉起 caulk）。
        guard let engine else {
            logger.info("AudioCaptureService stopped (was never started)")
            return
        }

        // 先停 engine 再 removeTap（Apple 标准顺序），并且只在装过 tap 时才 remove。
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        // **同步摘下全部 session 状态再排干** —— 下面每个 await 都是 actor
        // 重入窗口,start() 若在窗口内插入会重建这些字段:旧 stop 恢复后会
        // flush 错新 recorder(把新 session 的段流 finish 掉 → 孤儿 wav 换
        // 路径回归)、或 await 到永不结束的新 forwardTask(stop 永久 park,
        // restartIfRunning / 退出清理跟着卡死)。摘成 local copy 后排干只碰
        // 本次 session 的对象,交错的 start 不受影响。
        //
        // engine / converter / targetFormat 也在这里同步置 nil,让 ARC 回收
        // AVAudioEngine 实例。否则即使调了 engine.stop(),内部 AUHAL 仍持着
        // 麦克风硬件连接,macOS 还把这个 app 当"正在录",蓝牙耳机会被强切到
        // HFP(低音质双向)→ 音乐音质明显下降。
        // 代价:下次 start() 要重建 engine(拉起 caulk),~50ms 额外开销。
        let doomedCont = samplesContinuation
        let doomedSamplesTask = samplesTask
        let doomedForwardTask = forwardTask
        let doomedRecorder = vadRecorder
        samplesContinuation = nil
        samplesTask = nil
        forwardTask = nil
        vadRecorder = nil
        self.engine = nil
        self.converter = nil
        self.targetFormat = nil

        // 排干顺序(防丢正在说的最后一段):
        // ① 样本流 finish → **等** samplesTask 把已缓冲样本喂完 VADRecorder
        //   (不 cancel —— cancel 会让 for-await 立即返回,缓冲样本丢失);
        // ② flush 当前段(写盘 + yield 段事件 + finish 段流);
        // ③ **等** forwardTask 把段事件(含 flush 刚关的这段)转发给
        //    TranscriptionScheduler 后自然退出。
        // 先 cancel forwardTask 再 flush 会让 flush yield 的段事件无人接收
        // → wav 留盘成孤儿、DB 无行、永不转录 —— 每次 stop(音乐暂停 / 锁屏 /
        // 设备热插拔 / 退出)都丢用户正在说的最后一段。
        doomedCont?.finish()
        await doomedSamplesTask?.value
        await doomedRecorder?.flush()
        await doomedForwardTask?.value

        // 清掉 activeUID,否则 UI 一直显示「recording from <设备>」幻影(start
        // 时在 line 225 设过)。"" 走 else 分支干净置空。
        Task { @MainActor in AudioDevicesMonitor.shared.setActiveUID("") }

        logger.info("AudioCaptureService stopped")
    }

    // MARK: - 引擎配置 + tap

    private func configureEngineAndStartTap() throws {
        // 真正需要 AVAudioEngine 的时候才构造（实际录音那一瞬间）。见上面 engine 注释。
        let engine: AVAudioEngine = {
            if let e = self.engine { return e }
            let e = AVAudioEngine()
            self.engine = e
            return e
        }()

        lastDefaultInputUID = Self.currentDefaultInputUID()   // 记下启动时的真实默认,供 follow-system 过滤抖动

        let inputNode = engine.inputNode
        // 用户在 Settings 锁定输入设备 → 绑定 AUHAL.CurrentDevice。**必须在
        // 读 outputFormat / installTap 之前** —— 这两步会触发 AU initialize,
        // 之后再改 CurrentDevice 已晚。空字符串 = follow system default (跳过)。
        Self.bindPreferredInputDevice(inputNode: inputNode, logger: logger)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // 设备不可用/切换瞬间(疯狂开关 audio capture、蓝牙断连),outputFormat 会是
        // sampleRate=0 的无效格式,后面 installTap 拿它会抛 NSException → SIGABRT
        // 闪退(线上崩溃栈正是 installTap → NSException → abort)。前置挡掉,让
        // start() 优雅失败而不是杀进程。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCaptureService", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "Input device has no valid format (sampleRate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)) — device unavailable or switching",
            ])
        }

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

        // 蓝牙输入设备投递抖动大（±200ms），用更大的 tap 缓冲吸收抖动。
        let bufferSize: AVAudioFrameCount = Self.boundInputIsBluetooth(inputNode: inputNode) ? 8192 : 4096
        // 防御:install 前先 remove 任何残留 tap。Apple 文档保证没 tap 时
        // 是 no-op。撞 `nullptr == Tap()` 的根因是重复 install,这里兜底。
        inputNode.removeTap(onBus: 0)
        tapInstalled = false
        // installTap / engine.start 在格式不匹配 / aggregate device 异常时用
        // **NSException** 报错,Swift 接不住 → 直接 SIGABRT 闪退(线上崩溃就是这个)。
        // 用 MyPortraitObjC 的 try/catch helper(本就是为这俩造的,之前没接线)兜住,
        // 转成 Swift error 让 start() 优雅失败。block 只碰 local 变量,避开 actor 隔离;
        // tapInstalled 在成功后于 block 外置位。
        var startError: Error?
        let nsErr = MyPortraitObjCTryCatch {
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self else { return }
                Task { [weak self] in
                    await self?.performConversion(buffer: buffer)
                }
            }
            do { try engine.start() } catch { startError = error }
        }
        if let nsErr {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw NSError(domain: "AudioCaptureService", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "audio tap/engine failed (NSException): \(nsErr.localizedDescription)",
                "underlying": nsErr,
            ])
        }
        if let startError {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw startError
        }
        tapInstalled = true

        // 通知 AudioDevicesMonitor:app 现在在录哪个 device(UI live status)。
        // 不阻塞主路径,fire-and-forget。
        let activeUID = Self.currentInputDeviceUID(inputNode: inputNode)
        Task { @MainActor in AudioDevicesMonitor.shared.setActiveUID(activeUID) }

        let recorder = vadRecorder
        samplesTask = Task {
            for await samples in stream {
                await recorder?.feed(samples)
            }
        }
    }

    /// 把 inputNode 底层 AUHAL 的 CurrentDevice 绑到用户在 Settings 锁定
    /// 的 UID。空 UID / 设备不存在(拔了)/ 绑定失败 → 让它 fallback 系统
    /// default(AVAudioEngine 默认行为),不抛错。
    nonisolated private static func bindPreferredInputDevice(
        inputNode: AVAudioInputNode, logger: Logger
    ) {
        let uid = ConfigStore.snapshot.preferredInputDeviceUID
        guard !uid.isEmpty else { return }   // follow system

        // AudioDevicesMonitor 是 @MainActor —— 这里在 actor 外,直接查
        // CoreAudio 同步 API(避免引 hop 复杂度)。
        guard let deviceID = currentDeviceID(forUID: uid) else {
            logger.warning("preferred input device UID '\(uid, privacy: .public)' not found — falling back to system default")
            return
        }

        // 用 AUAudioUnit.setDeviceID(现代 API)—— 这是 AVAudioEngine 真正认的设备切换
        // 方式:引擎会按新设备重配输入,下面 line 186 的 inputNode.outputFormat 随之更新
        // 成新设备的真实采样率。旧做法直接 AudioUnitSetProperty(kAudioOutputUnitProperty_
        // CurrentDevice)在已 initialize 的 AUHAL 上会被静默忽略 → 设备号变了但引擎仍渲染
        // 旧默认 → 不亮 mic 灯、零 buffer(默认 16k 蓝牙 vs 96k 内置麦尤其明显)。
        do {
            try inputNode.auAudioUnit.setDeviceID(deviceID)
            logger.notice("bound mic input to device UID '\(uid, privacy: .public)' via setDeviceID")
        } catch {
            logger.warning("setDeviceID failed: \(String(describing: error), privacy: .public) — falling back to system default")
        }
    }

    /// 查当前 inputNode 实际在用的 device UID(给 UI live status)。
    nonisolated private static func currentInputDeviceUID(inputNode: AVAudioInputNode) -> String {
        guard let au = inputNode.audioUnit else { return "" }
        var did = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &did, &size
        )
        guard status == noErr, did != 0 else { return "" }
        return deviceUID(forID: did) ?? ""
    }

    /// AudioDeviceID → UID(同步 CoreAudio query)。
    nonisolated private static func deviceUID(forID id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf as String
    }

    /// UID → AudioDeviceID(扫所有设备找匹配,同步)。
    nonisolated private static func currentDeviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return nil }
        for id in ids {
            if deviceUID(forID: id) == uid { return id }
        }
        return nil
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
                // .noDataNow（不是 .endOfStream）：本次输入喂完，但流继续。
                // .endOfStream 会永久终结转换器，导致第二个缓冲起 convert 全失败。
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
        conversionCount += 1
        if conversionCount == 1 || conversionCount % 150 == 0 {
            logger.notice("tap buffer converted: count=\(self.conversionCount, privacy: .public) samples=\(count, privacy: .public)")
        }
        cont.yield(samples)
    }

    // MARK: - 设备热插拔

    /// 读系统当前默认输入设备的 UID(不是 app 绑的设备,也不是 AVAudioEngine 自建的
    /// 聚合设备 CADefaultDeviceAggregate)。follow-system 判断"默认是否真变了"用,
    /// 过滤聚合设备抖动。
    nonisolated private static func currentDefaultInputUID() -> String {
        var addr = defaultInputAddress()
        var did = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &did
        ) == noErr, did != 0 else { return "" }
        return deviceUID(forID: did) ?? ""
    }

    /// 默认输入设备的属性地址（系统对象上）。CoreAudio API 要 `&` 指针，
    /// 调用处各自拷一份本地 var 传入。
    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 注册「输入设备变化」监听。订阅两个事件:
    ///   - default input device 变(系统层切默认 —— follow-system 模式重启)
    ///   - 设备列表变(插拔 —— 锁定模式可能要 fallback / 回切)
    private func registerDeviceChangeListener() {
        guard deviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { await self?.handleDeviceChange() }
        }
        var defAddr = Self.defaultInputAddress()
        var listAddr = Self.devicesListAddress()
        var ok = true
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defAddr, DispatchQueue.main, block
        ) != noErr { ok = false }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main, block
        ) != noErr { ok = false }
        if ok {
            deviceListenerBlock = block
        } else {
            logger.warning("failed to register one or both device listeners")
        }
    }

    private func unregisterDeviceChangeListener() {
        guard let block = deviceListenerBlock else { return }
        var defAddr = Self.defaultInputAddress()
        var listAddr = Self.devicesListAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defAddr, DispatchQueue.main, block
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main, block
        )
        deviceListenerBlock = nil
    }

    nonisolated private static func devicesListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 设备变更回调。防抖：1 秒内的连续变更合并成一次决策（拔插常爆发多个事件）。
    private func handleDeviceChange() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.restartForDeviceChange()
        }
    }

    /// 用户在 Settings 改了 preferredInputDeviceUID → Services 调这个,
    /// 在跑的话立刻重新绑定新设备。没在跑就 no-op(下次 start() 自然绑)。
    func restartIfRunning() async {
        guard samplesTask != nil else { return }
        logger.info("config change: preferredInputDeviceUID → restart")
        await stop()
        // ⚠️ stop()→start() 不原子。stop 的 await 期间用户可能关了 Audio Capture 主开关。
        // 重新确认主开关还开着才 start,否则重启的 start 会在"关"之后把引擎拉起来 →
        // 关了橙色 mic 灯还亮(日志铁证)。
        let masterOn = await MainActor.run { ConfigStore.shared.current.capture.audio.enabled }
        guard masterOn else {
            logger.notice("restart aborted: Audio Capture turned off mid-restart (config path)")
            return
        }
        await start()
    }

    /// 决定要不要重启:
    /// - follow-system(preferredUID=""):default 变 → 重启(切新 default)
    /// - 锁定 UID:绑的设备消失(被拔)→ 重启 fallback;绑的设备**回来**了
    ///   (之前 fallback 的)→ 重启重绑;其他变化(无关设备插拔)→ 不动
    private func restartForDeviceChange() async {
        guard samplesTask != nil else { return }   // 没在采集就不重启
        let preferredUID = ConfigStore.snapshot.preferredInputDeviceUID
        let nowActiveUID = await MainActor.run { AudioDevicesMonitor.shared.activeUID }
        let availableUIDs = Set(AudioDevicesMonitor.enumerateInputDevices().map { $0.id })

        let shouldRestart: Bool
        let reason: String
        if preferredUID.isEmpty {
            // follow-system:只在**真实系统默认输入设备**变了时重启。AVAudioEngine 自建的
            // 聚合设备(CADefaultDeviceAggregate)反复建毁会狂发设备列表变更通知,但真实
            // 默认没变 —— 不能跟着重启,否则正常使用时自己喂自己重启 → 重启失败把引擎卡停。
            let curDefault = Self.currentDefaultInputUID()
            if curDefault == lastDefaultInputUID {
                shouldRestart = false
                reason = "follow-system default unchanged (\(curDefault)) — ignoring device-list churn"
            } else {
                shouldRestart = true
                reason = "default input changed: \(lastDefaultInputUID ?? "nil") → \(curDefault)"
                lastDefaultInputUID = curDefault
            }
        } else {
            let preferredNowAvailable = availableUIDs.contains(preferredUID)
            let alreadyOnPreferred = (nowActiveUID == preferredUID)
            if preferredNowAvailable && !alreadyOnPreferred {
                shouldRestart = true; reason = "preferred device '\(preferredUID)' is back — rebinding"
            } else if !preferredNowAvailable && alreadyOnPreferred {
                shouldRestart = true; reason = "preferred device '\(preferredUID)' disconnected — falling back to system default"
            } else {
                shouldRestart = false; reason = "no-op (preferred=\(preferredUID), active=\(nowActiveUID))"
            }
        }

        guard shouldRestart else {
            logger.info("device change: \(reason, privacy: .public)")
            return
        }
        logger.info("device change: \(reason, privacy: .public) — restarting mic capture")
        await stop()
        // 同 restartIfRunning:重启的 stop→start 不原子,期间用户可能关了主开关 →
        // 再确认开着才 start,否则关了引擎被重启拉回来 → 橙灯卡住。
        let masterOn = await MainActor.run { ConfigStore.shared.current.capture.audio.enabled }
        guard masterOn else {
            logger.notice("restart aborted: Audio Capture turned off mid-restart (device-change path)")
            return
        }
        await start()
    }

    /// tap **实际绑定**的输入设备是不是蓝牙(读 AUHAL CurrentDevice,不是系统默认)。
    /// 用户锁了非默认设备时,buffer 大小要按真正在用的设备判 —— 原来查系统默认会判错。
    /// 蓝牙投递抖动大(±200ms),命中时用更大 tap 缓冲吸收。
    private static func boundInputIsBluetooth(inputNode: AVAudioInputNode) -> Bool {
        guard let au = inputNode.audioUnit else { return false }
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID, &size) == noErr,
              deviceID != 0 else { return false }

        var transport: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        var taddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &taddr, 0, nil, &tsize, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
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
