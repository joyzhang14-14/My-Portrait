import Foundation

/// 屏幕采集的功耗档位 —— 仿 screenpipe `power/profile.rs`。
///
/// My-Portrait 的采集层比 screenpipe 轻(截图 + OCR,非连续录像),所以只接
/// 两个真正有意义的 knob:
///   - `minCaptureIntervalMs`:两次抓帧的最小间隔(防抖)。越大越省电。
///   - `jpegQuality`:JPG 压缩质量。越低越省 CPU/盘。
///
/// 数值与 screenpipe 三档对齐(performance/balanced/saver):
///   interval 200/500/1000ms,jpeg 0.80/0.60/0.40。
struct PowerProfile: Sendable, Equatable {
    var minCaptureIntervalMs: Int
    var jpegQuality: Double

    static let performance = PowerProfile(minCaptureIntervalMs: 200,  jpegQuality: 0.80)
    static let balanced    = PowerProfile(minCaptureIntervalMs: 500,  jpegQuality: 0.60)
    static let saver       = PowerProfile(minCaptureIntervalMs: 1000, jpegQuality: 0.40)

    /// 把用户选的模式 + 当前系统快照,解析成实际生效的 profile。
    /// auto 决策仿 screenpipe `Profile::for_state`:
    ///   1. 热压力 serious/critical → saver
    ///   2. 系统低电量模式 → saver
    ///   3. 接电(AC) → performance
    ///   4. 电池:≤40% → saver,>40%(或未知)→ balanced
    static func resolve(userMode: PowerMode, snapshot: PowerSnapshot) -> PowerProfile {
        switch userMode {
        case .performance:
            return .performance
        case .batterySaver:
            return .saver
        case .auto:
            if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
                return .saver
            }
            if snapshot.isLowPowerMode { return .saver }
            if snapshot.state == .ac { return .performance }
            // 电池供电(或未知)
            if let pct = snapshot.batteryPercent, pct <= 40 { return .saver }
            return .balanced
        }
    }
}
