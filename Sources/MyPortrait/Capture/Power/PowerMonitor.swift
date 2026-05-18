import Foundation
import IOKit.ps

/// 电源状态。
public enum PowerState: String, Sendable {
    case ac
    case battery
    case unknown
}

/// 当前电源状态查询（同步、无副作用）。
///
/// P3 用：CompactionWorker 跳过电池模式。
/// P4 会扩展为基于 IOKit 通知的事件驱动 monitor，给 WhisperKit 转录调度用。
public enum PowerMonitor {

    public static func currentState() -> PowerState {
        guard let snapshotRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        guard let sourcesRef = IOPSCopyPowerSourcesList(snapshotRef)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }

        for source in sourcesRef {
            guard let info = IOPSGetPowerSourceDescription(snapshotRef, source)?.takeUnretainedValue() as? [String: Any],
                  let state = info[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSACPowerValue { return .ac }
            if state == kIOPSBatteryPowerValue { return .battery }
        }
        return .unknown
    }

    /// 便利属性。电池或未知都按"非 AC"对待，最保守。
    public static var isOnAC: Bool {
        currentState() == .ac
    }
}
