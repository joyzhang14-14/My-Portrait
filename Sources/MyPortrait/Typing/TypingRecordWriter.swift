import Foundation
import QuartzCore

/// Typing Observer v2 — Layer 4 写入层（v14 splice 模型）。
///
/// 一个 (app, element) 一段 in-progress session。每次 AX value-change 经 350ms
/// debounce 收敛后，用 `TextDiff.sandwich` 出 delta，**就地 splice** 进
/// `text`（insert / removeSubrange / replaceSubrange）—— 中段编辑、删除都在
/// 原位生效。修掉 KI-1（中段错位）+ KI-2（大段删除丢失）。
///
/// session 在 5s 静默 / 切 element / 切 app / 发送 / 进程退出时 flush ——
/// **INSERT 一条新 record**（append-only，不 UPSERT），record 落库后 immutable。
///
/// 不变量：`lastValueSnapshot == baseline + text`。splice 的位置换算
/// （`effPos = splicePos - baselineOffset`）全靠它。burst / 粘贴 / 程序输出
/// 这些「噪声」也照常 splice 进 text（保住不变量），只是把那段 segment
/// 进黑名单 —— flush 时 `stripBlacklist` 减掉。
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

        /// session 开始时 element 已有的内容（不算用户本次输入）。
        var baseline: String
        /// = `baseline.count`（Character 数），splice 位置换算用。
        var baselineOffset: Int
        /// 本次 session 用户真实输入 —— splice 的目标。
        var text: String
        var editLog: [EditEntry]

        /// 该 element 上次 AX 完整 value。不变量：`== baseline + text`。
        var lastValueSnapshot: String
        var lastValueChangeTs: TimeInterval

        /// debounce 窗口内最近一次的 AX value。
        var pendingValue: String?
        /// 本 debounce 窗口是否见过 burst / 粘贴 / 物理按键。
        var windowHadBurst = false
        var windowHadPaste = false
        var windowHadKeystroke = false

        var debounceTimer: Timer?
        var flushTimer: Timer?
        var pendingChanges = false

        init(bundleId: String, elementHash: Int, baseline: String, nowMs: Int64) {
            self.bundleId = bundleId
            self.elementHash = elementHash
            self.startedAtMs = nowMs
            self.lastEventMs = nowMs
            self.baseline = baseline
            self.baselineOffset = baseline.count
            self.text = ""
            self.editLog = []
            self.lastValueSnapshot = baseline
            self.lastValueChangeTs = CACurrentMediaTime()
        }
    }

    // MARK: - 硬编码参数（M5 统一挪进 ConfigStore）

    static let burstCharThreshold = 10
    static let burstIntervalMs: Double = 30
    static let blacklistTTLSec: TimeInterval = 3600
    /// AX value 稳定多久才走 splice —— 收敛 IME 拼音中间态。
    static let debounceSec: TimeInterval = 0.350
    /// session 静默多久落库。
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
                                      baseline: baseline, nowMs: Self.nowMs())
    }

    /// 一次 AX value-change。存进 pendingValue + 重排 350ms debounce。
    /// burst / 粘贴 / 按键 的判定在这里做（要时间新鲜）→ 标记到 record。
    func noteValueChange(key: ElementKey, newValue: String) {
        guard let rec = state[key] else { return }

        // 发送检测：输入框被清空 + 之前有内容 + 刚按过回车 = 聊天 app 发出消息。
        // 在 value-change 时刻判（不是 debounce 触发时）—— 此刻 pendingValue
        // 还是清空前的消息内容。
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
        if abs(newValue.count - prevSeen.count) > Self.burstCharThreshold,
           intervalMs < Self.burstIntervalMs {
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

    // MARK: - debounce 触发 → splice

    private func fireDebounce(_ key: ElementKey) {
        guard let rec = state[key], let pending = rec.pendingValue else { return }
        rec.debounceTimer = nil
        rec.pendingValue = nil
        let prev = rec.lastValueSnapshot
        guard prev != pending else { return }

        // 噪声判定（窗口标记，noteValueChange 时新鲜采集的）。
        let noise = rec.windowHadBurst || rec.windowHadPaste || !rec.windowHadKeystroke
        rec.windowHadBurst = false
        rec.windowHadPaste = false
        rec.windowHadKeystroke = false
        rec.lastValueSnapshot = pending

        let nowMs = Self.nowMs()
        let (_, inserted) = Self.splice(rec, prev: prev, new: pending, nowMs: nowMs)

        // 噪声 → 把这次插入的 segment 进黑名单（flush 时 stripBlacklist 减掉）。
        // 照常 splice 进 text 是为了保住「lastValueSnapshot == baseline+text」
        // 不变量；黑名单负责落库时把噪声剔除。
        if noise, !inserted.isEmpty {
            blacklist[key, default: [:]][inserted] = CACurrentMediaTime()
            onDevLog?("noise→blacklist bundle=\(rec.bundleId) \(inserted.count) chars")
        }

        rec.lastEventMs = nowMs
        rec.pendingChanges = true
        scheduleFlush(rec, key: key)
    }

    /// 对 record 做一次 prev→new 的就地 splice。baseline 吸纳、3 路 splice、
    /// editLog 追加都在内。纯逻辑、无 timer / ledger —— 单测直接覆盖。
    /// 返回 (prevMid 删掉的, newMid 新插的)。
    @discardableResult
    static func splice(_ rec: InProgressRecord, prev: String, new: String, nowMs: Int64)
        -> (prevMid: String, newMid: String) {
        let (prefix, prevMid, newMid, _) = TextDiff.sandwich(prev: prev, new: new)
        if prevMid.isEmpty, newMid.isEmpty { return ("", "") }

        // splice 位置：AX 坐标 → session-text 坐标。
        let splicePos = prefix.count
        var effPos = splicePos - rec.baselineOffset
        if effPos < 0 {
            // 触及 baseline → 把 baseline 吸纳进 text，之后只在 text 里 splice。
            rec.text = rec.baseline + rec.text
            rec.baseline = ""
            rec.baselineOffset = 0
            effPos = splicePos
        }
        // 不变量成立时 effPos / delLen 必然合法；min/max 兜底防越界 trap。
        effPos = min(max(effPos, 0), rec.text.count)
        let lo = rec.text.index(rec.text.startIndex, offsetBy: effPos)
        let delLen = min(prevMid.count, rec.text.distance(from: lo, to: rec.text.endIndex))
        let hi = rec.text.index(lo, offsetBy: delLen)

        if prevMid.isEmpty {
            rec.text.insert(contentsOf: newMid, at: lo)
            rec.editLog.append(EditEntry(ts: nowMs, kind: "commit", text: newMid))
        } else if newMid.isEmpty {
            rec.text.removeSubrange(lo..<hi)
            rec.editLog.append(EditEntry(ts: nowMs, kind: "delete", text: prevMid))
        } else {
            rec.text.replaceSubrange(lo..<hi, with: newMid)
            rec.editLog.append(EditEntry(ts: nowMs, kind: "delete", text: prevMid))
            rec.editLog.append(EditEntry(ts: nowMs, kind: "commit", text: newMid))
        }
        return (prevMid, newMid)
    }

    // MARK: - 发送

    /// 聊天 app 回车发送 —— 输入框清空。`fullValue` = 清空前的完整内容。
    /// 把它当本次 session 的最终 text，记一条 submit，立即 flush，开新空 session。
    private func handleSubmit(key: ElementKey, rec: InProgressRecord, fullValue: String) {
        rec.debounceTimer?.invalidate()
        rec.debounceTimer = nil
        // 用户本次输入 = fullValue 去掉 baseline 前缀（聊天框 baseline 通常为空）。
        let message = fullValue.hasPrefix(rec.baseline)
            ? String(fullValue.dropFirst(rec.baseline.count))
            : fullValue
        rec.text = message
        rec.editLog.append(EditEntry(ts: Self.nowMs(), kind: "submit", text: message))
        rec.pendingChanges = true
        onDevLog?("submit bundle=\(rec.bundleId) \(message.count) chars")
        flushAndContinue(key, newBaseline: "")
    }

    // MARK: - flush

    private func scheduleFlush(_ rec: InProgressRecord, key: ElementKey) {
        rec.flushTimer?.invalidate()
        rec.flushTimer = Timer.scheduledTimer(
            withTimeInterval: Self.flushSec, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.state[key] else { return }
                // 5s 静默落库 —— element 还活着，落库后用当前完整内容当新 baseline 续上。
                self.flushAndContinue(key, newBaseline: r.lastValueSnapshot)
            }
        }
    }

    /// flush 一个 element 的 in-progress record：有变化 → INSERT 一条新 record，
    /// 然后把它从 state 移除。无变化 → 直接移除、不落库。
    func flushElement(_ key: ElementKey) {
        guard let rec = state[key] else { return }
        rec.debounceTimer?.invalidate()
        rec.flushTimer?.invalidate()
        if rec.pendingChanges {
            // 落库前减黑名单（只减 text）。
            let combined = Set((blacklist[key] ?? [:]).keys)
            let cleaned = Self.stripBlacklist(rec.text, blacklist: combined)
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

    /// flush 后立刻在同一 element 上开新 session（5s 静默续写 / 发送后续写）。
    private func flushAndContinue(_ key: ElementKey, newBaseline: String) {
        guard let rec = state[key] else { return }
        let bundleId = rec.bundleId
        let elementHash = rec.elementHash
        flushElement(key)
        state[key] = InProgressRecord(bundleId: bundleId, elementHash: elementHash,
                                      baseline: newBaseline, nowMs: Self.nowMs())
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

    /// 移除命中时刻早于 1h 的黑名单条目。`now` 用 CACurrentMediaTime()。
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

    /// 黑名单减法：按长度倒序减（避免短串先吃长串），每个 entry 只减一次。
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
