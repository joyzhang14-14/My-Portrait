import XCTest
@testable import MyPortrait

/// IMEStateMachine 单测 —— Layer 2 IME 折叠层。
///
/// 状态机内部 `state` 不暴露，状态变化通过「下一个 feed 的行为」验证。
/// normalize 不输出事件，断言 `lastTraceTag`。
final class IMEStateMachineTests: XCTestCase {

    // MARK: - 构造辅助

    private func insert(_ text: String, at location: Int = 0, ts: TimeInterval = 0) -> RawEdit {
        RawEdit(kind: .insert, text: text, script: Script.classify(text),
                range: NSRange(location: location, length: 0),
                ts: ts, pid: 42, elementHash: 7, traceTag: nil)
    }

    private func replace(_ text: String, location: Int, length: Int,
                         ts: TimeInterval = 0) -> RawEdit {
        RawEdit(kind: .replace, text: text, script: Script.classify(text),
                range: NSRange(location: location, length: length),
                ts: ts, pid: 42, elementHash: 7, traceTag: nil)
    }

    private func delete(location: Int = 0, length: Int = 1,
                        ts: TimeInterval = 0) -> RawEdit {
        RawEdit(kind: .delete, text: "", script: .latin,
                range: NSRange(location: location, length: length),
                ts: ts, pid: 42, elementHash: 7, traceTag: nil)
    }

    // MARK: - 11 条规则

