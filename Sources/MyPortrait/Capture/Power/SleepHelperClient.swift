import Foundation
import ServiceManagement
import os.log

/// app 端对接 PortraitSleepHelper(特权 root LaunchDaemon)的客户端。
///
/// 职责:
///   1. 注册 / 注销 daemon(由 General 设置「合盖时保持运行」开关驱动);
///   2. 经 XPC 让 helper 以 root 跑 `pmset disablesleep 0/1`,使机器合盖+插电也能
///      把后台任务(event/portrait/personality)跑完。
///
/// 触发由 [[MemoryScheduler]] 的 refreshKeepAwake 统一调度,和 IOPMAssertion 同一
/// 门槛(有任务在跑 + 插电)。开盖时 IOPMAssertion 就够;合盖只有 pmset 能挡 clamshell。
///
/// 崩溃安全不在这里兜底,而是绑在 XPC 连接生死上 —— app 崩/被杀/退出 → 连接断 →
/// helper 的 invalidationHandler 复位 disablesleep 0 并退出(详见 helper main.swift)。
@MainActor
final class SleepHelperClient {
    static let shared = SleepHelperClient()

    /// 必须跟 daemon plist 的 Label / MachServices key 和 helper 的
    /// NSXPCListener(machServiceName:) 逐字一致。
    static let machServiceName = "com.joyzhang.myportrait.SleepHelper"

    private let service = SMAppService.daemon(plistName: "\(machServiceName).plist")
    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "sleephelper")

    /// 长连接,复用(研究结论:别每次 toggle 新建)。所有后台任务停了才拆。
    private var connection: NSXPCConnection?
    /// 当前是否已让 helper 持 disablesleep=1。
    private var holding = false

    private init() {}

    var status: SMAppService.Status { service.status }

    // MARK: - 注册 / 注销(General 设置开关驱动)

    /// 开关打开:注册 daemon。首次 status 变 .requiresApproval → 跳系统设置引导批准
    /// (不弹密码框,需用户在「登录项与扩展」手动开「允许在后台」一次)。
    func enable() {
        do {
            try service.register()
            log.info("register OK, status=\(self.statusName, privacy: .public)")
        } catch {
            // 首次 register() 抛 code 1 == requiresApproval,是正常流程不是失败。
            log.info("register threw code=\((error as NSError).code, privacy: .public) — 首次 requiresApproval 正常")
        }
        if service.status != .enabled {
            log.info("status=\(self.statusName, privacy: .public) → 打开系统设置让用户批准")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// 开关关闭:复位 disablesleep + 拆连接(helper 退出)+ 注销 daemon。
    func disable() {
        teardownConnection(resetFirst: true)
        do { try service.unregister(); log.info("unregister OK") }
        catch { log.error("unregister failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// app 启动时调一次的**自愈**:开关开着就 `register()` 刷新注册,让 rebuild 后
    /// 变化的 cdhash 重新进 SMAppService 的 LWCR —— 否则自签名每次重编都让注册陈旧、
    /// launchd 拒启 helper(EX_CONFIG / spawn failed)、"开关开着却悄悄失效"。
    /// 无副作用:① 开关没开 → 直接返回,不注册;② **不弹系统设置**(首次批准仍由
    /// enable() 负责);③ **不 unregister**(只 register,幂等;稳定 build 上 no-op,
    /// 已批准的不需重新批准)。
    func syncRegistration() {
        guard ConfigStore.shared.current.general.keepAwakeLidClosed else { return }
        do {
            try service.register()
            log.info("launch sync register OK, status=\(self.statusName, privacy: .public)")
        } catch {
            log.info("launch sync register threw code=\((error as NSError).code, privacy: .public), status=\(self.statusName, privacy: .public)")
        }
    }

    // MARK: - keep-awake(MemoryScheduler.refreshKeepAwake 驱动)

    /// 有任务在跑 + 插电 → `true` 让机器合盖也清醒;全停 → `false` 复位。
    /// 仅当用户开了开关且 helper 已批准(.enabled)才真正动作,否则静默 no-op。
    func setKeepAwake(_ enabled: Bool) {
        guard ConfigStore.shared.current.general.keepAwakeLidClosed,
              service.status == .enabled else {
            if !enabled { teardownConnection(resetFirst: false) }   // 没开/没批准:别占着 helper
            return
        }
        if enabled {
            guard let proxy = proxy() else { return }
            holding = true
            proxy.setKeepAwake(true) { [weak self] ok, diag in
                Task { @MainActor in
                    self?.log.info("setKeepAwake(true) → ok=\(ok, privacy: .public) \(diag, privacy: .public)")
                }
            }
        } else if holding {
            holding = false
            // 拆连接 → helper invalidationHandler 复位 disablesleep 0 并退出
            //(跟崩溃安全同一条路径,最稳;空闲时不留 root 进程)。
            teardownConnection(resetFirst: true)
        }
    }

    // MARK: - XPC 连接

    private func proxy() -> PortraitSleepHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: PortraitSleepHelperProtocol.self)
            // ⚠️ 所有 handler 必须显式 `@Sendable`。它们由 XPC 在**连接自己的队列**
            // 上回调;不标的话在 @MainActor 类里会被推断成 @MainActor 隔离,XPC 在非
            // 主队列调用时触发 `_dispatch_assert_queue_fail` 崩溃(invalidate() 拆连接
            // 时 invalidationHandler fire 实测崩)。@Sendable 闭包不可能 actor 隔离,
            // 闭包体内仍 Task{@MainActor} 跳回主线程改状态。
            c.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil; self?.holding = false }
            }
            c.interruptionHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil; self?.holding = false }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            Task { @MainActor in
                self?.log.error("XPC error: \(error.localizedDescription, privacy: .public)")
                self?.connection = nil; self?.holding = false
            }
        } as? PortraitSleepHelperProtocol
    }

    private func teardownConnection(resetFirst: Bool) {
        if resetFirst,
           let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable _ in }) as? PortraitSleepHelperProtocol {
            proxy.setKeepAwake(false) { @Sendable _, _ in }
        }
        connection?.invalidate()
        connection = nil
        holding = false
    }

    private var statusName: String {
        switch service.status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown"
        }
    }
}
