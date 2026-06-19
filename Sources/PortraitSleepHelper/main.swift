import Foundation
import os.log

// PortraitSleepHelper —— 特权 root LaunchDaemon。
//
// 唯一职责:以 root 跑 `pmset -c disablesleep 0/1`,让 Mac 合盖+插电时也完全清醒
// (撑长云调用),并在 app 崩/退/被杀时**自动复位**,绝不把机器永久钉醒着。
//
// 启动方式:SMAppService 注册的 LaunchDaemon,**按需(on-demand)**拉起 ——
// daemon plist 只声明 MachServices(无 RunAtLoad / KeepAlive),app 端连这个
// mach service 名字就触发 launchd 把本进程以 root 拉起(参照 Pearcleaner 的现网
// helper 形态;Tailscale 的 KeepAlive+RunAtLoad 是常驻 daemon,不是我们要的模型)。
//
// 崩溃安全三层(都幂等,跑两次 `disablesleep 0` 无害):
//   1) reset-on-launch:进程一起来无条件清零(兜底上个实例被强杀没复位的情况);
//   2) per-connection invalidation/interruption:client(app)连接一断就复位 + 退出;
//   3) 退出让 launchd 下次按需重拉,每个新实例从已知状态起步。

// 服务名 —— 必须跟下面三处**逐字一致**:
//   · Support/com.joyzhang.myportrait.SleepHelper.plist 的 Label / MachServices key
//   · app 端 SleepHelperClient 的 machServiceName / daemon(plistName:)
// 改这里要同步改那两处。
let kMachServiceName = "com.joyzhang.myportrait.SleepHelper"

// 只接受**我们自己签名**的 app 连接。
// ⚠️ 自签名必须钉**叶证书 SHA-1 哈希**,不能用 `certificate leaf[subject.CN]="MyPortraitDev"`:
// 自签证书没有 Apple anchor / Team OU 背书,任何人都能重新自签一张同 CN 的证书冒充
// (已实测:同 CN 不同证书能过 CN 校验)。这是 root 控 pmset 的通道,必须钉死叶证书。
// 哈希 = MyPortraitDev 叶证书 SHA-1;证书若重签会变,届时更新此串:
//   codesign -d -r- /path/to/MyPortrait.app    # 取 `certificate leaf = H"..."`
// (若将来改用 Developer ID 公证版,改成 `anchor apple generic and certificate
//  leaf[subject.OU] = <TeamID>`。)
let kClientRequirement =
    "identifier \"com.joyzhang.myportrait\" and certificate leaf = H\"0E173239AFD0E59C792062669801286CC513104E\""

// subsystem 用服务名 → 排查时:
//   sudo log stream --predicate 'subsystem == "com.joyzhang.myportrait.SleepHelper"' --info
let log = Logger(subsystem: kMachServiceName, category: "helper")

/// 以 root 跑 `pmset -c disablesleep <0/1>`。helper 本身就是 root,不需要 sudo。
/// `-c`(AC profile)跟我们 set 的方式对称。返回 pmset 退出码(0=成功)。
@discardableResult
func runPmset(disable: Bool) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-c", "disablesleep", disable ? "1" : "0"]
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    } catch {
        log.error("pmset run failed: \(error.localizedDescription, privacy: .public)")
        return -1
    }
}

/// `pmset -g` 里的 SleepDisabled 行(1=已钉醒,0=正常),给 ping / 诊断用。
func currentSleepDisabled() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run(); p.waitUntilExit() } catch { return "?" }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n")
        .first { $0.localizedCaseInsensitiveContains("SleepDisabled") }
        .map(String.init) ?? "(no SleepDisabled line)"
}

