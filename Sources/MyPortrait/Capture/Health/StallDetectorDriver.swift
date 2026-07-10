import AppKit
import Darwin
import Foundation
import os.log

/// 30s 周期跑一次 `StallDetector.evaluate`,新 verdict → 写 health.log +
/// (如果用户开了通知开关) post 到 NotificationCenterService。
///
/// 借鉴 upstream `health.rs` 的 1s 缓存 + 60s log throttle 思路,但 My-Portrait
/// 没有 HTTP 客户端常轮的需求,只用一个后台 task 拉数据。
@MainActor
final class StallDetectorDriver {

    private let db: PortraitDB
    private let permissions: PermissionMonitor
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "stall-detector")

    /// 30s ≥ Driver tick 间隔。短于此 evaluate 会跑很多次但 verdict 节流挡住,
    /// 只是浪费 CPU。30s 给 audio backlog freshness 留时间;短于 10s 会刷
    /// healthLog 太频繁。
    private let tickIntervalSec: TimeInterval = 30

    private var task: Task<Void, Never>?
    private var lastResourceSample: (at: Date, cpuSeconds: Double)?

    /// 当前 active stall fault 的 kind 集合 → 用来配 HealthMonitor 自动 clear。
    /// 加进来的时机:report() 那一刻;清掉的时机:该 kind 在 `recoveryWindowSec`
    /// 秒内没有任何新 verdict 出现。
    private var activeFaults: Set<StallVerdict.Kind> = []

    /// 恢复窗口:某 kind 连续这么久没新 verdict → 视为已恢复,清状态栏黄标。
    /// 60s 跟 StallDetector.warnThrottleSec 对齐 —— 条件持续存在时每 60s
    /// 会有一条新 verdict 进 recent,recoveryWindow 永远刷不到尾;条件真消失
    /// 后 ~1-1.5 个 driver tick(30s 一次)就能 clear,体感"亮一会儿就灭"。
    private let recoveryWindowSec: TimeInterval = 60

    init(db: PortraitDB, permissions: PermissionMonitor) {
        self.db = db
        self.permissions = permissions
    }

    func start() {
        guard task == nil else { return }
        MainThreadHangWatchdog.shared.start()
        let intervalNs = UInt64(tickIntervalSec * 1_000_000_000)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
        logger.info("StallDetectorDriver started (tick=\(self.tickIntervalSec)s)")
    }

    func stop() {
        task?.cancel()
        task = nil
        MainThreadHangWatchdog.shared.stop()
        logger.info("StallDetectorDriver stopped")
    }

    private func tick() async {
        // 1) 抓所有信号源的 snapshot。
        let visionSnap = await VisionMetrics.shared.snapshot()
        let audioSnap = await AudioMetrics.shared.snapshot()
        let pause = IntentionalPauseState.shared

        let cfg = ConfigStore.shared.current
        let captureEnabled = cfg.capture.screen.enabled
        let audioEngineEnabled = cfg.capture.audio.enabled
            && cfg.capture.audio.engine != "disabled"
        let permissionGranted = permissions.screenRecording == .granted

        // 2) 音频 backlog 查 DB。失败 → 当作没活,放过这轮 audio 类判定。
        let pendingAudio: (count: Int, oldestAgeMs: Int64)
        do {
            let stats = try await db.audioBacklogStats()
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let oldestAge = stats.oldestRecordedAtMs.map { nowMs - $0 } ?? 0
            pendingAudio = (stats.pendingCount, oldestAge)
        } catch {
            logger.warning("audioBacklogStats failed: \(String(describing: error), privacy: .public)")
            pendingAudio = (0, 0)
        }

        // App 是否被遮挡(后台不可见)。遮挡 = macOS App Nap 领地,30s idle
        // 心跳的 Task.sleep 会被拖长 → vision frozen 误判,故传给 evaluate 跳过。
        // .visible 不在 occlusionState 里 = 完全被挡 / 最小化 / 退后台。
        let appOccluded = !NSApp.occlusionState.contains(.visible)

        // 诊断包需要趋势而不只是导出瞬间的一张快照。每 30s 留一条纯数字
        // 资源样本，能看出 CPU 锁死 / 内存线性上涨发生在什么时间段。
        let resources = ProcessResourceSnapshot.capture()
        var resourceContext: [String: Any] = [
            "physical_footprint_bytes": resources.physicalFootprintBytes,
            "resident_bytes": resources.residentBytes,
            "virtual_bytes": resources.virtualBytes,
            "pending_audio": pendingAudio.count,
            "capture_attempts": visionSnap.captureAttempts,
            "frames_persisted": visionSnap.framesPersisted,
            "app_visible": !appOccluded,
        ]
        if let previous = lastResourceSample {
            let wall = max(0.001, Date().timeIntervalSince(previous.at))
            let cpu = max(0, resources.cpuSeconds - previous.cpuSeconds)
            resourceContext["cpu_percent"] = min(10_000, cpu / wall * 100)
        }
        lastResourceSample = (Date(), resources.cpuSeconds)
        DiagLog.event("resource.sample", ctx: resourceContext)

        // 3) 判定。
        let fresh = StallDetector.shared.evaluate(
            vision: visionSnap,
            audio: audioSnap,
            pause: pause,
            permissionGranted: permissionGranted,
            captureEnabled: captureEnabled,
            audioEngineEnabled: audioEngineEnabled,
            pendingAudio: pendingAudio,
            appOccluded: appOccluded
        )

        // 4) 写 log + (开关亮时) 发通知。HealthMonitor.report 同时拨红状态栏。
        if !fresh.isEmpty {
            let notify = ConfigStore.shared.notifications.captureStalls
            for v in fresh {
                logger.warning(
                    "stall: \(v.kind.rawValue, privacy: .public) — \(v.reason, privacy: .public)\(v.cause.map { " (\($0))" } ?? "", privacy: .public)"
                )
                HealthMonitor.shared.report(
                    component: "stall.\(v.kind.rawValue)",
                    reason: v.cause ?? v.reason
                )
                activeFaults.insert(v.kind)
                if notify {
                    NotificationCenterService.shared.post(.captureStall(reason: v.reason))
                }
            }
        }

        // 5) 自动恢复:某 kind 已经 recoveryWindowSec 没新 verdict → 视为
        // 解除,清 HealthMonitor 让状态栏黄标变回。原本只 report 不 clear,
        // 一次警告之后图标永久卡在黄色。
        let now = Date()
        let recent = StallDetector.shared.recent
        for kind in activeFaults {
            let latest = recent.last { $0.kind == kind }?.detectedAt
            let stale: Bool = {
                guard let latest else { return true }
                return now.timeIntervalSince(latest) > recoveryWindowSec
            }()
            if stale {
                HealthMonitor.shared.clear(component: "stall.\(kind.rawValue)")
                activeFaults.remove(kind)
                logger.info("stall \(kind.rawValue, privacy: .public): recovered after \(Int(self.recoveryWindowSec))s without recurrence")
            }
        }
    }
}

