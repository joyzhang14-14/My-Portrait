import CoreGraphics
import Foundation
import Vision
import os.log

/// Vision OCR 包装。
///
/// 算法（抄 My-Orphies apple.rs）：
///   1. 查 OCRCache（key = appTitle + imageHash@1/6 下采样）
///   2. 转灰度 luma8（提速 + 不掉精度）
///   3. VNImageRequestHandler + VNRecognizeTextRequest
///      - recognitionLanguages = config.ocrLanguages
///      - usesLanguageCorrection = false
///      - recognitionLevel = .accurate
///   4. 每个 observation 按空白 tokenize，每词单独 boundingBox(for:)
///   5. bbox 坐标翻转：Vision 左下原点 → 我们左上原点 (top = 1 - y - h)
///   6. 30+ 连续数字（编辑器行号）替换为空格
///   7. 写缓存
///
/// 性能要点：
///   - 每次 new 一个 VNRecognizeTextRequest（不复用，内部状态会脏）
///   - 灰度转换 + Vision 调用包 autoreleasepool（Vision 会泄漏 Obj-C 临时对象）
///   - 通过 DispatchQueue.global 跑同步 Vision 调用，避免阻塞 actor
struct OCRService: Sendable {

    private let config: CaptureConfig
    private let cache: OCRCache
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "ocr")

    init(config: CaptureConfig, cache: OCRCache, reporter: UnimplementedReporter) {
        self.config = config
        self.cache = cache
        self.reporter = reporter
    }

    /// 对一张图做 OCR / 或直接用 AX text。
    /// `focus` 只用来构造缓存 key（appName::windowTitle）。
    ///
    /// 决策流程：
    ///   1. 查缓存
    ///   2. 一律走 Vision OCR
    ///
    /// ⚠️ **AX 快路已于 2026-08-04 移除**（用户裁定：不信 AX、不硬编码 app 名单）。
    /// 原设计是「AX text ≥20 字 && 非终端 && 非浏览器 → 直接用 AX，省 ~50ms Vision」，
    /// 假设「编辑器/原生聊天 app 的 AX 是 canvas 内容，比 OCR 准」。**实测该假设在多数
    /// app 上不成立** —— 同 app 下 AX 文本长度 ÷ OCR 文本长度：
    ///     Obsidian 0.06x · 微信 0.06x · Spotify 0.04x · Discord 0.03x ·
    ///     Xcode 0.10x · Finder 0.22x · Preview 0.20x · Sourcetree 0.04x
    /// AX 只给控件名（`navigator`/`debug bar`/`editor area`），正文一个字读不到；
    /// 开图核实：Preview 的 PDF 正文全丢、Xcode 的代码全丢、Obsidian 只有标题重复两遍，
    /// 更有帧的 AX 读到了**屏幕外窗口**的内容（图文不同源）。
    /// AX 赢的只有 My Portrait 1.76x / Activity Monitor 2.73x —— 恰是内容价值最低的两类。
    ///
    /// 存量影响（2026-08-04 全量统计）：ax 帧 54,899（占 19%）；生产 event 1,001 个
    /// 有源帧的里，重度污染（源帧全是劣质 AX）8 个、中度 139 个。
    ///
    /// 注：`focus.axText` 仍照常采集，只是不再顶掉 Vision；写作采集的 AX 主力通道走
    /// `Typing/TypingObserver`（自己监听 kAXValueChangedNotification），与本路径无关。
    func recognize(image: CGImage, focus: FocusInfo) async throws -> OCRResult {
        // 1. 缓存查询。
        let appTitle = "\(focus.appName)::\(focus.windowTitle ?? "")"
        let imageHash = Self.computeImageHash(
            image, factor: config.ocrCacheHashDownscale
        )
        let key = OCRCacheKey(appTitle: appTitle, imageHash: imageHash)

        if let cached = cache.get(key: key) {
            return cached
        }

        // 2. 灰度（失败回退到原图）。
        let imageToOCR = Self.toGrayscale(image) ?? image

        // 3. 在全局并发队列跑同步 Vision。
        let result = try await Self.performOCR(
            on: imageToOCR, config: config
        )

        cache.put(key: key, value: result)
        return result
    }

    // MARK: - 私有

    private static func performOCR(
        on image: CGImage,
        config: CaptureConfig
    ) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLanguages = config.ocrLanguages
                        request.usesLanguageCorrection = config.ocrUseLanguageCorrection
                        request.recognitionLevel = .accurate

                        let handler = VNImageRequestHandler(cgImage: image, options: [:])
                        try handler.perform([request])

                        let observations = request.results ?? []
                        let result = Self.buildResult(observations: observations)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// 把 observations 转 OCRResult：每词一条 OCRWord（坐标已翻转）。
    private static func buildResult(observations: [VNRecognizedTextObservation]) -> OCRResult {
        var fullTextParts: [String] = []
        var words: [OCRWord] = []
        var confSum = 0.0
        var confCount = 0

        for observation in observations {
            // 取置信度最高的候选。
            let candidates = observation.topCandidates(1)
            guard let candidate = candidates.first else { continue }
            let text = candidate.string
            if text.isEmpty { continue }

            fullTextParts.append(text)
            let obsConfidence = Double(candidate.confidence)

            // 按空白 tokenize；每词独立 boundingBox。
            // Swift 的 String.Index 天然按 grapheme 走，VNRecognizedText.boundingBox
            // 内部按 UTF-16 处理，调用方不用手算偏移。
            let wordRanges = Self.whitespaceWordRanges(in: text)
            if wordRanges.isEmpty {
                // 极端情况：candidate string 非空但全是空白？保险加一条空 bbox。
                continue
            }

            for (wordText, range) in wordRanges {
                guard let rect = try? candidate.boundingBox(for: range) else {
                    continue
                }
                let bbox = rect.boundingBox
                // Vision: 左下原点。我们用左上原点。
                let top = 1.0 - Double(bbox.origin.y) - Double(bbox.size.height)
                words.append(OCRWord(
                    text: wordText,
                    left: Double(bbox.origin.x),
                    top: top,
                    width: Double(bbox.size.width),
                    height: Double(bbox.size.height),
                    confidence: obsConfidence
                ))
                confSum += obsConfidence
                confCount += 1
            }
        }

        let merged = fullTextParts.joined(separator: " ")
        // 30+ 连续数字 → 一个空格（IDE / editor 的行号 gutter 噪音）。
        let cleaned = merged.replacingOccurrences(
            of: #"[0-9]{30,}"#,
            with: " ",
            options: .regularExpression
        )
        let avg = confCount > 0 ? confSum / Double(confCount) : 0.0
        return OCRResult(fullText: cleaned, words: words, avgConfidence: avg)
    }

    /// 按空白拆词，返回每词的 Swift `Range<String.Index>`。
    /// CJK 等无空白文本会得到一个整体 range，保留 Vision 的原始 observation 边界。
    private static func whitespaceWordRanges(in s: String) -> [(String, Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            // 跳空白
            while idx < s.endIndex, s[idx].isWhitespace {
                idx = s.index(after: idx)
            }
            guard idx < s.endIndex else { break }
            let start = idx
            // 推到下一个空白前。
            while idx < s.endIndex, !s[idx].isWhitespace {
                idx = s.index(after: idx)
            }
            let range = start..<idx
            out.append((String(s[range]), range))
        }
        return out
    }

    /// 灰度 luma8 CGImage。失败返回 nil，调用方回退用原图。
    private static func toGrayscale(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 1/factor 下采样后 FNV-1a UInt64 hash。
    /// 用作 OCRCache key 一部分 —— 跟 FrameComparer 的 1/4 hash 不同，避免冲突。
    private static func computeImageHash(_ image: CGImage, factor: Int) -> UInt64 {
        let f = max(1, factor)
        let dstW = image.width / f
        let dstH = image.height / f
        guard dstW > 0, dstH > 0 else { return 0 }

        let bytesCount = dstW * dstH
        var bytes = [UInt8](repeating: 0, count: bytesCount)
        let cs = CGColorSpaceCreateDeviceGray()

        let ok = bytes.withUnsafeMutableBufferPointer { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: dstW,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            return true
        }
        guard ok else { return 0 }

        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return h
    }
}

