import Foundation
import Observation

/// 聚合所有"故意暂停"的信号源,给 StallDetector 抑制误报用。
///
/// 借鉴 upstream `health.rs` 的 `intentionally_deferring` 概念:
///   - DRM 命中:故意停采集,不算 stall
///   - 屏幕睡眠 / 锁屏:故意停采集,不算 stall
///   - 用户关 capture toggle:故意停采集,不算 stall
///
/// 各个 watcher 主动推这里(setter @MainActor 安全)。@Observable 让 HealthView
/// 自动响应变化。
@MainActor
@Observable
final class IntentionalPauseState {
    static let shared = IntentionalPauseState()

    /// DRMWatcher → CaptureCoordinator.handleDRMState 推。
    var drmActive: Bool = false

    /// SleepWakeWatcher → CaptureCoordinator.handleSleepWake 推。willSleep /
    /// screensDidSleep 翻 true,didWake / screensDidWake 翻 false。
    var screenAsleep: Bool = false

    /// ConfigStore.capture.enabled == false 时翻 true。CaptureSettings 那条
    /// Combine sink 顺手推一下。
    var captureDisabled: Bool = false

    /// TranscriptionScheduler 在 battery 模式下 gate 掉一轮转录时翻 true。
    /// **仅压 audio 类 stall**(audioBacklog),不进 anyPaused,vision 该报还报。
    /// 在电池场景:mic 段继续入库 → pending 队列堆 → 不是 stall,是设计。
    var audioTranscriptionPaused: Bool = false

    /// 当前是否处于任何 *全局* 故意暂停状态(DRM / 锁屏睡眠 / 用户关 toggle)。
    /// StallDetector 早查这个跳过所有 stall。audioTranscriptionPaused 不在此 ——
    /// 它只能压 audio 路径,不该顺手压住 vision。
    var anyPaused: Bool {
        drmActive || screenAsleep || captureDisabled
    }

    private init() {}
}
