import XCTest
@testable import MyPortrait

/// `TypingSessionAggregator` 单测 —— Layer 3 会话聚合层。
///
/// 纯数据 / 纯逻辑（不碰 AX / DB），全部通过 `feed` / `close` / `idleKeys`
/// 直接驱动。`EditEntry` 的 Codable round-trip 也在这里测。
final class TypingSessionAggregatorTests: XCTestCase {

    // MARK: - 构造辅助

    private func commit(_ text: String, ts: TimeInterval,
                        pid: pid_t = 42, elementHash: Int = 7) -> IMEFoldEvent {
        IMEFoldEvent(kind: .commit, text: text, script: Script.classify(text),
                     ts: ts, pid: pid, elementHash: elementHash, traceTag: nil)
    }

    private func delete(_ text: String, ts: TimeInterval,
                        pid: pid_t = 42, elementHash: Int = 7) -> IMEFoldEvent {
        IMEFoldEvent(kind: .delete, text: text, script: Script.classify(text),
                     ts: ts, pid: pid, elementHash: elementHash, traceTag: nil)
    }

    private let key = SessionKey(pid: 42, elementHash: 7)

    private func makeCtx() -> SessionContext {
        SessionContext(bundleId: "com.tinyspeck.slackmacgap",
                       appName: "Slack",
                       windowTitle: "general",
                       elementRole: "AXTextArea",
                       threadId: "thread-1")
    }

    // MARK: - feed

    /// 多条 commit → editLog 顺序 + ts 相对（首条 0.0）。
    func testFeedMultipleCommits_editLogOrderAndRelativeTs() {
        let agg = TypingSessionAggregator()
        let ctx = makeCtx()
        agg.feed(commit("he", ts: 100.0), key: key, ctx: ctx)
        agg.feed(commit("llo", ts: 100.5), key: key, ctx: ctx)
        agg.feed(commit(" world", ts: 101.2), key: key, ctx: ctx)

        let event = agg.close(key: key, finalText: "hello world", reason: "idle")
        let log = try! XCTUnwrap(event).editLog
        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(log[0].ts, 0.0, accuracy: 1e-9)       // 首条相对 0
        XCTAssertEqual(log[1].ts, 0.5, accuracy: 1e-9)
        XCTAssertEqual(log[2].ts, 1.2, accuracy: 1e-9)
        XCTAssertEqual(log.map(\.text), ["he", "llo", " world"])
        XCTAssertEqual(log.map(\.kind), [.commit, .commit, .commit])
    }

    /// commit + delete + commit 三条 → editLog 3 条，kind 正确。
    func testFeedCommitDeleteCommit_editLogThreeEntries() {
        let agg = TypingSessionAggregator()
        let ctx = makeCtx()
        agg.feed(commit("helo", ts: 0.0), key: key, ctx: ctx)
        agg.feed(delete("o", ts: 0.3), key: key, ctx: ctx)
        agg.feed(commit("llo", ts: 0.6), key: key, ctx: ctx)

        let event = try! XCTUnwrap(
            agg.close(key: key, finalText: "hello", reason: "idle"))
        XCTAssertEqual(event.editLog.count, 3)
        XCTAssertEqual(event.editLog.map(\.kind), [.commit, .delete, .commit])
        XCTAssertEqual(event.editLog.map(\.text), ["helo", "o", "llo"])
    }

    /// CJK 一条 commit → editLog 1 条。
    func testFeedSingleCJKCommit_editLogOneEntry() {
        let agg = TypingSessionAggregator()
        agg.feed(commit("你好世界", ts: 5.0), key: key, ctx: makeCtx())
        let event = try! XCTUnwrap(
            agg.close(key: key, finalText: "你好世界", reason: "idle"))
        XCTAssertEqual(event.editLog.count, 1)
        XCTAssertEqual(event.editLog[0].text, "你好世界")
        XCTAssertEqual(event.editLog[0].kind, .commit)
        XCTAssertEqual(event.languageHint, "cjk")
    }

    // MARK: - close

