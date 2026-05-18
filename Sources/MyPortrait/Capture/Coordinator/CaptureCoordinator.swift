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
    private let events: EventSources

    // 状态
    private var captureTask: Task<Void, Never>?
    private var lastCaptureAt: Date?
    /// P1 期间 DB 是 stub，stub.insertFrameWithOCR 会 throw。
    /// 为了让 frameEvents 仍能流动，coordinator 自己维护一个递增的 fake id。
    /// 一旦真实 PortraitDB 接好，这个字段和相关 catch 都应该删除。
    private var fakeFrameIdCounter: Int64 = 0

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
        self.drm = DRMGate()
        self.events = EventSources()

        var c: AsyncStream<FrameEvent>.Continuation!
        self.frameEvents = AsyncStream<FrameEvent> { cont in
            c = cont
        }
        self._continuation = c
    }

    var isRunning: Bool { captureTask != nil }

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

        // 3. 启动事件源（@MainActor，自动 hop 过去）。
        await events.start()

        // 4. 事件循环（detached：脱离当前 task tree，免被父 task cancel 牵连）。
        let stream = events.stream
        captureTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEventLoop(stream: stream)
        }

        logger.info("CaptureCoordinator started (event-driven)")
    }

    /// 停止采集流水线。释放 SCStream 缓存、注销通知、关闭 events 流。
    func stop() async {
        captureTask?.cancel()
        captureTask = nil

        await events.stop()
        await focus.stop()
        await screen.invalidateStream()
        comparer.reset()
        await snapshot.reset()

        _continuation.finish()
        logger.info("CaptureCoordinator stopped")
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
            } catch {
                logger.error("captureOneFrame(\(trigger.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                // 错误降级：等下一个 trigger。权限错短期内每帧都会撞，靠 reporter 红点提示。
            }
        }
    }

    private func captureOneFrame(trigger: CaptureTrigger, force: Bool) async throws {
        let now = Date()

        // 防抖：两次实际入库的最小间隔。
        if !force, let last = lastCaptureAt {
            let elapsedMs = now.timeIntervalSince(last) * 1000
            if elapsedMs < Double(config.minCaptureIntervalMs) {
                return
            }
        }

        // 1. 焦点信息（actor，O(1) 读缓存）。
        let focusInfo = await focus.snapshot()

        // 2. DRM 闸门（P1：仅跳帧不停 stream）。
        if drm.isBlocked(focusInfo) {
            return
        }

        // 3. 抓帧。
        let image = try await screen.captureMainDisplay()

        // 4. 去重。
        if !force, !comparer.shouldKeep(image, now: now) {
            return
        }

        lastCaptureAt = now

        // 5. JPG 路径（同步纯计算，立即可用）。
        let url = snapshot.predictURL(timestamp: now)

        // 6. JPG 落盘（actor 串行；不等 IO 完成，与 OCR/DB 并行）。
        let snapshotActor = snapshot
        let imageBox = SendableCGImage(image)
        let writeTask = Task.detached(priority: .utility) { [logger] in
            do {
                try await snapshotActor.write(image: imageBox.image, to: url)
            } catch {
                logger.warning("snapshot write failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // 7. OCR（同步，主路径）。失败只 log，不阻塞入库。
        var ocrResult: OCRResult?
        do {
            ocrResult = try await ocr.recognize(image: image, focus: focusInfo)
        } catch {
            logger.warning("OCR failed: \(String(describing: error), privacy: .public)")
            ocrResult = nil
        }

        // 8. 入库。
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
            // P1：stub DB throws notImplemented。降级用 fake id 让事件流继续。
            // 真实 PortraitDB 接好后这段 catch 应被移除。
            fakeFrameIdCounter += 1
            frameId = fakeFrameIdCounter
        }

        // 9. 发事件。
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
