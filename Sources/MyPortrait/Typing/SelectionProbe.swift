import Foundation
import AppKit
import ApplicationServices
import os.log

/// 调研用 probe —— 只在 DEBUG build 起。
///
/// 每 100ms 轮询当前焦点元素的:
///   - `kAXSelectedTextAttribute`         —— 选中的文本(关键:删之前选了什么)
///   - `kAXSelectedTextRangeAttribute`    —— 选中范围 / 光标位置
///   - `kAXNumberOfCharactersAttribute`   —— 焦点元素总字符数
///   - `kAXValueAttribute` 的前 80 字符    —— 跟 AXSelectedText 对照
///   - `kAXRoleAttribute`                 —— 焦点元素类型
///
/// 只在 selectedText 或 range 变化时落日志,纯光标移动也算 range 变,
/// 但会过滤掉「跟上次完全一样」的重复采样。
///
/// 跟 KeystrokeProbe(同时间戳)结合,能验证:
///   - 用户「选中 X → 按 backspace」时,从 selectedText 能取回 X 吗?
///   - canvas 编辑器(Google Docs)里这条路径有没有用?
///   - 各类 app 行为差异
///
/// 落到 `~/Library/Logs/MyPortrait/selection-probe.jsonl`。
final class SelectionProbe {

    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "selection.probe")

    private static let logURL: URL = {
        let dir = NSString(string: "~/Library/Logs/MyPortrait").expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir).appendingPathComponent("selection-probe.jsonl")
    }()

    private var fileHandle: FileHandle?
    private let writeLock = NSLock()

    private var timer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.myportrait.selection-probe.poll")

    private(set) var isRunning: Bool = false

    /// 上一次采样的状态,用于去重。
    private var lastSelected: String = "<<INIT>>"
    private var lastRangeStr: String = ""

    init() {}

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            log.warning("AX not trusted — SelectionProbe stays idle")
            return
        }

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

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + .milliseconds(300),
                       repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer

        isRunning = true
        writeJSON([
            "ts": Date().timeIntervalSince1970,
            "event": "_probe_start",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ])
        log.info("SelectionProbe started, log -> \(Self.logURL.path, privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        try? fileHandle?.close()
        fileHandle = nil
        log.info("SelectionProbe stopped")
    }

    // MARK: - 采样

    private func sample() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier ?? "unknown"

        // 跟 TypingObserver / FocusProbe 共串 AX 队列,避免并发抢 AX。
        // sync —— 持锁修改 lastSelected/lastRangeStr,自洽。
        AXSerialQueue.shared.sync {
            self.readAndLog(pid: pid, bundleId: bid)
        }
    }

    private func readAndLog(pid: pid_t, bundleId: String) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        // focused element
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return }
        // swiftlint:disable:next force_cast
        let focused = focusedRef as! AXUIElement

        // role
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"

        // selected text
        var selRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, &selRef)
        let selectedText = (selRef as? String) ?? ""

        // selected range
        var rangeRef: CFTypeRef?
        var rangeStr = "?"
        if AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let val = rangeRef, CFGetTypeID(val) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            // swiftlint:disable:next force_cast
            if AXValueGetValue(val as! AXValue, .cfRange, &range) {
                rangeStr = "\(range.location)+\(range.length)"
            }
        }

        // number of characters in focused element
        var numCharsRef: CFTypeRef?
        var numChars = -1
        if AXUIElementCopyAttributeValue(
            focused, kAXNumberOfCharactersAttribute as CFString, &numCharsRef) == .success,
           let n = numCharsRef as? Int {
            numChars = n
        }

        // value preview (跟 AXSelectedText 对照,canvas 里这个常常很短/无用)
        var valueRef: CFTypeRef?
        var valueLen = 0
        var valuePreview = ""
        if AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef) == .success,
           let v = valueRef as? String {
            valueLen = v.count
            valuePreview = String(v.prefix(80))
        }

        // 去重
        if selectedText == lastSelected && rangeStr == lastRangeStr {
            return
        }
        lastSelected = selectedText
        lastRangeStr = rangeStr

        writeJSON([
            "ts": Date().timeIntervalSince1970,
            "app": bundleId,
            "role": role,
            "selectedText": selectedText,
            "selectedTextHex": selectedText.unicodeScalars
                .map { String(format: "U+%04X", $0.value) }.joined(separator: " "),
            "selectedRange": rangeStr,
            "numChars": numChars,
            "valueLen": valueLen,
            "valuePreview": valuePreview,
        ])
    }

    // MARK: - JSONL

    private func writeJSON(_ payload: [String: Any]) {
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
}
