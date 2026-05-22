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

    // MARK: - 参数
    //
    // debounce / flush idle / submit window 三个走 ConfigStore（用户可调），
    // 其余仍硬编码。

    nonisolated static let burstCharThreshold = 10
    nonisolated static let burstIntervalMs: Double = 30
    nonisolated static let blacklistTTLSec: TimeInterval = 3600
    nonisolated static let pasteAssocSec: TimeInterval = 0.5
    /// continuation 匹配比首 / 尾各这么多字 —— 同 element 内足够辨识。
    nonisolated static let matchWindowChars = 100

    // MARK: - 状态

    private let store: TypingEventStore?
    private let ledger: KeystrokeLedger
    private let pasteboard: PasteboardMonitor
    var onDevLog: ((String) -> Void)?

    private(set) var state: [ElementKey: InProgressRecord] = [:]
    /// 黑名单 per (app, element)：噪声 segment → 命中时刻（CACurrentMediaTime）。
    private(set) var blacklist: [ElementKey: [String: TimeInterval]] = [:]

    /// flush 的 DB 读写跑在这条后台串行队列上 —— GRDB 的 read/write 是同步
    /// 阻塞调用，绝不能在 MainActor 上跑（DB 一忙主线程就吊死）。串行 →
    /// continuation 合并的顺序（先 INSERT 才能被后面 merge 查到）有保证。
    private let dbQueue = DispatchQueue(label: "com.joyzhang.myportrait.typing.db")

    init(store: TypingEventStore?, ledger: KeystrokeLedger, pasteboard: PasteboardMonitor) {
        self.store = store
        self.ledger = ledger
        self.pasteboard = pasteboard
    }

    /// flush 时从 in-progress record 取下来、交给后台 DB 队列的快照（Sendable）。
    private struct FlushSnapshot: Sendable {
        let bundleId: String
        let elementHash: Int
        let startedAtMs: Int64
        let sessionStart: String
        let endValue: String
        let editLog: [EditEntry]
        let blacklist: Set<String>
    }

    /// UTC 毫秒 —— started_at / ended_at / edit_log ts 都用它。
    nonisolated static func nowMs() -> Int64 {
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
        let cfg = ConfigStore.shared.recording
        // 发送检测：只对 Enter-to-send 列表里的 app。列表内，回车后第一次
        // value-change 即视为发送（Shift+Enter 不算回车，见 KeystrokeLedger）。
        // 不靠「输入框变空」判断 —— 有些 app（Claude desktop）空框是占位符
        // 文字、永远非空。
        if ConfigStore.shared.privacy.typingSubmitBundleIds.contains(rec.bundleId),
           ledger.hasSubmitKey(within: Double(cfg.typingSubmitWindowMs) / 1000.0) {
            ledger.consumeSubmit()
            let msg = rec.pendingValue ?? rec.lastValueSnapshot
            if !msg.isEmpty, msg != rec.sessionStart {
                handleSubmit(key: key, rec: rec, message: msg, clearedValue: newValue)
                return
            }
            // 否则（没真打过字 / 误触回车）：consumeSubmit 已作废这次回车，
            // 继续按普通输入处理。
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
            withTimeInterval: Double(cfg.typingDebounceMs) / 1000.0, repeats: false
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

        let windowNoise = rec.windowHadBurst || rec.windowHadPaste || !rec.windowHadKeystroke
        rec.windowHadBurst = false
        rec.windowHadPaste = false
        rec.windowHadKeystroke = false
        rec.lastValueSnapshot = pending

        let (_, deleted, added, _) = TextDiff.sandwich(prev: prev, new: pending)
        // windowNoise = ⌘V / burst / 无按键；外加剪贴板内容匹配 —— 抓菜单 /
        // 右键 / 拖拽等非 ⌘V 粘贴。
        let noise = windowNoise || pasteboard.looksLikePaste(added)
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

    /// 回车发送 —— `message` = 发出的整条消息；`clearedValue` = 发送后输入框
    /// 当前内容（空串 / 占位符文字，作为下一段 session 的起点）。
    private func handleSubmit(key: ElementKey, rec: InProgressRecord,
                              message: String, clearedValue: String) {
        rec.debounceTimer?.invalidate()
        rec.debounceTimer = nil
        rec.lastValueSnapshot = message
        // submit 条目记**整条发出的消息**。
        rec.editLog.append(EditEntry(ts: Self.nowMs(), kind: "submit", text: message))
        rec.pendingChanges = true
        onDevLog?("submit bundle=\(rec.bundleId) \(message.count) chars")
        flushAndContinue(key, newSessionStart: clearedValue)
    }

    // MARK: - flush

    private func scheduleFlush(_ rec: InProgressRecord, key: ElementKey) {
        rec.flushTimer?.invalidate()
        rec.flushTimer = Timer.scheduledTimer(
            withTimeInterval: Double(ConfigStore.shared.recording.typingFlushIdleSec),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.state[key] else { return }
                self.flushAndContinue(key, newSessionStart: r.lastValueSnapshot)
            }
        }
    }

    /// flush 一个 element 的 in-progress record：从 in-progress state 取下快照、
    /// 移除，把 DB 读写**派到后台串行队列**（GRDB 的 read/write 同步阻塞，
    /// 不能在 MainActor 上跑）。
    func flushElement(_ key: ElementKey) {
        guard let rec = state[key] else { return }
        rec.debounceTimer?.invalidate()
        rec.flushTimer?.invalidate()
        if rec.pendingChanges, let store {
            let snap = FlushSnapshot(
                bundleId: rec.bundleId,
                elementHash: rec.elementHash,
                startedAtMs: rec.startedAtMs,
                sessionStart: rec.sessionStart,
                endValue: rec.lastValueSnapshot,
                editLog: rec.editLog,
                blacklist: Set((blacklist[key] ?? [:]).keys)
            )
            dbQueue.async { Self.persist(snap, store: store) }
        }
        state[key] = nil
    }

    /// 落库 —— 在后台 DB 队列上跑。接得上某条已有 record（continuation）→
    /// **合并进那条**（UPDATE）；接不上 → INSERT 一条新 record。
    /// `text` = `sandwich(sessionStart, 最终值).newMid`。
    nonisolated private static func persist(_ snap: FlushSnapshot, store: TypingEventStore) {
        let nowMs = nowMs()

        // continuation 目标：同 (app, element)、end_value 首尾 100 字接得上。
        let candidates = (try? store.recordsForElement(
            bundleId: snap.bundleId, elementHash: snap.elementHash)) ?? []
        let target = snap.sessionStart.isEmpty ? nil : candidates.first {
            isContinuation(sessionStart: snap.sessionStart, recordEndValue: $0.endValue)
        }

        if let target {
            // 接得上 → 合并。剔除时并上 target 自己记的 stripped —— 即使内存
            // 黑名单已过期，旧噪声也不复活。
            let combined = snap.blacklist.union(decodeStrings(target.stripped))
            let (mergedText, strippedNow) = stripBlacklist(
                sessionText(sessionStart: target.sessionStart, finalValue: snap.endValue),
                blacklist: combined)
            var mergedLog = decodeLog(target.editLog)
            mergedLog.append(contentsOf: snap.editLog)
            let merged = TypingEvent(
                id: target.id,
                bundleId: target.bundleId,
                elementHash: target.elementHash,
                startedAt: target.startedAt,
                endedAt: nowMs,
                text: mergedText,
                editLog: encodeLog(mergedLog),
                totalChars: mergedText.count,
                sessionStart: target.sessionStart,
                endValue: snap.endValue,
                stripped: encodeStrings(strippedNow)
            )
            try? store.update(merged)
        } else {
            // 接不上 → 新建 record。
            let (cleaned, strippedNow) = stripBlacklist(
                sessionText(sessionStart: snap.sessionStart, finalValue: snap.endValue),
                blacklist: snap.blacklist)
            let event = TypingEvent(
                id: nil,
                bundleId: snap.bundleId,
                elementHash: snap.elementHash,
                startedAt: snap.startedAtMs,
                endedAt: nowMs,
                text: cleaned,
                editLog: encodeLog(snap.editLog),
                totalChars: cleaned.count,
                sessionStart: snap.sessionStart,
                endValue: snap.endValue,
                stripped: encodeStrings(strippedNow)
            )
            try? store.insert(event)
        }
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

    /// 测试用：阻塞等所有已派发的后台 DB 写入完成。串行队列上的 barrier。
    func waitForPendingDBWork() {
        dbQueue.sync {}
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
    nonisolated static func isBurst(jumpChars: Int, intervalMs: Double) -> Bool {
        jumpChars > burstCharThreshold && intervalMs < burstIntervalMs
    }

    /// 一段 session 的净新增内容 = `sandwich(sessionStart, 最终值).newMid`。
    nonisolated static func sessionText(sessionStart: String, finalValue: String) -> String {
        TextDiff.sandwich(prev: sessionStart, new: finalValue).newMid
    }

    /// 本 session 起点内容是否接得上某 record 的结尾。
    ///
    /// `sessionStart` 是本 session「还没编辑前」的输入框快照 —— 真延续时它跟
    /// 旧 record 的 `end_value` 完全相等。比**首尾各 `matchWindowChars` 字两个
    /// 锚点**：都对上才算延续，防两篇不同内容尾巴碰巧相同的误合并。
    /// 同 (app, element) 内、不限时间。空起点（如聊天发送后输入框清空）不算。
    nonisolated static func isContinuation(sessionStart: String, recordEndValue: String) -> Bool {
        guard !sessionStart.isEmpty, !recordEndValue.isEmpty else { return false }
        return sessionStart.prefix(matchWindowChars) == recordEndValue.prefix(matchWindowChars)
            && sessionStart.suffix(matchWindowChars) == recordEndValue.suffix(matchWindowChars)
    }

    /// 黑名单减法：按长度倒序减，每个 entry 只减一次。返回剔除后文本 +
    /// 实际命中（被剔掉）的段 —— 后者落进 record 的 `stripped`。
    nonisolated static func stripBlacklist(_ text: String, blacklist: Set<String>)
        -> (text: String, stripped: Set<String>) {
        var result = text
        var used: Set<String> = []
        for entry in blacklist.sorted(by: { $0.count > $1.count }) where !entry.isEmpty {
            if let range = result.range(of: entry) {
                result.removeSubrange(range)
                used.insert(entry)
            }
        }
        return (result, used)
    }

    nonisolated static func decodeLog(_ json: String) -> [EditEntry] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EditEntry].self, from: data)
        else { return [] }
        return decoded
    }

    nonisolated static func encodeLog(_ entries: [EditEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    nonisolated static func decodeStrings(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(arr)
    }

    nonisolated static func encodeStrings(_ set: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(Array(set)),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }
}
