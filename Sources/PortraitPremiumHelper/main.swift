import Foundation

// PortraitPremiumHelper —— 封区间 LaunchAgent(com.joyzhang.myportrait.premium-export)的可执行体。
//
// 只做一件事:拉起同目录的主程序 `MyPortrait --premium-export --seal-check`,等它结束,
// 原样返回它的退出码(被信号杀掉时返回 128 + 信号号)。收到 SIGTERM / SIGINT / SIGHUP
// 时转发给主程序,等它退出后照同样规则返回;主程序还没拉起就收到的,不再拉起,直接返回 128 + 信号号。
//
// 主程序用 posix_spawn + responsibility_spawnattrs_setdisclaim(libquarantine 的 SPI,
// 运行时 dlsym 取)拉起:主程序自己当 TCC 责任进程,沿用 app 的授权,而不是算在本 helper
// 头上。取不到这个 SPI 或这条路 spawn 失败时退回 Process(责任进程是本 helper),stderr 记一行。
//
// 单独成程序是为了 cdhash 稳定:自签名(无 Team ID)下 BTM 把 agent 的启动约束锁在
// 登记时的可执行文件 cdhash 上。scripts/release/build.sh 按本 target 源码哈希复用已签名
// 二进制,本文件不变 cdhash 就不变;改动本文件后由 PremiumNightlyAgent.sync() 重新登记。
// 所以这里越小、越少改越好,不依赖任何 app 代码。

func warn(_ msg: String) {
    FileHandle.standardError.write(Data("PortraitPremiumHelper: \(msg)\n".utf8))
}

var size: UInt32 = 0
_ = _NSGetExecutablePath(nil, &size)
var buf = [CChar](repeating: 0, count: Int(size))
guard _NSGetExecutablePath(&buf, &size) == 0 else {
    warn("cannot resolve own path")
    exit(1)
}
let selfPath = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
let app = URL(fileURLWithPath: selfPath).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("MyPortrait")

guard FileManager.default.isExecutableFile(atPath: app.path) else {
    warn("\(app.path) not found")
    exit(1)
}

let args = ["--premium-export", "--seal-check"]
let forwarded: [Int32] = [SIGTERM, SIGINT, SIGHUP]

/// 子进程 pid 与拉起前收到的信号;只在 `signalQueue` 上读写。
final class ChildState: @unchecked Sendable {
    var pid: pid_t = 0
    var pending: Int32 = 0
}
let child = ChildState()
let signalQueue = DispatchQueue(label: "PortraitPremiumHelper.signals")

// 先改成忽略、交给 dispatch source 接;子进程在 spawn 时恢复默认处理。
// handler 显式 @Sendable:顶层代码里的闭包默认隔离在 main actor,在 signalQueue 上跑会被
// Swift 6 的隔离检查当场 trap。
let signalSources = forwarded.map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler { @Sendable [child] in
        if child.pid > 0 { kill(child.pid, sig) } else { child.pending = sig }
    }
    source.resume()
    return source
}

typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

/// posix_spawn + disclaim;任何一步不成返回 nil 并在 stderr 说明。
func spawnDisclaimed(_ path: String, _ args: [String], resetting signals: [Int32]) -> pid_t? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
        warn("responsibility_spawnattrs_setdisclaim unavailable, falling back to Process")
        return nil
    }
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for s in signals { sigaddset(&defaults, s) }
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setsigmask(&attr, &mask)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    let rc = setDisclaim(&attr, 1)
    guard rc == 0 else {
        warn("responsibility_spawnattrs_setdisclaim returned \(rc), falling back to Process")
        return nil
    }
    let argv = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let err = posix_spawn(&pid, path, nil, &attr, argv, environ)
    guard err == 0 else {
        warn("posix_spawn failed: \(String(cString: strerror(err))), falling back to Process")
        return nil
    }
    return pid
}

// 拉起和记下 pid 放在同一个 signalQueue.sync 里,信号处理不会插在两者之间。
let task: Process? = signalQueue.sync {
    if child.pending != 0 { exit(128 + child.pending) }
    if let pid = spawnDisclaimed(app.path, args, resetting: forwarded) {
        child.pid = pid
        return nil
    }
    let t = Process()
    t.executableURL = app
    t.arguments = args
    do {
        try t.run()
    } catch {
        warn("launch failed: \(error)")
        exit(1)
    }
    child.pid = t.processIdentifier
    return t
}

if let task {
    task.waitUntilExit()
    exit(task.terminationReason == .uncaughtSignal ? 128 + task.terminationStatus : task.terminationStatus)
}
var status: Int32 = 0
while waitpid(child.pid, &status, 0) == -1 {
    guard errno == EINTR else {
        warn("waitpid failed: \(String(cString: strerror(errno)))")
        exit(1)
    }
}
let termSignal = status & 0x7f
exit(termSignal == 0 ? (status >> 8) & 0xff : 128 + termSignal)
