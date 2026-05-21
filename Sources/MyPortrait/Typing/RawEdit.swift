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

extension RawEdit {
    /// 对比 element 的旧值/新值，求单段连续编辑。
    ///
    /// UTF-16 层面求公共前缀长度 P + 公共后缀长度 S（后缀不与前缀重叠）：
    ///   oldMid = old[P ..< old.count-S]，newMid = new[P ..< new.count-S]
    ///   - oldMid 空 & newMid 非空 → `.insert`，text=newMid，range=(P, 0)
    ///   - oldMid 非空 & newMid 空  → `.delete`，text=""，range=(P, oldMid.count)
    ///   - 两者都非空              → `.replace`，text=newMid，range=(P, oldMid.count)
    ///   - 两者都空                → nil（无变化）
    ///
    /// range 是 UTF-16 单元，location 指向 OLD 值里的改动起点。
    /// `script` 由 `Script.classify(newMid)` 算（delete 时 newMid 空 → `.latin`）。
    static func from(oldValue: String, newValue: String,
                     pid: pid_t, elementHash: Int, ts: TimeInterval) -> RawEdit? {
        let oldUnits = Array(oldValue.utf16)
        let newUnits = Array(newValue.utf16)
        let oldCount = oldUnits.count
        let newCount = newUnits.count

        // 公共前缀长度 P。
        var prefix = 0
        let prefixMax = min(oldCount, newCount)
        while prefix < prefixMax && oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        // 公共后缀长度 S —— 不能与前缀重叠（两侧剩余长度封顶）。
        var suffix = 0
        let suffixMax = min(oldCount - prefix, newCount - prefix)
        while suffix < suffixMax
            && oldUnits[oldCount - 1 - suffix] == newUnits[newCount - 1 - suffix] {
            suffix += 1
        }

        let oldMidLen = oldCount - prefix - suffix
        let newMidLen = newCount - prefix - suffix

        // 两者都空 → 无变化。
        if oldMidLen == 0 && newMidLen == 0 { return nil }

        let newMidUnits = Array(newUnits[prefix ..< (prefix + newMidLen)])
        let newMid = String(decoding: newMidUnits, as: UTF16.self)

        let kind: Kind
        if oldMidLen == 0 {
            kind = .insert
        } else if newMidLen == 0 {
            kind = .delete
        } else {
            kind = .replace
        }

        let text = (kind == .delete) ? "" : newMid
        return RawEdit(
            kind: kind,
            text: text,
            script: Script.classify(text),
            range: NSRange(location: prefix, length: oldMidLen),
            ts: ts,
            pid: pid,
            elementHash: elementHash,
            traceTag: nil
        )
    }
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
