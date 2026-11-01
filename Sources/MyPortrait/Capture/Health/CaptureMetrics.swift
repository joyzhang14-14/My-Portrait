import Foundation

/// Vision 采集流水线的累计指标。actor 隔离写入,snapshot() 拍快照给 StallDetector。
///
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
    /// 已 recordAttempt、还没有结果的帧(截图 / OCR / 写库进行中)。从 silent_loss
    /// 扣除,否则健康检查正好赶上一帧处理到一半时会把它当成丢失。
    /// 每个结果(persisted / dedup / skip / lost)都在同一次 actor 调用里减一,快照前后一致。
    private(set) var inFlight: UInt64 = 0
    private(set) var lastAttemptMs: Int64 = 0
    private(set) var lastDbWriteMs: Int64 = 0
    /// 0 = 未启动。`markStarted()` 幂等,只在第一次写入。
    private(set) var startedAtMs: Int64 = 0

    func markStarted() {
        if startedAtMs == 0 { startedAtMs = Self.nowMs() }
    }

    func recordAttempt() {
        captureAttempts &+= 1
        inFlight &+= 1
        lastAttemptMs = Self.nowMs()
    }

    func recordPersisted() {
        framesPersisted &+= 1
        finish()
        lastDbWriteMs = Self.nowMs()
    }

    func recordDedup() {
        dedupSkips &+= 1
        finish()
    }

    /// 故意整帧跳过(无痕窗在屏 / 锁屏 / 亮度最低 / DRM)。不算 silent_loss,防 StallDetector 误报。
    func recordIntentionalSkip() {
        intentionalSkips &+= 1
        finish()
    }

    /// 这帧失败了(截图抛错 / 写库失败):只结束 in-flight,留在 silent_loss 里。
    func recordLost() {
        finish()
    }

    private func finish() {
        if inFlight > 0 { inFlight -= 1 }
    }

    func snapshot() -> VisionSnapshot {
        VisionSnapshot(
            captureAttempts: captureAttempts,
            framesPersisted: framesPersisted,
            dedupSkips: dedupSkips,
            intentionalSkips: intentionalSkips,
            inFlight: inFlight,
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
    let inFlight: UInt64
    let lastAttemptMs: Int64
    let lastDbWriteMs: Int64
    let startedAtMs: Int64

    /// uptime(秒)。未启动返回 0。
    var uptimeSec: Double {
        guard startedAtMs > 0 else { return 0 }
        return Double(Self.nowMs() - startedAtMs) / 1000.0
    }

    /// silent_loss = attempts - persisted - dedup - intentionalSkips - inFlight。
    /// > 0 = 处理完了但没写库、没去重、也不是故意跳过 = 真沉默丢失。
    var silentLoss: Int64 {
        Int64(captureAttempts) - Int64(framesPersisted)
            - Int64(dedupSkips) - Int64(intentionalSkips) - Int64(inFlight)
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

    /// 起点 = 用户把 Audio Capture 打开的那一刻,不是 app 启动、也不是转录器 boot。
    /// 关掉 → `markStopped()` 清零,Health 页显示 "—",再打开重新计时。
    /// StallDetector 也读 `startedAtMs`:>0 等于"用户开着音频采集"。
    func markStarted() {
        if startedAtMs == 0 { startedAtMs = VisionMetrics.nowMs() }
    }
    func markStopped() { startedAtMs = 0 }
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
