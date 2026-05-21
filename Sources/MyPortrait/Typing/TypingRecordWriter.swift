import Foundation
import QuartzCore

/// Typing Observer v2 — Layer 4「写入层」。
///
/// `TypingObserver`（L1+L2+L3，AX 重耦合）把折叠好的 commit / delete 交给
/// 这里。L4 负责：
///   - 按 app 维护 in-progress 主记录（一个 app 一条）
///   - 跨记录 delete（当前内存记录 → DB 主记录末尾 2000 字符窗口）
///   - 5s debounce flush + 写库时减黑名单
///   - 速度阈值 burst 命中的黑名单（per element，1h TTL）
///
/// 拆成独立类有两个理由：(1) 让 spec 要求的单测（burst 边界 / 黑名单减法 /
/// handleDelete 三态 / flush 重置）能脱离 AX 直接跑；(2) L4 是 spec 命名的
/// 分层，不是为「灵活性」造的抽象。
///
/// `@MainActor` —— 只被 `TypingObserver`（MainActor）和它的 Timer 回调驱动。
@MainActor
final class TypingRecordWriter {

    // MARK: - 内存中的 in-progress 记录

    /// 一个 app 一条。flush 后清空累积部分但保留对象（下次有 event 再累加）。
    final class InProgressRecord {
        let bundleId: String
        var text: String = ""
        var editLog: [EditEntry] = []
        /// UTC ms，创建时设定，不变。
        let timeStartMs: Int64
        var lastEventMs: Int64
        var flushTimer: Timer?
        /// 自上次 flush 后有无新变化。
        var pendingChanges: Bool = false

        init(bundleId: String, timeStartMs: Int64) {
            self.bundleId = bundleId
            self.timeStartMs = timeStartMs
            self.lastEventMs = timeStartMs
        }
    }

    /// 黑名单 key —— per (app, element)。
    struct ElementKey: Hashable {
        let bundleId: String
        let elementHash: Int
    }

    // MARK: - 硬编码参数（M5 统一挪进 ConfigStore）

    /// burst 判定：segment 字符数 **超过** 此值。
    static let burstCharThreshold = 10
    /// burst 判定：两次 value-change 间隔 **小于** 此毫秒数。
    static let burstIntervalMs: Double = 30
    /// 黑名单条目存活时长（秒）。
    static let blacklistTTLSec: TimeInterval = 3600
    /// 跨记录 delete 在 DB 主记录里搜索的末尾窗口（字符）。
    static let deleteSearchWindow = 2000

    // MARK: - 状态

    private let store: TypingEventStore?
    /// flush debounce 间隔（秒）。默认 5s，单测可注入短值。
    let flushInterval: TimeInterval

    /// app_bundle_id → in-progress 记录。
    private(set) var records: [String: InProgressRecord] = [:]
    /// (app, element) → 黑名单：entry 字符串 → 命中时刻（CACurrentMediaTime）。
    /// 用普通 Dictionary —— spec 写 OrderedDict，但顺序在任何地方都没被用到
    /// （TTL 全扫、finalize 按长度排序），无需引入 swift-collections。
    private(set) var blacklist: [ElementKey: [String: TimeInterval]] = [:]

    /// dev flag 日志出口（跨记录 delete / flush 关键事件）。
    var onDevLog: ((String) -> Void)?

    init(store: TypingEventStore?, flushInterval: TimeInterval = 5.0) {
        self.store = store
        self.flushInterval = flushInterval
    }

    // MARK: - 时间源

    /// UTC 毫秒（墙上时钟）。edit_log ts / time_start / last_updated 都用它。
    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    // MARK: - 步骤 2：burst 检测

    /// 速度阈值：segment 字符数 > 10 **且** 间隔 < 30ms → burst。
    /// 纯函数，供 `TypingObserver` 调用 + 单测覆盖边界。
    static func isBurst(segmentCharCount: Int, intervalMs: Double) -> Bool {
        segmentCharCount > burstCharThreshold && intervalMs < burstIntervalMs
    }

    /// burst 命中 → 把 segment 记进该 element 的黑名单。
    func recordBurst(key: ElementKey, segment: String, now: TimeInterval) {
        blacklist[key, default: [:]][segment] = now
    }

    // MARK: - 步骤 4：累加 commit

    /// L2 折出的 commit 文本累加进该 app 的 in-progress 记录，并重置 flush 计时。
    func accumulate(commitTexts: [String], bundleId: String, nowMs: Int64) {
        let texts = commitTexts.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        let rec = recordFor(bundleId: bundleId, nowMs: nowMs)
        for text in texts {
            rec.text += text
            rec.editLog.append(EditEntry(ts: nowMs, kind: "commit", text: text))
        }
        rec.lastEventMs = nowMs
        rec.pendingChanges = true
        scheduleFlush(rec)
    }

    // MARK: - 步骤 5：handleDelete（跨记录，2000 字符窗口）