    func testRule1_idleInsertCJK_emitsCommit() {
        let sm = IMEStateMachine()
        let events = sm.feed(insert("中"))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "中")
        XCTAssertEqual(events[0].script, .cjk)
        XCTAssertEqual(events[0].traceTag, .l2Commit(text: "中"))
    }

    func testRule2_idleInsertLatin_entersComposing() {
        let sm = IMEStateMachine()
        let events = sm.feed(insert("h"))
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(sm.lastTraceTag, nil) // normalize 未触发
        // 验证已进 Composing：紧接 delete 应砍 buffer（规则 7），不是 idle-delete。
        let next = sm.feed(delete())
        XCTAssertEqual(next.count, 0) // buffer "h" 砍空 → 回 Idle，不输出
    }

    func testRule3_composingInsertContiguous_appends() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("h", at: 0))          // 进 Composing，anchor=[0,1]
        let events = sm.feed(insert("i", at: 1)) // 连续，location == anchorLoc+anchorLen
        XCTAssertEqual(events.count, 0)
        // buffer 现在是 "hi"；焦点切换应 flush "hi"。
        let flushed = sm.handleFocusChange()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].text, "hi")
    }

    func testRule4_composingInsertNonContiguous_flushAndOpen() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("ab", at: 0))           // Composing，anchor=[0,2]
        let events = sm.feed(insert("x", at: 99))  // 非连续 location
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "ab")
        XCTAssertEqual(events[0].traceTag, .l2FlushAndOpen(flushed: "ab", opened: "x"))
        // 新 Composing 已开（buffer="x"）：焦点切换 flush "x"。
        let flushed = sm.handleFocusChange()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].text, "x")
    }

    func testRule5_composingReplaceCJK_emitsCJKCommit() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("zhong", at: 0))        // Composing，anchor=[0,5]
        let events = sm.feed(replace("中", location: 0, length: 5))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "中")
        XCTAssertEqual(events[0].script, .cjk)
        // 已回 Idle：紧接 cjk insert 应直接 commit（规则 1）。
        let next = sm.feed(insert("国"))
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].text, "国")
    }

    func testRule6_composingReplaceLatin_emitsLatinCommit() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("ab", at: 0))           // Composing，anchor=[0,2]
        let events = sm.feed(replace("cd", location: 0, length: 2))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "cd")
        XCTAssertEqual(events[0].script, .latin)
        // 已回 Idle：tick 不应再 flush。
        XCTAssertEqual(sm.tick(now: 1000).count, 0)
    }

    func testRule7_composingDelete_shrinksBuffer() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("h", at: 0))            // anchor=[0,1]
        _ = sm.feed(insert("i", at: 1))            // buffer="hi"
        let events = sm.feed(delete())             // 砍成 "h"，非空，不输出
        XCTAssertEqual(events.count, 0)
        // 仍在 Composing：focus change flush "h"。
        let flushed = sm.handleFocusChange()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].text, "h")
    }

    func testRule7_composingDeleteEmpty_returnsToIdle() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("h", at: 0))            // buffer="h"
        let events = sm.feed(delete())             // 砍空 → 回 Idle
        XCTAssertEqual(events.count, 0)
        // 已回 Idle：再 delete 应输出 idle-delete 信号（规则 8）。
        let next = sm.feed(delete())
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].kind, .delete)
        XCTAssertEqual(next[0].traceTag, .l2IdleDelete)
    }

    func testRule8_idleDelete_emitsDeleteSignal() {
        let sm = IMEStateMachine()
        let events = sm.feed(delete())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .delete)
        XCTAssertEqual(events[0].text, "")
        XCTAssertEqual(events[0].traceTag, .l2IdleDelete)
    }

    func testRule9_composingTimeout_flushesAsLatin() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("hel", at: 0, ts: 0))   // openedAt = 0
        // 未超时：tick 不 flush。
        XCTAssertEqual(sm.tick(now: 0.2).count, 0)  // 200ms < 350ms
        // 超时：now - openedAt = 400ms > 350ms。
        let events = sm.tick(now: 0.4)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "hel")
        XCTAssertEqual(events[0].script, .latin)
        // 已回 Idle：再 tick 不输出。
        XCTAssertEqual(sm.tick(now: 1.0).count, 0)
    }

    func testRule10_focusChange_flushesComposingBuffer() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("wo", at: 0))
        let events = sm.handleFocusChange()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "wo")
        // 已回 Idle：再 focus change 不输出。
        XCTAssertEqual(sm.handleFocusChange().count, 0)
    }

    func testRule11_unrecognized_passesThrough() {
        // Idle + replace（range.length > 0，非空 text）：normalize 不重写，
        // 规则 1/2 只吃 insert，规则 5/6 只在 Composing → 落到规则 11。
        let sm = IMEStateMachine()
        let events = sm.feed(replace("foo", location: 3, length: 2))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "foo")
        XCTAssertEqual(events[0].traceTag, .l2Commit(text: "foo"))
    }

    // MARK: - normalize 3 条

    func testNormalize_emptyInsert_dropped() {
        let sm = IMEStateMachine()
        let events = sm.feed(insert("", at: 0))
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(sm.lastTraceTag, .l2DropEmptyInsert)
    }

    func testNormalize_emptyReplace_treatedAsDelete() {
        // replace text 空 + range.length > 0 → 重写为 delete。
        // 在 Idle 下 → 走规则 8 输出 delete 信号。
        let sm = IMEStateMachine()
        let events = sm.feed(replace("", location: 0, length: 3))
        XCTAssertEqual(sm.lastTraceTag, .l2RewriteReplaceToDelete)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .delete)
        XCTAssertEqual(events[0].traceTag, .l2IdleDelete)
    }

    func testNormalize_zeroLengthReplace_treatedAsInsert() {
        // replace range.length == 0 → 重写为 insert。
        // Idle + latin insert → 进 Composing（规则 2），不输出。
        let sm = IMEStateMachine()
        let events = sm.feed(replace("h", location: 0, length: 0))
        XCTAssertEqual(sm.lastTraceTag, .l2RewriteReplaceToInsert)
        XCTAssertEqual(events.count, 0)
        // 验证已进 Composing：focus change flush "h"。
        let flushed = sm.handleFocusChange()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].text, "h")
    }

    // MARK: - 边界 case

    func testEdge_chineseFullCommit() {
        let sm = IMEStateMachine()
        let events = sm.feed(insert("你好世界"))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "你好世界")
        XCTAssertEqual(events[0].script, .cjk)
    }

    func testEdge_emojiZWJ() {
        // 👨‍👩‍👧 是 ZWJ 序列：1 个 Character 但多个 UTF-16 单元。
        // emoji scalar 既非 CJK 也非 latin，classify 0% CJK → .latin（spec 口径）。
        // 走 latin path → 进 Composing；focus change flush 验证 buffer 完整往返。
        let emoji = "👨‍👩‍👧"
        XCTAssertGreaterThan(emoji.utf16.count, 1) // 多 UTF-16 单元
        let sm = IMEStateMachine()
        let raw = RawEdit(kind: .insert, text: emoji, script: Script.classify(emoji),
                          range: NSRange(location: 0, length: emoji.utf16.count),
                          ts: 0, pid: 42, elementHash: 7, traceTag: nil)
        let entered = sm.feed(raw)
        XCTAssertEqual(entered.count, 0) // 进 Composing
        let flushed = sm.handleFocusChange()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].kind, .commit)
        XCTAssertEqual(flushed[0].text, emoji) // 多 UTF-16 单元不出错
    }

    func testEdge_mixedScript20PercentCJK_usesCJKPath() {
        // "中abcd"：1 cjk / 5 total = 20% → usesCJKPath true → 规则 1 commit。
        let text = "中abcd"
        XCTAssertEqual(Script.classify(text), .mixed)
        XCTAssertTrue(Script.classify(text).usesCJKPath(text))
        let sm = IMEStateMachine()
        let events = sm.feed(insert(text))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
    }

    func testEdge_mixedScriptUnder20PercentCJK_usesLatinPath() {
        // "中abcde": 1 cjk / 6 total ≈ 16.7% < 20% → usesCJKPath false → 进 Composing。
        let text = "中abcde"
        XCTAssertEqual(Script.classify(text), .mixed)
        XCTAssertFalse(Script.classify(text).usesCJKPath(text))
        let sm = IMEStateMachine()
        let events = sm.feed(insert(text))
        XCTAssertEqual(events.count, 0) // 进 Composing，不输出
    }

    func testEdge_pinyinLongWord_bufferAccumulates_thenCJKReplace() {
        let sm = IMEStateMachine()
        _ = sm.feed(insert("z", at: 0))
        _ = sm.feed(insert("h", at: 1))
        _ = sm.feed(insert("o", at: 2))
        _ = sm.feed(insert("n", at: 3))
        _ = sm.feed(insert("g", at: 4))            // buffer="zhong", anchor=[0,5]
        let events = sm.feed(replace("中", location: 0, length: 5))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "中")
        XCTAssertEqual(events[0].script, .cjk)
    }

    func testEdge_selectionReplace_singleCharAnchor() {
        // "我" 进 Composing（cjk path? "我" 是纯 cjk → 规则 1 直接 commit，
        // 不进 Composing）。要命中规则 5/6 需 buffer 是 latin。
        // 用 latin 单字符 buffer 模拟选区替换：insert "x" → Composing anchor=[0,1]，
        // replace "你" 覆盖 [0,1] → 规则 5 cjk commit。
        let sm = IMEStateMachine()
        _ = sm.feed(insert("x", at: 0))            // Composing anchor=[0,1]
        let events = sm.feed(replace("你", location: 0, length: 1))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .commit)
        XCTAssertEqual(events[0].text, "你")
        XCTAssertEqual(events[0].script, .cjk)
    }

    func testTickWithoutComposing_noOp() {
        let sm = IMEStateMachine()
        XCTAssertEqual(sm.tick(now: 1000).count, 0)
    }
}
