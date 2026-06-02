import Foundation
import os.log

/// 几何 chrome filter:从 OCR 文本里砍掉 menubar / dock / 极小字体。
///
/// 数据源:`frames.ocr_words_json` —— OCRService 写入时已经把每词 bbox 归一化到
/// 左上原点 0-1。
///
/// 规则(归一化坐标):
///   - top < 0.035  → macOS 顶部菜单栏 (~28px / 1080)
///   - top > 0.96   → dock / 任务栏
///   - height < 0.012 → 极小字体(状态栏 / tooltip / 标签栏 chrome)
///
/// 只对 `text_source == "ocr"` 生效;AX 帧 word list 为空,自然不会动。
///
/// 仅 writing capture 调用 —— 其他 pipeline(personality/writing-style)继续用
/// 原始 full_text。
enum WritingCaptureChromeFilter {
    static let menubarTopMax: Double = 0.035
    static let dockTopMin: Double = 0.96
    static let tinyHeightMax: Double = 0.012

    private static let log = Logger(
        subsystem: "com.myportrait.memory", category: "chrome-filter"
    )

    /// 入口:`text_source != "ocr"` 或 wordsJson 解不出来 → 原样返回 rawText。
    /// 否则过滤后按 (top, left) 重排拼回文本。
    static func applyIfOcr(
        rawText: String,
        wordsJson: String?,
        textSource: String?
    ) -> String {
        guard textSource == "ocr",
              let wordsJson, !wordsJson.isEmpty,
              let data = wordsJson.data(using: .utf8),
              let words = try? JSONDecoder().decode([OCRWord].self, from: data),
              !words.isEmpty
        else { return rawText }

        let kept = words.filter { w in
            !(w.top < menubarTopMax || w.top > dockTopMin || w.height < tinyHeightMax)
        }
        guard !kept.isEmpty else {
            // 全砍光了不太合理,fallback 原文本(保守)
            log.warning("chrome filter dropped all words; fallback to raw")
            return rawText
        }

        // 按 top 行序、同行按 left 重排。同行判定:top 差 < 0.5 * 行高。
        let sorted = kept.sorted { lhs, rhs in
            if abs(lhs.top - rhs.top) < max(lhs.height, rhs.height) * 0.5 {
                return lhs.left < rhs.left
            }
            return lhs.top < rhs.top
        }
        let merged = sorted.map { $0.text }.joined(separator: " ")
        return merged
    }
}
