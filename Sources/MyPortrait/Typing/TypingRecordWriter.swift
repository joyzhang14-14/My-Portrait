import Foundation
import QuartzCore

/// Typing Observer v2 — Layer 4 写入层（v14 event-log 模型）。
///
/// 一个 (app, element) 一段 in-progress session。每次 AX value-change 经
/// 350ms debounce 收敛后，`TextDiff.sandwich(上次快照, 当前值)` 出 delta
/// 记进 `editLog`。session flush 时 **INSERT 一条新 record**（append-only，
/// immutable）。
///
/// `text` 字段 = `sandwich(sessionStart, 最终值).newMid` —— 即这段 session
/// 用户**净新增**的内容。session 开始时 element 已有的旧内容（`sessionStart`）
/// 不进 `text`（修「中段编辑把整篇笔记吸进 text」的 bug）。
/// `editLog` 是逐 debounce 窗口的编辑流水，记录编辑过程。
///
/// `@MainActor` —— 只被 `TypingObserver`（MainActor）与它的 Timer 驱动。
@MainActor
final class TypingRecordWriter {

    /// state / 黑名单 的 key —— per (app 进程, element)。
    struct ElementKey: Hashable {
        let pid: pid_t
        let elementHash: Int
    }

    /// 一个 (app, element) 的 in-progress 输入 session。
    final class InProgressRecord {
        let bundleId: String
        let elementHash: Int
        let startedAtMs: Int64
        var lastEventMs: Int64

        /// session 开始时 element 已有的内容（immutable）。不进最终 `text`。
        let sessionStart: String
        /// 该 element 最近一次 AX 完整 value。
        var lastValueSnapshot: String
        var lastValueChangeTs: TimeInterval
        /// 逐 debounce 窗口的编辑流水。
        var editLog: [EditEntry]

        /// debounce 窗口内最近一次 AX value。
        var pendingValue: String?
        var windowHadBurst = false
        var windowHadPaste = false
        var windowHadKeystroke = false

        var debounceTimer: Timer?
        var flushTimer: Timer?
        var pendingChanges = false

        init(bundleId: String, elementHash: Int, sessionStart: String, nowMs: Int64) {
            self.bundleId = bundleId
            self.elementHash = elementHash
            self.startedAtMs = nowMs
            self.lastEventMs = nowMs
            self.sessionStart = sessionStart
            self.lastValueSnapshot = sessionStart
            self.lastValueChangeTs = CACurrentMediaTime()
            self.editLog = []
        }
    }

    // MARK: - 硬编码参数（M5 统一挪进 ConfigStore）

    static let burstCharThreshold = 10
    static let burstIntervalMs: Double = 30
    static let blacklistTTLSec: TimeInterval = 3600
    static let debounceSec: TimeInterval = 0.350
    static let flushSec: TimeInterval = 5.0
    static let pasteAssocSec: TimeInterval = 0.5
    static let submitAssocSec: TimeInterval = 1.0

    // MARK: - 状态

    private let store: TypingEventStore?
    private let ledger: KeystrokeLedger
    var onDevLog: ((String) -> Void)?

    private(set) var state: [ElementKey: InProgressRecord] = [:]
    /// 黑名单 per (app, element)：噪声 segment → 命中时刻（CACurrentMediaTime）。
    private(set) var blacklist: [ElementKey: [String: TimeInterval]] = [:]

    init(store: TypingEventStore?, ledger: KeystrokeLedger) {
        self.store = store
        self.ledger = ledger
    }

    /// UTC 毫秒 —— started_at / ended_at / edit_log ts 都用它。
    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    // MARK: - session 生命周期

    /// element 获得焦点 → 开一段新 session。`baseline` = 此刻 AX 完整 value。
    func beginSession(key: ElementKey, bundleId: String, baseline: String) {
        flushElement(key)   // 若有旧 record，先 flush 落库 + 移除
        state[key] = InProgressRecord(bundleId: bundleId, elementHash: key.elementHash,
                                      sessionStart: baseline, nowMs: Self.nowMs())
    }

