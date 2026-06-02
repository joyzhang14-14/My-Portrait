import Foundation
import GRDB

/// Foundation-backed FTS5 tokenizer。
///
/// **为什么这么做**：macOS 系统 sqlite3 **没编译进 SQLITE_ENABLE_ICU**
/// （`PRAGMA compile_options` 验证过），所以 `FTS5TokenizerDescriptor("icu")`
/// 在运行时会失败。但 Foundation 的 `enumerateSubstrings(.byWords)` 在 Darwin
/// 上**内部就是 ICU**——用 ICU word break iterator + locale 规则做分词。
///
/// 我们写一个 FTS5CustomTokenizer，让 GRDB 在 SQLite FTS5 引擎里调 Foundation。
/// 效果跟"直接用 ICU 分词器"等价：
///   - 中文 "力矩传感器" → ["力矩", "传感器"]（而不是 unicode61 的"力/矩/传/感/器"单字）
///   - 英文 "Vision OCR" → ["vision", "ocr"]（lowercase 大小写无关）
///   - 中英混合句"今天用 Xcode 写代码" → ["今天", "用", "xcode", "写", "代码"]
///
/// 注：FTS5 callback 接收的 iStart/iEnd 是**原始 pText 的 UTF-8 字节偏移**（不是
/// UTF-16 / character index）。snippet() 用这些偏移生成高亮，错位会出乱码。
final class FoundationTokenizer: FTS5CustomTokenizer {

    static let name: String = "foundation_icu"

    init(db: Database, arguments: [String]) throws {
        // 暂无参数。未来可加 locale 选项（默认走系统 default）。
    }

    func tokenize(
        context: UnsafeMutableRawPointer?,
        tokenization: FTS5Tokenization,
        pText: UnsafePointer<CChar>?,
        nText: Int32,
        tokenCallback: FTS5TokenCallback
    ) -> Int32 {
        guard let pText, nText > 0 else { return 0 }  // SQLITE_OK = 0

        // 把 pText 这段 UTF-8 bytes 还原成 Swift String。
        let length = Int(nText)
        let data = Data(bytes: pText, count: length)
        guard let text = String(data: data, encoding: .utf8) else {
            return 0
        }

        var result: Int32 = 0
        let ns = text as NSString

        // 增量游标:byteOffset 始终 = text[0..<lastUTF16] 的 UTF-8 字节数。
        // enumerateSubstrings(.byWords) 按递增 range 访问,只对「上个词尾→本词头」
        // 的间隙补算 UTF-8 长度 → 全文 O(n)。原来每个词重算 [0..<location] 前缀
        // 是 O(n²),满屏 OCR 文本(几十 KB)每次入库/查询都白烧 CPU。
        var lastUTF16 = 0
        var byteOffset = 0

        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byWords
        ) { substring, range, _, stop in
            guard let substring, !substring.isEmpty else { return }

            // 把 UTF-16 range（NSString 索引）转 UTF-8 字节偏移（FTS5 要求）。
            // 间隙(标点/空格)的 UTF-8 长度补进 byteOffset —— disjoint 子串的 UTF-8
            // 拼接 = 整段 UTF-8,故 iStart 与原来逐前缀算法字节级一致。
            if range.location > lastUTF16 {
                let gap = ns.substring(with: NSRange(location: lastUTF16, length: range.location - lastUTF16))
                byteOffset += gap.utf8.count
                lastUTF16 = range.location
            }
            let iStart = byteOffset
            let iEnd = iStart + substring.utf8.count   // substring 是原词(非小写),偏移映射原始字节
            byteOffset = iEnd
            lastUTF16 = range.location + range.length

            // 小写：大小写无关搜索。
            let normalized = substring.lowercased()

            normalized.withCString { tokenPtr in
                let tokenLen = Int32(strlen(tokenPtr))
                let code = tokenCallback(
                    context,
                    0,                      // tflags: 0 = primary token
                    tokenPtr,
                    tokenLen,
                    Int32(iStart),
                    Int32(iEnd)
                )
                if code != 0 {              // SQLITE_OK = 0
                    result = code
                    stop.pointee = true
                }
            }
        }

        return result
    }
}
