import Foundation
import CoreGraphics
import ApplicationServices
import QuartzCore
import Carbon.HIToolbox
import os.log
import os.lock

/// Typing Observer v2 — Layer 1 「人类心跳层」。
///
/// 全局监听 keyDown（CGEventTap, **listenOnly** —— spec 强调：default 模式
/// 进程卡顿会冻死整机键盘），把时间戳写进 64 槽固定长度环形缓冲；
/// 只暴露 `hasKeystroke(within:)` / `recentTimestamps(within:)` 给上层判定。
///
/// 时间戳源：`CACurrentMediaTime()`（单调时钟，不受 NTP 跳变影响），
/// 内部存 ms `Int64`。
///
/// 线程模型：
/// - 起一条后台 `Thread`，它的 main 里把 EventTap source 加进
///   `CFRunLoopGetCurrent()` 并 `CFRunLoopRun()`。
/// - 回调在该后台线程被触发 → 写 buffer。
/// - 主线程读 buffer。
/// - `os_unfair_lock` 保护 buffer，持锁时只扫描 64 个 Int64，O(64) μs 级。
final class KeystrokeLedger {

    // MARK: - 环形缓冲

    private static let capacity = 64
    private var buffer: [Int64] = Array(repeating: 0, count: KeystrokeLedger.capacity)
    private var writeIdx: Int = 0
    private var lock = os_unfair_lock_s()

    /// 最近一次 ⌘V / Shift+⌘V 的时间戳（ms，单调时钟）。0 = 还没发生过。
    /// 粘贴不是「打字」，不进 `buffer`；但上层（TypingObserver）需要知道
    /// 「这次 value 变化是不是粘贴触发的」，故单独记一个时刻。`lock` 同护。
    private var lastPasteMs: Int64 = 0

    /// 最近一次 ⌘X(cut)/ ⌘C(copy)/ ⌘Z(undo)/ ⌘⇧Z(redo) 时间戳。
    /// 给 TypingRecordWriter 判用户在重组自己内容 vs 粘外人内容用。
    private var lastCutMs: Int64 = 0
    private var lastCopyMs: Int64 = 0
    private var lastUndoMs: Int64 = 0
    private var lastRedoMs: Int64 = 0

    /// 最近一次回车键（Return / 小键盘 Enter）的时间戳（ms，单调时钟）。
    /// 聊天 app 里回车 = 发送消息 → 输入框被清空。上层据此把「输入框清空」
    /// 判定为发送而非删除。`lock` 同护。
    private var lastSubmitMs: Int64 = 0

    // MARK: - CGEventTap / 后台线程

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    /// 后台线程 RunLoop 引用 —— stop() 时跨线程 CFRunLoopStop 它。
    private var tapRunLoop: CFRunLoop?
    /// thread 启动 / 退出同步。
    private let startedSem = DispatchSemaphore(value: 0)
    private let stoppedSem = DispatchSemaphore(value: 0)

    private(set) var isRunning: Bool = false

