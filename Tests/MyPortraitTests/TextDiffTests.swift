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
