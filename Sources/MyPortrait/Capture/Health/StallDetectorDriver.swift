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

    /// 当前 active stall fault 的 kind 集合 → 用来配 HealthMonitor 自动 clear。
    /// 加进来的时机:report() 那一刻;清掉的时机:该 kind 在 `recoveryWindowSec`
    /// 秒内没有任何新 verdict 出现。
    private var activeFaults: Set<StallVerdict.Kind> = []

    /// 恢复窗口:某 kind 连续这么久没新 verdict → 视为已恢复,清状态栏黄标。
    /// 5 min 跟 HealthView "5 minutes" 状态判定对齐。
    private let recoveryWindowSec: TimeInterval = 5 * 60

    init(db: PortraitDB, permissions: PermissionMonitor) {
        self.db = db
        self.permissions = permissions
    }

    func start() {
        guard task == nil else { return }
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

        // 3) 判定。
        let fresh = StallDetector.shared.evaluate(
            vision: visionSnap,
            audio: audioSnap,
            pause: pause,
            permissionGranted: permissionGranted,
            captureEnabled: captureEnabled,
            audioEngineEnabled: audioEngineEnabled,
            pendingAudio: pendingAudio
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
