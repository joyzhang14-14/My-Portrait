import XCTest
@testable import MyPortrait

final class TextDiffTests: XCTestCase {

    // 1. 纯插入：尾部追加 + 中间插入。
    func testPureInsert() {
        let tail = TextDiff.diff(from: "hello", to: "hello world")
        XCTAssertEqual(tail?.kind, .insert)
        XCTAssertEqual(tail?.text, " world")
        XCTAssertNil(tail?.replacedText)

        let middle = TextDiff.diff(from: "abef", to: "abcdef")
        XCTAssertEqual(middle?.kind, .insert)
        XCTAssertEqual(middle?.text, "cd")
    }

    // 2. 纯删除：单字 backspace + 选中段删除。
    func testPureDelete() {
        let backspace = TextDiff.diff(from: "hello", to: "hell")
        XCTAssertEqual(backspace?.kind, .delete)
        XCTAssertEqual(backspace?.text, "o")

        let segment = TextDiff.diff(from: "hello world", to: "hello")
        XCTAssertEqual(segment?.kind, .delete)
        XCTAssertEqual(segment?.text, " world")
    }

    // 3. selection 替换：选中一段 → 替换。
    func testSelectionReplace() {
        let change = TextDiff.diff(from: "hello world", to: "hello swift")
        XCTAssertEqual(change?.kind, .replace)
        XCTAssertEqual(change?.replacedText, "world")
        XCTAssertEqual(change?.text, "swift")
    }

    // 4. CJK 多字符一次上屏 —— 一条 insert，不是 4 条单字符。
    func testCJKMultiCharCommit() {
        let fromEmpty = TextDiff.diff(from: "", to: "你好世界")
        XCTAssertEqual(fromEmpty?.kind, .insert)
        XCTAssertEqual(fromEmpty?.text, "你好世界")
        XCTAssertEqual(fromEmpty?.languageHint, "cjk")

        let fromAbc = TextDiff.diff(from: "abc", to: "abc你好世界")
        XCTAssertEqual(fromAbc?.kind, .insert)
        XCTAssertEqual(fromAbc?.text, "你好世界")
    }

    // 5. emoji ZWJ：插入 👨‍👩‍👧（带 ZWJ）—— emoji 完整不拆。
    func testEmojiZWJNotSplit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" // 👨‍👩‍👧
        let change = TextDiff.diff(from: "hi ", to: "hi " + family)
        XCTAssertEqual(change?.kind, .insert)
        XCTAssertEqual(change?.text, family)
        // 整个 ZWJ 序列是单个 Character。
        XCTAssertEqual(change?.text.count, 1)
    }

    // 6. 大段粘贴：插入 >1000 字符 —— 一条 insert，text 完整。
    func testLargePaste() {
        let pasted = String(repeating: "x", count: 1500)
        let change = TextDiff.diff(from: "start", to: "start" + pasted)
        XCTAssertEqual(change?.kind, .insert)
        XCTAssertEqual(change?.text, pasted)
        XCTAssertEqual(change?.text.count, 1500)
    }

    // 7. value 完全替换（全选 + 粘贴）—— 一次 replace，不是两条。
    func testFullValueReplace() {
        let change = TextDiff.diff(from: "alpha beta gamma", to: "完全不同的内容")
        XCTAssertEqual(change?.kind, .replace)
        XCTAssertEqual(change?.replacedText, "alpha beta gamma")
        XCTAssertEqual(change?.text, "完全不同的内容")
    }

    // 8. 撤销：new 回到更早状态 —— 产生一条合理的 TypingChange，不崩。
    func testUndoLikeChange() {
        let change = TextDiff.diff(from: "hello world foo", to: "hello")
        XCTAssertNotNil(change)
        // Step 2 不做 undo 识别，自然识为 delete " world foo"。
        XCTAssertEqual(change?.kind, .delete)
        XCTAssertEqual(change?.text, " world foo")
    }

    // 9. 空值 ↔ 非空。
    func testEmptyToNonEmptyAndBack() {
        let inserted = TextDiff.diff(from: "", to: "hello")
        XCTAssertEqual(inserted?.kind, .insert)
        XCTAssertEqual(inserted?.text, "hello")

        let deleted = TextDiff.diff(from: "hello", to: "")
        XCTAssertEqual(deleted?.kind, .delete)
        XCTAssertEqual(deleted?.text, "hello")

        // 相等返回 nil。
        XCTAssertNil(TextDiff.diff(from: "same", to: "same"))
    }
}

/// `TextDiff.sandwich` —— M4 AX value-change delta 提取。
final class TextDiffSandwichTests: XCTestCase {

    // 纯插入（尾部）：newMid = 新打的字，prevMid 空。
    func testPureInsertTail() {
        let r = TextDiff.sandwich(prev: "hello", new: "hello world")
        XCTAssertEqual(r.prefix, "hello")
        XCTAssertEqual(r.prevMid, "")
        XCTAssertEqual(r.newMid, " world")
        XCTAssertEqual(r.suffix, "")
    }

    // 纯插入（中段）：前后缀夹出中段。
    func testPureInsertMiddle() {
        let r = TextDiff.sandwich(prev: "abef", new: "abcdef")
        XCTAssertEqual(r.prefix, "ab")
        XCTAssertEqual(r.prevMid, "")
        XCTAssertEqual(r.newMid, "cd")
        XCTAssertEqual(r.suffix, "ef")
    }

    // 纯删除：prevMid = 删掉的字，newMid 空。
    func testPureDelete() {
        let r = TextDiff.sandwich(prev: "hello world", new: "hello")
        XCTAssertEqual(r.prevMid, " world")
        XCTAssertEqual(r.newMid, "")
    }

    // 替换：prevMid + newMid 都非空。
    func testReplace() {
        let r = TextDiff.sandwich(prev: "zhong", new: "中")
        XCTAssertEqual(r.prefix, "")
        XCTAssertEqual(r.prevMid, "zhong")
        XCTAssertEqual(r.newMid, "中")
        XCTAssertEqual(r.suffix, "")
    }

    // 空 → 非空 / 非空 → 空 / 完全相等。
    func testEmptyEdges() {
        let ins = TextDiff.sandwich(prev: "", new: "中文")
        XCTAssertEqual(ins.newMid, "中文")
        XCTAssertEqual(ins.prevMid, "")

        let del = TextDiff.sandwich(prev: "中文", new: "")
        XCTAssertEqual(del.prevMid, "中文")
        XCTAssertEqual(del.newMid, "")

        let same = TextDiff.sandwich(prev: "same", new: "same")
        XCTAssertEqual(same.prevMid, "")
        XCTAssertEqual(same.newMid, "")
        XCTAssertEqual(same.prefix, "same")
    }

    // 前后缀不重叠：prev 全在 new 里时，前缀吃满后缀不再回头。
    func testPrefixSuffixNoOverlap() {
        // "aa" → "aaa"：公共前缀 2，剩余只能算一侧，suffix 不与 prefix 重叠。
        let r = TextDiff.sandwich(prev: "aa", new: "aaa")
        XCTAssertEqual(r.prefix.count + r.suffix.count, 2)
        XCTAssertEqual(r.newMid, "a")
        XCTAssertEqual(r.prevMid, "")
    }

    // emoji ZWJ 序列按 Character 处理，不被拆。
    func testEmojiNotSplit() {
        let r = TextDiff.sandwich(prev: "hi", new: "hi👨‍👩‍👧")
        XCTAssertEqual(r.newMid, "👨‍👩‍👧")
        XCTAssertEqual(r.newMid.count, 1)
    }
}
