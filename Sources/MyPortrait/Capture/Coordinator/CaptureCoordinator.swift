import CoreGraphics
import Foundation
import os.log

/// 采集层总调度。一个 app 一个实例，AppDelegate 持有。
///
/// 职责：
///   1. 持有 ScreenCaptureService / OCRService / FocusProbe / FrameComparer /
///      SnapshotWriter / EventSources
///   2. 启停采集流水线
///   3. 把每帧入库完成事件通过 `frameEvents` AsyncStream 推给订阅方
///
/// P2 起改为事件驱动：
///   订阅 EventSources.stream → 每个 trigger 触发一次抓帧。
///   重复 / 高频事件由 minCaptureIntervalMs 防抖 + FrameComparer 去重吸收。
actor CaptureCoordinator {

    private let db: PortraitDB
    private let config: CaptureConfig
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "coordinator")

    // 子服务
    private let screen: ScreenCaptureService
    private let focus: FocusProbe
    private let comparer: FrameComparer
    private let snapshot: SnapshotWriter
    private let ocrCache: OCRCache
    private let ocr: OCRService
    private let drm: DRMGate
    private let ignore: IgnoreGate
    private let events: EventSources
    private let drmWatcher: DRMWatcher
    private let sleepWakeBox: SleepWakeBox

    // 状态
    private var captureTask: Task<Void, Never>?
    private var drmTask: Task<Void, Never>?
    private var sleepWakeTask: Task<Void, Never>?
    private var lastCaptureAt: Date?
    /// DRM 命中时为 true —— captureOneFrame 全部跳过。
    private var drmActive: Bool = false

    nonisolated let frameEvents: AsyncStream<FrameEvent>
    private let _continuation: AsyncStream<FrameEvent>.Continuation

    init(db: PortraitDB, reporter: UnimplementedReporter, config: CaptureConfig = .default) {
        self.db = db
        self.reporter = reporter
        self.config = config

        let cache = OCRCache(config: config)
        self.ocrCache = cache
        self.screen = ScreenCaptureService(config: config, reporter: reporter)
        self.focus = FocusProbe(reporter: reporter)
        self.comparer = FrameComparer(config: config, reporter: reporter)
        self.snapshot = SnapshotWriter(config: config, reporter: reporter)
        self.ocr = OCRService(config: config, cache: cache, reporter: reporter)
        let drmGate = DRMGate()
        self.drm = drmGate
        self.ignore = IgnoreGate()
        self.events = EventSources()
        let focusInstance = self.focus
        self.drmWatcher = DRMWatcher(focus: focusInstance, gate: drmGate)
        self.sleepWakeBox = SleepWakeBox()

        var c: AsyncStream<FrameEvent>.Continuation!
        self.frameEvents = AsyncStream<FrameEvent> { cont in
            c = cont
        }
        self._continuation = c
    }

    var isRunning: Bool { captureTask != nil }

    /// Services 在 ConfigStore.privacy.ignoredApps 变化时调。
    /// 直接传给 IgnoreGate（lock-protected，线程安全）。
    nonisolated func setIgnoredApps(_ apps: Set<String>) {
        ignore.setIgnoredApps(apps)
    }

    /// Services 在 ConfigStore.privacy.ignoredUrls 变化时调。
    nonisolated func setIgnoredUrlPatterns(_ patterns: [String]) {
        ignore.setIgnoredUrlPatterns(patterns)
    }

    /// Services 在 ConfigStore.privacy.ignoredWindowTitles 变化时调。
    nonisolated func setIgnoredWindowTitles(_ titles: [String]) {
        ignore.setIgnoredWindowTitles(titles)
    }

    /// 启动采集流水线。幂等。
    /// 失败抛错；调用方 catch 后状态栏会自动亮红点。
    func start() async throws {
        guard captureTask == nil else { return }

        // 1. 焦点监听（NSWorkspace 通知 + 初次刷新）。
        await focus.start()

        // 2. 试抓一帧 —— 触发屏幕录制权限弹窗，及早暴露问题。
        //    同时这一帧自身就作为首帧被抓住，触发后续 frameEvent。
        do {
            try await captureOneFrame(trigger: .manual, force: true)
        } catch {
            logger.error("initial capture failed: \(String(describing: error), privacy: .public)")
            // 不抛 —— 让事件流仍能启动。状态栏会从其他错误路径冒红点。
        }

        // 3. 启动事件源（@MainActor，自动 hop 过去）。返回一条新的 trigger 流。
        let stream = await events.start()

        // 4. DRM watcher（后台 3s 一次轮询；命中 → drmActive=true → 跳过所有帧）。
        await drmWatcher.start()
        let drmStates = drmWatcher.states
        drmTask = Task.detached(priority: .background) { [weak self] in
            for await blocked in drmStates {
                await self?.handleDRMState(blocked)
            }
        }

        // 5. Sleep/Wake 监听。睡眠 → invalidate stream + reset comparer。
        let sleepStream = await sleepWakeBox.start()
        sleepWakeTask = Task.detached(priority: .background) { [weak self] in
            for await event in sleepStream {
                await self?.handleSleepWake(event)
            }
        }

        // 6. 事件循环（detached：脱离当前 task tree，免被父 task cancel 牵连）。
        captureTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEventLoop(stream: stream)
        }

        logger.info("CaptureCoordinator started (event-driven, DRM + sleep-aware)")
    }

    /// 停止采集流水线。释放 SCStream 缓存、注销通知、关闭 events 流。
    func stop() async {
        captureTask?.cancel()
        drmTask?.cancel()
        sleepWakeTask?.cancel()
        captureTask = nil
        drmTask = nil
        sleepWakeTask = nil

        await drmWatcher.stop()
        await sleepWakeBox.stop()
        await events.stop()
        await focus.stop()
        await screen.invalidateStream()
        comparer.reset()
        await snapshot.reset()

        _continuation.finish()
        logger.info("CaptureCoordinator stopped")
    }

    // MARK: - 状态变化处理

    private func handleDRMState(_ blocked: Bool) async {
        drmActive = blocked
        if blocked {
            // 命中 → 立即释放 SCStream，避免触发系统的录屏副作用。
            await screen.invalidateStream()
            logger.info("DRM active: capture pipeline paused, SCStream invalidated")
        } else {
            // 清除 → reset comparer 强制下一帧保留，下一次 trigger 自然恢复。
            comparer.reset()
            logger.info("DRM clear: capture pipeline resumed")
        }
    }

    private func handleSleepWake(_ event: SleepWakeEvent) async {
        switch event {
        case .willSleep:
            await screen.invalidateStream()
            comparer.reset()
        case .didWake:
            // 睡前/睡后差异巨大，强制下一帧保留。
            comparer.reset()
            // SCStream 已 invalidate，下次 trigger 来时会懒重建。
        }
    }

    /// 手动触发一帧。
    func captureOnce() async throws {
        try await captureOneFrame(trigger: .manual, force: true)
    }

    // MARK: - 事件循环

    private func runEventLoop(stream: AsyncStream<CaptureTrigger>) async {
        for await trigger in stream {
            if Task.isCancelled { break }
            do {
                try await captureOneFrame(trigger: trigger, force: false)
            } catch CaptureError.screenRecordingPermissionDenied,
                    CaptureError.captureFailed(CaptureError.screenRecordingPermissionDenied) {
                // **权限没给**：再 trigger 也只是反复撞 SCK XPC，每次都让 caulk
                // 多投递一个失败回调，最终可能撞 dispatch_assert_queue_fail 整进程崩。
                // 直接断了事件循环，等用户重新 toggle 才会重启。
                logger.error("screen recording permission denied — pausing capture loop. User needs to grant permission in System Settings and re-toggle screen capture.")
                break
            } catch {
                logger.error("captureOneFrame(\(trigger.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                // 其他错误降级：等下一个 trigger（短暂的网络 / display unplug 类型恢复得过来）。
            }
        }
    }

    private func captureOneFrame(trigger: CaptureTrigger, force: Bool) async throws {
        let now = Date()

        // P5: DRM 命中 → 整个流水线暂停，SCStream 已 invalidate。
        // 强制 force=true 也照样停（手动 captureOnce 在 DRM 期间会静默返回）。
        if drmActive {
            return
        }

        // 防抖：两次实际入库的最小间隔。
        if !force, let last = lastCaptureAt {
            let elapsedMs = now.timeIntervalSince(last) * 1000
            if elapsedMs < Double(config.minCaptureIntervalMs) {
                return
            }
        }

        // 1. 焦点信息（actor，O(1) 读缓存）。
        let focusInfo = await focus.snapshot()

        // 2. DRM 即时检测兜底（DRMWatcher 3s 才轮询一次，可能错过短暂打开 Netflix 等场景）。
        if drm.isBlocked(focusInfo) {
            drmActive = true
            await screen.invalidateStream()
            return
        }

        // 3. 用户隐私 ignore 列表。命中 → 静默跳过这一帧（不动 lastCaptureAt
        //    以免影响 minCaptureIntervalMs 计数，让真正可采集的下一帧立刻能跑）。
        if ignore.shouldSkip(focusInfo) {
            return
        }

        // 4. 抓帧。
        let image = try await screen.captureMainDisplay()

        // 5. 去重。
        if !force, !comparer.shouldKeep(image, now: now) {
            return
        }

        lastCaptureAt = now

        // 6. JPG 路径（同步纯计算，立即可用）。
        let url = snapshot.predictURL(timestamp: now)

        // 7. JPG 落盘（actor 串行；不等 IO 完成，与 OCR/DB 并行）。
        let snapshotActor = snapshot
        let imageBox = SendableCGImage(image)
        let writeTask = Task.detached(priority: .utility) { [logger] in
            do {
                try await snapshotActor.write(image: imageBox.image, to: url)
            } catch {
                logger.warning("snapshot write failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // 8. OCR（同步，主路径）。失败只 log，不阻塞入库。
        var ocrResult: OCRResult?
        do {
            ocrResult = try await ocr.recognize(image: image, focus: focusInfo)
        } catch {
            logger.warning("OCR failed: \(String(describing: error), privacy: .public)")
            ocrResult = nil
        }

        // 9. 入库。
        let record = FrameRecord(
            timestampMs: Int64(now.timeIntervalSince1970 * 1000),
            appName: focusInfo.appName,
            windowName: focusInfo.windowTitle,
            browserUrl: focusInfo.browserUrl,
            focused: focusInfo.isFocused,
            deviceName: config.monitorId,
            snapshotPath: url.path,
            captureTrigger: trigger.rawValue
        )

        let frameId: Int64
        do {
            frameId = try await db.insertFrameWithOCR(record, ocr: ocrResult)
        } catch {
            // DB 写失败 → 静默丢弃这帧的事件（避免下游收到无效 frameId）。
            // JPG 已经落盘了，可以通过 compactor / 手动 SQL 回补。
            logger.error("DB insertFrameWithOCR failed: \(String(describing: error), privacy: .public)")
            return
        }

        // 10. 发事件。
        let event = FrameEvent(
            frameId: frameId,
            timestampMs: record.timestampMs,
            appName: record.appName,
            windowName: record.windowName,
            browserUrl: record.browserUrl,
            snapshotPath: record.snapshotPath,
            ocrText: ocrResult?.fullText,
            captureTrigger: record.captureTrigger
        )
        _continuation.yield(event)

        // 不 await writeTask —— 主路径不等磁盘 IO 完成。
        _ = writeTask
    }
}

/// CGImage 包装供 Task.detached 跨 Sendable 边界传递。
/// CGImage 在创建后实质不可变 + CFRetain/Release 原子，标记 unchecked Sendable 安全。
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// 一帧入库完成（含 OCR 完成或确认空）后由 Coordinator 发出。
public struct FrameEvent: Sendable {
    public let frameId: Int64
    public let timestampMs: Int64
    public let appName: String
    public let windowName: String?
    public let browserUrl: String?
    public let snapshotPath: String
    /// `nil` = OCR 失败或被跳过。订阅方按需 poll DB。
    public let ocrText: String?
    public let captureTrigger: String
}
