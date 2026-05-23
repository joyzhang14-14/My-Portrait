import XCTest
import GRDB
@testable import MyPortrait

/// `TypingRecordWriter`（v14 event-log 模型）单测：净新增 text / burst /
/// 黑名单减法 / flush INSERT / 多 element 独立。
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

    // MARK: - sessionText：净新增内容

    /// 空 element 打字 → text = 全部输入。
    func testSessionTextFromEmpty() {
        XCTAssertEqual(
            TypingRecordWriter.sessionText(sessionStart: "", finalValue: "你好"),
            "你好")
    }

    /// 末尾追加 → text 只含追加部分。
    func testSessionTextAppend() {
        XCTAssertEqual(
            TypingRecordWriter.sessionText(sessionStart: "ABC", finalValue: "ABCDEF"),
            "DEF")
    }

    /// 中段插入 —— text 只含插入的字，不把旧内容吸进来（修「吸走笔记」bug）。
    func testSessionTextMidInsertDoesNotAbsorb() {
        XCTAssertEqual(
            TypingRecordWriter.sessionText(sessionStart: "ABCD", finalValue: "ABXXXCD"),
            "XXX")
    }

    /// 一大段已有内容里只插了 XXX → text = "XXX"，不是整篇。
    func testSessionTextMidInsertLongDoc() {
        let doc = "第一段内容。\n第二段内容。\n第三段。"
        let edited = "第一段内容。\n第二XXX段内容。\n第三段。"
        XCTAssertEqual(
            TypingRecordWriter.sessionText(sessionStart: doc, finalValue: edited),
            "XXX")
    }

    /// 删除旧内容 → 净新增为空。
    func testSessionTextPureDelete() {
        XCTAssertEqual(
            TypingRecordWriter.sessionText(sessionStart: "你好世界", finalValue: "你好"),
            "")
    }

    // MARK: - 纯函数

    func testIsBurst() {
        XCTAssertTrue(TypingRecordWriter.isBurst(jumpChars: 11, intervalMs: 29))
        XCTAssertFalse(TypingRecordWriter.isBurst(jumpChars: 10, intervalMs: 29))
        XCTAssertFalse(TypingRecordWriter.isBurst(jumpChars: 11, intervalMs: 30))
    }

    func testLooksLikeSubmitClear() {
        // 真发送:value 清空 → 是
        XCTAssertTrue(TypingRecordWriter.looksLikeSubmitClear(
            message: "因为有的app", newValue: "", sessionStart: ""))

        // 真发送:value 回到 session 初始 placeholder → 是
        XCTAssertTrue(TypingRecordWriter.looksLikeSubmitClear(
            message: "hello world", newValue: "Write a message...",
            sessionStart: "Write a message..."))

        // Bug 复现:Claude desktop plain Enter 插换行 → 不是
        XCTAssertFalse(TypingRecordWriter.looksLikeSubmitClear(
            message: "因为有的app", newValue: "因为有的app\n", sessionStart: ""))

        // IME commit Enter:value 长度差不多 → 不是
        XCTAssertFalse(TypingRecordWriter.looksLikeSubmitClear(
            message: "yin w", newValue: "因", sessionStart: ""))

        // 长消息 + 断崖下降 → 是(覆盖 placeholder 短的情况)
        XCTAssertTrue(TypingRecordWriter.looksLikeSubmitClear(
            message: String(repeating: "a", count: 50), newValue: "Send a msg",
            sessionStart: ""))

        // 短消息 + 没清空 → 不是(避免短消息误判)
        XCTAssertFalse(TypingRecordWriter.looksLikeSubmitClear(
            message: "hi", newValue: "hi.", sessionStart: ""))
    }

    func testIsOversizedDelta() {
        // 1258 字 + 0 按键(Obsidian 切 note) → 触发
        XCTAssertTrue(TypingRecordWriter.isOversizedDelta(jumpChars: 1258, keystrokeCount: 0))
        // 1258 字 + 1 按键(用户按了一下箭头 + 程序注入) → 仍触发
        XCTAssertTrue(TypingRecordWriter.isOversizedDelta(jumpChars: 1258, keystrokeCount: 1))
        // 跳变 ≤ floor 50,即使 0 按键也不算
        XCTAssertFalse(TypingRecordWriter.isOversizedDelta(jumpChars: 50, keystrokeCount: 0))
        // 中文 IME 短 commit:「你好世界」4 字 + 1 键 → 远低 floor,不触发
        XCTAssertFalse(TypingRecordWriter.isOversizedDelta(jumpChars: 4, keystrokeCount: 1))
        // 边界:51 字 + 51 键(用户用键盘连打 51 字) → 不触发
        XCTAssertFalse(TypingRecordWriter.isOversizedDelta(jumpChars: 51, keystrokeCount: 51))
        // snippet expand:60 字 + 6 键 —— 6 键不可能产 60 字,触发
        XCTAssertTrue(TypingRecordWriter.isOversizedDelta(jumpChars: 60, keystrokeCount: 6))
        // 52 字 + 51 键(快打多出 1 字,可能 IME 选词) → 触发
        // ↑ 这条边界严苛,但用户确认要 1:1。floor=50 已经保护正常 IME 用法。
        XCTAssertTrue(TypingRecordWriter.isOversizedDelta(jumpChars: 52, keystrokeCount: 51))
    }

    func testStripBlacklist() {
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("aXXbXX", blacklist: ["XX"]).text, "abXX")
        // 长度倒序：先减 XXXX，剩 "ab"，"XX" 找不到。
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("aXXXXb",
                                                         blacklist: ["XX", "XXXX"]).text, "ab")
        XCTAssertEqual(TypingRecordWriter.stripBlacklist("keep", blacklist: []).text, "keep")
        // 命中的段进 stripped，没命中的不进。
        let r = TypingRecordWriter.stripBlacklist("aXXb", blacklist: ["XX", "ZZ"])
        XCTAssertEqual(r.text, "ab")
        XCTAssertEqual(r.stripped, ["XX"])
    }

    /// stripped 持久化往返：encode → decode 不丢。
    func testStrippedRoundTrip() {
        let set: Set<String> = ["pasted junk", "burst"]
        XCTAssertEqual(
            TypingRecordWriter.decodeStrings(TypingRecordWriter.encodeStrings(set)), set)
        XCTAssertEqual(TypingRecordWriter.decodeStrings("[]"), [])
    }

    // MARK: - flush

    /// flush → INSERT 一条 record，text = 净新增；flush 后 record 从 state 移除。
    func testFlushInsertsNetText() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger(), pasteboard: PasteboardMonitor())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)
        writer.beginSession(key: key, bundleId: "app.a", baseline: "", url: "")
        let rec = try XCTUnwrap(writer.state[key])
        rec.lastValueSnapshot = "hello"
        rec.pendingChanges = true
        writer.flushElement(key)

        writer.waitForPendingDBWork()
        let recs = try store.records(bundleId: "app.a", url: "")
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.text, "hello")
        XCTAssertNil(writer.state[key])
    }

    /// 已有内容的 element 里中段插入 → 落库 text 只含插入字，不含旧内容。
    func testFlushMidInsertDoesNotAbsorb() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger(), pasteboard: PasteboardMonitor())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)
        writer.beginSession(key: key, bundleId: "app.a", baseline: "一大段已有的笔记内容", url: "")
        let rec = try XCTUnwrap(writer.state[key])
        rec.lastValueSnapshot = "一大段已XXX有的笔记内容"
        rec.pendingChanges = true
        writer.flushElement(key)

        writer.waitForPendingDBWork()
        XCTAssertEqual(try store.records(bundleId: "app.a", url: "").first?.text, "XXX")
    }

    /// 没发生变化的 session → flush 不落库。
    func testFlushSkipsEmptySession() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger(), pasteboard: PasteboardMonitor())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)
        writer.beginSession(key: key, bundleId: "app.a", baseline: "", url: "")
        writer.flushElement(key)
        XCTAssertEqual(try store.records(bundleId: "app.a", url: "").count, 0)
    }

    /// 两个 element 各自独立 record（不再 UPSERT 同 bundle_id）。
    func testMultipleElementsIndependent() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger(), pasteboard: PasteboardMonitor())
        for (eh, txt) in [(1, "first"), (2, "second")] {
            let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: eh)
            writer.beginSession(key: key, bundleId: "app.a", baseline: "", url: "")
            let rec = try XCTUnwrap(writer.state[key])
            rec.lastValueSnapshot = txt
            rec.pendingChanges = true
            writer.flushElement(key)
        }
        writer.waitForPendingDBWork()
        let recs = try store.records(bundleId: "app.a", url: "")
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(Set(recs.map(\.text)), ["first", "second"])
    }

    // MARK: - continuation 合并

    func testIsContinuation() {
        XCTAssertTrue(TypingRecordWriter.isContinuation(
            sessionStart: "ABC", recordEndValue: "ABC"))
        XCTAssertFalse(TypingRecordWriter.isContinuation(
            sessionStart: "", recordEndValue: "ABC"))      // 空起点（聊天发送后）
        XCTAssertFalse(TypingRecordWriter.isContinuation(
            sessionStart: "ABC", recordEndValue: ""))
        XCTAssertFalse(TypingRecordWriter.isContinuation(
            sessionStart: "XYZ", recordEndValue: "ABC"))
        // 首尾两个锚点都要对上：尾 100 字相同但首不同 → 不算延续（防误合并）。
        let tail = String(repeating: "x", count: 100)
        XCTAssertFalse(TypingRecordWriter.isContinuation(
            sessionStart: "AAAA" + tail, recordEndValue: "BBBB" + tail))
        // 首尾都相同 → 延续。
        let big = String(repeating: "本", count: 300)
        XCTAssertTrue(TypingRecordWriter.isContinuation(
            sessionStart: big, recordEndValue: big))
    }

    /// 起点接得上已有 record → 合并，不新建。
    func testMergeContinuation() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger(), pasteboard: PasteboardMonitor())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)

        writer.beginSession(key: key, bundleId: "app.a", baseline: "", url: "")
        writer.state[key]?.lastValueSnapshot = "ABC"
        writer.state[key]?.pendingChanges = true
        writer.flushElement(key)

        // session 2 起点 = "ABC"，接得上 record1 的 end_value "ABC"。
        writer.beginSession(key: key, bundleId: "app.a", baseline: "ABC", url: "")
        writer.state[key]?.lastValueSnapshot = "ABCDEF"
        writer.state[key]?.pendingChanges = true
        writer.flushElement(key)

        writer.waitForPendingDBWork()
        let recs = try store.records(bundleId: "app.a", url: "")
        XCTAssertEqual(recs.count, 1)               // 合并，没新建
        XCTAssertEqual(recs.first?.text, "ABCDEF")
        XCTAssertEqual(recs.first?.endValue, "ABCDEF")
    }

    /// 聊天每条消息发送后输入框清空 → 起点为空 → 每条独立，不合并。
    func testChatMessagesStayIndependent() throws {
        let store = try makeStore()
        let writer = TypingRecordWriter(store: store, ledger: KeystrokeLedger(), pasteboard: PasteboardMonitor())
        let key = TypingRecordWriter.ElementKey(pid: 1, elementHash: 1)
        for msg in ["msg1", "msg2"] {
            writer.beginSession(key: key, bundleId: "app.chat", baseline: "", url: "")
            writer.state[key]?.lastValueSnapshot = msg
            writer.state[key]?.pendingChanges = true
            writer.flushElement(key)
        }
        writer.waitForPendingDBWork()
        XCTAssertEqual(try store.records(bundleId: "app.chat", url: "").count, 2)
    }
}
