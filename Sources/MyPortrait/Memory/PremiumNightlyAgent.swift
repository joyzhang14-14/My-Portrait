import CryptoKit
import Foundation
import ServiceManagement
import os.log

private let agentLog = Logger(subsystem: "com.myportrait.memory", category: "premium-agent")

/// 封区间 helper:用户级 LaunchAgent
/// (`Contents/Library/LaunchAgents/com.joyzhang.myportrait.premium-export.plist`),
/// 每个 :00 / :30 跑 PortraitPremiumHelper,由它拉起同目录的
/// `MyPortrait --premium-export --seal-check`,app 没开也照跑;睡过
/// 检查点时 launchd 在唤醒后补跑一次。封区间对本机跑的 event 链也需要,所以不看有没有
/// 链搬到 Premium;导出那一步才看。跟合盖用的 PortraitSleepHelper(root daemon)是两回事。
///
/// `ConfigApplier` 在启动时调一次 `sync()`。只有 /Applications 里的正式版才注册:
/// BTM 按 bundle 路径绑定,DerivedData 的 debug 构建路径随重建漂移,抢到绑定会让正式版
/// 的注册失效(debug 构建靠 app tick 跑同一个检查)。
///
/// 自签名(无 Team ID)下 BTM 把启动约束(LWCR)锁在登记时 helper 的 cdhash 上,所以 bundle
/// 里 agent plist 或 helper 二进制一变(两者的 sha256 记在 UserDefaults)就要刷新登记。
/// unregister 不删 BTM 记录(只标 disabled),register 按 label 找回这条旧记录、沿用旧约束,
/// 所以光注销再登记不够,要按试跑结果走完系统自己的修复链(见 `refresh`):
///   第一次拉起被 AMFI 以 Launch Constraint Violation 杀掉(SIGKILL)→ 下一次拉起时 launchd
///   请 smd 修约束,BTM 按当前 helper 换一条新记录,但 job 还挂着旧记录,以退出码 78 失败 →
///   重新提交(unregister → register)后 job 指向新记录,helper 正常起来。
/// 用户在「登录项与扩展」里关掉了(status 为 `.requiresApproval`)就不注销、不登记、不记指纹。
@MainActor
enum PremiumNightlyAgent {

    nonisolated static let label = "com.joyzhang.myportrait.premium-export"

    private static var service: SMAppService { SMAppService.agent(plistName: "\(label).plist") }

    private static var mayRegister: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    private static let fingerprintKey = "premiumAgentRegisteredFingerprint"

