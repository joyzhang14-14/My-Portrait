import XCTest
import GRDB
@testable import MyPortrait

/// `TypingEventStore`（v13 master-record schema）基础写入 / 查询测试。
/// 用临时文件 DatabasePool + 跑 `DBSchema.migrator()`（WAL 模式不支持
/// `:memory:`，跟 PortraitDBImplTests 一致）。
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
        // 注册 ICU 分词器，否则 v1 的 frames_fts migration 会失败
        // （跟 PortraitDBImpl.init 一致）。
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: FoundationTokenizer.self)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(pool)
        return TypingEventStore(dbPool: pool)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// upsert 一条 → fetch 取回，字段一致。
    func testUpsertAndFetch() throws {
        let store = try makeStore()
        let ts = nowMs()
        let event = TypingEvent(
            bundleId: "com.tinyspeck.slackmacgap",
            text: "hello world",
            editLog: #"[{"ts":1,"kind":"commit","text":"hello world"}]"#,
            timeStart: ts,
            lastUpdated: ts + 500,
            totalChars: 11
        )
        try store.upsert(event)

        let got = try XCTUnwrap(store.fetch(bundleId: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(got.bundleId, event.bundleId)
        XCTAssertEqual(got.text, event.text)
        XCTAssertEqual(got.editLog, event.editLog)
        XCTAssertEqual(got.timeStart, event.timeStart)
        XCTAssertEqual(got.lastUpdated, event.lastUpdated)
        XCTAssertEqual(got.totalChars, event.totalChars)
    }

    /// 同 bundle_id 再 upsert → 整行替换（不是插第二行）。
    func testUpsertReplacesSameBundle() throws {
        let store = try makeStore()
        let ts = nowMs()
        try store.upsert(TypingEvent(bundleId: "app.x", text: "v1", editLog: "[]",
                                     timeStart: ts, lastUpdated: ts, totalChars: 2))
        try store.upsert(TypingEvent(bundleId: "app.x", text: "v2-longer", editLog: "[]",
                                     timeStart: ts, lastUpdated: ts + 100, totalChars: 9))

        let all = try store.recentApps(limit: 100)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.text, "v2-longer")
    }

    /// fetch 不存在的 bundle → nil。
    func testFetchMissing() throws {
        let store = try makeStore()
        XCTAssertNil(try store.fetch(bundleId: "no.such.app"))
    }

    /// recentApps 按 last_updated 降序。
    func testRecentAppsOrder() throws {
        let store = try makeStore()
        let ts = nowMs()
        try store.upsert(TypingEvent(bundleId: "app.old", text: "o", editLog: "[]",
                                     timeStart: ts, lastUpdated: ts - 1000, totalChars: 1))
        try store.upsert(TypingEvent(bundleId: "app.new", text: "n", editLog: "[]",
                                     timeStart: ts, lastUpdated: ts, totalChars: 1))

        let recent = try store.recentApps(limit: 10)
        XCTAssertEqual(recent.map(\.bundleId), ["app.new", "app.old"])
    }
}