/// OCR 完整结果。
public struct OCRResult: Sendable {
    /// 合并后的纯文本，供 FTS5 索引。
    public let fullText: String

    /// 词级 bbox。DB 那边 JSON encode 进单列。
    public let words: [OCRWord]

    /// 所有词置信度平均。
    public let avgConfidence: Double

    public init(fullText: String, words: [OCRWord], avgConfidence: Double) {
        self.fullText = fullText
        self.words = words
        self.avgConfidence = avgConfidence
    }

    /// 计算属性：DB 写入时用启发式判断这一帧的文本来源。
    ///
    /// 当前规则：
    ///   - AX 快路返回 words=[] + avgConfidence=1.0 → `.ax`
    ///   - Vision OCR 返回 words 非空 → `.ocr`
    ///   - 边界（理论上不应该发生）→ `.unknown`
    ///
    /// 未来可能多更多 case（subtitle 解析 / 系统通知 / etc.），所以 `.unknown`
    /// 留了口子，**别在 DB 那边用 SQL CHECK 限死 enum 集合**。
    public var textSource: TextSource {
        if words.isEmpty && avgConfidence == 1.0 { return .ax }
        if !words.isEmpty { return .ocr }
        return .unknown
    }

    public enum TextSource: String, Sendable {
        case ax       // 从焦点窗口的 accessibility tree 取
        case ocr      // Vision OCR
        case unknown  // 兜底（words=[] 且 avgConfidence!=1.0）
    }
}

/// 单词级 bbox。坐标已转换为**左上原点归一化** (0-1)。
public struct OCRWord: Codable, Sendable {
    public let text: String
    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double
    public let confidence: Double

    public init(text: String, left: Double, top: Double, width: Double, height: Double, confidence: Double) {
        self.text = text
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}
