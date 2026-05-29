import Foundation

/// 一次 stall 判定的输出。`kind` 分类、`reason` 给用户看、`cause` 给 log 留诊断。
struct StallVerdict: Sendable, Identifiable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case visionDbWrite       // 抓得到帧但写库停了
        case visionFrozenCapture // 抓帧本身停了 (TCC 撤权 / 显示器睡眠等)
        case audioBacklog        // pending 队列堆积
        case audioNeverCaptured  // 启动 > 120s 但 produced == 0
        case permissionRevoked   // ScreenRecording 权限被撤
    }

    let id = UUID()
    let kind: Kind
    let reason: String
    let cause: String?
    let detectedAt: Date

    static func == (lhs: StallVerdict, rhs: StallVerdict) -> Bool {
        lhs.kind == rhs.kind && lhs.reason == rhs.reason && lhs.detectedAt == rhs.detectedAt
    }
}

/// 纯函数判定 + 节流。`evaluate(...)` 不打日志、不发通知,只返回 verdict 列表。
/// 副作用(节流、surfacing)由 Driver 拿。
@MainActor
final class StallDetector {
    static let shared = StallDetector()

    /// 借鉴 upstream:capture 频率 ≥ 1/min 时阈值取 60s 足够,小于则会被
    /// 误报。My-Portrait 是事件驱动,空闲期可能数分钟无帧,但只要 pause
    /// 标志亮就不会被判 stall —— 这是设计前提。
    private let stallThresholdMs: Int64 = 60 * 1000
    /// 上游叫 warmup —— 启动 120s 内一切判定先 skip,允许冷启动一段时间。
    private let warmupMs: Int64 = 120 * 1000
    /// pending 队列大于这个数 + 最老 chunk 比 freshness 还老 → 真 backlog。
    /// freshness 取 audio chunk 段长(默认 ~30s)的若干倍,这里固定 20min
    /// 给重型场景留余量。
    private let audioBacklogPendingThreshold = 20
    private let audioBacklogOldestAgeMs: Int64 = 20 * 60 * 1000

    /// 同 kind 的 warn 节流间隔。Driver 30s 一次 evaluate,这里再用 60s
    /// 抑制重复推送给 NotificationCenterService。
    private let warnThrottleSec: TimeInterval = 60

    /// 历史 verdict ring buffer,给 HealthView Recent stalls 显示。
    private(set) var recent: [StallVerdict] = []
    private let recentCap = 50

    /// 最近一次 warn 时间,按 kind 隔离。
    private var lastWarnAt: [StallVerdict.Kind: Date] = [:]
    /// 上次 evaluate 拍下的 vision snapshot,用来算 silent_loss 增量。
    private var prevVision: VisionSnapshot?

    private init() {}

