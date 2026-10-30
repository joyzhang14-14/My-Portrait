import AppKit
import Foundation
import GRDB
import os.log

/// 窗口没显示(后台采集)时,把能还的内存还给系统:SQLite 页缓存和读连接、
/// malloc 里整页空着的内存。窗口显示时什么都不做,前台照旧。
///
/// 调用时机:关窗卸视图树之后,以及每个后台任务(压 MP4 / 补 OCR / 转录 /
/// 事件画像等 job)跑完之后。缓存下次用到时自己长回来。
enum MemoryTrim {

    /// Services 启动时填上。
    nonisolated(unsafe) static var dbPool: DatabasePool?

    static func ifHidden() {
        Task { @MainActor in
            guard !HealthMonitor.shared.windowVisible else { return }
            let pool = dbPool
            Task.detached(priority: .utility) {
                // releaseMemory 会等手上的读写做完再关读连接,放在后台线程。
                pool?.releaseMemory()
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}

/// 关窗后回收界面内存的最后一步。界面框架加载过之后留下的十来 MB 进程内缓存
/// 卸视图树也还不回去,只有进程退出才回收。所以窗口关够一阵、用户停手、后台活
/// 都空闲时,以 `--background` 重启自己,回到纯后台的内存底线。
///
/// 只在用户不动电脑、没人说话、没有任务在跑时重启 —— 重启那一两秒采集停着,
/// 这时屏幕和键盘都没有东西可采。Debug 版不做(会脱离 Xcode 调试器)。
@MainActor
enum BackgroundRelaunch {

    private static let minHidden: TimeInterval = 60
    private static let minUserIdle: TimeInterval = 60
    private static let minSilence: TimeInterval = 60

    private static var timer: Timer?
    private static var hiddenSince: Date?
    private static var checking = false
    /// 界面发起、关窗后还在跑的长任务(导入、下载模型)。非空就不重启。
    private static var holds: [String: Int] = [:]
    private static let log = Logger(subsystem: "com.myportrait", category: "lifecycle")

    static func hold(_ reason: String) { holds[reason, default: 0] += 1 }

    static func release(_ reason: String) {
        guard let n = holds[reason] else { return }
        holds[reason] = n > 1 ? n - 1 : nil
    }

    /// 关窗卸视图树之后调。
    static func arm() {
        #if !DEBUG
        hiddenSince = Date()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
        #endif
    }

    /// 窗口重新打开时调。
    static func disarm() {
        timer?.invalidate()
        timer = nil
        hiddenSince = nil
    }

    private static func check() {
        guard !checking, let since = hiddenSince,
              Date().timeIntervalSince(since) >= minHidden,
              let services = AppDelegate.current?.services,
              blocker() == nil else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            // 转录在 actor 里,异步问一次。
            if await services.transcriber.isBusy { return }
            guard hiddenSince != nil, blocker() == nil else { return }
            relaunch()
        }
    }

    /// 不能重启的原因;nil = 可以。
    private static func blocker() -> String? {
        if HealthMonitor.shared.windowVisible { return "window" }
        // 菜单展开、通知浮窗、弹框都是可见窗口;只有菜单栏图标本身不算。
        if NSApp.windows.contains(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) {
            return "visible window"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        if idle < minUserIdle { return "user active" }
        let sinceSpeech = ProcessInfo.processInfo.systemUptime - VADRecorder.lastSpeechUptime.withLock { $0 }
        if sinceSpeech < minSilence { return "speech" }
        if MemoryScheduler.shared.isBusy { return "memory pipeline" }
        if PiAgentRegistry.shared.hasLiveAgents { return "llm agent" }
        if DeferredOCRStatus.shared.running { return "deferred ocr" }
        if VoiceTrainer.shared.isRunning { return "voice training" }
        if WritingStyleUIState.shared.isRunning { return "writing style" }
        if !holds.isEmpty { return "hold" }
        return nil
    }

    private static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 等这个进程完全退出再拉起新的,避免两份同时采集。
        task.arguments = ["-c",
            "while /bin/kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -g -a \"$1\" --args --background",
            String(pid), Bundle.main.bundlePath]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            log.error("background relaunch: spawn failed: \(error.localizedDescription, privacy: .public)")
            disarm()
            return
        }
        log.notice("background relaunch: restarting into --background to release UI memory")
        DiagLog.event("lifecycle.background_relaunch")
        NSApp.terminate(nil)
    }
}
