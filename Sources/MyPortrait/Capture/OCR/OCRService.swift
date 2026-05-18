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
    /// `focus` 用来构造缓存 key（appName::windowTitle）和决定是否走 AX 快路。
    ///
    /// 决策流程：
    ///   1. 查缓存（不管 AX 还是 OCR 命中都返回）
    ///   2. AX text 非空 && app 非终端 → 直接用 AX text（words=[]，bbox 缺失但
    ///      内容更准 + 省 ~50ms Vision 开销）
    ///   3. 否则走 Vision OCR（终端 / 无 AX 内容 / 无 AX 权限）
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

        // 2. AX text 快路（非终端 + 文本足够丰富）。
        //    My-Orphies 经验：编辑器/浏览器/聊天 app 上 AX 比 OCR 准且快。
        if let axText = focus.axText,
           axText.count >= Self.axMinChars,
           let bundleId = focus.bundleId,
           !FocusProbe.terminalBundleIds.contains(bundleId)
        {
            let result = OCRResult(
                fullText: axText,
                words: [],            // AX 不提供 bbox；timeline 词级高亮在 AX 帧上失效
                avgConfidence: 1.0
            )
            cache.put(key: key, value: result)
            return result
        }

        // 3. 灰度（失败回退到原图）。
        let imageToOCR = Self.toGrayscale(image) ?? image

        // 4. 在全局并发队列跑同步 Vision。
        let result = try await Self.performOCR(
            on: imageToOCR, config: config
        )

        cache.put(key: key, value: result)
        return result
    }

    /// AX text 走快路所需的最小字符数。少于这个就退回 Vision —
    /// 防止 AX 偶尔只返回一两字 placeholder 时丢掉真正的屏幕内容。
    private static let axMinChars: Int = 20

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
