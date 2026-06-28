import Foundation
import IOKit
import IOKit.ps

/// 电源状态。
public enum PowerState: String, Sendable {
    case ac
    case battery
    case unknown
}

/// 一次电源/系统状态快照 —— 给 PowerProfile.resolve 的 auto 决策用。
/// 仿 screenpipe power/monitor.rs 收集的几项。
public struct PowerSnapshot: Sendable {
    public let state: PowerState
    /// 电池电量百分比 0–100。台式机 / 取不到时 nil。
    public let batteryPercent: Int?
    /// 系统「低电量模式」开关(设置 → 电池)。
    public let isLowPowerMode: Bool
    /// 热压力等级。.serious / .critical 时 auto 降到 saver。
    public let thermalState: ProcessInfo.ThermalState
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

    /// 读 IORegistry `IOPMrootDomain` 的某个 Bool property(Yes/No)。
    /// 取不到按 false 最保守。普通权限可读。
    private static func rootDomainBool(_ key: String) -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        return (prop as? Bool) ?? false
    }

    /// 笔记本盖子是否合上。读 `AppleClamshellState`(实测:开盖=No/false，
    /// 合盖=Yes/true；`AppleClamshellCausesSleep` 是另一回事，别用)。取不到时
    /// 按"开盖"(false)最保守 —— 让 helper 宁可不持有 disablesleep。
    public static var isLidClosed: Bool { rootDomainBool("AppleClamshellState") }

    /// 系统当前是否处于 disablesleep(`pmset disablesleep 1`)。读 `SleepDisabled`
    /// (普通权限可读、不可写)。用于检测 helper 异常死亡(SIGKILL/重启)留下、
    /// 没人复位的残留 —— app 据此主动连 helper 清成 0。
    public static var systemSleepDisabled: Bool { rootDomainBool("SleepDisabled") }

    /// 完整快照：电源状态 + 电池百分比 + 低电量模式 + 热压力。
    /// PowerProfile.resolve 的 auto 决策用。
    public static func snapshot() -> PowerSnapshot {
        var resolvedState: PowerState = .unknown
        var pct: Int? = nil

        if let snapshotRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshotRef)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(snapshotRef, source)?
                        .takeUnretainedValue() as? [String: Any] else { continue }
                if let s = info[kIOPSPowerSourceStateKey] as? String {
                    if s == kIOPSACPowerValue { resolvedState = .ac }
                    else if s == kIOPSBatteryPowerValue { resolvedState = .battery }
                }
                // 电量 = 当前容量 / 最大容量 × 100。多数机型 cur 已是 0–100。
                if let cur = info[kIOPSCurrentCapacityKey] as? Int,
                   let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    pct = Int((Double(cur) / Double(max) * 100).rounded())
                }
            }
        }

        let pi = ProcessInfo.processInfo
        return PowerSnapshot(
            state: resolvedState,
            batteryPercent: pct,
            isLowPowerMode: pi.isLowPowerModeEnabled,
            thermalState: pi.thermalState
        )
    }
}
