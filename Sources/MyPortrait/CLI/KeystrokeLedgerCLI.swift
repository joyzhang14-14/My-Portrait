import Foundation
import Dispatch

/// `--typing-observe-m1` CLI 入口（dev tool）。
///
/// 起 `KeystrokeLedger.start()`，每秒 print 一次最近 5 秒内的击键时间戳；
/// 收到 SIGINT → `ledger.stop()` + `exit(0)`。
///
/// 不跑正常 App 启动（不 init Services / UI / Capture / Memory）—— 进入
/// 本 entry 后直接 `dispatchMain()`，AppKit 路径完全 bypass。
enum KeystrokeLedgerCLI {

    /// 顶住 SIGINT dispatch source 生命周期，否则会被立即释放。
    /// 仅在 run()（启动早期、单线程）写一次 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) private static var sigintSource: DispatchSourceSignal?
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var ledger: KeystrokeLedger?

    static func run() -> Never {
        let l = KeystrokeLedger()
        ledger = l
        do {
            try l.start()
        } catch {
            print("[m1] KeystrokeLedger.start failed: \(error)")
            exit(1)
        }
        if !l.isRunning {
            print("[m1] WARNING: ledger not running (AX 未授权 / tapCreate 失败) — 仍会跑 print loop，输出全 0")
        } else {
            print("[m1] KeystrokeLedger running. Press Ctrl+C to stop.")
        }

        // 每秒 print 一次最近 5s 的击键。
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler {
            let ts = l.recentTimestamps(within: 5.0)
            let nowSec = Double(KeystrokeLedger.nowMs()) / 1000.0
            if ts.isEmpty {
                print(String(format: "[m1 t=%.3f] keystrokes in last 5s: 0 events", nowSec))
                return
            }
            // 计算相邻间隔（ms）。
            var gaps: [Int64] = []
            for i in 1..<ts.count {
                gaps.append(ts[i] - ts[i - 1])
            }
            let gapsStr = gaps.map { String($0) }.joined(separator: ", ")
            print(String(format: "[m1 t=%.3f] keystrokes in last 5s: %d events, gaps_ms=[%@]",
                         nowSec, ts.count, gapsStr))
        }
        t.resume()
        timer = t

        // SIGINT → stop + exit。
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            print("\n[m1] SIGINT received, stopping...")
            ledger?.stop()
            exit(0)
        }
        src.resume()
        signal(SIGINT, SIG_IGN)
        sigintSource = src

        // 主线程进入 dispatch run loop，所有 source / timer 在这里跑。
        dispatchMain()
    }
}
