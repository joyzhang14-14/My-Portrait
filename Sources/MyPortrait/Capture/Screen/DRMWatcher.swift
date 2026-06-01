import Foundation
import os.log

/// DRM 状态后台监视器。
///
/// 单纯轮询 FocusProbe 当前焦点是否命中 DRM 黑名单（无 SCK 调用，避免在 DRM
/// 期间触发系统的"录屏正在保护内容"黑屏副作用）。
///
/// 输出：`AsyncStream<Bool>` —— `true` = DRM 当前命中（采集应暂停），
/// `false` = 已清除（可恢复）。
///
/// 抄 My-Orphies drm_detector.rs::poll_drm_clear 思路：用 AX/NSWorkspace
/// 检查，不碰 SCK。
actor DRMWatcher {

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "drm")
    private let focus: FocusProbe
    private let gate: DRMGate
    private let intervalSeconds: TimeInterval

    private var task: Task<Void, Never>?
    private var lastBlocked: Bool = false

    /// 当前轮询循环用的 continuation。每次 start() 重建(见下)。
    private var _continuation: AsyncStream<Bool>.Continuation?

    init(focus: FocusProbe, gate: DRMGate = DRMGate(), intervalSeconds: TimeInterval = 3) {
        self.focus = focus
        self.gate = gate
        self.intervalSeconds = intervalSeconds
    }

    /// 启动轮询,返回一条**新的** DRM 状态流。
    ///
    /// **每次 start 都重建流**:本 watcher 实例被 CaptureCoordinator 跨 capture
    /// off/on toggle 复用,而 stop() 会 `finish()` 掉旧流。复用同一条已 finish 的流
    /// 再 start,信号永远送不出去 → DRM 命中后无法恢复采集。镜像 EventSources.start()
    /// / SleepWakeBox.start() 的「start 返回新流」模式。
    ///
    /// `lastBlocked` 故意不重置:它和 CaptureCoordinator.drmActive 跨 toggle 一起保留、
    /// 始终镜像当前 DRM 状态;重建的只是信号通道,下一次状态翻转照常发出。
    func start() -> AsyncStream<Bool> {
        task?.cancel()
        _continuation?.finish()
        var c: AsyncStream<Bool>.Continuation!
        let stream = AsyncStream<Bool> { cont in c = cont }
        _continuation = c
        task = Task.detached(priority: .background) { [weak self] in
            await self?.loop()
        }
        logger.info("DRMWatcher started (interval=\(self.intervalSeconds)s)")
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
        _continuation?.finish()
        _continuation = nil
        logger.info("DRMWatcher stopped")
    }

    /// CaptureCoordinator 的即时兜底路径(captureOneFrame 里 3s 轮询来不及时直接
    /// 把 drmActive 置 true)调用 —— 给轮询器补记一笔 `lastBlocked = true`。否则
    /// 轮询器的 lastBlocked 还停在 false,等 DRM 内容消失时 `false != false` 不成立、
    /// 永远不发 clear 事件 → drmActive 永久锁死、采集再也不恢复。
    func noteInlineBlock() {
        lastBlocked = true
    }

    // MARK: - 私有

    private func loop() async {
        let intervalNs = UInt64(intervalSeconds * 1_000_000_000)
        while !Task.isCancelled {
            let info = await focus.snapshot()
            let blocked = gate.isBlocked(info)
            if blocked != lastBlocked {
                lastBlocked = blocked
                logger.info("DRM state changed → \(blocked ? "BLOCKED" : "CLEAR", privacy: .public)")
                _continuation?.yield(blocked)
            }
            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }
}
