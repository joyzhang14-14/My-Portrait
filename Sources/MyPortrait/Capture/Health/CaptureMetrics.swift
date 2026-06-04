import Foundation

/// Vision 采集流水线的累计指标。actor 隔离写入,snapshot() 拍快照给 StallDetector。
///
/// 借鉴 upstream `crates/screenpipe-engine/src/routes/health.rs` 的 vision_snap 结构。
/// 三类计数器组合可以区分:
///   - 活跃健康(attempts↑ persisted↑ dedup≈0)
///   - 静屏误报(attempts↑ persisted 平 dedup↑)
///   - 真沉默丢失(attempts↑ persisted 平 dedup 平 → 抓得到帧但没写库)
///   - 抓帧暂停(attempts 平 → TCC 撤权 / 显示器睡眠)
actor VisionMetrics {
    static let shared = VisionMetrics()

    private(set) var captureAttempts: UInt64 = 0
    private(set) var framesPersisted: UInt64 = 0
    private(set) var dedupSkips: UInt64 = 0
    /// 故意跳过(无痕窗在屏)的帧:recordAttempt 过但整帧不写库。从 silent_loss
    /// 扣除,否则 StallDetector 把它当"抓得到帧但写库停了"误报 Capture stalled。
    private(set) var intentionalSkips: UInt64 = 0
    private(set) var lastAttemptMs: Int64 = 0
    private(set) var lastDbWriteMs: Int64 = 0
    /// 0 = 未启动。`markStarted()` 幂等,只在第一次写入。
    private(set) var startedAtMs: Int64 = 0

    func markStarted() {
        if startedAtMs == 0 { startedAtMs = Self.nowMs() }
    }

    func recordAttempt() {
        captureAttempts &+= 1
        lastAttemptMs = Self.nowMs()
    }

    func recordPersisted() {
        framesPersisted &+= 1
        lastDbWriteMs = Self.nowMs()
    }

    func recordDedup() {
        dedupSkips &+= 1
    }

    /// 无痕窗在屏 → 整帧故意跳过(不写库)。不算 silent_loss,防 StallDetector 误报。
    func recordIntentionalSkip() {
        intentionalSkips &+= 1
    }

    func snapshot() -> VisionSnapshot {
        VisionSnapshot(
            captureAttempts: captureAttempts,
            framesPersisted: framesPersisted,
            dedupSkips: dedupSkips,
            intentionalSkips: intentionalSkips,
            lastAttemptMs: lastAttemptMs,
            lastDbWriteMs: lastDbWriteMs,
            startedAtMs: startedAtMs
        )
    }

    fileprivate static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

struct VisionSnapshot: Sendable {
    let captureAttempts: UInt64
    let framesPersisted: UInt64
    let dedupSkips: UInt64
    let intentionalSkips: UInt64
    let lastAttemptMs: Int64
    let lastDbWriteMs: Int64
    let startedAtMs: Int64

    /// uptime(秒)。未启动返回 0。
    var uptimeSec: Double {
        guard startedAtMs > 0 else { return 0 }
        return Double(Self.nowMs() - startedAtMs) / 1000.0
    }

    /// silent_loss = attempts - persisted - dedup - intentionalSkips。
    /// > 0 = 抓到了但没写库、没去重、也不是故意跳过(无痕)= 真沉默丢失。
    var silentLoss: Int64 {
        Int64(captureAttempts) - Int64(framesPersisted)
            - Int64(dedupSkips) - Int64(intentionalSkips)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// 音频流水线累计指标。pending 队列长度不在这里维护(查 DB 拿实时值,避免双写),
/// 这里只记 produced(VAD 通过 + 入库)和 transcribed(WhisperKit 转完写库)。
actor AudioMetrics {
    static let shared = AudioMetrics()

    private(set) var chunksProduced: UInt64 = 0
    private(set) var chunksTranscribed: UInt64 = 0
    private(set) var startedAtMs: Int64 = 0

    func markStarted() {
        if startedAtMs == 0 { startedAtMs = VisionMetrics.nowMs() }
    }
    func recordChunkProduced()    { chunksProduced &+= 1 }
    func recordChunkTranscribed() { chunksTranscribed &+= 1 }

    func snapshot() -> AudioMetricsSnapshot {
        AudioMetricsSnapshot(
            chunksProduced: chunksProduced,
            chunksTranscribed: chunksTranscribed,
            startedAtMs: startedAtMs
        )
    }
}

struct AudioMetricsSnapshot: Sendable {
    let chunksProduced: UInt64
    let chunksTranscribed: UInt64
    let startedAtMs: Int64

    var uptimeSec: Double {
        guard startedAtMs > 0 else { return 0 }
        return Double(Int64(Date().timeIntervalSince1970 * 1000) - startedAtMs) / 1000.0
    }
}
