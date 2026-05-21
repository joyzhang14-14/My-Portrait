import XCTest
import GRDB
@testable import MyPortrait

/// `TypingEventStore` 基础写入 / 查询测试。用临时文件 DatabasePool + 跑
/// `DBSchema.migrator()`（WAL 模式不支持 `:memory:`，跟 PortraitDBImplTests 一致）。
final class TypingEventStoreTests: XCTestCase {

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
            .appendingPathComponent("MyPortraitTypingTest-\(UUID().uuidString).sqlite")
            .path
        tempPaths.append(path)
        // 注册 ICU 分词器，否则 v1 的 frames_fts migration 会因
        // "no such tokenizer: foundation_icu" 失败（跟 PortraitDBImpl.init 一致）。
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: FoundationTokenizer.self)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(pool)
        return TypingEventStore(dbPool: pool)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// insert 一条 → recent(1) 取回，字段一致。
    func testInsertAndRecent() throws {
        let store = try makeStore()
        let ts = nowMs()
        let event = TypingEvent(
            id: nil,
            startedAtMs: ts,
            endedAtMs: ts + 500,
            bundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "general",
            url: nil,
            elementRole: "AXTextArea",
            threadId: "thread-1",
            text: "hello world",
            charCount: 11,
            languageHint: "latin",
            createdAtMs: ts + 600
        )
        try store.insert(event)

        let fetched = try store.recent(limit: 1)
        XCTAssertEqual(fetched.count, 1)
        let got = try XCTUnwrap(fetched.first)
        XCTAssertNotNil(got.id)
        XCTAssertEqual(got.startedAtMs, event.startedAtMs)
        XCTAssertEqual(got.endedAtMs, event.endedAtMs)
        XCTAssertEqual(got.bundleId, event.bundleId)
        XCTAssertEqual(got.appName, event.appName)
        XCTAssertEqual(got.windowTitle, event.windowTitle)
        XCTAssertEqual(got.url, event.url)
        XCTAssertEqual(got.elementRole, event.elementRole)
        XCTAssertEqual(got.threadId, event.threadId)
        XCTAssertEqual(got.text, event.text)
        XCTAssertEqual(got.charCount, event.charCount)
        XCTAssertEqual(got.languageHint, event.languageHint)
        XCTAssertEqual(got.createdAtMs, event.createdAtMs)
    }

    /// editLog + closeReason 经 DB 往返一致（v12：edit_log JSON 列）。
    func testEditLogAndCloseReasonRoundTrip() throws {
        let store = try makeStore()
        let ts = nowMs()
        let editLog = [
            EditEntry(ts: 0.0, kind: .commit, text: "hel"),
            EditEntry(ts: 0.4, kind: .delete, text: "l"),
            EditEntry(ts: 0.8, kind: .commit, text: "llo"),
        ]
        let event = TypingEvent(
            id: nil,
            startedAtMs: ts,
            endedAtMs: ts + 800,
            bundleId: "com.example.app",
            appName: "Example",
            windowTitle: "win",
            url: nil,
            elementRole: "AXTextField",
            threadId: "t-edit",
            text: "hello",
            charCount: 5,
            languageHint: "latin",
            createdAtMs: ts + 900,
            editLog: editLog,
            closeReason: "submit"
        )
        try store.insert(event)

        let fetched = try XCTUnwrap(try store.recent(limit: 1).first)
        XCTAssertEqual(fetched.editLog, editLog)
        XCTAssertEqual(fetched.closeReason, "submit")
    }

    /// 默认构造（不传 editLog / closeReason）→ DB 里是空数组 / NULL。
    func testInsertWithoutEditLog_defaultsEmpty() throws {
        let store = try makeStore()
        let ts = nowMs()
        let event = TypingEvent(
            id: nil,
            startedAtMs: ts,
            endedAtMs: ts + 100,
            bundleId: "b",
            appName: nil,
            windowTitle: nil,
            url: nil,
            elementRole: nil,
            threadId: "t-default",
            text: "abc",
            charCount: 3,
            languageHint: nil,
            createdAtMs: ts
        )
        try store.insert(event)
        let fetched = try XCTUnwrap(try store.recent(limit: 1).first)
        XCTAssertEqual(fetched.editLog, [])
        XCTAssertNil(fetched.closeReason)
    }

    /// lastEvent：窗口内查得到，超出 1 小时窗口查不到。
    func testLastEventRespectsWindow() throws {
        let store = try makeStore()
        let now = nowMs()

        let recent = TypingEvent(
            id: nil,
            startedAtMs: now,
            endedAtMs: now + 100,
            bundleId: "x",
            appName: "App X",
            windowTitle: "y",
            url: nil,
            elementRole: nil,
            threadId: "t-recent",
            text: "fresh",
            charCount: 5,
            languageHint: nil,
            createdAtMs: now
        )
        try store.insert(recent)

        // 1 小时窗口内能找到。
        let hit = try store.lastEvent(bundleId: "x", windowTitle: "y", withinMs: 3_600_000)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.text, "fresh")

        // 插一条 2 小时前的同 (bundle, window)，1 小时窗口查不到。
        let stale = TypingEvent(
            id: nil,
            startedAtMs: now - 7_200_000,
            endedAtMs: now - 7_200_000 + 100,
            bundleId: "stale-bundle",
            appName: "App Stale",
            windowTitle: "stale-window",
            url: nil,
            elementRole: nil,
            threadId: "t-stale",
            text: "old",
            charCount: 3,
            languageHint: nil,
            createdAtMs: now - 7_200_000
        )
        try store.insert(stale)

        let miss = try store.lastEvent(
            bundleId: "stale-bundle", windowTitle: "stale-window", withinMs: 3_600_000)
        XCTAssertNil(miss)
    }
}
