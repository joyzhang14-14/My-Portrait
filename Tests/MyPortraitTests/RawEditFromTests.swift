import XCTest
@testable import MyPortrait

/// `RawEdit.from(oldValue:newValue:...)` 单测 —— 纯函数，UTF-16 公共前后缀 diff。
///
/// AX / CGEventTap 路径无法 unit test，走 manual test via `--typing-observe-m3`
/// （见 App.swift）。这里只覆盖纯函数 diff 逻辑。
final class RawEditFromTests: XCTestCase {

    /// 纯 insert：尾部追加一段。
    func testPureInsert() {
        let raw = RawEdit.from(oldValue: "abc", newValue: "abcdef",
                               pid: 1, elementHash: 9, ts: 0)
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.kind, .insert)
        XCTAssertEqual(raw?.text, "def")
        XCTAssertEqual(raw?.range, NSRange(location: 3, length: 0))
    }

    /// 纯 delete：尾部砍掉一段。text = 被删的中段内容（oldMid）。
    func testPureDelete() {
        let raw = RawEdit.from(oldValue: "abcdef", newValue: "abc",
                               pid: 1, elementHash: 9, ts: 0)
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.kind, .delete)
        // M4：delete 的 text 是被删内容 oldMid，不再是空串。
        XCTAssertEqual(raw?.text, "def")
        // oldMid = "def" → range 长 3，location 指向 OLD 值改动起点。
        XCTAssertEqual(raw?.range, NSRange(location: 3, length: 3))
    }

    /// 中段 delete：被删内容是中间一段。
    func testMidDelete() {
        let raw = RawEdit.from(oldValue: "abXYZcd", newValue: "abcd",
                               pid: 1, elementHash: 9, ts: 0)
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.kind, .delete)
        XCTAssertEqual(raw?.text, "XYZ")
        XCTAssertEqual(raw?.range, NSRange(location: 2, length: 3))
    }

    /// replace：中段被替换（前缀 + 后缀都非空）。
    func testReplace() {
        let raw = RawEdit.from(oldValue: "abXYZcd", newValue: "abQQcd",
                               pid: 1, elementHash: 9, ts: 0)
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.kind, .replace)
        XCTAssertEqual(raw?.text, "QQ")
        // oldMid = "XYZ" → location 2, length 3。
        XCTAssertEqual(raw?.range, NSRange(location: 2, length: 3))
    }

    /// 无变化：两值相同 → nil。
    func testNoChangeReturnsNil() {
        let raw = RawEdit.from(oldValue: "hello", newValue: "hello",
                               pid: 1, elementHash: 9, ts: 0)
        XCTAssertNil(raw)
    }
}