    /// 输入当前所有信号 → 返回 *本轮* 新触发的 verdict(不含被节流的)。
    /// Driver 拿这个返回值决定是否 post 通知 / 写 log。
    /// `now` 显式传入方便测试。
    func evaluate(
        vision: VisionSnapshot,
        audio: AudioMetricsSnapshot,
        pause: IntentionalPauseState,
        permissionGranted: Bool,
        captureEnabled: Bool,
        audioEngineEnabled: Bool,
        pendingAudio: (count: Int, oldestAgeMs: Int64),
        now: Date = Date()
    ) -> [StallVerdict] {
        var fresh: [StallVerdict] = []

        // —— 权限被撤(优先)。即便其他 stall 也触发,这一条 root cause 更值得报。
        if captureEnabled, !permissionGranted {
            if let v = makeVerdict(
                kind: .permissionRevoked,
                reason: "Screen Recording permission was revoked. Grant it again in System Settings.",
                cause: nil, now: now
            ) { fresh.append(v) }
        }

        // —— 故意 pause 一律不报(锁屏 / DRM / 用户关 toggle / 屏幕睡眠)。
        // permission 那条已经早 return 前评估过 —— 它本来就和 pause 互斥意义。
        guard !pause.anyPaused else {
            prevVision = vision
            return fresh
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // —— vision 类 stall。要求 captureEnabled + 过 warmup。
        if captureEnabled,
           vision.startedAtMs > 0,
           nowMs - vision.startedAtMs > warmupMs {
            // 1. visionFrozenCapture:连续 60s+ 无任何抓帧尝试 (capture loop 卡死)。
            //    必须 attempts > 0 才报(否则就是 audio-only 用户根本没在抓)。
            if vision.captureAttempts > 0,
               vision.lastAttemptMs > 0,
               nowMs - vision.lastAttemptMs > stallThresholdMs {
                let cause = "no capture attempt in \(secAgo(vision.lastAttemptMs, now: nowMs))s"
                if let v = makeVerdict(
                    kind: .visionFrozenCapture,
                    reason: "Screen capture appears frozen. Try toggling Screen Capture off and on.",
                    cause: cause, now: now
                ) { fresh.append(v) }
            }
            // 2. visionDbWrite:抓帧在跑但写库停了。
            //    capture_fresh (attempt 在 60s 内) && db_stale (write > 60s 没动且 > 0)。
            //    再要求"上次 evaluate 以来 silent_loss 真的在涨" —— 防止静屏全靠
            //    dedup 跑出来的 ratio 当成 stall(上游同样思路)。
            let captureFresh = vision.lastAttemptMs > 0
                && nowMs - vision.lastAttemptMs < stallThresholdMs
            let dbStale = vision.lastDbWriteMs > 0
                && nowMs - vision.lastDbWriteMs > stallThresholdMs
            if captureFresh, dbStale {
                let silentLossDelta = (vision.silentLoss)
                    - (prevVision?.silentLoss ?? 0)
                if silentLossDelta > 0 {
                    let cause = "silent_loss +\(silentLossDelta) since last check; "
                        + "lifetime attempts=\(vision.captureAttempts), "
                        + "persisted=\(vision.framesPersisted), dedup=\(vision.dedupSkips)"
                    if let v = makeVerdict(
                        kind: .visionDbWrite,
                        reason: "Capturing screen but DB writes have stopped. Check disk space and logs.",
                        cause: cause, now: now
                    ) { fresh.append(v) }
                }
            }
        }

        // —— audio 类 stall。要求 audioEngineEnabled + 过 warmup。
        if audioEngineEnabled,
           audio.startedAtMs > 0,
           nowMs - audio.startedAtMs > warmupMs {
            // 3. audioNeverCaptured:启动 > warmup 但一段都没出。设备权限 / VAD
            //    全否决 / 设备未连之类。
            if audio.chunksProduced == 0 {
                if let v = makeVerdict(
                    kind: .audioNeverCaptured,
                    reason: "Audio capture started but no chunks have been recorded. Check microphone permission and device selection.",
                    cause: "uptime=\(Int(audio.uptimeSec))s, chunksProduced=0", now: now
                ) { fresh.append(v) }
            }
            // 4. audioBacklog:pending > 阈值 + 最老 chunk 比 freshness 还老。
            //    在转的设备本来就累 — 但只要 pendingCount 涨过 20 + 最老超 20min
            //    肯定是 worker 落后,不是节奏问题。
            if pendingAudio.count > audioBacklogPendingThreshold,
               pendingAudio.oldestAgeMs > audioBacklogOldestAgeMs {
                let cause = "pending=\(pendingAudio.count), oldest \(pendingAudio.oldestAgeMs / 1000)s old"
                if let v = makeVerdict(
                    kind: .audioBacklog,
                    reason: "Audio transcription is falling behind (\(pendingAudio.count) pending). Check WhisperKit model load and CPU.",
                    cause: cause, now: now
                ) { fresh.append(v) }
            }
        }

        prevVision = vision
        return fresh
    }

    /// 把 verdict 推进 ring buffer + 节流。返回非 nil 表示这是本轮真要 surface
    /// 的;返回 nil 表示同 kind 60s 内已 warn 过 —— 调用方只静默累计,不再
    /// post 通知。
    private func makeVerdict(
        kind: StallVerdict.Kind,
        reason: String,
        cause: String?,
        now: Date
    ) -> StallVerdict? {
        if let last = lastWarnAt[kind], now.timeIntervalSince(last) < warnThrottleSec {
            return nil
        }
        lastWarnAt[kind] = now
        let v = StallVerdict(kind: kind, reason: reason, cause: cause, detectedAt: now)
        recent.append(v)
        if recent.count > recentCap {
            recent.removeFirst(recent.count - recentCap)
        }
        return v
    }

    private func secAgo(_ ts: Int64, now: Int64) -> Int64 {
        max(0, (now - ts) / 1000)
    }
}
