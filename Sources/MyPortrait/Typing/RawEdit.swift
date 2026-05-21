import Foundation
import QuartzCore

/// Typing Observer v2 — Layer 1 产物，喂给 Layer 2 IMEStateMachine 的输入单元。
///
/// 一条 `RawEdit` 描述「某个 AX element 的文本发生了一次原子变化」。
/// M2 阶段不接 Layer 1 也不接 AX，由单测直接构造。
struct RawEdit {
    enum Kind { case insert, replace, delete }

    let kind: Kind
    let text: String
    /// 文字所属书写系统，由 `Script.classify(text)` 算出。
    let script: Script
    /// UTF-16 单元为单位的范围（不是 Character 数）。
    let range: NSRange
    /// `CACurrentMediaTime()` —— 单调时钟。
    let ts: TimeInterval
    let pid: pid_t
    let elementHash: Int
    /// Layer 1 附上的追踪标签，跟事件走完全程；M2 阶段可为 nil。
    var traceTag: TraceTag?
}

/// 书写系统分类。
enum Script {
    case latin, cjk, mixed, other

    /// 数文字里 CJK（中日韩）scalar 占比，判定 Script。
    ///
    /// CJK 口径：
    /// - CJK Unified Ideographs `U+4E00...U+9FFF`
    /// - Hiragana `U+3040...U+309F`
    /// - Katakana `U+30A0...U+30FF`
    /// - Hangul Syllables `U+AC00...U+D7AF`
    ///
    /// total 用 `unicodeScalars.count`，跟 cjk 计数同口径。
    /// 比例 >= 50% → `.cjk`；0% → `.latin`；其他 → `.mixed`。
    /// 空串 → `.latin`（给 normalize 用）。
    static func classify(_ text: String) -> Script {
        let total = text.unicodeScalars.count
        guard total > 0 else { return .latin }
        let cjk = cjkScalarCount(text)
        let ratio = Double(cjk) / Double(total)
        if ratio >= 0.5 { return .cjk }
        if cjk == 0 { return .latin }
        return .mixed
    }

    /// 数文字里属于 CJK 区段的 unicode scalar 个数。
    fileprivate static func cjkScalarCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)        // CJK Unified Ideographs
                || (0x3040...0x309F).contains(v)    // Hiragana
                || (0x30A0...0x30FF).contains(v)    // Katakana
                || (0xAC00...0xD7AF).contains(v) {  // Hangul Syllables
                count += 1
            }
        }
        return count
    }

    /// IMEStateMachine 内部用：判定一段文字是否该走 CJK path。
    /// - 纯 `.cjk` → true
    /// - 纯 `.latin` → false
    /// - `.mixed`：CJK scalar 占比 >= 20% → true，否则 false
    /// - `.other`（理论不出现，classify 不产 `.other`）→ false
    func usesCJKPath(_ text: String) -> Bool {
        switch self {
        case .cjk:
            return true
        case .latin, .other:
            return false
        case .mixed:
            let total = text.unicodeScalars.count
            guard total > 0 else { return false }
            let cjk = Script.cjkScalarCount(text)
            return Double(cjk) / Double(total) >= 0.2
        }
    }
}
