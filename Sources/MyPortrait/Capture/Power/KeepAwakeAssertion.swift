import Foundation
import IOKit.pwr_mgt
import os.log

/// 阻止系统**空闲睡眠**(idle sleep)的 IOPMAssertion 封装。
///
/// 只挡空闲睡眠 —— 合盖(clamshell)和手动睡眠这条断言挡不住:合盖走 macOS 的
/// IOPMrootDomain 独立路径,PreventUserIdleSystemSleep 类断言看不到它。它的作用是:
/// 插着电、盖子开着、有活干时不让机器空闲打盹,把转录积压**全速**跑完再放行睡眠。
///
/// 别被「合盖即停」误导:实测 Apple Silicon + AC 下,合盖后机器进 Clamshell
/// Sleep⇄DarkWake 循环,后台任务(零断言也行)仍会在 DarkWake 窗口里机会性继续推进,
/// 只是被睡眠周期节流、明显变慢。要合盖还满速,得靠外接显示器进 clamshell 模式或
/// `sudo pmset -c disablesleep`——不是这条断言能做的。
///
/// 用法:`refresh(true)` 持有断言,`refresh(false)` 释放。幂等 —— 重复调同一状态
/// 是 no-op。断言是进程级的,进程退出时系统自动回收(但我们仍在 scheduler stop()
/// 显式释放,避免关采集后机器一直不睡)。
@MainActor
final class KeepAwakeAssertion {
    static let shared = KeepAwakeAssertion()

    private var assertionID: IOPMAssertionID?
    /// 按 owner 的引用计数。任一 owner 持有 → 断言在;全部释放 → 撤。
    /// 多个子系统(转录 owner "default" / 记忆管线 owner "memory")各自独立持有,
    /// 互不踩 —— 否则单例 + 布尔 refresh 时,一方 refresh(false) 会误放另一方的断言。
    private var owners: Set<String> = []
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "power")

    private init() {}

    /// 单 owner on/off(转录沿用此 API,等价 `set(hold, owner: "default")`)。
    func refresh(_ hold: Bool) { set(hold, owner: "default") }

    /// 多 owner 引用计数版:`hold` 把该 owner 加入/移出持有集,断言随"是否还有
    /// 任一 owner"创建 / 释放。幂等 —— 已是目标状态是 no-op。
    func set(_ hold: Bool, owner: String) {
        if hold { owners.insert(owner) } else { owners.remove(owner) }
        let want = !owners.isEmpty
        if want {
            guard assertionID == nil else { return }
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MyPortrait: background work on AC power" as CFString,
                &id
            )
            if r == kIOReturnSuccess {
                assertionID = id
                logger.info("idle-sleep assertion acquired (id=\(id, privacy: .public))")
            } else {
                logger.warning("IOPMAssertionCreateWithName failed: \(r, privacy: .public)")
            }
        } else {
            guard let id = assertionID else { return }
            IOPMAssertionRelease(id)
            assertionID = nil
            logger.info("idle-sleep assertion released")
        }
    }
}
