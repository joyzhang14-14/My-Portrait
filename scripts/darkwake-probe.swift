// darkwake-probe.swift — 合盖 DarkWake 触发存活探针(P0,动管线代码前必跑)
//
// 目的:验证整套"合盖运行"设计的命门——【in-app 计时器在合盖 DarkWake 里到底
// fire 不 fire】。并行起三种计时器,各每 60s fire 一次,各写一行带【墙钟时间 +
// systemUptime】的日志;systemUptime 不计睡眠时间,所以两者之差能直接看出机器睡了多久。
// 另外在 willSleep 时起忙循环,测"睡前还能执行多久"(=进程被 suspend 前的宽限期,
// 决定云任务"放行让它跑完"安不安全)。
//
// 三种计时器:
//   (a) Foundation Timer(加进 RunLoop .common mode)—— 现状 MemoryScheduler 用的就是这种
//   (b) DispatchSourceTimer
//   (c) NSBackgroundActivityScheduler(系统维护调度,理论上最可能在 DarkWake fire)
//
// === 怎么跑(插电、合盖、放一夜)===
//   1. 编译:  swiftc scripts/darkwake-probe.swift -o /tmp/darkwake-probe
//   2. 后台跑: nohup /tmp/darkwake-probe >/dev/null 2>&1 &
//      记下打印的 PID。**不要**用 caffeinate/lidrun 包它(要测的就是裸跑的自然行为)。
//   3. 插上电源,合上盖子,放一夜。Terminal 窗口可以留着,机器别拔电。
//   4. 次日开盖,看日志: cat ~/.portrait/probe/darkwake.log
//      停掉探针: kill <PID>(或 pkill -f darkwake-probe)
//
// === 怎么读结果 ===
//   关键看凌晨(确定在 Sleep⇄DarkWake)的 TIMER/DISPATCH/BGACTIVITY 行:
//   · 若整夜每 ~60s 都有行(墙钟连续推进)→ 该计时器在 DarkWake 真的 fire,方案2(in-app)成立。
//   · 若中间一大段空白、然后开盖时刻一堆行挤在一起补发 → 它只在完全唤醒(开盖)才 fire,
//     合盖期间零推进 → 本地化合盖目标受限,要考虑 Phase 3 的 LaunchAgent helper。
//   · 哪种计时器在 DarkWake 醒得最勤 = 选它当兜底主力。
//   · WILLSLEEP→最后一条 GRACE 的耗时 = 宽限期;<1s 而云 RPC 要几秒 → 云"放行"不安全,得也 pause。
//   每 fire 行里 wall 与 up 的增量对比:wall 涨很多而 up 几乎没涨 = 这段机器在睡。
//
//   快速分桶(每小时各类计时器 fire 次数):
//     grep -oE '^[0-9-]+T[0-9]{2}' ~/.portrait/probe/darkwake.log | sort | uniq -c

import Foundation
import AppKit

// ---- 日志 ----
let logDir = ("~/.portrait/probe" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
let logPath = (logDir as NSString).appendingPathComponent("darkwake.log")
if !FileManager.default.fileExists(atPath: logPath) {
    FileManager.default.createFile(atPath: logPath, contents: nil)
}
let fh = FileHandle(forWritingAtPath: logPath)
fh?.seekToEndOfFile()

let isoFmt = ISO8601DateFormatter()
isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
isoFmt.timeZone = TimeZone.current

let writeQ = DispatchQueue(label: "probe.log")   // 串行化写,避免交错
func log(_ tag: String, _ msg: String = "") {
    let up = ProcessInfo.processInfo.systemUptime   // 不计睡眠 → 跟墙钟对比可测睡了多久
    let line = "\(isoFmt.string(from: Date())) [\(tag)] up=\(String(format: "%.1f", up)) \(msg)\n"
    let data = Data(line.utf8)
    writeQ.async { fh?.write(data); FileHandle.standardError.write(data) }
}

log("START", "pid=\(ProcessInfo.processInfo.processIdentifier) — 合盖 DarkWake 探针启动")

// ---- (a) Foundation Timer,.common mode(现状调度器用的就是这种)----
let foundationTimer = Timer(timeInterval: 60, repeats: true) { _ in log("TIMER", "Foundation Timer fired") }
RunLoop.main.add(foundationTimer, forMode: .common)

// ---- (b) DispatchSourceTimer ----
let dispatchTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
dispatchTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
dispatchTimer.setEventHandler { log("DISPATCH", "DispatchSourceTimer fired") }
dispatchTimer.resume()

// ---- (c) NSBackgroundActivityScheduler ----
let bgScheduler = NSBackgroundActivityScheduler(identifier: "com.myportrait.darkwakeprobe")
bgScheduler.repeats = true
bgScheduler.interval = 60
bgScheduler.tolerance = 30
bgScheduler.qualityOfService = .background
bgScheduler.schedule { completion in
    log("BGACTIVITY", "NSBackgroundActivityScheduler fired")
    completion(NSBackgroundActivityScheduler.Result.finished)
}

// ---- willSleep/didWake + 宽限期忙循环 ----
var graceActive = false
let nc = NSWorkspace.shared.notificationCenter
nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
    let t0 = Date()
    graceActive = true
    log("WILLSLEEP", "system willSleep —— 开始测宽限期")
    DispatchQueue.global(qos: .userInteractive).async {
        // 忙循环每 100ms 打一行,直到被系统 suspend 或开盖。最多记 30s。
        while graceActive {
            let el = Date().timeIntervalSince(t0)
            if el > 30 { break }
            log("GRACE", String(format: "+%.3fs since willSleep", el))
            usleep(100_000)   // 100ms
        }
    }
}
nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    graceActive = false
    log("DIDWAKE", "system didWake(完全唤醒/开盖)")
}

log("READY", "三种计时器已 armed;插电、合盖、放一夜。次日 cat ~/.portrait/probe/darkwake.log")
RunLoop.main.run()