    /// bundle 里 agent plist + helper 二进制的 sha256;读不到返回 nil。
    private static var currentFingerprint: String? {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        guard let plist = try? Data(contentsOf: contents.appendingPathComponent("Library/LaunchAgents/\(label).plist")),
              let helper = try? Data(contentsOf: contents.appendingPathComponent("MacOS/PortraitPremiumHelper"))
        else { return nil }
        var h = SHA256()
        h.update(data: plist)
        h.update(data: helper)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 卡片状态:`enabled` / `requires approval` / `not registered`。
    static var statusText: String {
        switch service.status {
        case .enabled:          return "enabled"
        case .requiresApproval: return "requires approval"
        default:                return "not registered"
        }
    }

    static var requiresApproval: Bool { service.status == .requiresApproval }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// plist / helper 变了、没登记、或上一次运行死在启动约束 / 78 上时刷新登记;失败只记日志,
    /// 不记指纹,下次启动再试。
    static func sync() {
        guard mayRegister else {
            agentLog.info("seal-check agent sync skipped — only the /Applications copy registers")
            return
        }
        let fp = currentFingerprint
        if fp == nil { agentLog.error("seal-check agent plist or helper missing in bundle") }
        Task {
            let changed = fp != nil && fp != UserDefaults.standard.string(forKey: fingerprintKey)
            if service.status == .enabled, !changed {
                guard let job = await jobState(), job.lastRunFailed else {
                    agentLog.info("seal-check agent status: \(statusText, privacy: .public)")
                    return
                }
                agentLog.info("seal-check agent last run failed (\(job.summary, privacy: .public)), refreshing")
            }
            let result = await refresh(liveOps)
            switch result {
            case .done:
                if let fp { UserDefaults.standard.set(fp, forKey: fingerprintKey) }
                agentLog.info("seal-check agent registered and helper launched")
            case .userDisabled:
                agentLog.info("seal-check agent turned off in Login Items — left as is")
            case .failed(let why):
                agentLog.error("seal-check agent refresh failed: \(why, privacy: .public)")
            }
            agentLog.info("seal-check agent status: \(statusText, privacy: .public)")
        }
    }

    // MARK: - 刷新登记

    /// 一次试跑(kickstart)的结果。
    enum ProbeOutcome: Equatable {
        case ran            // helper 活过了 exec(还在跑,或已正常退出)
        case killed         // SIGKILL:启动约束不符,exec 时被 AMFI 杀掉
        case configFailure  // 退出码 78:job 挂着已被 BTM 换掉的旧记录
        case noRun          // 等不到新一次运行
    }

    enum RefreshResult: Equatable {
        case done
        case userDisabled
        case failed(String)
    }

    /// `refresh` 用到的系统操作;selftest 注入假的状态序列。
    struct Ops {
        var status: () -> SMAppService.Status
        var unregister: () async -> Void
        var register: () throws -> Void
        var probe: () async -> ProbeOutcome
    }

    /// 登记并试跑,按结果走完修复链直到 helper 真能起来(最多 `maxProbes` 次试跑)。
    /// `.requiresApproval` 时什么都不做:按 SMAppService 文档,这是用户在系统设置里收回了
    /// 许可,要用户自己处理;注销再登记会动到用户的选择。
    static func refresh(_ ops: Ops, maxProbes: Int = 5) async -> RefreshResult {
        let status = ops.status()
        if status == .requiresApproval { return .userDisabled }
        if status == .enabled { await ops.unregister() }
        if let stop = register(ops) { return stop }
        for _ in 0..<maxProbes {
            switch await ops.probe() {
            case .ran:
                return .done
            case .killed:
                continue   // 下一次拉起时 launchd 请求修约束,BTM 换新记录
            case .configFailure:
                await ops.unregister()   // job 还挂着旧记录:重新提交才指向新记录
                if let stop = register(ops) { return stop }
            case .noRun:
                return .failed("no new run after kickstart")
            }
        }
        return .failed("helper still failing after \(maxProbes) probes")
    }

    /// 登记;成功返回 nil。用户拒绝(`kSMErrorLaunchDeniedByUser`,或登记后要用户批准)
    /// 返回 `.userDisabled`,其它错误返回 `.failed`。
    private static func register(_ ops: Ops) -> RefreshResult? {
        do {
            try ops.register()
        } catch {
            let code = (error as NSError).code
            return code == Int(kSMErrorLaunchDeniedByUser) ? .userDisabled : .failed("register threw code=\(code)")
        }
        return ops.status() == .requiresApproval ? .userDisabled : nil
    }

    private static var liveOps: Ops {
        Ops(status: { service.status },
            unregister: {
                do { try await service.unregister() } catch {
                    agentLog.info("seal-check agent unregister threw code=\((error as NSError).code, privacy: .public)")
                }
            },
            register: { try service.register() },
            probe: { await probe() })
    }

    // MARK: - launchd 侧观测

    /// `launchctl print gui/<uid>/<label>` 里本 job 的几项(只看一个 tab 缩进的顶层行)。
    /// state 除 `running` / `not running` 外还有 `spawn scheduled`、`xpcproxy` 等拉起中的
    /// 中间态;中间态下 runs 可能已加一,last exit code / last terminating signal 却还是上一次的。
    struct JobState: Equatable {
        var state = ""
        var runs = 0
        var lastExit: Int?
        var killed = false
        var btmUUID = ""

        /// 已 exec(过了启动约束检查),正在跑。
        var running: Bool { state == "running" }
        /// 不在跑也不在拉起:last exit code / signal 就是最近一次运行的结果。
        var idle: Bool { state == "not running" }
        /// 只在 idle 时判:在跑说明这次已过了启动约束,拉起中读到的是上一次的结果;
        /// 这两种情况下刷新登记还会把正在进行的封区间检查注销掉。
        var lastRunFailed: Bool { idle && (killed || lastExit == 78) }
        var summary: String {
            "state=\(state) runs=\(runs) exit=\(lastExit.map(String.init) ?? "-") killed=\(killed) btm=\(btmUUID)"
        }

        init(print text: String) {
            for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
                let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "runs":                    runs = Int(kv[1]) ?? 0
                case "state":                   state = kv[1]
                case "last exit code":          lastExit = Int(kv[1].prefix { $0.isNumber })
                case "last terminating signal": killed = killed || kv[1].hasSuffix(": 9")
                // 新提交的 job 第一次被 AMFI 杀时只有这一行,没有 signal / exit code。
                case "last exit reason":        killed = killed || kv[1].contains("CODESIGNING")
                case "BTM uuid":                btmUUID = kv[1]
                default: break
                }
            }
        }
    }

    nonisolated private static func launchctl(_ args: [String]) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    nonisolated static func jobState() async -> JobState? {
        guard let r = launchctl(["print", "gui/\(getuid())/\(label)"]), r.status == 0 else { return nil }
        return JobState(print: r.out)
    }

    /// kickstart 一次,盯 `launchctl print` 看这一次(runs 加一)的结果,最多等 20s
    /// (job 的 minimum runtime 是 10s,刚被杀后的下一次拉起可能被 launchd 推迟到 10s 后)。
    /// 启动约束的 SIGKILL 发生在 exec 当下,活过 0.5s 就算起来了;这次试跑就是一次正常的
    /// 封区间检查。只在 `running` 或 `not running` 时下结论:拉起中的中间态读到的退出状态
    /// 是上一次的,这时下结论会让下一次 kickstart 落在还没结束的这次拉起上被吞掉。
    nonisolated static func probe() async -> ProbeOutcome {
        guard let before = await jobState() else { return .noRun }
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        kick.standardOutput = FileHandle.nullDevice
        kick.standardError = FileHandle.nullDevice
        do { try kick.run() } catch { return .noRun }
        defer { if kick.isRunning { kick.terminate() } }
        var runningSince: Date?
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let s = await jobState(), s.runs > before.runs else { continue }
            agentLog.info("seal-check agent probe: \(s.summary, privacy: .public)")
            if s.running {
                if let t = runningSince, Date().timeIntervalSince(t) >= 0.5 { return .ran }
                if runningSince == nil { runningSince = Date() }
                continue
            }
            guard s.idle else { continue }
            if s.killed { return .killed }
            if s.lastExit == 78 { return .configFailure }
            return .ran
        }
        return .noRun
    }
}
