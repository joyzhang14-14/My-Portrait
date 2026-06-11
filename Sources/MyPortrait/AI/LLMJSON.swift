import Foundation

/// 公共 LLM 输出 → JSON 抽取工具。
///
/// 替代各 processor 里直接 `firstIndex(of: "{")` / `firstIndex(of: "[")` 那种
/// 天真抽法 —— 模型经常在 JSON 前后加废话 / 包 markdown fence(```json ... ```)
/// / 不平衡 bracket(尾部加注释),那些都会让天真抽法 silently 把脏数据传到
/// JSONSerialization,要么炸要么解出畸形结果污染 portrait。
///
/// 本文件**只做无损抽取 + 去 fence**,不做 schema 校验(那一层由 caller 自己
/// 决定)。
enum LLMJSON {

    enum Kind { case object, array }
    enum Failure: LocalizedError {
        case noJSON
        case unbalancedBrackets(opened: Int, closed: Int)
        var errorDescription: String? {
            switch self {
            case .noJSON: return "no JSON object/array found in LLM output"
            case let .unbalancedBrackets(o, c):
                return "JSON brackets unbalanced (opened=\(o), closed=\(c))"
            }
        }
    }

    /// 抽出第一个**完整 balanced** JSON object 或 array 的子串。
    /// 跳过:markdown fence、前后散文、字符串字面量内的 brace。
    /// 失败抛 `Failure.noJSON`。
    static func extract(_ raw: String, expecting kind: Kind = .object) throws -> String {
        let stripped = stripMarkdownFence(raw)
        let openChar: Character = (kind == .object) ? "{" : "["
        let closeChar: Character = (kind == .object) ? "}" : "]"

        guard let startIdx = stripped.firstIndex(of: openChar) else {
            // expecting object 没找到 { 时,再试一次 array(模型有时候顶层给 array
            // 即使我们期望 object,反过来也然);避免一刀切误报 noJSON。
            if kind == .object, let arrStart = stripped.firstIndex(of: "[") {
                return try scanBalanced(stripped, from: arrStart, open: "[", close: "]")
            }
            throw Failure.noJSON
        }
        return try scanBalanced(stripped, from: startIdx, open: openChar, close: closeChar)
    }

    /// 抽 + 解码到 Decodable。便利封装。
    static func decode<T: Decodable>(_ type: T.Type, from raw: String, expecting kind: Kind = .object) throws -> T {
        let json = try extract(raw, expecting: kind)
        guard let data = json.data(using: .utf8) else { throw Failure.noJSON }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Internals

    /// 用 stack 扫平衡 bracket,**尊重字符串字面量内的 brace**(那些不算)。
    /// 失败抛 unbalancedBrackets。
    private static func scanBalanced(_ s: String, from start: String.Index,
                                     open: Character, close: Character) throws -> String {
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if escape {
                escape = false
            } else if inString {
                if ch == "\\" { escape = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == open { depth += 1 }
                else if ch == close {
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...i])
                    }
                }
            }
            i = s.index(after: i)
        }
        throw Failure.unbalancedBrackets(opened: depth + 1, closed: 0)
    }

    /// 去掉 ```json ... ``` 这种 markdown fence,留下纯文本。模型偶发把整个
    /// JSON 用 fence 包起来(自以为是教学),不剥掉会让 firstIndex(of:"{")
    /// 误命中 fence 前的散文里的随意 brace。
    private static func stripMarkdownFence(_ raw: String) -> String {
        var s = raw
        // 头部 fence:```json\n / ```JSON\n / ```\n / ```
        let fenceHeads = ["```json\n", "```JSON\n", "```\n", "```"]
        for f in fenceHeads where s.hasPrefix(f) {
            s = String(s.dropFirst(f.count))
            break
        }
        // 尾部 fence
        let fenceTails = ["\n```", "```"]
        for f in fenceTails where s.hasSuffix(f) {
            s = String(s.dropLast(f.count))
            break
        }
        return s
    }

    // MARK: - Repair

    /// 把"几乎是 JSON"的 LLM 输出修成 JSONSerialization 能解析的形态。
    /// 修三类**机械**缺陷,对合法 JSON 是 no-op:
    ///   1. 字符串字面量**内**的裸控制字符(\n \r \t)→ 标准转义。reasoning
    ///      模型(deepseek-v4-pro 等)给长 markdown body 字符串时最常犯 ——
    ///      合法 JSON 字符串里本就不允许裸控制字符,所以转义不会破坏语义。
    ///   2. 字符串**内**的裸 ASCII 引号 → 转义。模型写中文引用别人的话
    ///      (`他说"原话"`)/引文件名时直接打 `"` 不转义。判定:`"` 后面的
    ///      第一个非空白字符是 JSON 结构符(, : } ])才算字符串终结符,
    ///      否则视为内容。合法 JSON 的终结引号后必然紧跟结构符 → no-op。
    ///   3. 字符串**外**的尾逗号(`,]` / `,}`)→ 删除。
    /// 语义级缺陷(单引号 / 注释)不在这里修 —— caller 解析时配
    /// `.json5Allowed` 兜。修不动的(如内容引号恰好后跟 ASCII 逗号)会
    /// 产出不可解析的结果,caller 失败路径 dump 原文兜底。
    static func repair(_ json: String) -> String {
        let chars = Array(json)
        var out = String()
        out.reserveCapacity(chars.count)
        var inString = false
        var escape = false
        /// 字符串外攒住的 "," + 其后空白 —— 看到 ]/} 时丢逗号,否则原样吐出。
        var pending = ""

        func flushPending(dropComma: Bool) {
            if dropComma, pending.first == "," {
                out.append(contentsOf: pending.dropFirst())
            } else {
                out.append(pending)
            }
            pending = ""
        }

        /// i 处的 `"`(在字符串内)是不是真正的终结符:看后面第一个非空白。
        func isTerminatorQuote(at i: Int) -> Bool {
            var j = i + 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            if j >= chars.count { return true }
            return chars[j] == "," || chars[j] == ":" || chars[j] == "}" || chars[j] == "]"
        }

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escape {
                    out.append(ch); escape = false
                } else if ch == "\\" {
                    out.append(ch); escape = true
                } else if ch == "\"" {
                    if isTerminatorQuote(at: i) {
                        out.append(ch); inString = false
                    } else {
                        out.append("\\\"")   // 内容引号 → 转义留在串内
                    }
                } else if ch == "\n" {
                    out.append("\\n")
                } else if ch == "\r" {
                    out.append("\\r")
                } else if ch == "\t" {
                    out.append("\\t")
                } else {
                    out.append(ch)
                }
                i += 1; continue
            }
            // —— 字符串外 ——
            if !pending.isEmpty {
                if ch.isWhitespace { pending.append(ch); i += 1; continue }
                if ch == "]" || ch == "}" {
                    flushPending(dropComma: true)
                    out.append(ch)
                    i += 1; continue
                }
                flushPending(dropComma: false)
                // fall through:ch 按正常字符继续处理
            }
            if ch == "," { pending = ","; i += 1; continue }
            if ch == "\"" { inString = true; out.append(ch); i += 1; continue }
            out.append(ch)
            i += 1
        }
        if !pending.isEmpty { flushPending(dropComma: false) }
        return out
    }
}