    /// 最近一次收到 keyDown 的时间(单调时钟 ms)。健康检查用 ——
    /// healthMonitorTimer 每 5 min 看 tap.isEnabled + 这个值。
    private var lastKeystrokeMonoMs: Int64 = 0
    /// 主线程定时器,每 5 分钟检查一次 tap 健康状态。
    private var healthCheckTimer: Timer?
    /// healthCheck 周期(秒)。也是"距上次 keystroke 多久算可疑"的阈值。
    private static let healthCheckIntervalSec: TimeInterval = 300

    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "typing.ledger")

    /// 可选 L3 字符 logger —— 挂上后,每次 keyDown callback 都会同步派一份给它。
    /// 生产路径由 TypingObserver 注入;dev/observe 模式不带。
    var charLogger: KeystrokeCharLogger?

    // MARK: - 生命周期

    init() {}

    /// 起 CGEventTap + 后台 thread + RunLoop。
    /// AX 未授权时不抛错也不崩，log warning，`isRunning` 保持 false，
    /// `hasKeystroke` 永远 false。
    func start() throws {
        guard !isRunning else { return }

        guard AXIsProcessTrusted() else {
            log.warning("AX not trusted — KeystrokeLedger stays idle, hasKeystroke() will always return false")
            return
        }

        // keyDown + tap-disabled 事件(后者收不进 mask 也会 fire,但显式加上更稳)
        let mask: CGEventMask =
              (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keystrokeLedgerTapCallback,
            userInfo: userInfo
        ) else {
            log.warning("CGEvent.tapCreate failed — KeystrokeLedger stays idle")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            log.warning("CFMachPortCreateRunLoopSource failed — KeystrokeLedger stays idle")
            return
        }

        self.eventTap = tap
        self.runLoopSource = source

        // 后台 dedicated thread 跑 RunLoop。
        // 用 Thread 子类，把 tap / source 当 stored property —— 这样
        // Thread.main 是普通方法，不是 @Sendable 闭包，绕开 CoreFoundation
        // 类型不 Sendable 的捕获警告。
        let thread = LedgerTapThread(
            owner: self,
            tap: tap,
            source: source
        )
        thread.name = "KeystrokeLedger.tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // 等线程把 RunLoop wire 起来，避免 stop() 抢跑。
        _ = startedSem.wait(timeout: .now() + 1.0)
        isRunning = true
        log.info("KeystrokeLedger started")

        // 起健康检查 timer:每 5 min 看 tap 还在不在 enable 状态。macOS 偶发
        // disable(已有 callback auto re-enable 兜底,但 callback 没被触发的
        // silent dead 也要查)。同时记录最近 keystroke 时间,长期 0 keystroke
        // + tap enabled = 用户离开,不报警;tap disabled = 主动 re-enable + 报警。
        startHealthCheck()
    }

    /// 起健康检查 timer(MainActor)。重复调用安全:旧 timer 先 invalidate。
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.healthCheckIntervalSec, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheckTick() }
        }
    }

    @MainActor
    private func healthCheckTick() {
        guard let tap = eventTap else { return }
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        os_unfair_lock_lock(&lock)
        let lastKey = lastKeystrokeMonoMs
        os_unfair_lock_unlock(&lock)
        let now = Self.nowMs()
        let idleMs = lastKey > 0 ? (now - lastKey) : Int64.max

        if !enabled {
            // 硬异常:tap 被 disable 了 —— 主动 re-enable + 红灯
            log.warning("HEALTH: CGEventTap disabled silently — re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            HealthMonitor.shared.report(
                component: "KeystrokeLedger.tap",
                reason: "tap disabled silently (no callback fired) — re-enabled. last keystroke \(idleMs)ms ago"
            )
            return
        }

        // tap 还活着:5 min 0 keystroke 只 log,不变红(可能用户离开)。
        // 但如果 30 分钟 0 keystroke 而你之前有过键击,值得 log warn。
        if lastKey > 0 && idleMs > Int64(Self.healthCheckIntervalSec * 1000 * 6) {
            log.warning("HEALTH: no keystroke for \(idleMs)ms (tap still enabled — likely user idle)")
        }
        // tap 健康 → 清掉之前可能存在的 fault
        HealthMonitor.shared.clear(component: "KeystrokeLedger.tap")
    }

    /// 停 tap，CFRunLoopStop，等 thread 退出。
    func stop() {
        guard isRunning else { return }
        isRunning = false

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        _ = stoppedSem.wait(timeout: .now() + 1.0)

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        log.info("KeystrokeLedger stopped")
    }

    /// macOS disable 了 tap 后调用,显式 re-enable。callback 内调。
    /// `reason` 仅用于 log,方便后续看哪类 disable 频发。
    fileprivate func reenableTap(reason: CGEventType) {
        guard let tap = eventTap else { return }
        let why = reason == .tapDisabledByTimeout ? "timeout" : "user_input"
        log.warning("CGEventTap disabled (\(why, privacy: .public)) — re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - 写入 / 查询

    /// 写一笔时间戳（callback 内调；单测也可直接注入）。
    func record(timestampMs: Int64) {
        os_unfair_lock_lock(&lock)
        buffer[writeIdx] = timestampMs
        writeIdx = (writeIdx + 1) % Self.capacity
        lastKeystrokeMonoMs = timestampMs
        os_unfair_lock_unlock(&lock)
    }

    /// 用「现在」当时间戳记一笔。
    func record() {
        record(timestampMs: Self.nowMs())
    }

    /// 记一次粘贴（⌘V / Shift+⌘V）。callback 内调。
    func recordPaste() {
        os_unfair_lock_lock(&lock)
        lastPasteMs = Self.nowMs()
        os_unfair_lock_unlock(&lock)
    }

    func recordCut() {
        os_unfair_lock_lock(&lock); lastCutMs = Self.nowMs(); os_unfair_lock_unlock(&lock)
    }
    func recordCopy() {
        os_unfair_lock_lock(&lock); lastCopyMs = Self.nowMs(); os_unfair_lock_unlock(&lock)
    }
    func recordUndo() {
        os_unfair_lock_lock(&lock); lastUndoMs = Self.nowMs(); os_unfair_lock_unlock(&lock)
    }
    func recordRedo() {
        os_unfair_lock_lock(&lock); lastRedoMs = Self.nowMs(); os_unfair_lock_unlock(&lock)
    }

    /// 最近 `seconds` 秒内是否发生过粘贴。TypingObserver 用它判定某次
    /// value 变化是不是 ⌘V 触发的（→ 不是打字，进黑名单）。
    func hasPaste(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs()
        let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock)
        let p = lastPasteMs
        os_unfair_lock_unlock(&lock)
        return p > 0 && p >= cutoff && p <= now
    }

    func hasCut(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs(); let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock); let p = lastCutMs; os_unfair_lock_unlock(&lock)
        return p > 0 && p >= cutoff && p <= now
    }
    func hasCopy(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs(); let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock); let p = lastCopyMs; os_unfair_lock_unlock(&lock)
        return p > 0 && p >= cutoff && p <= now
    }
    func hasUndo(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs(); let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock); let p = lastUndoMs; os_unfair_lock_unlock(&lock)
        return p > 0 && p >= cutoff && p <= now
    }
    func hasRedo(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs(); let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock); let p = lastRedoMs; os_unfair_lock_unlock(&lock)
        return p > 0 && p >= cutoff && p <= now
    }

    /// 记一次回车键（Return / 小键盘 Enter）。callback 内调。
    func recordSubmit() {
        os_unfair_lock_lock(&lock)
        lastSubmitMs = Self.nowMs()
        os_unfair_lock_unlock(&lock)
    }

    /// 最近 `seconds` 秒内是否按过回车。TypingObserver 用它判定「输入框清空」
    /// 是发送消息（→ 不是删除，保留）还是真删除。
    func hasSubmitKey(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs()
        let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock)
        let s = lastSubmitMs
        os_unfair_lock_unlock(&lock)
        return s > 0 && s >= cutoff && s <= now
    }

    /// 清掉最近回车记录 —— 一次发送只触发一次，处理过即作废。
    func consumeSubmit() {
        os_unfair_lock_lock(&lock)
        lastSubmitMs = 0
        os_unfair_lock_unlock(&lock)
    }

    /// 最近 `seconds` 秒内是否有击键。
    /// 边界用 `<=` —— 精确 seconds 秒前那一笔仍算 hit。
    func hasKeystroke(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs()
        let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for ts in buffer {
            if ts > 0 && ts >= cutoff && ts <= now {
                return true
            }
        }
        return false
    }

    /// 最近 `seconds` 秒内的时间戳列表（升序）。给 dev flag 打分布用。
    func recentTimestamps(within seconds: TimeInterval) -> [Int64] {
        let now = Self.nowMs()
        let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock)
        let snapshot = buffer
        os_unfair_lock_unlock(&lock)
        return snapshot
            .filter { $0 > 0 && $0 >= cutoff && $0 <= now }
            .sorted()
    }

    // MARK: - 后台 thread 回调

    fileprivate func attachRunLoop(_ rl: CFRunLoop) { self.tapRunLoop = rl }
    fileprivate func signalStarted() { startedSem.signal() }
    fileprivate func signalStopped() { stoppedSem.signal() }

    // MARK: - 时间源

    /// CACurrentMediaTime → ms `Int64`。单调时钟，不受 NTP 影响。
    static func nowMs() -> Int64 {
        Int64(CACurrentMediaTime() * 1000.0)
    }
}

