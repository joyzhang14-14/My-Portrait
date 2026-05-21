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

    /// 最近一次「提交键」（Return / 小键盘 Enter）的时间戳（ms）。0 = 还没按过。
    /// 单个变量即够 —— Layer 3 的 submit_close 只关心「刚刚有没有按提交键」。
    /// 跟 buffer 共用 `lock` 保护。纯 Enter 和 ⌘+Enter 都算提交，不看修饰键。
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

    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "typing.ledger")

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

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
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
    }

    /// 停 tap，CFRunLoopStop，等 thread 退出。
    func stop() {
        guard isRunning else { return }
        isRunning = false

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

    // MARK: - 写入 / 查询

    /// 写一笔时间戳（callback 内调；单测也可直接注入）。
    func record(timestampMs: Int64) {
        os_unfair_lock_lock(&lock)
        buffer[writeIdx] = timestampMs
        writeIdx = (writeIdx + 1) % Self.capacity
        os_unfair_lock_unlock(&lock)
    }

    /// 用「现在」当时间戳记一笔。
    func record() {
        record(timestampMs: Self.nowMs())
    }

    /// 记一次「提交键」按下（callback 内调；单测也可直接注入）。
    func recordSubmit(timestampMs: Int64) {
        os_unfair_lock_lock(&lock)
        lastSubmitMs = timestampMs
        os_unfair_lock_unlock(&lock)
    }

    /// 最近 `seconds` 秒内是否按过提交键（Return / 小键盘 Enter）。
    /// 边界 `<=`，与 `hasKeystroke` 同款。
    func hasSubmitKey(within seconds: TimeInterval) -> Bool {
        let now = Self.nowMs()
        let cutoff = now - Int64(seconds * 1000.0)
        os_unfair_lock_lock(&lock)
        let ts = lastSubmitMs
        os_unfair_lock_unlock(&lock)
        return ts > 0 && ts >= cutoff && ts <= now
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
    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let ledger = Unmanaged<KeystrokeLedger>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isPaste = flags.contains(.maskCommand) && keyCode == Int64(kVK_ANSI_V)
    if !isPaste {
        ledger.record()
    }
    // 提交键检测：纯 Return / 小键盘 Enter 都算提交，不看 ⌘ 修饰键
    // （Slack 等 ⌘+Enter 发送也要算）。
    if keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) {
        ledger.recordSubmit(timestampMs: KeystrokeLedger.nowMs())
    }
    return Unmanaged.passUnretained(event)
}
