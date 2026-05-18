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

    nonisolated let states: AsyncStream<Bool>
    private let _continuation: AsyncStream<Bool>.Continuation

    init(focus: FocusProbe, gate: DRMGate = DRMGate(), intervalSeconds: TimeInterval = 3) {
        self.focus = focus
        self.gate = gate
        self.intervalSeconds = intervalSeconds
        var c: AsyncStream<Bool>.Continuation!
        self.states = AsyncStream<Bool> { cont in c = cont }
        self._continuation = c
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .background) { [weak self] in
            await self?.loop()
        }
        logger.info("DRMWatcher started (interval=\(self.intervalSeconds)s)")
    }

    func stop() {
        task?.cancel()
        task = nil
        _continuation.finish()
        logger.info("DRMWatcher stopped")
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
                _continuation.yield(blocked)
            }
            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }
}
