import CoreGraphics
import Foundation
import ImageIO
import Observation
import os.log

/// Workflow 第 1 层:延后 OCR(10-25 update)。
///
/// 采集时不做 OCR(全分辨率 OCR 的工作内存是常驻 300–600MB 的大头),帧存全分辨率
/// HEIC 并登记进 `ocr_pending`。这里在**充电**时按设置里的档位补做(`OCRPowerMode`):
///   - Charging:充电就跑;
///   - Charging & lid closed:合盖;
///   - Charging & idle:没人在用(合盖、亮度调到 0 或 5 分钟没有键鼠操作,`PowerMonitor.isIdle`)。
/// 积压的图超过 5GB 时,后两档也是充电就跑(兜底)。
/// 另外内存要够:系统内存压力正常,且能立刻让出来的内存不低于 1.5GB
/// (`SystemMemory`)。设置里关掉延后 OCR 后,剩下的积压只看内存,马上补完。
///
/// 每帧:交给 OCR 子进程(`OCRHelper`,OCR + 按常规写一张 JPG)→ 写 OCR 字段、换
/// snapshot_path、移出队列 → 删 HEIC。之后 MP4 压缩、Premium 打包、时间轴看到的和采集时
/// 直接 OCR 的帧一样。每帧之前重判条件,用户回来,当前这帧做完就停;一轮结束子进程退出。
///
/// 下游等这一层做完:事件区间封口不越过最旧的待 OCR 帧(`EventIntervalStore`),
/// 这一层在跑时事件 / 画像 / 性格都不开跑(`MemoryScheduler`)。
actor DeferredOCRWorker {

    static let backlogFallbackBytes: Int64 = 5 * 1024 * 1024 * 1024
    /// 刚采的帧 HEIC 可能还没写完盘,留一分钟。
    private static let settleMs: Int64 = 60_000
    private static let pollSeconds: UInt64 = 30
    private static let batch = 50
    /// 积压概况(要逐个 stat 图片)最多一分钟刷一次。
    private static let summaryEverySeconds: TimeInterval = 60

    private let db: PortraitDB
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "deferred-ocr")

    private var task: Task<Void, Never>?
    private var draining = false
    private var summary: (at: Date, count: Int, oldestMs: Int64?, bytes: Int64)?
    /// 只放自己拿过的防睡眠(别每 30 秒去碰一次 helper)。
    private var awake = false
    /// 这一轮的 OCR 子进程,第一帧时开,drain 结束关。
    private var helper: OCRHelper.Connection?
    /// 子进程处理某帧时死掉(含超时)的次数。
    private var crashes: [Int64: Int] = [:]
    /// 死过两次的帧:先跳过,等别的帧做成功、证明子进程本身没问题,再认定是这帧的问题,
    /// 不 OCR 放行,免得卡住整个队列。
    private var suspects: Set<Int64> = []
    /// 上次有帧做成功以来,子进程失败(起不来 / 交不出去 / 处理中死掉)的次数。
    /// 连续失败到 `systemicFailures` 次 = 子进程本身坏了,不怪哪一帧:清掉嫌疑、亮健康红点,
    /// 帧都留在队列里,每轮照常重试。
    private var failuresSinceSuccess = 0
    private static let systemicFailures = 3
    static let healthComponent = "deferredOCR.helper"

    init(db: PortraitDB) {
        self.db = db
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - 主循环

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        var done = 0
        outer: while !Task.isCancelled {
            let s = await refreshSummary(force: done > 0)
            let gate = await checkGate(backlogBytes: s.bytes)
            await publish(running: gate == nil && s.count > 0, waiting: gate)
            guard gate == nil else { break }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let frames = (try? await db.pendingOCRFrames(beforeMs: nowMs - Self.settleMs, limit: Self.batch)) ?? []
            if frames.isEmpty { break }
            await holdAwake(true)
            var tried = false
            for f in frames where !suspects.contains(f.id) {
                if done > 0, await checkGate(backlogBytes: s.bytes) != nil { break outer }
                tried = true
                guard await process(f) else { break outer }
                done += 1
            }
            // 这一批全是嫌疑帧:等下一轮(有新帧做成功才能给它们定性)。
            if !tried { break }
        }
        await helper?.close()
        helper = nil
        await holdAwake(false)
        if done > 0 {
            logger.notice("drained \(done, privacy: .public) frame(s)")
            MemoryTrim.ifHidden()
        }
        let s = await refreshSummary(force: done > 0)
        let gate = await checkGate(backlogBytes: s.bytes)
        await publish(running: false, waiting: s.count > 0 ? gate : nil)
    }

    /// false = 子进程起不来或中途死了,这一轮先停。
    private func process(_ f: PendingOCRFrame) async -> Bool {
        guard let path = f.snapshotPath else {
            logger.warning("frame \(f.id, privacy: .public): no image, leaving it without OCR")
            try? await db.completePendingOCR(frameId: f.id, ocr: nil, snapshotPath: nil)
            return true
        }
        let connection: OCRHelper.Connection
        if let helper {
            connection = helper
        } else {
            do {
                connection = try OCRHelper.Connection()
                helper = connection
            } catch {
                logger.error("OCR helper failed to start: \(String(describing: error), privacy: .public)")
                await helperFailed(frame: nil)
                return false
            }
        }
        let reply: OCRHelper.Reply
        switch await connection.run(OCRHelper.Request(id: f.id, path: path)) {
        case .reply(let r):
            reply = r
        case .notDelivered:
            logger.error("frame \(f.id, privacy: .public): OCR helper wasn't running, frame not sent")
            await helperFailed(frame: nil)
            return false
        case .died(let timedOut):
            logger.error("frame \(f.id, privacy: .public): OCR helper \(timedOut ? "timed out" : "exited", privacy: .public) on this frame")
            await helperFailed(frame: f.id)
            return false
        }
        await helperWorked()
        guard reply.readable else {
            logger.warning("frame \(f.id, privacy: .public): image unreadable, leaving it without OCR")
            try? await db.completePendingOCR(frameId: f.id, ocr: nil, snapshotPath: nil)
            return true
        }
        do {
            let applied = try await db.completePendingOCR(frameId: f.id, ocr: reply.ocr, snapshotPath: reply.jpg)
            if reply.jpg != nil { try? FileManager.default.removeItem(atPath: path) }
            // 处理期间这帧被删了 / 图被清了:新写出的 JPG 没人指向,一起删。
            if !applied, let jpg = reply.jpg { try? FileManager.default.removeItem(atPath: jpg) }
        } catch {
            logger.error("frame \(f.id, privacy: .public): DB update failed: \(String(describing: error), privacy: .public)")
            if let jpg = reply.jpg { try? FileManager.default.removeItem(atPath: jpg) }
        }
        return true
    }

    /// `frame` = 子进程是在处理这帧时死的;nil = 跟具体帧无关(起不来 / 没交出去)。
    private func helperFailed(frame: Int64?) async {
        helper = nil
        failuresSinceSuccess += 1
        if let id = frame {
            let n = (crashes[id] ?? 0) + 1
            crashes[id] = n
            if n >= 2 { suspects.insert(id) }
        }
        guard failuresSinceSuccess >= Self.systemicFailures else { return }
        crashes = [:]
        suspects = []
        let n = failuresSinceSuccess
        await MainActor.run {
            HealthMonitor.shared.report(component: Self.healthComponent,
                                        reason: "OCR helper failed \(n)x in a row with no frame done")
        }
    }

    /// 有帧做成功了:子进程是好的,之前死过两次的帧就是它们自己的问题,不 OCR 放行。
    private func helperWorked() async {
        if failuresSinceSuccess >= Self.systemicFailures {
            await MainActor.run { HealthMonitor.shared.clear(component: Self.healthComponent) }
        }
        failuresSinceSuccess = 0
        for id in suspects {
            logger.warning("frame \(id, privacy: .public): OCR helper died on it twice, leaving it without OCR")
            try? await db.completePendingOCR(frameId: id, ocr: nil, snapshotPath: nil)
            crashes[id] = nil
        }
        suspects = []
    }

    // MARK: - 条件

    /// nil = 可以跑;否则是等待原因(显示在 Screen Capture 页的 Screen Text Recognition 卡)。
    private func checkGate(backlogBytes: Int64) async -> String? {
        let settings = await MainActor.run { ConfigStore.shared.current.capture.screen }
        if let level = SystemMemory.pressureLevel(), level > 1 { return "Memory pressure is high" }
        guard let avail = SystemMemory.availableBytes() else { return "Can't read free memory" }
        if avail < SystemMemory.minFreeBytes { return "Not enough free memory" }
        if !settings.deferOCR { return nil }
        guard PowerMonitor.isOnAC else { return "Waiting for the charger" }
        switch settings.ocrPowerMode {
        case .charging: return nil
        case .chargingLidClosed: if PowerMonitor.isLidClosed { return nil }
        case .chargingIdle: if PowerMonitor.isIdle { return nil }
        }
        if backlogBytes > Self.backlogFallbackBytes { return nil }
        return settings.ocrPowerMode == .chargingIdle ? "Waiting until the screen isn't in use" : "Waiting for the lid to close"
    }

    private func refreshSummary(force: Bool) async -> (count: Int, bytes: Int64) {
        if !force, let s = summary, Date().timeIntervalSince(s.at) < Self.summaryEverySeconds {
            return (s.count, s.bytes)
        }
        guard let p = try? await db.pendingOCRSummary() else { return (summary?.count ?? 0, summary?.bytes ?? 0) }
        // 只要大小,用 stat;attributesOfItem 每个文件还要读一遍扩展属性,上千张就很慢。
        let bytes = p.snapshotPaths.reduce(Int64(0)) { sum, path in
            var st = stat()
            return sum + (stat(path, &st) == 0 ? Int64(st.st_size) : 0)
        }
        summary = (Date(), p.count, p.oldestMs, bytes)
        let (count, oldest) = (p.count, p.oldestMs)
        await MainActor.run {
            let st = DeferredOCRStatus.shared
            st.pendingCount = count
            st.oldestMs = oldest
            st.backlogBytes = bytes
        }
        return (count, bytes)
    }

    private func publish(running: Bool, waiting: String?) async {
        await MainActor.run {
            let st = DeferredOCRStatus.shared
            st.running = running
            st.waitingReason = waiting
        }
    }

    /// 跑的时候不让机器空闲睡眠;合盖时再借 helper 让机器完全醒着(helper 没批准则静默不生效)。
    private func holdAwake(_ on: Bool) async {
        guard on || awake else { return }
        awake = on
        await MainActor.run {
            let ac = PowerMonitor.isOnAC
            KeepAwakeAssertion.shared.set(on && ac, owner: "ocr")
            SleepHelperClient.shared.setKeepAwake(on && ac && PowerMonitor.isLidClosed, owner: "ocr")
        }
    }
}

/// 延后 OCR 的状态,给 Screen Text Recognition 卡和 MemoryScheduler 读。
@MainActor
@Observable
final class DeferredOCRStatus {
    static let shared = DeferredOCRStatus()
    var running = false
    var waitingReason: String?
    var pendingCount = 0
    var oldestMs: Int64?
    var backlogBytes: Int64 = 0
    private init() {}
}
