import CoreGraphics
import Foundation
import os.log

/// 采集层总调度。一个 app 一个实例，AppDelegate 持有。
///
/// 职责：
///   1. 持有 ScreenCaptureService / OCRService / FocusProbe / FrameComparer /
///      SnapshotWriter / EventSources
///   2. 启停采集流水线
///
/// 事件驱动：订阅 EventSources.stream → 每个 trigger 触发一次抓帧。
///   重复 / 高频事件由 minCaptureIntervalMs 防抖 + FrameComparer 去重吸收。
actor CaptureCoordinator {

    private let db: PortraitDB
    private var config: CaptureConfig
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
    /// 锁屏 / login window 时跳帧。Services 在 config 变化时推。
    private var pauseWhenLocked: Bool = true
    /// 亮度最低时跳帧。Services 在 config 变化时推。
    private var pauseAtMinBrightness: Bool = true
    /// 采集时不做 OCR,帧存全分辨率 HEIC 进 `ocr_pending`,由 DeferredOCRWorker 补。
    /// Services 在 config 变化时推。
    private var deferOCR: Bool = false
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
    /// 切换等稳任务(见 scheduleSettleCapture)。同一时间最多一个。
    private var settleTask: Task<Void, Never>?
    /// 这次等稳开始时的画面(灰度格)和开始时刻。
    private var settleBaseline: [UInt8]?
    private var settleStartedAt: Date?

    /// 切换等稳:切 app 后新画面要过一阵才上屏,快的机器 0.1s,慢的机器 / 冷启动的 app 要几秒,
    /// 所以不按固定时间等,每 settlePollMs 截一张小图看画面:前台读数稳定、画面变过且停住才抓;
    /// 画面一直没变(点的是本来就露着的窗口)等满 settleQuietMs 也抓;最多等 settleTimeoutMs。
    /// 等稳期间截下的其他帧一律标 switching。
    private let settleTimeoutMs = 5_000
    private let settlePollMs = 100
    private let settleQuietMs = 1_500
    /// 灰度格平均差(0–255):≥ changed 算画面换了,< still 算停住了。实测切 app 4–30,停住后 0–1。
    private let settleChangedDiff = 2.0
    private let settleStillDiff = 1.0

    init(db: PortraitDB, reporter: UnimplementedReporter, config: CaptureConfig = .default) {
        self.db = db
        self.reporter = reporter
        self.config = config

        let cache = OCRCache(config: config)
        self.ocrCache = cache
        let ignoreGate = IgnoreGate()
        self.ignore = ignoreGate
        self.screen = ScreenCaptureService(config: config, reporter: reporter, ignore: ignoreGate)
        self.focus = FocusProbe(reporter: reporter)
        self.comparer = FrameComparer(config: config, reporter: reporter)
        self.snapshot = SnapshotWriter(config: config, reporter: reporter)
        self.ocr = OCRService(config: config, cache: cache, reporter: reporter)
        let drmGate = DRMGate()
        self.drm = drmGate
        self.events = EventSources()
        let focusInstance = self.focus
        self.drmWatcher = DRMWatcher(focus: focusInstance, gate: drmGate)
        self.sleepWakeBox = SleepWakeBox()
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

    /// Services 在 ConfigStore.privacy.ignoredCategories 变化时调。
    nonisolated func setIgnoredCategories(_ cats: [String]) {
        ignore.setIgnoredCategories(cats)
    }

    /// Services 在 ConfigStore.privacy.pauseCaptureApps/Urls 变化时调。
    /// drm 是共享的 class 实例(coordinator 与 drmWatcher 同一个),一次更新两边生效。
    nonisolated func setPauseCaptureList(apps: [String], urls: [String]) {
        drm.setPauseList(apps: apps, urls: urls)
    }

    /// Services 在 ConfigStore.capture.screen 的两个跳帧开关变化时调。
    func setCaptureGates(pauseWhenLocked locked: Bool, pauseAtMinBrightness dim: Bool) {
        pauseWhenLocked = locked
        pauseAtMinBrightness = dim
    }

    func setDeferOCR(_ on: Bool) {
        deferOCR = on
    }

    /// Services 在功耗档位变化时调(电源/低电量/热状态/用户改 powerMode)。
    /// 更新抓帧间隔(下一轮 loop 立即生效)+ 推 JPG 质量给 SnapshotWriter。
    func applyPowerProfile(_ profile: PowerProfile) {
        // minCaptureIntervalMs 只在本 actor 的 loop(line ~236)读,改这里即生效。
        config.minCaptureIntervalMs = profile.minCaptureIntervalMs
        let q = profile.jpegQuality
        Task { await snapshot.setJpegQuality(q) }
    }

    /// 启动采集流水线。幂等。
    /// 失败抛错；调用方 catch 后状态栏会自动亮红点。
    func start() async throws {
        guard captureTask == nil else { return }

        // 健康度起点。StallDetector 需要 uptime > 120s 才会判 stall(warmup)。
        await VisionMetrics.shared.markStarted()

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
        //    start() 重建并返回新流 —— 复用 coordinator 实例跨 toggle 时旧流已被上次
        //    stop() finish 掉,必须拿新流,否则 DRM 恢复信号送不出。
        let drmStates = await drmWatcher.start()
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
        settleTask?.cancel()
        captureTask = nil
        drmTask = nil
        sleepWakeTask = nil
        settleTask = nil
        settleBaseline = nil
        settleStartedAt = nil

        await drmWatcher.stop()
        await sleepWakeBox.stop()
        await events.stop()
        await focus.stop()
        await screen.invalidateStream()
        comparer.reset()
        await snapshot.reset()

        logger.info("CaptureCoordinator stopped")
    }

    // MARK: - 状态变化处理

    private func handleDRMState(_ blocked: Bool) async {
        drmActive = blocked
        // 通知 StallDetector:故意暂停,后续 60s 无帧不算 stall。
        await MainActor.run { IntentionalPauseState.shared.drmActive = blocked }
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
            await MainActor.run { IntentionalPauseState.shared.markScreenAsleep() }
            await screen.invalidateStream()
            comparer.reset()
        case .didWake:
            await MainActor.run { IntentionalPauseState.shared.markScreenAwake() }
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
            // 切 app 不当场抓:这时画面多半还是上一个 app,交给等稳任务看画面换好了再抓。
            if trigger == .appSwitch {
                scheduleSettleCapture(trigger: .appSwitch, restart: true)
                continue
            }
            do {
                // 回车帧必拍:敲完一行再回车整屏直方图几乎不变,走去重会被吃掉近一半。
                try await captureOneFrame(trigger: trigger, force: trigger == .typingPause)
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

    /// `fromSettle`:等稳任务抓的那一帧(切换后第一张可信帧 / 补拍帧)。
    private func captureOneFrame(trigger: CaptureTrigger, force: Bool, fromSettle: Bool = false) async throws {
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

        // 健康度埋点:这帧真正进入抓帧流水线(过了 DRM/防抖 gate)。
        // dedup / DB 失败仍计入 attempt — silent_loss = attempts - persisted -
        // dedup 才能算对。
        await VisionMetrics.shared.recordAttempt()

        // 1. 焦点信息（actor，O(1) 读缓存）。
        let focusInfo = await focus.snapshot()

        // 2. DRM 即时检测兜底（DRMWatcher 3s 才轮询一次，可能错过短暂打开 Netflix 等场景）。
        //    走 handleDRMState(true)(统一置 drmActive + IntentionalPauseState +
        //    invalidateStream),并给轮询器补记 lastBlocked —— 否则 DRM 内容在一个
        //    轮询间隔内开了又关,轮询器没见过 blocked,永远不发 clear,drmActive 锁死。
        if drm.isBlocked(focusInfo) {
            await handleDRMState(true)
            await drmWatcher.noteInlineBlock()
            return
        }

        // 2b. 锁屏 / login window → 整帧跳过(用户不在电脑前,拍到的只有锁屏
        //     壁纸)。记 intentionalSkip:这帧是**故意**不写库,别让 StallDetector
        //     把它算进 silent_loss,误报 "Capturing screen but DB writes have
        //     stopped"。
        if pauseWhenLocked, ScreenLockMonitor.queryLocked() {
            await VisionMetrics.shared.recordIntentionalSkip()
            return
        }

        // 2c. 屏幕亮度调到最低(滑块 0)→ 整帧跳过(屏幕黑着,用户没在看)。
        //     读不到亮度(外接不可控显示器等)fail-open 不跳,照常采集。
        if pauseAtMinBrightness, DisplayBrightness.isAtMinimum() {
            await VisionMetrics.shared.recordIntentionalSkip()
            return
        }

        // 3. 抓帧。**用户 ignore 名单不跳整帧** —— 帧就是时间轴本身,跟音频 /
        //    打字两路按时间对齐,少一帧就是时间轴上少一段。命中的窗口由
        //    ScreenCaptureService 在 SCK content filter 里排除(content
        //    masking:帧照拍,那个窗口在帧里被抠掉)。
        //    截图后立即读前台(激活 app + 画面最前 app),判这帧的焦点状态。
        //    切换途中截的帧标 switching,并在前台稳定后补拍一帧。
        let image = try await screen.captureMainDisplay()
        let front = await focus.liveFront()
        var focusState = FrameFocusState.classify(front)
        // 等稳期间截的帧、或截图途中来了切换通知(点别的 app 时点击帧先截、激活后到):
        // 前台读数已是新 app,画面可能还是上一个,标签不可信。
        if focusState == .normal, !fromSettle,
           settleTask != nil || SwitchClock.shared.lastSwitch >= now {
            focusState = .switching
        }
        if focusState == .switching, !fromSettle {
            scheduleSettleCapture(trigger: .switchSettle, restart: false)
        }

        // 5. 去重。
        if !force, !comparer.shouldKeep(image, now: now) {
            await VisionMetrics.shared.recordDedup()
            return
        }

        lastCaptureAt = now

        // 5b. app 名取截图后的激活 app。focusInfo 是 FocusProbe 缓存(通知刷新,有节流),
        //     会落后于激活 app。正在切换时 windowTitle/url/axText 一并作废(宁可空也别
        //     张冠李戴);画面已稳定、只是缓存还是上一个 app 的,当场补读标题和 URL。
        var recordFocus = focusInfo
        if focusState == .switching {
            recordFocus = FocusInfo(appName: front.activeName, bundleId: front.activeBundleId,
                                    windowTitle: nil, browserUrl: nil, axText: nil,
                                    axIdentifier: nil, isFocused: true)
        } else if front.activeName != focusInfo.appName {
            recordFocus = await focus.quickFocus(front)
        }

        // 6. JPG 路径（同步纯计算，立即可用）。延后 OCR 时存全分辨率 HEIC,OCR 做完再换成 JPG。
        let deferred = deferOCR
        let url = snapshot.predictURL(timestamp: now, ext: deferred ? SnapshotWriter.pendingOCRExt : "jpg")

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

        // 8. OCR（同步，主路径）。失败只 log，不阻塞入库。延后 OCR 时跳过。
        var ocrResult: OCRResult?
        if !deferred {
            do {
                ocrResult = try await ocr.recognize(image: image, focus: recordFocus)
            } catch {
                logger.warning("OCR failed: \(String(describing: error), privacy: .public)")
                ocrResult = nil
            }
            // 全分辨率 OCR 一帧要开几份十几 MB 的工作缓冲,用完 malloc 会把这些
            // 空闲大块攒着不还系统,后台进程等不到内存压力信号,footprint 就一直
            // 挂在 300-600MB。每帧干完主动交还,只动空闲块,不影响 OCR 本身。
            malloc_zone_pressure_relief(nil, 0)
        } else {
            // 不做 OCR 时主路径很短,等 HEIC 写完再走:手上始终只压一张全分辨率图,
            // 编码器的缓冲用完也一并交还。
            await writeTask.value
            malloc_zone_pressure_relief(nil, 0)
        }

        // 9. 入库。
        let record = FrameRecord(
            timestampMs: Int64(now.timeIntervalSince1970 * 1000),
            appName: recordFocus.appName,
            windowName: recordFocus.windowTitle,
            browserUrl: recordFocus.browserUrl,
            focused: recordFocus.isFocused,
            deviceName: config.monitorId,
            snapshotPath: url.path,
            captureTrigger: trigger.rawValue,
            visibleApp: front.visibleName,
            focusState: focusState.rawValue,
            visibleWindows: front.visibleWindowsJSON
        )

        do {
            _ = deferred ? try await db.insertFramePendingOCR(record)
                         : try await db.insertFrameWithOCR(record, ocr: ocrResult)
        } catch {
            // DB 写失败 → 这帧不入库。
            // JPG 已经落盘了，可以通过 compactor / 手动 SQL 回补。
            // 不调 recordPersisted —— silent_loss 自动 +1 反映真"沉默丢失"。
            logger.error("DB insertFrameWithOCR failed: \(String(describing: error), privacy: .public)")
            DiagLog.error("capture.frame.db_insert_failed", ctx: [
                "trigger":  trigger.rawValue,
                "snapshot": url.lastPathComponent,
                "app":      focusInfo.appName,
                "err":      String(describing: error),
            ])
            return
        }
        // 健康度埋点:真落库成功 → lastDbWriteMs 跳。StallDetector 拿这个
        // 跟 lastAttemptMs 比,差 > 60s 且非 dedup → vision_db_write stall。
        await VisionMetrics.shared.recordPersisted()

        // 不 await writeTask —— 主路径不等磁盘 IO 完成。
        _ = writeTask
    }

    /// 开一次切换等稳,等好后强制抓一帧(trigger = .appSwitch 或 .switchSettle)。
    /// 新的切 app 会顶掉正在等的那次(restart);switching 帧补拍不顶(已在等就算了)。
    /// 等稳帧自己若仍是 switching 不再续约,避免连环补拍。
    private func scheduleSettleCapture(trigger: CaptureTrigger, restart: Bool) {
        if settleTask != nil {
            guard restart else { return }
            settleTask?.cancel()
            // 切走 / 切入两个通知前后脚到:0.5s 内的沿用原来的起点和画面,那时画面还没动。
            if let t = settleStartedAt, Date().timeIntervalSince(t) >= 0.5 {
                settleBaseline = nil
                settleStartedAt = nil
            }
        }
        settleTask = Task { [weak self] in
            guard let self else { return }
            await self.runSettleCapture(trigger: trigger)
        }
    }

    private func runSettleCapture(trigger: CaptureTrigger) async {
        if settleStartedAt == nil {
            settleStartedAt = Date()
            settleBaseline = try? await screen.captureGrid()
            if Task.isCancelled { return }
        }
        let started = settleStartedAt ?? Date()
        var prev = settleBaseline
        var changed = false
        while true {
            try? await Task.sleep(nanoseconds: UInt64(settlePollMs) * 1_000_000)
            if Task.isCancelled { return }   // stop() 或新的切 app 顶掉了
            let waitedMs = Int(Date().timeIntervalSince(started) * 1000)
            if waitedMs >= settleTimeoutMs { break }
            let grid = try? await screen.captureGrid()
            if Task.isCancelled { return }
            var still = false
            if let grid, let base = settleBaseline {
                if ScreenCaptureService.gridDiff(base, grid) >= settleChangedDiff { changed = true }
                still = prev.map { ScreenCaptureService.gridDiff($0, grid) < settleStillDiff } ?? false
                prev = grid
            }
            let front = await focus.liveFront()
            if Task.isCancelled { return }
            guard front.isSettled else { continue }
            // 小图截不到时只看前台读数。
            if grid == nil || settleBaseline == nil { break }
            // 画面没变时,激活 app 还没有窗口(慢机器上 app 还在启动)就接着等它的窗口,等满为止。
            if changed ? still : (waitedMs >= settleQuietMs && front.activeHasWindow) { break }
        }
        // 抓之前就让出位置:这帧的 OCR + 写库要几百 ms,这期间又来的切换要能开自己的等稳。
        settleTask = nil
        settleBaseline = nil
        settleStartedAt = nil
        do {
            try await captureOneFrame(trigger: trigger, force: true, fromSettle: true)
        } catch {
            logger.error("switch settle capture failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// CGImage 包装供 Task.detached 跨 Sendable 边界传递。
/// CGImage 在创建后实质不可变 + CFRetain/Release 原子，标记 unchecked Sendable 安全。
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