    /// 处理一次删除。优先在当前内存记录里 `.backwards` 找；找不到再查 DB 主
    /// 记录末尾 `deleteSearchWindow` 字符；都没有 → 丢弃（按 spec 设计）。
    func handleDelete(deletedText: String, bundleId: String, nowMs: Int64) {
        guard !deletedText.isEmpty else { return }
        let rec = recordFor(bundleId: bundleId, nowMs: nowMs)

        // 当前内存记录，从后往前找。
        if let range = rec.text.range(of: deletedText, options: .backwards) {
            rec.text.removeSubrange(range)
            rec.editLog.append(EditEntry(ts: nowMs, kind: "delete", text: deletedText))
            rec.pendingChanges = true
            scheduleFlush(rec)
            return
        }

        // 当前记录找不到 → 查 DB 同 app 的主记录，限末尾 2000 字符。
        guard let store, let dbRec = try? store.fetch(bundleId: bundleId) else { return }
        var fullText = dbRec.text
        // Substring 与父 String 共享 index space —— window 上算出的 range
        // 直接能用在 fullText 上，不用做 offset 换算。
        let window = fullText.suffix(Self.deleteSearchWindow)
        guard let range = window.range(of: deletedText, options: .backwards) else {
            return  // 窗口内也没有 → 丢弃
        }
        fullText.removeSubrange(range)
        var log = Self.decodeLog(dbRec.editLog)
        log.append(EditEntry(ts: nowMs, kind: "delete", text: deletedText))
        let updated = TypingEvent(
            bundleId: bundleId,
            text: fullText,
            editLog: Self.encodeLog(log),
            timeStart: dbRec.timeStart,
            lastUpdated: nowMs,
            totalChars: fullText.count
        )
        try? store.upsert(updated)
        onDevLog?("cross-record delete bundle=\(bundleId) "
                  + "deleted=\"\(deletedText)\" remaining=\(fullText.count) chars")
    }

    // MARK: - 步骤 6：flush 计时

    /// 重置该记录的 5s debounce 计时器（每次活动都调）。
    private func scheduleFlush(_ rec: InProgressRecord) {
        rec.flushTimer?.invalidate()
        let bundleId = rec.bundleId
        rec.flushTimer = Timer.scheduledTimer(
            withTimeInterval: flushInterval, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush(bundleId: bundleId, nowMs: Self.nowMs())
            }
        }
    }

    // MARK: - 步骤 7：flushRecord（写库时减黑名单）

    /// 把某 app 的 in-progress 记录写进 DB。写入前用该 app 所有 element 的
    /// 黑名单做减法。无 pending 变化 → 直接返回。
    func flush(bundleId: String, nowMs: Int64) {
        guard let rec = records[bundleId] else { return }
        rec.flushTimer?.invalidate()
        rec.flushTimer = nil
        guard rec.pendingChanges else { return }

        // 该 app 所有 element 的黑名单合并。
        var combined: Set<String> = []
        for (key, entries) in blacklist where key.bundleId == bundleId {
            combined.formUnion(entries.keys)
        }
        let cleanedText = Self.stripBlacklist(rec.text, blacklist: combined)

        // 读 DB 现有行 → 追加 → 整行 INSERT OR REPLACE。
        var existing: TypingEvent?
        if let store {
            existing = (try? store.fetch(bundleId: bundleId)) ?? nil
        }
        let newText = (existing?.text ?? "") + cleanedText
        let mergedLog = Self.mergeEditLogs(existing: existing?.editLog,
                                           appending: rec.editLog)
        let timeStart = existing?.timeStart ?? rec.timeStartMs
        let event = TypingEvent(
            bundleId: bundleId,
            text: newText,
            editLog: mergedLog,
            timeStart: timeStart,
            lastUpdated: nowMs,
            totalChars: newText.count
        )
        try? store?.upsert(event)
        onDevLog?("flush bundle=\(bundleId) +\(cleanedText.count) chars "
                  + "(total \(newText.count))")

        // 清空累积部分，保留 record 对象。
        rec.text = ""
        rec.editLog = []
        rec.pendingChanges = false
    }

    /// flush 所有 in-progress 记录（进程退出 / observer 停）。
    func flushAll(nowMs: Int64) {
        for bundleId in Array(records.keys) {
            flush(bundleId: bundleId, nowMs: nowMs)
        }
    }

    // MARK: - 步骤 8：黑名单 TTL 清理

    /// 移除所有命中时刻早于 1h 的黑名单条目。`now` 用 `CACurrentMediaTime()`。
    func cleanupBlacklist(now: TimeInterval) {
        for (key, entries) in blacklist {
            let kept = entries.filter { now - $0.value <= Self.blacklistTTLSec }
            if kept.isEmpty {
                blacklist[key] = nil
            } else if kept.count != entries.count {
                blacklist[key] = kept
            }
        }
    }

    // MARK: - 纯函数辅助（单测覆盖）

    /// 黑名单减法：按 entry 长度倒序减（避免短串先吃掉长串的一部分），
    /// 每个 entry 只减 first occurrence 一次。
    static func stripBlacklist(_ text: String, blacklist: Set<String>) -> String {
        var result = text
        for entry in blacklist.sorted(by: { $0.count > $1.count }) where !entry.isEmpty {
            if let range = result.range(of: entry) {
                result.removeSubrange(range)
            }
        }
        return result
    }

    /// 把新的 edit_log entries 追加到已有 JSON 之后，返回新 JSON。
    static func mergeEditLogs(existing: String?, appending: [EditEntry]) -> String {
        var entries = existing.map(decodeLog) ?? []
        entries += appending
        return encodeLog(entries)
    }

    /// 解析 edit_log JSON。坏数据 → 空数组（不崩）。
    static func decodeLog(_ json: String) -> [EditEntry] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EditEntry].self, from: data)
        else { return [] }
        return decoded
    }

    /// 编码 edit_log JSON。失败 → `"[]"`。
    static func encodeLog(_ entries: [EditEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    // MARK: - 私有

    /// 取某 app 的 in-progress 记录，没有则新建（time_start = now）。
    @discardableResult
    func recordFor(bundleId: String, nowMs: Int64) -> InProgressRecord {
        if let existing = records[bundleId] { return existing }
        let rec = InProgressRecord(bundleId: bundleId, timeStartMs: nowMs)
        records[bundleId] = rec
        return rec
    }
}
