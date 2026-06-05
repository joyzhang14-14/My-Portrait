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
        /// 浏览器输入时所在页面 URL；非浏览器为空。
        let url: String
        /// 该 element 最近一次 AX 完整 value。
        var lastValueSnapshot: String
        var lastValueChangeTs: TimeInterval
        /// 逐 debounce 窗口的编辑流水。
        var editLog: [EditEntry]

        /// debounce 窗口内最近一次 AX value。
        var pendingValue: String?
        var windowHadBurst = false
        var windowHadPaste = false
        var windowHadCut = false
        var windowHadUndo = false
        var windowHadRedo = false
        var windowHadKeystroke = false
        /// 单次 AX 跳变远超附近按键能产生的字符量 —— Electron 切 note、
        /// 程序注入、插件改值 等场景。`isOversizedDelta` 判定。
        var windowOversizedDelta = false

        var debounceTimer: Timer?
        var flushTimer: Timer?
        var pendingChanges = false

        init(bundleId: String, elementHash: Int, sessionStart: String,
             url: String, nowMs: Int64) {
            self.bundleId = bundleId
            self.elementHash = elementHash
            self.startedAtMs = nowMs
            self.lastEventMs = nowMs
            self.sessionStart = sessionStart
            self.url = url
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
    /// 单次 AX 跳变最小值 —— 低于这个不查,正常打字会自然在这个量级。
    nonisolated static let oversizedDeltaFloor = 50
    /// 每个按键最多产生 1 个字符 —— 一键一字。
    /// 注:跳变小于 `oversizedDeltaFloor` 不查,所以中文 IME 短 commit
    /// (你好世界 4 字 / 1 键 之类)天然过关,不会被这条误拦。
    nonisolated static let oversizedDeltaCharsPerKey = 1
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
        let url: String
    }

    /// UTC 毫秒 —— started_at / ended_at / edit_log ts 都用它。
    nonisolated static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    // MARK: - session 生命周期

    /// element 获得焦点 → 开一段新 session。`baseline` = 此刻 AX 完整 value，
    /// `url` = 浏览器当前页面 URL（非浏览器传空）。
    func beginSession(key: ElementKey, bundleId: String, baseline: String, url: String) {
        flushElement(key)   // 若有旧 record，先 flush 落库 + 移除
        state[key] = InProgressRecord(bundleId: bundleId, elementHash: key.elementHash,
                                      sessionStart: baseline, url: url, nowMs: Self.nowMs())
    }

    /// 一次 AX value-change。存进 pendingValue + 重排 350ms debounce。
    func noteValueChange(key: ElementKey, newValue: String) {
        guard let rec = state[key] else { return }

        // 发送检测:回车 + value 真的清空/断崖式缩短 = 聊天 app 发出消息。
        // 不再用 app 白名单(app 无限多,写死维护不过来)。靠键盘事件 +
        // `looksLikeSubmitClear` 行为检测:
        //   - 编辑器(Notes/Obsidian)按 Enter 是换行,value 不清空 → 不判 submit
        //   - 聊天 app 按 Enter 发消息,value 清空/回 placeholder → 判 submit
        // IME commit / 误触场景 value 也不清空,自然过滤。
        let cfg = ConfigStore.shared.capture
        if ledger.hasSubmitKey(within: Double(cfg.typingSubmitWindowMs) / 1000.0) {
            ledger.consumeSubmit()
            let msg = rec.pendingValue ?? rec.lastValueSnapshot
            if !msg.isEmpty, msg != rec.sessionStart,
               Self.looksLikeSubmitClear(
                   message: msg, newValue: newValue, sessionStart: rec.sessionStart) {
                handleSubmit(key: key, rec: rec, message: msg, clearedValue: newValue)
                return
            }
            // 否则(回车按了但 value 没像被清空) —— 换行 / IME commit / 误触。
            // consumeSubmit 已作废这次回车,继续按普通输入处理。
        }

        let now = CACurrentMediaTime()
        let intervalMs = (now - rec.lastValueChangeTs) * 1000.0
        let prevSeen = rec.pendingValue ?? rec.lastValueSnapshot
        let jumpChars = abs(newValue.count - prevSeen.count)
        if Self.isBurst(jumpChars: jumpChars, intervalMs: intervalMs) {
            rec.windowHadBurst = true
        }
        let corrWindowSec =
            Double(ConfigStore.shared.capture.typingKeyCorrelationWindowMs) / 1000.0
        let keystrokeCount = ledger.recentTimestamps(within: corrWindowSec).count
        if keystrokeCount > 0 { rec.windowHadKeystroke = true }
        // 一次跳变 50+ 字,但相关窗口内按键数撑不起来 —— 不是打字,可能是
        // Electron 切 note / 程序写入 / 插件 / autosave。
        if Self.isOversizedDelta(jumpChars: jumpChars, keystrokeCount: keystrokeCount) {
            rec.windowOversizedDelta = true
            onDevLog?("oversize→noise bundle=\(rec.bundleId) jump=\(jumpChars) keys=\(keystrokeCount)")
        }
        if ledger.hasPaste(within: Self.pasteAssocSec) { rec.windowHadPaste = true }
        if ledger.hasCut(within: Self.pasteAssocSec)  { rec.windowHadCut  = true }
        if ledger.hasUndo(within: Self.pasteAssocSec) { rec.windowHadUndo = true }
        if ledger.hasRedo(within: Self.pasteAssocSec) { rec.windowHadRedo = true }

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

        let hadPaste = rec.windowHadPaste
        let hadCut   = rec.windowHadCut
        let hadUndo  = rec.windowHadUndo
        let hadRedo  = rec.windowHadRedo
        let hadBurst = rec.windowHadBurst
        let hadNoKey = !rec.windowHadKeystroke
        let hadOver  = rec.windowOversizedDelta
        rec.windowHadBurst = false
        rec.windowHadPaste = false
        rec.windowHadCut = false
        rec.windowHadUndo = false
        rec.windowHadRedo = false
        rec.windowHadKeystroke = false
        rec.windowOversizedDelta = false
        rec.lastValueSnapshot = pending

        let (_, deleted, added, _) = TextDiff.sandwich(prev: prev, new: pending)
        let nowMs = Self.nowMs()
        let recordPasteEvents = ConfigStore.shared.capture.typingRecordPasteEvents
        let pasteboardMatch = pasteboard.looksLikePaste(added)
        // 优先级:undo/redo > cut > paste(含剪贴板匹配)> oversized/burst/no-key
        // 100 字阈值:短粘贴(< 100 字)大概率是用户挪自己的片段 / 短小代码片段,
        // 当 commit 计;长粘贴才标 kind="paste" 让 LLM 判外来。
        let pasteShortThreshold = 100
        if hadUndo || hadRedo {
            // undo/redo 不记 text(value 是回滚态,记 text 没意义),只标时间
            rec.editLog.append(EditEntry(ts: nowMs, kind: hadRedo ? "redo" : "undo", text: ""))
            // value 真的回滚了不要忘了对应的 delete/add,LLM 凭 kind 判,这里不
            // 重复记
        } else if hadCut {
            if !deleted.isEmpty {
                rec.editLog.append(EditEntry(ts: nowMs, kind: "cut", text: deleted))
            }
            if !added.isEmpty {
                // cut 通常只删,但保险万一同窗口又有输入
                rec.editLog.append(EditEntry(ts: nowMs, kind: "commit", text: added))
            }
        } else if hadPaste || pasteboardMatch {
            // paste(⌘V / 剪贴板匹配)
            if !added.isEmpty {
                // 剪贴板镜像命中:用剪贴板确切原文当内容,kind 一律 "paste"(不再
                // 按 100 字折叠成 commit)—— 让下游统一按 <30 留 / ≥30 丢处理短
                // 粘贴。仅 ⌘V、镜像没命中(被 app 转格式等)才退回旧逻辑。
                let pasteText = pasteboardMatch ? (pasteboard.currentText ?? added) : added
                let kind = pasteboardMatch
                    ? "paste"
                    : (added.count <= pasteShortThreshold ? "commit" : "paste")
                if recordPasteEvents || kind == "commit" {
                    rec.editLog.append(EditEntry(ts: nowMs, kind: kind, text: pasteText))
                } else {
                    blacklist[key, default: [:]][added] = CACurrentMediaTime()
                    onDevLog?("paste→blacklist bundle=\(rec.bundleId) \(added.count) chars")
                }
            }
            if !deleted.isEmpty {
                rec.editLog.append(EditEntry(ts: nowMs, kind: "delete", text: deleted))
            }
        } else if hadBurst || hadOver || hadNoKey {
            // 非用户输入(程序注入 / autosave / oversized)—— 进黑名单或标 paste
            if !added.isEmpty {
                if recordPasteEvents {
                    rec.editLog.append(EditEntry(ts: nowMs, kind: "paste", text: added))
                } else {
                    blacklist[key, default: [:]][added] = CACurrentMediaTime()
                    onDevLog?("noise→blacklist bundle=\(rec.bundleId) \(added.count) chars")
                }
            }
            if recordPasteEvents, !deleted.isEmpty {
                rec.editLog.append(EditEntry(ts: nowMs, kind: "delete", text: deleted))
            }
        } else {
            // 正常打字
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
            withTimeInterval: Double(ConfigStore.shared.capture.typingFlushIdleSec),
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
        // 还有未落定的 value-change(debounce 在飞)→ 先按正常流程把它折进
        // edit_log + lastValueSnapshot 再 flush。否则 flush 读的是上一拍 snapshot,
        // 会丢掉最后这一拍 —— IME 组词 + 回车"提交+发送+清空"挤在一个回车里时,
        // 尾巴(如"发给我")常卡在 pendingValue 还没落定就被 flush 抢走。
        if rec.pendingValue != nil { fireDebounce(key) }
        rec.debounceTimer?.invalidate()
        rec.flushTimer?.invalidate()
        // URL 级黑名单:整 app 屏蔽已经在 TypingObserver.attach 拦住,这里
        // 处理"app 没全屏蔽但当前 URL 命中前缀"。命中 → 直接弃掉本 record。
        if TypingPrivacyFilter.isBlacklisted(bundleId: rec.bundleId, url: rec.url) {
            onDevLog?("url-blacklist drop bundle=\(rec.bundleId) url=\(rec.url)")
            state[key] = nil
            return
        }
        let snapBlacklist = Set((blacklist[key] ?? [:]).keys)
        // **整段判为 noise 的 record 直接不写**:editLog 全空(没有任何被算法
        // 认可的 commit/delete)且 blacklist 非空(value-change 全被 fireDebounce
        // 判 paste/burst/oversized/no-keystroke)→ session 净增量全是 noise,
        // 不是真打字。
        //
        // 典型症状:typing_events 落了一条 text 几百字 + edit_log = "[]" +
        // stripped 非空 —— sandwich diff 和 blacklist 段字符串不重合时
        // stripBlacklist 减不干净,残留 noise 写进了 DB。
        let allNoise = rec.editLog.isEmpty && !snapBlacklist.isEmpty
        if rec.pendingChanges, let store, !allNoise {
            let snap = FlushSnapshot(
                bundleId: rec.bundleId,
                elementHash: rec.elementHash,
                startedAtMs: rec.startedAtMs,
                sessionStart: rec.sessionStart,
                endValue: rec.lastValueSnapshot,
                editLog: rec.editLog,
                blacklist: snapBlacklist,
                url: rec.url
            )
            dbQueue.async { Self.persist(snap, store: store) }
        }
        if allNoise {
            onDevLog?("drop all-noise record bundle=\(rec.bundleId) blacklist=\(snapBlacklist.count) segs")
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
        // 接得上还要求**同 URL** —— 浏览器换页 → 新 record，不跟旧页合并。
        let target = snap.sessionStart.isEmpty ? nil : candidates.first {
            $0.url == snap.url
                && isContinuation(sessionStart: snap.sessionStart, recordEndValue: $0.endValue)
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
                stripped: encodeStrings(strippedNow),
                url: target.url
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
                stripped: encodeStrings(strippedNow),
                url: snap.url
            )
            try? store.insert(event)
        }
    }

    /// flush 后立刻在同一 element 上开新 session。
    private func flushAndContinue(_ key: ElementKey, newSessionStart: String) {
        guard let rec = state[key] else { return }
        let bundleId = rec.bundleId
        let elementHash = rec.elementHash
        let url = rec.url
        flushElement(key)
        state[key] = InProgressRecord(bundleId: bundleId, elementHash: elementHash,
                                      sessionStart: newSessionStart, url: url,
                                      nowMs: Self.nowMs())
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

    /// 「Enter 后 value 真的看起来像被清空」判定 —— submit 二道防线。
    ///
    /// 真发送后 value 表现:
    ///   (a) 清空(`newValue` empty)
    ///   (b) 回到 session 初始值(placeholder 模式;`newValue == sessionStart`)
    ///   (c) 长消息发出后只剩**极少**残渣(`message ≥ 30` 且 `newValue ≤ 4`)
    ///
    /// 不像被清空的(应当返回 false):
    /// - Enter = 换行 的 app (多行编辑器、开了 Enter-newline 设置的 Slack)
    ///   → `newValue = message + "\n"`
    /// - IME commit Enter(commit raw pinyin)→ `newValue` 仍是落定后的整条文字
    /// - 用户连按 Enter 但 value 几乎没变
    ///
    /// ⚠️ (c) 早先写的是「`newValue < 30`」绝对断崖,IME 落字会跨界误判
    /// (拼音 31 字 → 落定 29 字,29 < 30 被当成发送把消息劈两半)。改判「残渣绝对
    /// 极少」:发送后留下的是**小常量**(Discord 的 `﻿\n`=2 字;占位符已被 (b) 接走),
    /// 跟消息多长无关。IME 落定留的是整条真文字(≥30 消息远不止 4 字)→ 不会命中。
    nonisolated static func looksLikeSubmitClear(
        message: String, newValue: String, sessionStart: String
    ) -> Bool {
        if newValue.isEmpty { return true }
        if newValue == sessionStart { return true }
        if message.count >= 30 && newValue.count <= 4 { return true }
        return false
    }

    /// 「单次 AX 跳变远超附近按键能产生的字符量」判定。
    /// - `jumpChars > oversizedDeltaFloor` (50):跳变够大值得查
    /// - `jumpChars > keystrokeCount`(每键 1 字封顶):按键撑不起这量
    ///
    /// 一键一字是用户真实输入的硬上限。`floor=50` 让中文 IME 短 commit、
    /// 小 autocomplete 这类天然过关;超过 floor 后,按键计数才严格生效。
    ///
    /// 触发场景:Obsidian 切 note 整段替换、Electron 编辑器程序写入、
    /// 插件 / autosave / snippet expand / 大段 autocomplete。
    nonisolated static func isOversizedDelta(jumpChars: Int, keystrokeCount: Int) -> Bool {
        jumpChars > oversizedDeltaFloor
            && jumpChars > keystrokeCount * oversizedDeltaCharsPerKey
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
