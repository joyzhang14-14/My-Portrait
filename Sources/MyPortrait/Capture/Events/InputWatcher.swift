import AppKit
import Foundation
import os.log

/// 全局键盘 / 鼠标事件 → .typingPause / .typingBurst / .scrollStop / .click。
///
/// 用 `NSEvent.addGlobalMonitorForEvents`（CGEventTap 的高层包装）。
/// 需要"输入监控"权限（macOS 10.15+：System Settings → Privacy → Input Monitoring）。
/// 权限缺失时静默降级 —— 只有 workspace 切换会触发抓帧。
///
/// 规则：
///   - 按下 Return / Enter → **立即**发 .typingPause(敲回车 = 一个动作完成,
///     发消息 / 换行 / 提交,越快抓帧越好)。连发防抖交给 CaptureCoordinator 的
///     minCaptureIntervalMs(200ms)+ 画面去重。
///   - **持续打字爆发**:从开始打字起计,10s 窗口内累计 ≥25 次按键 → 发 .typingBurst
///     (长段输入即使没敲回车也抓一帧)。停手 >5s 或切 app → 计数清零重来。
///   - 滚轮事件后 300ms 内无新滚轮 → 发 .scrollStop
///   - 左键点击 → 立即发 .click（无防抖）
@MainActor
final class InputWatcher {

    private let emit: @Sendable (CaptureTrigger) -> Void
    private let scrollStopMs: Int
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "input")

    private var monitor: Any?
    private var scrollDebounceTask: Task<Void, Never>?
    private var appSwitchObserver: NSObjectProtocol?

    /// keyCode：36 = Return，76 = 小键盘 Enter。
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    // —— 持续打字爆发参数 ——
    /// 累计窗口:从这段第一键算起 10s 内要凑够阈值。
    private static let burstWindowSec: TimeInterval = 10
    /// 触发阈值:窗口内 ≥25 次按键。
    private static let burstThreshold = 25
    /// 停手多久算"这段结束"→ 下次按键重新开始计数。
    private static let burstIdleResetSec: TimeInterval = 5

    private var burstCount = 0
    private var burstStartedAt: Date?
    private var lastKeyAt: Date?
    /// 上一次按键的 keyCode —— 连续 Return 判定用(上一击也是 Return → 这次不拍)。
    private var lastKeyCode: UInt16?

    init(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        scrollStopMs: Int = 300
    ) {
        self.emit = emit
        self.scrollStopMs = scrollStopMs
    }

    func start() {
        guard monitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .scrollWheel]
        let handle = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }

        if handle == nil {
            logger.warning("Input monitor not granted — typing / click / scroll triggers will be silent. Grant in System Settings → Privacy & Security → Input Monitoring.")
        }
        monitor = handle

        // 切 app(session 切换)→ 持续打字计数清零:换了上下文就别把上一段的
        // 按键数带过来。WorkspaceWatcher 也监听同一个通知(各取所需,互不影响)。
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetBurst() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        scrollDebounceTask?.cancel()
        scrollDebounceTask = nil
        if let o = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        appSwitchObserver = nil
        resetBurst()
    }

    // MARK: - 私有

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let now = Date()
            // 停手 >5s → 上一段结束:连续 Return 判定 + 持续打字计数都从头来。
            if let last = lastKeyAt, now.timeIntervalSince(last) > Self.burstIdleResetSec {
                resetBurst()
            }
            let prevKeyCode = lastKeyCode   // resetBurst 后为 nil
            lastKeyAt = now
            lastKeyCode = event.keyCode

            // ① Return / Enter 瞬间触发 —— 但上一击键也是 Return 就跳过
            //(防有人一直换行刷屏 / 卡 bug)。
            let isReturn = Self.returnKeyCodes.contains(event.keyCode)
            let prevWasReturn = prevKeyCode.map(Self.returnKeyCodes.contains) ?? false
            if isReturn && !prevWasReturn {
                emit(.typingPause)
            }
            // ② 所有按键(含 Return)都计入"持续打字爆发"。
            countTypingBurst(now)

        case .leftMouseDown:
            emit(.click)

        case .scrollWheel:
            scrollDebounceTask?.cancel()
            let ms = scrollStopMs
            let e = emit
            scrollDebounceTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if !Task.isCancelled { e(.scrollStop) }
            }

        default:
            break
        }
    }

    /// 持续打字计数(停手 >5s 的段落重置已在 handle 顶部做过)。10s 窗口内凑够
    /// 25 键 → 发 .typingBurst 并清零(下一段重新数)。`now` 由 handle 传入,跟
    /// 连续 Return 判定共用同一个时间戳。
    private func countTypingBurst(_ now: Date) {
        if burstStartedAt == nil {
            burstStartedAt = now
            burstCount = 0
        }
        // 这一段超过 10s 还没凑够 → 从当前键重开窗口(只认"10s 内"的爆发)。
        if let start = burstStartedAt, now.timeIntervalSince(start) > Self.burstWindowSec {
            burstStartedAt = now
            burstCount = 0
        }
        burstCount += 1
        if burstCount >= Self.burstThreshold {
            emit(.typingBurst)
            resetBurst()   // 触发后清零,下一段重新数
        }
    }

    private func resetBurst() {
        burstCount = 0
        burstStartedAt = nil
        lastKeyAt = nil
        lastKeyCode = nil
    }
}