    /// 一次 AX value-change。存进 pendingValue + 重排 350ms debounce。
    func noteValueChange(key: ElementKey, newValue: String) {
        guard let rec = state[key] else { return }

        // 发送检测：输入框被清空 + 之前有内容 + 刚按过回车 = 聊天 app 发出消息。
        if newValue.isEmpty {
            let msg = rec.pendingValue ?? rec.lastValueSnapshot
            if !msg.isEmpty, ledger.hasSubmitKey(within: Self.submitAssocSec) {
                handleSubmit(key: key, rec: rec, fullValue: msg)
                return
            }
        }

        let now = CACurrentMediaTime()
        let intervalMs = (now - rec.lastValueChangeTs) * 1000.0
        let prevSeen = rec.pendingValue ?? rec.lastValueSnapshot
        if Self.isBurst(jumpChars: abs(newValue.count - prevSeen.count), intervalMs: intervalMs) {
            rec.windowHadBurst = true
        }
        let corrWindowSec =
            Double(ConfigStore.shared.recording.typingKeyCorrelationWindowMs) / 1000.0
        if ledger.hasKeystroke(within: corrWindowSec) { rec.windowHadKeystroke = true }
        if ledger.hasPaste(within: Self.pasteAssocSec) { rec.windowHadPaste = true }

        rec.lastValueChangeTs = now
        rec.pendingValue = newValue
        rec.debounceTimer?.invalidate()
        rec.debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceSec, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDebounce(key) }
        }
    }

    // MARK: - debounce 触发 → editLog

    private func fireDebounce(_ key: ElementKey) {
        guard let rec = state[key], let pending = rec.pendingValue else { return }
        rec.debounceTimer = nil
        rec.pendingValue = nil
        let prev = rec.lastValueSnapshot
        guard prev != pending else { return }

        let noise = rec.windowHadBurst || rec.windowHadPaste || !rec.windowHadKeystroke
        rec.windowHadBurst = false
        rec.windowHadPaste = false
        rec.windowHadKeystroke = false
        rec.lastValueSnapshot = pending

        let (_, deleted, added, _) = TextDiff.sandwich(prev: prev, new: pending)
        let nowMs = Self.nowMs()
        if noise {
            // burst / 粘贴 / 程序输出 —— 新增段进黑名单，flush 时从 text 减掉，
            // 不进 editLog。
            if !added.isEmpty {
                blacklist[key, default: [:]][added] = CACurrentMediaTime()
                onDevLog?("noise→blacklist bundle=\(rec.bundleId) \(added.count) chars")
            }
        } else {
            if !deleted.isEmpty {
                rec.editLog.append(EditEntry(ts: nowMs, kind: "delete", text: deleted))
            }
            if !added.isEmpty {
                rec.editLog.append(EditEntry(ts: nowMs, kind: "commit", text: added))
            }
        }
        rec.lastEventMs = nowMs
        rec.pendingChanges = true
        scheduleFlush(rec, key: key)
    }

    // MARK: - 发送

    /// 聊天 app 回车发送 —— 输入框清空。`fullValue` = 清空前的完整内容。
    private func handleSubmit(key: ElementKey, rec: InProgressRecord, fullValue: String) {
        rec.debounceTimer?.invalidate()
        rec.debounceTimer = nil
        rec.lastValueSnapshot = fullValue
        let (_, _, message, _) = TextDiff.sandwich(prev: rec.sessionStart, new: fullValue)
        rec.editLog.append(EditEntry(ts: Self.nowMs(), kind: "submit", text: message))
        rec.pendingChanges = true
        onDevLog?("submit bundle=\(rec.bundleId) \(message.count) chars")
        flushAndContinue(key, newSessionStart: "")
    }

    // MARK: - flush

    private func scheduleFlush(_ rec: InProgressRecord, key: ElementKey) {
        rec.flushTimer?.invalidate()
        rec.flushTimer = Timer.scheduledTimer(
            withTimeInterval: Self.flushSec, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.state[key] else { return }
                self.flushAndContinue(key, newSessionStart: r.lastValueSnapshot)
            }
        }
    }

    /// flush 一个 element 的 in-progress record：有变化 → INSERT 一条新 record，
    /// 再从 state 移除。`text` = `sandwich(sessionStart, 最终值).newMid` —— 这段
    /// session 的净新增内容（不含 sessionStart 旧内容）。
    func flushElement(_ key: ElementKey) {
        guard let rec = state[key] else { return }
        rec.debounceTimer?.invalidate()
        rec.flushTimer?.invalidate()
        if rec.pendingChanges {
            let (_, _, added, _) = TextDiff.sandwich(prev: rec.sessionStart,
                                                     new: rec.lastValueSnapshot)
            let combined = Set((blacklist[key] ?? [:]).keys)
            let cleaned = Self.stripBlacklist(added, blacklist: combined)
            let event = TypingEvent(
                id: nil,
                bundleId: rec.bundleId,
                elementHash: rec.elementHash,
                startedAt: rec.startedAtMs,
                endedAt: Self.nowMs(),
                text: cleaned,
                editLog: Self.encodeLog(rec.editLog),
                totalChars: cleaned.count
            )
            try? store?.insert(event)
            onDevLog?("flush bundle=\(rec.bundleId) element=\(rec.elementHash) "
                      + "\(cleaned.count) chars \(rec.editLog.count) edits")
        }
        state[key] = nil
    }

    /// flush 后立刻在同一 element 上开新 session。
    private func flushAndContinue(_ key: ElementKey, newSessionStart: String) {
        guard let rec = state[key] else { return }
        let bundleId = rec.bundleId
        let elementHash = rec.elementHash
        flushElement(key)
        state[key] = InProgressRecord(bundleId: bundleId, elementHash: elementHash,
                                      sessionStart: newSessionStart, nowMs: Self.nowMs())
    }

    /// flush 某 app 的所有 element（app 切走时）。
    func flushApp(bundleId: String) {
        for key in Array(state.keys) where state[key]?.bundleId == bundleId {
            flushElement(key)
        }
    }

    /// flush 所有 in-progress record（observer 停 / 进程退出）。
    func flushAll() {
        for key in Array(state.keys) { flushElement(key) }
    }

    // MARK: - 黑名单 TTL

    func cleanupBlacklist(now: TimeInterval) {
        for (key, entries) in blacklist {
            let kept = entries.filter { now - $0.value <= Self.blacklistTTLSec }
            if kept.isEmpty { blacklist[key] = nil }
            else if kept.count != entries.count { blacklist[key] = kept }
        }
    }

    // MARK: - 纯函数辅助（单测覆盖）

    /// burst 判定 —— 单次 value-change 的字符跳变 + 间隔。
    static func isBurst(jumpChars: Int, intervalMs: Double) -> Bool {
        jumpChars > burstCharThreshold && intervalMs < burstIntervalMs
    }

    /// 一段 session 的净新增内容 = `sandwich(sessionStart, 最终值).newMid`。
    static func sessionText(sessionStart: String, finalValue: String) -> String {
        TextDiff.sandwich(prev: sessionStart, new: finalValue).newMid
    }

    /// 黑名单减法：按长度倒序减，每个 entry 只减一次。
    static func stripBlacklist(_ text: String, blacklist: Set<String>) -> String {
        var result = text
        for entry in blacklist.sorted(by: { $0.count > $1.count }) where !entry.isEmpty {
            if let range = result.range(of: entry) {
                result.removeSubrange(range)
            }
        }
        return result
    }

    static func decodeLog(_ json: String) -> [EditEntry] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EditEntry].self, from: data)
        else { return [] }
        return decoded
    }

    static func encodeLog(_ entries: [EditEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }
}
