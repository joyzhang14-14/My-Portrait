import XCTest
import GRDB
@testable import MyPortrait

/// `TypingRecordWriter`（v14 splice 模型）单测：splice 三态 / baseline 吸纳 /
/// burst / 黑名单减法 / flush INSERT / 多 element 独立。
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

    private func makeStore() throws -> TypingEventStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPortraitL4Test-\(UUID().uuidString).sqlite")
            .path
        tempPaths.append(path)
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let pool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(pool)
        return TypingEventStore(dbPool: pool)
    }

    private func makeRecord(baseline: String = "") -> TypingRecordWriter.InProgressRecord {
        TypingRecordWriter.InProgressRecord(bundleId: "app.a", elementHash: 1,
                                            baseline: baseline, nowMs: 0)
    }

    // MARK: - splice 三态

    func testSplicePureInsert() {
        let rec = makeRecord()
        TypingRecordWriter.splice(rec, prev: "", new: "hello", nowMs: 1)
        XCTAssertEqual(rec.text, "hello")
        XCTAssertEqual(rec.editLog.count, 1)
        XCTAssertEqual(rec.editLog.first?.kind, "commit")
    }

    func testSpliceInsertMiddle() {
        let rec = makeRecord()
        TypingRecordWriter.splice(rec, prev: "", new: "ad", nowMs: 1)
        TypingRecordWriter.splice(rec, prev: "ad", new: "abcd", nowMs: 2)
        XCTAssertEqual(rec.text, "abcd")    // 中段插入 "bc"
    }

    func testSplicePureDelete() {
        let rec = makeRecord()
        TypingRecordWriter.splice(rec, prev: "", new: "hello", nowMs: 1)
        TypingRecordWriter.splice(rec, prev: "hello", new: "heo", nowMs: 2)
        XCTAssertEqual(rec.text, "heo")
        XCTAssertEqual(rec.editLog.last?.kind, "delete")
        XCTAssertEqual(rec.editLog.last?.text, "ll")
    }

    /// 中段替换 —— KI-1 修复验证：detest → detect 必须就地替换，不能转位成 detetc。
    func testSpliceReplaceMidText() {
        let rec = makeRecord()
        TypingRecordWriter.splice(rec, prev: "", new: "detest", nowMs: 1)
        TypingRecordWriter.splice(rec, prev: "detest", new: "detect", nowMs: 2)
        XCTAssertEqual(rec.text, "detect")
    }

    // MARK: - baseline 吸纳

    /// 中段插入触及 baseline → baseline 被吸纳进 text。
    func testBaselineAbsorptionOnMidInsert() {
        let rec = makeRecord(baseline: "ABC")
        XCTAssertEqual(rec.baselineOffset, 3)
        TypingRecordWriter.splice(rec, prev: "ABC", new: "ABXC", nowMs: 1)
        XCTAssertEqual(rec.text, "ABXC")
        XCTAssertEqual(rec.baseline, "")
        XCTAssertEqual(rec.baselineOffset, 0)
    }

    /// 末尾追加不触及 baseline → baseline 不动，text 只含 session 输入。
    func testBaselineNotAbsorbedOnAppend() {
        let rec = makeRecord(baseline: "ABC")
        TypingRecordWriter.splice(rec, prev: "ABC", new: "ABCDEF", nowMs: 1)
        XCTAssertEqual(rec.text, "DEF")
        XCTAssertEqual(rec.baseline, "ABC")
    }

    /// 删除 baseline 内容（KI-2 场景）→ 吸纳 + 就地删除。
    func testBaselineAbsorptionOnDelete() {
        let rec = makeRecord(baseline: "你好世界")
        TypingRecordWriter.splice(rec, prev: "你好世界", new: "你好", nowMs: 1)
        XCTAssertEqual(rec.text, "你好")
        XCTAssertEqual(rec.baseline, "")
        XCTAssertEqual(rec.editLog.last?.kind, "delete")
        XCTAssertEqual(rec.editLog.last?.text, "世界")
    }

    // MARK: - 纯函数

    func testIsBurst() {
        XCTAssertTrue(TypingRecordWriter.isBurst(jumpChars: 11, intervalMs: 29))
        XCTAssertFalse(TypingRecordWriter.isBurst(jumpChars: 10, intervalMs: 29))
        XCTAssertFalse(TypingRecordWriter.isBurst(jumpChars: 11, intervalMs: 30))
    }

    func testStripBlacklist() {
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("aXXbXX", blacklist: ["XX"]), "abXX")
        // 长度倒序：先减 XXXX，剩 "ab"，"XX" 找不到。
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("aXXXXb", blacklist: ["XX", "XXXX"]), "ab")
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("keep", blacklist: []), "keep")
    }

    // MARK: - flush

    /// flush → INSERT 一条新 record；flush 后 record 从 state 移除。
    func testFlushInsertsRecord() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)
        writer.beginSession(key: key, bundleId: "app.a", baseline: "")
        let rec = try XCTUnwrap(writer.state[key])
        TypingRecordWriter.splice(rec, prev: "", new: "hello", nowMs: 1)
        rec.pendingChanges = true
        writer.flushElement(key)

        let recs = try store.records(bundleId: "app.a")
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.text, "hello")
        XCTAssertNil(writer.state[key])
    }

    /// 没发生变化的 session → flush 不落库。
    func testFlushSkipsEmptySession() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)
        writer.beginSession(key: key, bundleId: "app.a", baseline: "")
        writer.flushElement(key)
        XCTAssertEqual(try store.records(bundleId: "app.a").count, 0)
    }

    /// 两个 element 各自独立 record（不再 UPSERT 同 bundle_id）。
    func testMultipleElementsIndependent() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger())
        for (eh, txt) in [(1, "first"), (2, "second")] {
            let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: eh)
            writer.beginSession(key: key, bundleId: "app.a", baseline: "")
            let rec = try XCTUnwrap(writer.state[key])
            TypingRecordWriter.splice(rec, prev: "", new: txt, nowMs: 1)
            rec.pendingChanges = true
            writer.flushElement(key)
        }
        let recs = try store.records(bundleId: "app.a")
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(Set(recs.map(\.text)), ["first", "second"])
    }
}
