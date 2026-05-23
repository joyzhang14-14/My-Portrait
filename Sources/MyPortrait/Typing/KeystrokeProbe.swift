import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import QuartzCore
import os.log

/// 调研用 probe —— 只在 DEBUG build 起。
///
/// 跟 `KeystrokeLedger` 平行(独立的 CGEventTap),抓键码 + Unicode 字符 +
/// 当前焦点 app,落 JSONL 到 `~/Library/Logs/MyPortrait/keystroke-probe.jsonl`。
///
/// 用途:验证 CGEventTap 路径下能拿到什么,具体回答
/// `current-arch-and-blockers.md` 的 Q-A:
///   - 英文打字:能拿字符吗?(预期能)
///   - 中文 IME 合成期间:`CGEventKeyboardGetUnicodeString` 返回什么?
///     (预期是拼音的 raw chars,不是合成后的汉字 —— CGEventTap 在 IME 之前)
///   - secure field / 密码框:看不看得到?
///   - 各种 app(原生 / Electron / Web / 终端 / Docs canvas)行为一致吗?
///
/// 实现复刻 `KeystrokeLedger` 的 tap 设置(后台 dedicated thread + CFRunLoop
/// + listenOnly),不动 ledger,保证独立可拆。
final class KeystrokeProbe {

    // MARK: - CGEventTap / 后台线程

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let startedSem = DispatchSemaphore(value: 0)
    private let stoppedSem = DispatchSemaphore(value: 0)

    private(set) var isRunning: Bool = false

    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "typing.probe")

    // MARK: - 日志输出

    private static let logURL: URL = {
        let dir = NSString(string: "~/Library/Logs/MyPortrait").expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir).appendingPathComponent("keystroke-probe.jsonl")
    }()

    private var fileHandle: FileHandle?
    private let writeLock = NSLock()

    // MARK: - 生命周期

    init() {}

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            log.warning("AX not trusted — KeystrokeProbe stays idle")
            return
        }

        // 打开日志文件 —— 追加模式。
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: Self.logURL)
            try fileHandle?.seekToEnd()
        } catch {
            log.warning("open log fail: \(String(describing: error), privacy: .public)")
            return
        }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keystrokeProbeTapCallback,
            userInfo: userInfo
        ) else {
            log.warning("tapCreate failed — probe stays idle")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            log.warning("CFMachPortCreateRunLoopSource failed")
            return
        }

        self.eventTap = tap
        self.runLoopSource = source

        let thread = ProbeTapThread(owner: self, tap: tap, source: source)
        thread.name = "KeystrokeProbe.tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        _ = startedSem.wait(timeout: .now() + 1.0)
        isRunning = true

        writeBanner()
        log.info("KeystrokeProbe started, log -> \(Self.logURL.path, privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = tapRunLoop { CFRunLoopStop(rl) }
        _ = stoppedSem.wait(timeout: .now() + 1.0)
        eventTap = nil; runLoopSource = nil; tapRunLoop = nil; tapThread = nil
        try? fileHandle?.close()
        fileHandle = nil
        log.info("KeystrokeProbe stopped")
    }

    // MARK: - 写入

    private func writeBanner() {
        let banner: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "event": "_probe_start",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        writeJSON(banner)
    }

    fileprivate func writeJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        writeLock.lock(); defer { writeLock.unlock() }
        guard let h = fileHandle, let bytes = line.data(using: .utf8) else { return }
        do {
            try h.write(contentsOf: bytes)
        } catch {
            log.warning("write fail: \(String(describing: error), privacy: .public)")
        }
    }

    fileprivate func attachRunLoop(_ rl: CFRunLoop) { self.tapRunLoop = rl }
    fileprivate func signalStarted() { startedSem.signal() }
    fileprivate func signalStopped() { stoppedSem.signal() }
}

// MARK: - 后台 Thread 子类

private final class ProbeTapThread: Thread {
    weak var owner: KeystrokeProbe?
    let tap: CFMachPort
    let source: CFRunLoopSource

    init(owner: KeystrokeProbe, tap: CFMachPort, source: CFRunLoopSource) {
        self.owner = owner; self.tap = tap; self.source = source
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

private func keystrokeProbeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let probe = Unmanaged<KeystrokeProbe>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    // 关键测试点:`CGEventKeyboardGetUnicodeString` 在 IME 合成时返回什么?
    var length = 0
    var unicodeBuffer = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(
        maxStringLength: 8, actualStringLength: &length, unicodeString: &unicodeBuffer)
    let chars = length > 0
        ? String(utf16CodeUnits: unicodeBuffer, count: length)
        : ""

    // 当前焦点 app —— frontmostApplication 读 cached 值,这里非主线程读,
    // 实测稳定;probe 是调研用,不追求严格线程安全。
    let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

    probe.writeJSON([
        "ts": Date().timeIntervalSince1970,
        "event": "keyDown",
        "keyCode": keyCode,
        "modifiers": flags.rawValue,
        "characters": chars,
        "charsHex": chars.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "),
        "app": app,
        "isARepeat": isRepeat,
    ])

    return Unmanaged.passUnretained(event)
}