    /// finalText >= 3 → 产出 TypingEvent，字段正确。
    func testClose_finalTextOk_producesEventWithCorrectFields() {
        let agg = TypingSessionAggregator()
        let ctx = makeCtx()
        agg.feed(commit("hello", ts: 0.0), key: key, ctx: ctx)
        let event = try! XCTUnwrap(
            agg.close(key: key, finalText: "hello world", reason: "submit"))
        XCTAssertEqual(event.text, "hello world")
        XCTAssertEqual(event.charCount, 11)
        XCTAssertEqual(event.closeReason, "submit")
        XCTAssertEqual(event.bundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(event.appName, "Slack")
        XCTAssertEqual(event.windowTitle, "general")
        XCTAssertEqual(event.elementRole, "AXTextArea")
        XCTAssertEqual(event.threadId, "thread-1")
        XCTAssertNil(event.url)
        XCTAssertNil(event.id)
        XCTAssertEqual(event.languageHint, "latin")
        XCTAssertEqual(event.editLog.count, 1)
        XCTAssertGreaterThan(event.endedAtMs, 0)
        XCTAssertGreaterThan(event.createdAtMs, 0)
    }

    /// finalText < 3 → nil（丢弃）。
    func testClose_finalTextTooShort_returnsNil() {
        let agg = TypingSessionAggregator()
        agg.feed(commit("hi", ts: 0.0), key: key, ctx: makeCtx())
        XCTAssertNil(agg.close(key: key, finalText: "hi", reason: "idle"))
    }

    /// close 后 key 从字典移除（无论产出与否）。
    func testClose_removesKey() {
        let agg = TypingSessionAggregator()
        agg.feed(commit("hello", ts: 0.0), key: key, ctx: makeCtx())
        XCTAssertTrue(agg.hasSession(key))
        _ = agg.close(key: key, finalText: "hello", reason: "idle")
        XCTAssertFalse(agg.hasSession(key))

        // 产出 nil 的路径同样移除 key。
        agg.feed(commit("ab", ts: 0.0), key: key, ctx: makeCtx())
        XCTAssertTrue(agg.hasSession(key))
        XCTAssertNil(agg.close(key: key, finalText: "ab", reason: "idle"))
        XCTAssertFalse(agg.hasSession(key))
    }

    /// close 一个不存在的 key → nil，不崩。
    func testClose_unknownKey_returnsNil() {
        let agg = TypingSessionAggregator()
        XCTAssertNil(agg.close(key: key, finalText: "hello", reason: "idle"))
    }

    // MARK: - max_chars

    /// committedChars 超 10000 → feed 返回 true。
    func testFeed_overMaxChars_returnsTrue() {
        let agg = TypingSessionAggregator()
        let ctx = makeCtx()
        // 每条 4000 字符，第三条累计 12000 > 10000。
        let chunk = String(repeating: "x", count: 4000)
        XCTAssertFalse(agg.feed(commit(chunk, ts: 0.0), key: key, ctx: ctx))
        XCTAssertFalse(agg.feed(commit(chunk, ts: 1.0), key: key, ctx: ctx))
        XCTAssertTrue(agg.feed(commit(chunk, ts: 2.0), key: key, ctx: ctx))
    }

    /// delete 不计入 committedChars。
    func testFeed_deleteNotCountedTowardMaxChars() {
        let agg = TypingSessionAggregator()
        let ctx = makeCtx()
        let chunk = String(repeating: "y", count: 9000)
        XCTAssertFalse(agg.feed(commit(chunk, ts: 0.0), key: key, ctx: ctx))
        // delete 一大段 —— 不该把累计字符往上推。
        XCTAssertFalse(agg.feed(delete(chunk, ts: 1.0), key: key, ctx: ctx))
    }

    // MARK: - idleKeys

    /// lastTs 旧的 session → idleKeys 命中。
    func testIdleKeys_staleSessionHit() {
        let agg = TypingSessionAggregator()
        agg.feed(commit("hello", ts: 100.0), key: key, ctx: makeCtx())
        // now=105，idle=4 → 105-100=5 > 4 → 命中。
        XCTAssertEqual(agg.idleKeys(now: 105.0, idleSeconds: 4.0), [key])
        // now=103 → 3 < 4 → 不命中。
        XCTAssertTrue(agg.idleKeys(now: 103.0, idleSeconds: 4.0).isEmpty)
    }

    /// 多 key 时 idleKeys 只返回过期的那些。
    func testIdleKeys_multiKey() {
        let agg = TypingSessionAggregator()
        let keyA = SessionKey(pid: 1, elementHash: 1)
        let keyB = SessionKey(pid: 2, elementHash: 2)
        agg.feed(commit("aaa", ts: 100.0), key: keyA, ctx: makeCtx())
        agg.feed(commit("bbb", ts: 110.0), key: keyB, ctx: makeCtx())
        // now=106：A 已过期（6>4），B 未过期。
        XCTAssertEqual(agg.idleKeys(now: 106.0, idleSeconds: 4.0), [keyA])
    }

    // MARK: - EditEntry Codable round-trip

    func testEditEntry_codableRoundTrip() throws {
        let entries = [
            EditEntry(ts: 0.0, kind: .commit, text: "hello"),
            EditEntry(ts: 1.5, kind: .delete, text: "中文"),
            EditEntry(ts: 2.75, kind: .commit, text: ""),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([EditEntry].self, from: data)
        XCTAssertEqual(decoded, entries)
    }

    func testEditEntry_jsonShape() throws {
        let entry = EditEntry(ts: 0.0, kind: .commit, text: "hi")
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // kind 是字符串 raw value。
        XCTAssertTrue(json.contains("\"kind\":\"commit\""))
        XCTAssertTrue(json.contains("\"text\":\"hi\""))
    }
}
