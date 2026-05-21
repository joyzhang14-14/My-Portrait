import XCTest
import GRDB
@testable import MyPortrait

/// `TypingEventStore`（v14 event-log schema）测试。临时文件 DatabasePool +
/// 跑 `DBSchema.migrator()`（WAL 不支持 `:memory:`）。
@MainActor
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
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: FoundationTokenizer.self)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(pool)
        return TypingEventStore(dbPool: pool)
    }

    private func event(_ bundle: String, _ element: Int, started: Int64, ended: Int64,
                       text: String) -> TypingEvent {
        TypingEvent(id: nil, bundleId: bundle, elementHash: element,
                    startedAt: started, endedAt: ended, text: text,
                    editLog: "[]", totalChars: text.count)
    }

    /// insert → fetch，字段一致。
    func testInsertAndFetch() throws {
        let store = try makeStore()
        try store.insert(event("app.a", 1, started: 100, ended: 200, text: "hello"))
        let recs = try store.records(bundleId: "app.a")
        XCTAssertEqual(recs.count, 1)
        let got = try XCTUnwrap(recs.first)
        XCTAssertNotNil(got.id)
        XCTAssertEqual(got.bundleId, "app.a")
        XCTAssertEqual(got.elementHash, 1)
        XCTAssertEqual(got.text, "hello")
        XCTAssertEqual(got.startedAt, 100)
        XCTAssertEqual(got.endedAt, 200)
    }

    /// append-only —— 同 bundle 再 insert 是第二条 record，不是 upsert。
    func testAppendOnlyNotUpsert() throws {
        let store = try makeStore()
        try store.insert(event("app.a", 1, started: 1, ended: 2, text: "first"))
        try store.insert(event("app.a", 1, started: 3, ended: 4, text: "second"))
        XCTAssertEqual(try store.records(bundleId: "app.a").count, 2)
    }

    /// records 按 started_at 倒序。
    func testRecordsOrderDesc() throws {
        let store = try makeStore()
        try store.insert(event("a", 1, started: 100, ended: 200, text: "old"))
        try store.insert(event("a", 1, started: 300, ended: 400, text: "new"))
        XCTAssertEqual(try store.records(bundleId: "a").map(\.text), ["new", "old"])
    }

    /// appSummaries：按 app 聚合 count + 最近 ended_at，按 ended_at 倒序。
    func testAppSummaries() throws {
        let store = try makeStore()
        try store.insert(event("a", 1, started: 1, ended: 10, text: "x"))
        try store.insert(event("a", 1, started: 2, ended: 20, text: "y"))
        try store.insert(event("b", 1, started: 3, ended: 30, text: "z"))
        let s = try store.appSummaries()
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first?.bundleId, "b")   // ended 30 最近
        let a = try XCTUnwrap(s.first(where: { $0.bundleId == "a" }))
        XCTAssertEqual(a.recordCount, 2)
        XCTAssertEqual(a.lastEndedAt, 20)
    }

    /// delete 只删该 app 的 records。
    func testDelete() throws {
        let store = try makeStore()
        try store.insert(event("a", 1, started: 1, ended: 2, text: "x"))
        try store.insert(event("b", 1, started: 1, ended: 2, text: "y"))
        try store.delete(bundleId: "a")
        XCTAssertEqual(try store.records(bundleId: "a").count, 0)
        XCTAssertEqual(try store.records(bundleId: "b").count, 1)
    }
}