/// 一次性闸。invalidation 与 interruption 对**同一条**连接可能都触发,这个闸保证
/// clientGone 每条连接只走一次 —— 否则两条连接短暂并存时(app 在 job 边界拆旧建新
/// 的窗口里可达),旧连接的双触发会把 activeConnections 误减到 0,在另一条还持有
/// disablesleep=1 时 exit + 复位 → 合盖跑到一半机器又开始睡。线程安全。
final class ConnectionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate, PortraitSleepHelperProtocol, @unchecked Sendable {
    // XPC delegate / handler 回调来自任意队列 → 用锁保护连接计数。
    private let lock = NSLock()
    private var activeConnections = 0

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // macOS 13+ 一等公民:钉死调用方的代码签名要求。非抛出 —— 校验是惰性的:
        // 不满足要求的对端,其连接会被 XPC 作废(对端 proxy 的 error handler 触发、
        // 我们这边 invalidationHandler 触发),不会真正调到 exported 方法。
        newConnection.setCodeSigningRequirement(kClientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: PortraitSleepHelperProtocol.self)
        newConnection.exportedObject = self
        // 崩溃安全核心:app(client)进程因任何原因消失(正常退、Force Quit、SIGKILL、
        // panic)内核都会拆这条 XPC 连接 → 下面的 handler 触发 → 复位 + 退出。
        // once 保证这条连接只把计数减一次(invalidation/interruption 可能都触发)。
        let once = ConnectionOnce()
        newConnection.invalidationHandler = { [weak self] in if once.fire() { self?.clientGone(reason: "invalidated") } }
        newConnection.interruptionHandler = { [weak self] in if once.fire() { self?.clientGone(reason: "interrupted") } }
        lock.lock(); activeConnections += 1; let n = activeConnections; lock.unlock()
        newConnection.resume()
        log.info("accepted client connection (active=\(n, privacy: .public))")
        return true
    }

    /// client 连接断开。最后一个断 → 复位 disablesleep 并退出,交回 launchd 按需重拉。
    /// invalidation 与 interruption 可能都触发 → 计数 + 幂等复位保证安全。
    private func clientGone(reason: String) {
        lock.lock(); activeConnections -= 1; let n = activeConnections; lock.unlock()
        log.info("client gone (\(reason, privacy: .public)), active=\(n, privacy: .public)")
        guard n <= 0 else { return }
        let st = runPmset(disable: false)
        log.info("last client gone → pmset disablesleep 0 (status=\(st, privacy: .public)); exiting for relaunch-on-demand")
        exit(0)
    }

    // MARK: - PortraitSleepHelperProtocol

    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping (Bool, String) -> Void) {
        let st = runPmset(disable: enabled)
        let diag = "pmset -c disablesleep \(enabled ? 1 : 0) → status=\(st); \(currentSleepDisabled())"
        log.info("setKeepAwake(\(enabled, privacy: .public)): \(diag, privacy: .public)")
        reply(st == 0, diag)
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        let msg = "helper uid=\(getuid()) (0=root); \(currentSleepDisabled())"
        log.info("ping → \(msg, privacy: .public)")
        reply(msg)
    }
}

// ── 进程入口 ──────────────────────────────────────────────────────────────
// "first light" —— 第一行就 log,排查 probe2 那种"helper 到底有没有被拉起"的问题:
//   没这行 = launchd 根本没启动它(签名/配置层);有这行但很快没了 = helper 崩了。
log.info("helper launched (uid=\(getuid(), privacy: .public)) — reset-on-launch")

// 1) 兜底复位(必须在 listener.resume() 之前,避免和新连接的 setKeepAwake(true) 抢)。
runPmset(disable: false)

// 2) 起 XPC listener。machServiceName 由 launchd 经 daemon plist 的 MachServices 广播,
//    app 连它就触发 launchd 按需拉起本进程。LaunchDaemon 用 machServiceName: 初始化,
//    不是 .service() / .anonymous()。
let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kMachServiceName)
listener.delegate = delegate
listener.resume()
log.info("listener resumed on \(kMachServiceName, privacy: .public) — waiting for connections")
RunLoop.main.run()
