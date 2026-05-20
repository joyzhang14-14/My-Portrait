/// TextDiff —— 两个文本快照之间 diff 出一次打字变更。纯函数,无副作用,
/// 不感知 AX、不感知 DB、不感知 IME。
///
/// 设计决策(Step 2 定,Step 4 依赖):
///
/// 1. 性能 hint range —— diff() 签名带 hintRange: Range<Int>? = nil。
///    Step 2 实现忽略它、永远全量 diff。预留此参数,使 Step 4 的
///    TypingObserver 能基于 selection 传一个收窄范围进来而不改签名。
///
/// 2. IME composition —— TextDiff 是纯函数、不感知 composition。过滤由
///    Step 4 的 TypingObserver 负责:检测 focused 元素的
///    kAXMarkedTextRangeAttribute——marked range 非空 = IME 正在
///    composition(未上屏拼写),此时跳过 snapshot/diff;marked range
///    清空(commit)后再快照。不暴露该属性的 app 靠短 debounce 兜底。
///
/// 3. snapshot 频率 —— Step 4 走事件驱动:kAXValueChangedNotification +
///    短 debounce(~200ms),不用 polling。polling 费 CPU 且每次 AX 读
///    都是跨进程消息;事件驱动只在真变化时触发,debounce 合并连续按键 +
///    IME 中间态。

import Foundation

/// 一次打字变更的结构化结果。
struct TypingChange: Equatable {
    enum Kind: Equatable {
        case insert
        case delete
        case replace
    }

    /// 变更类型。
    let kind: Kind
    /// 新插入的文本（delete 时为空串）。
    let text: String
    /// 被替换/删除掉的旧文本（仅 replace 携带）。
    let replacedText: String?
    /// 语言提示：cjk / latin / mixed。
    let languageHint: String
}

enum TextDiff {

    /// 对比两段文本，diff 出一次打字变更。相等返回 nil。
    ///
    /// - Parameters:
    ///   - old: 旧全文。
    ///   - new: 新全文。
    ///   - hintRange: 性能提示范围。Step 2 忽略它（永远全量 diff），仅为
    ///     Step 4 预留签名稳定性。
    static func diff(
        from old: String,
        to new: String,
        hintRange: Range<Int>? = nil
    ) -> TypingChange? {
        // hintRange 在 Step 2 刻意忽略，见文件头设计决策 1。
        _ = hintRange

        if old == new { return nil }

        // 按 Character 做 diff —— emoji ZWJ 序列（如 👨‍👩‍👧）是一个
        // Character，天然不会被拆。
        let oldChars = Array(old)
        let newChars = Array(new)
        let difference = newChars.difference(from: oldChars)

        // 把离散的 insert / remove 聚合成连续 chunk。
        // CollectionDifference 的 offset：removal 用 old 下标，insertion 用 new 下标。
        var removals: [(offset: Int, char: Character)] = []
        var insertions: [(offset: Int, char: Character)] = []
        for change in difference {
            switch change {
            case let .remove(offset, element, _):
                removals.append((offset, element))
            case let .insert(offset, element, _):
                insertions.append((offset, element))
            }
        }

        let removeChunks = chunk(removals)
        let insertChunks = chunk(insertions)

        // 情况 A：只有插入。
        if removeChunks.isEmpty, insertChunks.count == 1 {
            let text = String(insertChunks[0].chars)
            return TypingChange(
                kind: .insert,
                text: text,
                replacedText: nil,
                languageHint: languageHint(for: text)
            )
        }

        // 情况 B：只有删除。
        if insertChunks.isEmpty, removeChunks.count == 1 {
            let text = String(removeChunks[0].chars)
            return TypingChange(
                kind: .delete,
                text: text,
                replacedText: nil,
                languageHint: languageHint(for: text)
            )
        }

        // 情况 C：替换 —— 既有删又有插，且差异整体落在一段连续区间内。
        // 用「公共前缀 + 公共后缀」夹出差异区间：前后缀之外的中段，
        // old 中段即被替换段、new 中段即新输入段。若中段两侧都非空则是 replace。
        // 这样既覆盖单段删+单段插，也覆盖 difference 因 LCS 把替换拆成
        // 多个不连续 chunk 的情况（如 world→swift 共享字母 w）。
        if !removeChunks.isEmpty, !insertChunks.isEmpty {
            var prefix = 0
            let maxPrefix = min(oldChars.count, newChars.count)
            while prefix < maxPrefix, oldChars[prefix] == newChars[prefix] {
                prefix += 1
            }
            var suffix = 0
            let maxSuffix = min(oldChars.count, newChars.count) - prefix
            while suffix < maxSuffix,
                  oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
                suffix += 1
            }
            let oldMid = oldChars[prefix..<(oldChars.count - suffix)]
            let newMid = newChars[prefix..<(newChars.count - suffix)]
            if !oldMid.isEmpty, !newMid.isEmpty {
                let newText = String(newMid)
                let oldText = String(oldMid)
                return TypingChange(
                    kind: .replace,
                    text: newText,
                    replacedText: oldText,
                    languageHint: languageHint(for: newText)
                )
            }
        }

        // 情况 D：复杂/多段不连续差异 —— 退化成全文 replace。
        return TypingChange(
            kind: .replace,
            text: new,
            replacedText: old,
            languageHint: languageHint(for: new)
        )
    }

    // MARK: - 聚合

    /// 把按 offset 升序的离散字符操作聚合成连续 chunk。
    /// 连续 = offset 逐 1 递增。
    private static func chunk(
        _ ops: [(offset: Int, char: Character)]
    ) -> [(start: Int, chars: [Character])] {
        guard !ops.isEmpty else { return [] }
        let sorted = ops.sorted { $0.offset < $1.offset }
        var result: [(start: Int, chars: [Character])] = []
        var curStart = sorted[0].offset
        var curChars: [Character] = [sorted[0].char]
        var prevOffset = sorted[0].offset
        for op in sorted.dropFirst() {
            if op.offset == prevOffset + 1 {
                curChars.append(op.char)
            } else {
                result.append((curStart, curChars))
                curStart = op.offset
                curChars = [op.char]
            }
            prevOffset = op.offset
        }
        result.append((curStart, curChars))
        return result
    }

    // MARK: - 语言判定

    /// 扫文本的 Unicode scalar，按 CJK 占比判定 cjk / latin / mixed。
    private static func languageHint(for text: String) -> String {
        if text.isEmpty { return "latin" }
        var cjkCount = 0
        var latinCount = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
            } else if isLatin(scalar) {
                latinCount += 1
            }
        }
        if cjkCount > 0 && latinCount > 0 { return "mixed" }
        if cjkCount > 0 { return "cjk" }
        return "latin"
    }

    /// 是否落在中日韩相关 Unicode 区段。
    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)      // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(v)      // CJK 扩展 A
            || (0x20000...0x2A6DF).contains(v)    // CJK 扩展 B
            || (0xF900...0xFAFF).contains(v)      // CJK 兼容表意文字
            || (0x3040...0x309F).contains(v)      // 平假名
            || (0x30A0...0x30FF).contains(v)      // 片假名
            || (0xAC00...0xD7AF).contains(v)      // 谚文音节
            || (0x3000...0x303F).contains(v)      // CJK 符号与标点
    }

    /// 是否为 ASCII 拉丁字母（用于 latin 判定，标点/数字不计）。
    private static func isLatin(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }
}
