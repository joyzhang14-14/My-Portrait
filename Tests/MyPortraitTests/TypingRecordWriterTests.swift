import XCTest
import GRDB
@testable import MyPortrait

/// `TypingRecordWriter`（Layer 4 写入层）单测：burst 边界 / 黑名单减法 /
/// handleDelete 三态 / 2000 字符窗口 / flush 计时重置。
@MainActor
final class TypingRecordWriterTests: XCTestCase {

    private var tempPaths: [String] = []

    override func tearDown() async throws {
        let fm = FileManager.default
        for path in tempPaths {
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: path + "-wal")
            try? fm.removeItem(atPath: path + "-shm")
        }
        tempPaths.removeAll()
    }

    /// 临时文件 DatabasePool（WAL 不支持 `:memory:`）。
    private func makeStore() throws -> TypingEventStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPortraitL4Test-\(UUID().uuidString).sqlite")
            .path
        tempPaths.append(path)
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: FoundationTokenizer.self)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(pool)
        return TypingEventStore(dbPool: pool)
    }

    // MARK: - 步骤 2：burst 检测边界

    func testIsBurstBoundaries() {
        // 命中：> 10 字符 且 < 30ms。
        XCTAssertTrue(TypingRecordWriter.isBurst(segmentCharCount: 11, intervalMs: 29))
        XCTAssertTrue(TypingRecordWriter.isBurst(segmentCharCount: 100, intervalMs: 0))
        // 字符数边界：10 不算（要 **超过** 10）。
        XCTAssertFalse(TypingRecordWriter.isBurst(segmentCharCount: 10, intervalMs: 5))
        // 间隔边界：30ms 不算（要 **小于** 30）。
        XCTAssertFalse(TypingRecordWriter.isBurst(segmentCharCount: 50, intervalMs: 30))
        XCTAssertFalse(TypingRecordWriter.isBurst(segmentCharCount: 50, intervalMs: 31))
    }

    // MARK: - 黑名单 finalize 减法

    func testStripBlacklistFirstOccurrence() {
        // 只减 first occurrence 一次。
        XCTAssertEqual(
            TypingRecordWriter.stripBlacklist("XXmidXX", blacklist: ["XX"]),
            "midXX")
    }

    func testStripBlacklistLengthDescending() {
        // 长度倒序：先减 "XXXX"，"XX" 在剩余串里找不到 → 结果 "ab"。
        // 若按短串先减会得到错误的 "aXXb"。
        XCTAssertEqual(
            TypingRecordWriter.stripBlacklist("aXXXXb", blacklist: ["XX", "XXXX"]),
            "ab")
    }

    func testStripBlacklistEmpty() {
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("keep", blacklist: []), "keep")
    }

    // MARK: - edit_log 合并

    func testMergeEditLogs() {
        let existing = #"[{"ts":1,"kind":"commit","text":"a"}]"#
        let merged = TypingRecordWriter.mergeEditLogs(
            existing: existing,
            appending: [EditEntry(ts: 2, kind: "delete", text: "b")])
        let decoded = TypingRecordWriter.decodeLog(merged)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].text, "a")
        XCTAssertEqual(decoded[1].kind, "delete")
    }

    func testMergeEditLogsNilAndCorrupt() {
        // 已有为 nil → 只剩新 entries。
        let m1 = TypingRecordWriter.mergeEditLogs(
            existing: nil, appending: [EditEntry(ts: 1, kind: "commit", text: "x")])
        XCTAssertEqual(TypingRecordWriter.decodeLog(m1).count, 1)
        // 已有是坏 JSON → 当空数组处理，不崩。
        let m2 = TypingRecordWriter.mergeEditLogs(
            existing: "not json", appending: [EditEntry(ts: 1, kind: "commit", text: "x")])
        XCTAssertEqual(TypingRecordWriter.decodeLog(m2).count, 1)
    }

    // MARK: - handleDelete 三态

    func testHandleDeleteInCurrentRecord() {
        let writer = TypingRecordWriter(store: nil)
        writer.accumulate(commitTexts: ["hello"], bundleId: "a", nowMs: 1)
        writer.handleDelete(deletedText: "llo", bundleId: "a", nowMs: 2)

        let rec = writer.records["a"]
        XCTAssertEqual(rec?.text, "he")
        // edit_log: commit "hello" + delete "llo"。
        XCTAssertEqual(rec?.editLog.count, 2)
        XCTAssertEqual(rec?.editLog.last?.kind, "delete")
        XCTAssertEqual(rec?.editLog.last?.text, "llo")
    }

    func testHandleDeleteFromDBRecord() throws {
        let store = try makeStore()
        try store.upsert(TypingEvent(bundleId: "a", text: "world", editLog: "[]",
                                     timeStart: 1, lastUpdated: 1, totalChars: 5))
        let writer = TypingRecordWriter(store: store)
        // 当前内存记录为空 → 落到 DB 主记录。
        writer.handleDelete(deletedText: "rld", bundleId: "a", nowMs: 2)

        let got = try XCTUnwrap(store.fetch(bundleId: "a"))
        XCTAssertEqual(got.text, "wo")
        XCTAssertEqual(got.totalChars, 2)
        XCTAssertEqual(TypingRecordWriter.decodeLog(got.editLog).last?.kind, "delete")
    }

    func testHandleDeleteNotFoundIsDiscarded() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store)
        // 既无内存记录、DB 里也没这个 app → 静默丢弃，不崩。
        writer.handleDelete(deletedText: "zzz", bundleId: "ghost", nowMs: 1)
        XCTAssertNil(try store.fetch(bundleId: "ghost"))
        // 当前内存记录被 recordFor 建出来但 text 仍空。
        XCTAssertEqual(writer.records["ghost"]?.text, "")
    }

    // MARK: - 跨记录 delete：2000 字符窗口边界

    func testHandleDeleteWithinWindow() throws {
        let store = try makeStore()
        // 末尾 2000 字符内含 "TARGET"。
        let body = String(repeating: "a", count: 3000) + "TARGET"
        try store.upsert(TypingEvent(bundleId: "a", text: body, editLog: "[]",
                                     timeStart: 1, lastUpdated: 1, totalChars: body.count))
        let writer = TypingRecordWriter(store: store)
        writer.handleDelete(deletedText: "TARGET", bundleId: "a", nowMs: 2)

        let got = try XCTUnwrap(store.fetch(bundleId: "a"))
        XCTAssertEqual(got.text, String(repeating: "a", count: 3000))
    }

    func testHandleDeleteOutsideWindowIsDiscarded() throws {
        let store = try makeStore()
        // "TARGET" 在最前面，末尾 2000 字符里没有它 → 查不到 → 丢弃。
        let body = "TARGET" + String(repeating: "a", count: 3000)
        try store.upsert(TypingEvent(bundleId: "a", text: body, editLog: "[]",
                                     timeStart: 1, lastUpdated: 1, totalChars: body.count))
        let writer = TypingRecordWriter(store: store)
        writer.handleDelete(deletedText: "TARGET", bundleId: "a", nowMs: 2)

        let got = try XCTUnwrap(store.fetch(bundleId: "a"))
        XCTAssertEqual(got.text, body)  // 不变
    }

    // MARK: - flush

    func testFlushSubtractsBlacklist() throws {
        let store = try makeStore()
        // flushInterval 给很大，避免自动 flush 干扰。
        let writer = TypingRecordWriter(store: store, flushInterval: 1000)
        writer.accumulate(commitTexts: ["keepXXXX"], bundleId: "x", nowMs: 1)
        writer.recordBurst(key: .init(bundleId: "x", elementHash: 1),
                           segment: "XXXX", now: 0)
        writer.flush(bundleId: "x", nowMs: 2)

        let got = try XCTUnwrap(store.fetch(bundleId: "x"))
        XCTAssertEqual(got.text, "keep")  // 黑名单 "XXXX" 被减掉
    }

    func testFlushAppendsToExistingDBRow() throws {
        let store = try makeStore()
        try store.upsert(TypingEvent(bundleId: "x", text: "first", editLog: "[]",
                                     timeStart: 1, lastUpdated: 1, totalChars: 5))
        let writer = TypingRecordWriter(store: store, flushInterval: 1000)
        writer.accumulate(commitTexts: ["second"], bundleId: "x", nowMs: 10)
        writer.flush(bundleId: "x", nowMs: 11)

        let got = try XCTUnwrap(store.fetch(bundleId: "x"))
        XCTAssertEqual(got.text, "firstsecond")        // 追加，不覆盖
        XCTAssertEqual(got.timeStart, 1)               // 沿用旧 time_start
    }

    // MARK: - flush 计时重置

    func testScheduleFlushResetsTimer() {
        // flushInterval 给很大 → 测的是「重置」，不是「触发」。
        let writer = TypingRecordWriter(store: nil, flushInterval: 1000)
        writer.accumulate(commitTexts: ["a"], bundleId: "x", nowMs: 1)
        let t1 = writer.records["x"]?.flushTimer
        XCTAssertNotNil(t1)

        writer.accumulate(commitTexts: ["b"], bundleId: "x", nowMs: 2)
        let t2 = writer.records["x"]?.flushTimer
        XCTAssertNotNil(t2)

        // 旧 timer 被作废、换了新对象。
        XCTAssertFalse(t1!.isValid)
        XCTAssertTrue(t2!.isValid)
        XCTAssertFalse(t1 === t2)
    }

    func testFlushTimerFiresAndPersists() async throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, flushInterval: 0.05)
        writer.accumulate(commitTexts: ["hello"], bundleId: "x",
                          nowMs: TypingRecordWriter.nowMs())

        // 等 debounce 计时器在主 run loop 上触发。
        let exp = expectation(description: "flush fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        let got = try XCTUnwrap(store.fetch(bundleId: "x"))
        XCTAssertEqual(got.text, "hello")
    }

    // MARK: - 黑名单 TTL 清理

    func testCleanupBlacklistTTL() {
        let writer = TypingRecordWriter(store: nil)
        let key = TypingRecordWriter.ElementKey(bundleId: "x", elementHash: 1)
        writer.recordBurst(key: key, segment: "old", now: 0)        // ts 0
        writer.recordBurst(key: key, segment: "fresh", now: 4000)   // ts 4000

        // now = 4000：old 距今 4000s > 3600s → 删；fresh 距今 0s → 留。
        writer.cleanupBlacklist(now: 4000)
        XCTAssertEqual(writer.blacklist[key].map { Set($0.keys) }, ["fresh"])
    }
}