// MARK: - 后台 Thread 子类

/// 跑 CGEventTap RunLoop 的后台线程。
/// 用子类避开「@Sendable 闭包捕获 CF 类型」的 Swift 6 警告 —— main() 是
/// 普通方法，不是闭包。
private final class LedgerTapThread: Thread {
    weak var owner: KeystrokeLedger?
    let tap: CFMachPort
    let source: CFRunLoopSource

    init(owner: KeystrokeLedger, tap: CFMachPort, source: CFRunLoopSource) {
        self.owner = owner
        self.tap = tap
        self.source = source
        super.init()
    }

    override func main() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        owner?.attachRunLoop(runLoop)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        owner?.signalStarted()
        CFRunLoopRun()
        owner?.signalStopped()
    }
}

// MARK: - C callback

/// CGEventTap callback —— 跑在后台 dedicated thread。
/// listenOnly 模式也必须 `return Unmanaged.passUnretained(event)`。
/// ⌘V / Shift+⌘V 不算「打字」，不更新 ledger。
private func keystrokeLedgerTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // macOS 可能因 callback 慢 / 系统压力 disable tap。必须显式 re-enable,
    // 否则后续所有键都收不到(这是 5/22-5/23 大段 keystroke_log 空洞的真因)。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let ledger = Unmanaged<KeystrokeLedger>.fromOpaque(userInfo).takeUnretainedValue()
            ledger.reenableTap(reason: type)
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let ledger = Unmanaged<KeystrokeLedger>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let hasCmd = flags.contains(.maskCommand)
    let hasShift = flags.contains(.maskShift)
    // ⌘+key shortcuts(忽略 ctrl/opt 修饰组合,只识别纯 cmd / cmd+shift)
    let isPaste  = hasCmd && keyCode == Int64(kVK_ANSI_V)
    let isCut    = hasCmd && keyCode == Int64(kVK_ANSI_X)
    let isCopy   = hasCmd && keyCode == Int64(kVK_ANSI_C)
    let isUndoOrRedo = hasCmd && keyCode == Int64(kVK_ANSI_Z)
    let isRedo   = isUndoOrRedo && hasShift
    let isUndo   = isUndoOrRedo && !hasShift
    // Shift+Return 在多数 app 里是换行，不是发送 —— 不算提交信号。
    let isReturn = (keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter))
        && !hasShift
    if isPaste {
        ledger.recordPaste()
    } else if isCut {
        ledger.recordCut()
    } else if isCopy {
        ledger.recordCopy()
    } else if isRedo {
        ledger.recordRedo()
    } else if isUndo {
        ledger.recordUndo()
    } else {
        ledger.record()
        // 回车既是普通击键，也是「提交/发送」信号 —— 额外记一笔。
        if isReturn { ledger.recordSubmit() }
    }

    // L3 字符日志 —— 挂了 charLogger 就同步派一份。kVK_Delete 是退格(后退),
    // kVK_ForwardDelete 是 Fn+Delete(前删),都算「删字符」。
    if let charLogger = ledger.charLogger {
        let isBackspace = (keyCode == Int64(kVK_Delete) || keyCode == Int64(kVK_ForwardDelete))
        charLogger.ingest(event: event, isBackspace: isBackspace)
    }
    return Unmanaged.passUnretained(event)
}
