import Foundation

/// Memory → Input 显示的「元输入」(10-25 update):keystroke_log 按 app 和停顿切段,
/// 段内击键原样拼成文字,不经任何整理。
///
/// 拼法只做最直白的几件事:可见字符照写;回车记 `⏎` 并换行;退格删掉段里上一个字
/// (上一个不是普通字就记 `⌫`);⌘ / ⌃ 组合键记成 `⌘V` 这样的标记。方向键、Esc、
/// 功能键和被抹掉字符的键(密码框 / 黑名单 app)不显示。中文输入法下记的是拼音和
/// 选字键原样,不还原成汉字。
struct InputSegment: Identifiable, Sendable {
    let id: Int64           // 段内第一个击键的 id
    let app: String         // bundle id
    let startMs: Int64
    let endMs: Int64
    let text: String
    let keys: Int
}

enum InputSegments {

    /// 同一 app 里两次击键隔得比这久,就切成两段。
    static let gapMs: Int64 = 30_000

    /// 只有空白和退格 = 没东西可看(字符被抹掉的 app 只剩一串 ⌫)。
    private static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "⌫"))

    /// `ks` 须按时间升序。没有可显示内容的段(全是方向键 / 退格 / 被抹掉的键)丢掉。
    static func build(_ ks: [KeystrokeEntry]) -> [InputSegment] {
        var out: [InputSegment] = []
        var cur: [KeystrokeEntry] = []
        func flush() {
            defer { cur = [] }
            guard let first = cur.first, let last = cur.last else { return }
            let text = render(cur)
            guard !text.trimmingCharacters(in: Self.blank).isEmpty else { return }
            out.append(InputSegment(id: first.id ?? first.tsMs, app: first.bundleId,
                                    startMs: first.tsMs, endMs: last.tsMs,
                                    text: text, keys: cur.count))
        }
        for k in ks {
            if let prev = cur.last, prev.bundleId != k.bundleId || k.tsMs - prev.tsMs > gapMs { flush() }
            cur.append(k)
        }
        flush()
        return out
    }

    static func render(_ ks: [KeystrokeEntry]) -> String {
        var tokens: [(text: String, erasable: Bool)] = []
        for k in ks {
            let scalar = k.char?.unicodeScalars.first?.value ?? 0
            if k.isBackspace != 0 || scalar == 8 || scalar == 127 {
                if tokens.last?.erasable == true { tokens.removeLast() } else { tokens.append(("⌫", false)) }
                continue
            }
            guard let c = k.char, !c.isEmpty else { continue }
            if k.modifiers & 0x05 != 0 {                          // ⌘ 或 ⌃ = 快捷键,不是打字
                tokens.append((shortcut(k.modifiers, scalar: scalar, char: c), false))
                continue
            }
            switch scalar {
            case 13, 10: tokens.append(("⏎\n", false))
            case 9:      tokens.append(("⇥", false))
            case 0..<32, 0xF700...0xF8FF: continue                // Esc、方向键、功能键
            default:     tokens.append((c, true))
            }
        }
        return tokens.map(\.text).joined()
    }

    /// `⌃⌥⇧⌘` + 键名。⌃ 组合时系统给的是控制字符(⌃P → 0x10),还原成字母。
    private static func shortcut(_ modifiers: Int, scalar: UInt32, char: String) -> String {
        var s = ""
        if modifiers & 0x04 != 0 { s += "⌃" }
        if modifiers & 0x02 != 0 { s += "⌥" }
        if modifiers & 0x08 != 0 { s += "⇧" }
        if modifiers & 0x01 != 0 { s += "⌘" }
        switch scalar {
        case 13, 10: return s + "⏎"
        case 9:      return s + "⇥"
        case 27:     return s + "⎋"
        case 28:     return s + "←"
        case 29:     return s + "→"
        case 30:     return s + "↑"
        case 31:     return s + "↓"
        case 32:     return s + "Space"
        case 1...26: return s + String(UnicodeScalar(scalar + 64)!)
        case 0..<32, 0xF700...0xF8FF: return s + "?"
        default:     return s + char.uppercased()
        }
    }
}
