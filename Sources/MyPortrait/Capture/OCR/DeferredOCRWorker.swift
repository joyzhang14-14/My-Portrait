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
/// 每帧:OCR → 写 OCR 字段 → 按常规写一张 JPG 换掉 HEIC → 移出队列 → 删 HEIC。之后
/// MP4 压缩、Premium 打包、时间轴看到的和采集时直接 OCR 的帧一样。每帧之前重判条件,
/// 用户回来,当前这帧做完就停。
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
    private let config: CaptureConfig
    /// OCR 做完换 JPG 用,同采集的 JPG 规格(1920 宽)。
    private let jpgWriter: SnapshotWriter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "deferred-ocr")

    private var task: Task<Void, Never>?
    private var draining = false
    private var summary: (at: Date, count: Int, oldestMs: Int64?, bytes: Int64)?
    /// 只放自己拿过的防睡眠(别每 30 秒去碰一次 helper)。
    private var awake = false

    init(db: PortraitDB, reporter: UnimplementedReporter, config: CaptureConfig = .default) {
        self.db = db
        self.config = config
        self.jpgWriter = SnapshotWriter(config: config, reporter: reporter)
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
            for f in frames {
                if done > 0, await checkGate(backlogBytes: s.bytes) != nil { break outer }
                await process(f)
                done += 1
            }
        }
        await holdAwake(false)
        if done > 0 { logger.notice("drained \(done, privacy: .public) frame(s)") }
        let s = await refreshSummary(force: done > 0)
        let gate = await checkGate(backlogBytes: s.bytes)
        await publish(running: false, waiting: s.count > 0 ? gate : nil)
    }

    private func process(_ f: PendingOCRFrame) async {
        guard let path = f.snapshotPath,
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            logger.warning("frame \(f.id, privacy: .public): image unreadable, leaving it without OCR")
            try? await db.completePendingOCR(frameId: f.id, ocr: nil, snapshotPath: nil)
            return
        }
        var ocr: OCRResult?
        do {
            ocr = try await OCRService.recognizeUncached(image: image, config: config)
        } catch {
            logger.warning("frame \(f.id, privacy: .public): OCR failed: \(String(describing: error), privacy: .public)")
        }
        // HEIC → 常规 JPG。写失败就留着 HEIC(ImageIO 照样读得了)。
        let heic = URL(fileURLWithPath: path)
        var jpg: URL?
        if heic.pathExtension == SnapshotWriter.pendingOCRExt {
            let out = heic.deletingPathExtension().appendingPathExtension("jpg")
            do {
                try await jpgWriter.write(image: image, to: out)
                jpg = out
            } catch {
                logger.warning("frame \(f.id, privacy: .public): JPG write failed: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            try await db.completePendingOCR(frameId: f.id, ocr: ocr, snapshotPath: jpg?.path)
            if jpg != nil { try? FileManager.default.removeItem(at: heic) }
        } catch {
            logger.error("frame \(f.id, privacy: .public): DB update failed: \(String(describing: error), privacy: .public)")
            if let jpg { try? FileManager.default.removeItem(at: jpg) }
        }
        malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: - 条件

    /// nil = 可以跑;否则是等待原因(显示在 Local Optimization 页)。
    private func checkGate(backlogBytes: Int64) async -> String? {
        let settings = await MainActor.run { ConfigStore.shared.current.localOptimization }
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
        let fm = FileManager.default
        let bytes = p.snapshotPaths.reduce(Int64(0)) {
            $0 + ((try? fm.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0)
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

/// 延后 OCR 的状态,给 Local Optimization 页和 MemoryScheduler 读。
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
