import Foundation
import IOKit.pwr_mgt
import os.log

/// 阻止系统**空闲睡眠**(idle sleep)的 IOPMAssertion 封装。
///
/// 只挡空闲睡眠 —— 合盖(clamshell)睡眠和手动睡眠挡不住,那是 macOS 在系统/硬件层
/// 强制的,公开 API 无法覆盖。所以这只能保证「插着电、盖子开着、有活干」时机器不会
/// 自己打盹,把转录积压跑完再放行睡眠。
///
/// 用法:`refresh(true)` 持有断言,`refresh(false)` 释放。幂等 —— 重复调同一状态
/// 是 no-op。断言是进程级的,进程退出时系统自动回收(但我们仍在 scheduler stop()
/// 显式释放,避免关采集后机器一直不睡)。
@MainActor
final class KeepAwakeAssertion {
    static let shared = KeepAwakeAssertion()

    private var assertionID: IOPMAssertionID?
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "power")

    private init() {}

    /// `hold == true` 且当前未持有 → 创建断言;`hold == false` 且当前持有 → 释放。
    func refresh(_ hold: Bool) {
        if hold {
            guard assertionID == nil else { return }
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MyPortrait: transcribing audio backlog on AC power" as CFString,
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