private struct ProcessResourceSnapshot {
    let physicalFootprintBytes: UInt64
    let residentBytes: UInt64
    let virtualBytes: UInt64
    let cpuSeconds: Double

    static func capture() -> ProcessResourceSnapshot {
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }

        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }

        var usage = rusage()
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        let cpuSeconds: Double
        if usageResult == 0 {
            cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        } else {
            cpuSeconds = 0
        }

        return ProcessResourceSnapshot(
            physicalFootprintBytes: vmResult == KERN_SUCCESS ? vm.phys_footprint : 0,
            residentBytes: basicResult == KERN_SUCCESS ? basic.resident_size : 0,
            virtualBytes: basicResult == KERN_SUCCESS ? basic.virtual_size : 0,
            cpuSeconds: cpuSeconds
        )
    }
}

/// 后台队列每 2 秒 ping 一次主线程。主线程连续 8 秒不响应时，自动用系统
/// `sample` 抓一份调用栈。这样用户强退 / 重启后，诊断包仍能解释“刚才卡在哪”，
/// 不需要用户在卡死时自己打开 Instruments。
private final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    private let queue = DispatchQueue(label: "com.myportrait.hang-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingSentAt: DispatchTime?
    private var sampledCurrentHang = false
    private let hangThresholdNs: UInt64 = 8_000_000_000
    private let keepSamples = 3

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.pingSentAt = nil
            self?.sampledCurrentHang = false
        }
    }

    private func tick() {
        if let sent = pingSentAt {
            let stalledNs = DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds
            if stalledNs >= hangThresholdNs, !sampledCurrentHang {
                sampledCurrentHang = true
                captureSample(stalledMs: stalledNs / 1_000_000)
            }
            return
        }

        let sent = DispatchTime.now()
        pingSentAt = sent
        DispatchQueue.main.async { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.pingSentAt == sent else { return }
                let delayMs = (DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds)
                    / 1_000_000
                if delayMs >= 2_000 {
                    DiagLog.warn("main_thread.delayed", ctx: ["delay_ms": delayMs])
                }
                self.pingSentAt = nil
                self.sampledCurrentHang = false
            }
        }
    }

    private func captureSample(stalledMs: UInt64) {
        let fm = FileManager.default
        let base = Storage.dailyLogsDir.appendingPathComponent("hang-sample.txt")
        try? fm.createDirectory(at: base.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let oldest = base.appendingPathExtension("\(keepSamples)")
        try? fm.removeItem(at: oldest)
        if keepSamples > 1 {
            for i in stride(from: keepSamples - 1, through: 1, by: -1) {
                let from = base.appendingPathExtension("\(i)")
                let to = base.appendingPathExtension("\(i + 1)")
                if fm.fileExists(atPath: from.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }
        if fm.fileExists(atPath: base.path) {
            try? fm.moveItem(at: base, to: base.appendingPathExtension("1"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "3", "-file", base.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            DiagLog.warn("main_thread.hang_sampled", ctx: [
                "stalled_ms": stalledMs,
                "sample_exit": process.terminationStatus,
            ])
        } catch {
            DiagLog.error("main_thread.sample_failed", ctx: [
                "stalled_ms": stalledMs,
                "error_type": String(describing: type(of: error)),
            ])
        }
    }
}
