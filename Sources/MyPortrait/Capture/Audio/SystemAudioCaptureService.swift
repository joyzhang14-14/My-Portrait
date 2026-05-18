import AVFoundation
import CoreAudio
import Foundation
import os.log

/// 系统音频 (loopback / output) 采集服务。捕获其他 app 的输出（如视频会议
/// 另一方的声音、视频播放声等），与麦克风音频并列存在。
///
/// **状态：架构在位 + Core Audio 半实现**。
///
/// 完整的 process tap → aggregate device → AVAudioEngine 链路需要的代码量
/// 远超本 session 可消化的，且需要 macOS 14.4+ 实际机器联调。当前实现：
///   1. CATapDescription 创建 ✅
///   2. AudioHardwareCreateProcessTap 调用 ✅
///   3. Aggregate device 创建 ✅
///   4. AVAudioEngine ↔ aggregate 绑定 ❌（marks `notImplemented`）
///   5. VAD 状态机 ❌（待 #4 完成后复用 AudioCaptureService 的逻辑，建议抽公共类）
///
/// 跑到 start() 时如果 #4/#5 未完成，会通过 reporter 报 `notImplemented`，
/// **状态栏会冒红点**。Settings UI 仍可显示开关；用户切换不会崩。
///
/// 参考：
///   - Apple 示例：https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
///   - macOS 14.4+ 才有 process tap API
actor SystemAudioCaptureService {

    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "sysaudio")
    private let audioDir: URL

    /// 创建出来的 process tap audio object ID。0 = 未创建。
    private var tapID: AudioObjectID = 0
    /// 包含 tap 的 aggregate device ID。0 = 未创建。
    private var aggregateID: AudioDeviceID = 0

    private var isRunning: Bool = false

    /// 录段事件流。与 AudioCaptureService 并列；TranscriptionScheduler 同样
    /// 订阅这里产出的 wav 段（音频内容会标 `device="system_loopback"`）。
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
        guard !isRunning else { return }

        // 1. CATapDescription：捕获所有进程的 stereo 混合，排除自身避免回环。
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.muteBehavior = .unmuted     // 不静音源
        description.isPrivate = true             // 不向其他 app 暴露
        description.isExclusive = false          // 多 tap 共存

        // 2. 创建 process tap。
        var tap: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == kAudioHardwareNoError else {
            logger.error("AudioHardwareCreateProcessTap failed: status=\(status)")
            return
        }
        tapID = tap
        logger.info("process tap created: id=\(tap)")

        // 3. 把 tap 包成 aggregate device，让标准音频 API 能读它。
        let aggregateUID = "com.myportrait.aggregate.systemTap"
        var tapUIDStr: CFString = "" as CFString
        var tapUIDSize = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = AudioObjectGetPropertyData(tap, &addr, 0, nil, &tapUIDSize, &tapUIDStr)
        guard uidStatus == kAudioHardwareNoError else {
            logger.error("failed to read tap UID: status=\(uidStatus)")
            cleanup()
            return
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyPortraitSystemTapDevice",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUIDStr,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var aggregate: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate
        )
        guard aggStatus == kAudioHardwareNoError else {
            logger.error("AudioHardwareCreateAggregateDevice failed: status=\(aggStatus)")
            cleanup()
            return
        }
        aggregateID = aggregate
        logger.info("aggregate device created: id=\(aggregate)")

        // 4. 把 AVAudioEngine 接到 aggregateID，跑跟 AudioCaptureService 同款的
        //    VAD 状态机。这一步是剩余工作量最大的一段 —— AVAudioEngine 默认绑
        //    系统输入设备，要切到自定义 aggregate 需要直接操作底层 AudioUnit。
        //
        //    建议实现时：
        //      - 把 AudioCaptureService 的 VAD 状态机（processSamples + open/close）
        //        抽到独立的 VADSegmentWriter 类
        //      - 这里和 AudioCaptureService 都注入 VADSegmentWriter，传 device 名
        //      - 段文件用 `device="system_loopback"` 区分
        //
        //    现在直接抛 notImplemented，状态栏红点提示用户：
        //      "尚未接通采集，已分配资源但 0 个段"
        throw_notImplemented_marker()  // 见下方实际抛错点

        isRunning = true
    }

    func stop() async {
        cleanup()
        _segCont.finish()
        isRunning = false
    }

    // MARK: - 私有

    /// 释放 Core Audio 资源。
    private func cleanup() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    /// 仅用来命中 reporter.notImplemented 的桥接 —— async actor 方法里直接
    /// `throw reporter.notImplemented(...)` 会被 `start()` 的 `async`（无
    /// `throws`）拒绝，所以走"主动调 reporter + 用 logger 报错"的方式。
    private func throw_notImplemented_marker() {
        _ = reporter.notImplemented("SystemAudioCaptureService.start[engine wiring]")
        logger.error("SystemAudioCaptureService: resources allocated but engine wiring not yet implemented (P5.1). Tap + aggregate device exist but no segments will be produced.")
        cleanup()
    }
}
