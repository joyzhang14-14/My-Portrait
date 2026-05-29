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

    /// 当前是否处于任何故意暂停状态。StallDetector evaluate 时早查这个。
    var anyPaused: Bool {
        drmActive || screenAsleep || captureDisabled
    }

    private init() {}
}
