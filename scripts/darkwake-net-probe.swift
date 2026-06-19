// darkwake-net-probe.swift — 合盖 DarkWake 里"云调用通不通 / 能跑多久"探针。
//
// 背景:当前生产管线全是云 LLM(网络 RPC)。合盖+插电时机器走 Sleep⇄DarkWake,
// DarkWake 窗口 ~45s。云调用不可续接 —— 一次调用若在窗口结束被 suspend、连接断,
// 这次就失败。本探针实测:① 合盖夜间(确定在 DarkWake)网络调用成功率;② 跨越
// 睡眠边界的调用(slept>0)是断还是活;③ 较长的传输(几秒)能不能跑完。
//
// 每次调用都记 systemUptime(不计睡眠)—— 若一次调用的墙钟耗时 ≫ uptime 增量,
// 说明这次调用【中途机器睡过】,再看它 OK 还是 FAIL 就知道连接扛不扛得住合盖睡眠。
//
// 触发用 NSBackgroundActivityScheduler(P0 探针实测最抗 DarkWake)+ Foundation
// Timer 兜底,最大化"调用真的在 DarkWake 窗口里发起"的机会。
//
// === 怎么跑(插电、联网、合盖、放一夜)===
//   1. swiftc scripts/darkwake-net-probe.swift -o /tmp/darkwake-net-probe
//   2. nohup /tmp/darkwake-net-probe >/dev/null 2>&1 &     (记下 PID;别用 caffeinate 包)
//   3. 确认插电 + WiFi,合上盖子放一夜。
//   4. 次日: cat ~/.portrait/probe/darkwake-net.log ;停: pkill -f darkwake-net-probe
//
// === 怎么读 ===
//   · 凌晨(合盖 DarkWake)时段有没有 SHORT-OK / LONG-OK 行 → 合盖时网络调用能不能成。
//   · slept>0 的那些调用:OK = 连接扛过了睡眠;FAIL = 一睡连接就断(长调用合盖跑不完的证据)。
//   · LONG-OK 的 wall 多大 → 合盖时一次能撑多久的调用。
//   · 每小时成功/失败计数:
//       grep -oE '^[0-9-]+T[0-9]{2}.*\[(SHORT|LONG)-(OK|FAIL)\]' ~/.portrait/probe/darkwake-net.log \
//         | sed -E 's/.*T([0-9]{2}).*\[(.*)\]/\1 \2/' | sort | uniq -c

import Foundation
import AppKit

// ---- 日志 ----
let logDir = ("~/.portrait/probe" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
let logPath = (logDir as NSString).appendingPathComponent("darkwake-net.log")
if !FileManager.default.fileExists(atPath: logPath) {
    FileManager.default.createFile(atPath: logPath, contents: nil)
}
let fh = FileHandle(forWritingAtPath: logPath)
fh?.seekToEndOfFile()

let isoFmt = ISO8601DateFormatter()
isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
isoFmt.timeZone = TimeZone.current

let writeQ = DispatchQueue(label: "netprobe.log")
func log(_ tag: String, _ msg: String = "") {
    let up = ProcessInfo.processInfo.systemUptime
    let line = "\(isoFmt.string(from: Date())) [\(tag)] up=\(String(format: "%.1f", up)) \(msg)\n"
    let data = Data(line.utf8)
    writeQ.async { fh?.write(data); FileHandle.standardError.write(data) }
}

// ---- URLSession:不等连通性(测真实可用性)、显式超时、不走缓存 ----
let cfg = URLSessionConfiguration.ephemeral
cfg.waitsForConnectivity = false
cfg.timeoutIntervalForRequest = 90
cfg.timeoutIntervalForResource = 120
cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
let session = URLSession(configuration: cfg)

// 短:Apple 自家连通性检查端点(就是给频繁打的,响应极小)。
let shortURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
// 长:Cloudflare 测速下载端点 ~30MB(几秒级传输,更容易跨睡眠边界)。
let longURL  = URL(string: "https://speed.cloudflare.com/__down?bytes=30000000")!

func doCall(_ kind: String, _ url: URL) {
    let startWall = Date()
    let startUp = ProcessInfo.processInfo.systemUptime
    let task = session.dataTask(with: url) { data, resp, err in
        let wall = Date().timeIntervalSince(startWall)
        let slept = max(0, wall - (ProcessInfo.processInfo.systemUptime - startUp))   // 调用期间机器睡了多久
        if let err = err {
            log("\(kind)-FAIL", String(format: "wall=%.1fs slept=%.1fs err=%@",
                                       wall, slept, err.localizedDescription))
        } else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            log("\(kind)-OK", String(format: "wall=%.1fs slept=%.1fs http=%d bytes=%d",
                                     wall, slept, code, data?.count ?? 0))
        }
    }
    task.resume()
}

var fireCount = 0
func fire(_ src: String) {
    fireCount += 1
    doCall("SHORT", shortURL)
    if fireCount % 5 == 0 { doCall("LONG", longURL) }   // 长调用约每 5 分钟一次
}

log("START", "pid=\(ProcessInfo.processInfo.processIdentifier) — 合盖网络探针启动")

// 主触发:NSBackgroundActivityScheduler(最抗 DarkWake)
let bas = NSBackgroundActivityScheduler(identifier: "com.myportrait.netprobe")
bas.repeats = true
bas.interval = 60
bas.tolerance = 30
bas.qualityOfService = .utility
bas.schedule { completion in
    fire("bg")
    completion(NSBackgroundActivityScheduler.Result.finished)
}

// 兜底触发:Foundation Timer(.common)
let timer = Timer(timeInterval: 60, repeats: true) { _ in fire("timer") }
RunLoop.main.add(timer, forMode: .common)

// 立刻各打一次
doCall("SHORT", shortURL)
doCall("LONG", longURL)

// willSleep / didWake(只在完全睡/醒转换 fire,DarkWake 不 fire,做时间标记)
let nc = NSWorkspace.shared.notificationCenter
nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in log("WILLSLEEP") }
nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in log("DIDWAKE") }

log("READY", "插电 + 联网 + 合盖,放一夜。次日 cat ~/.portrait/probe/darkwake-net.log")
RunLoop.main.run()
