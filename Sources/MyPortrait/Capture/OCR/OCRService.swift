import CoreGraphics
import Foundation

/// Vision OCR 包装。
///
/// 算法（抄 My-Orphies apple.rs）：
///   1. 查 OCRCache（key = appTitle + imageHash）
///   2. 转灰度 luma8 CVPixelBuffer（提速 + 不掉精度）
///   3. VNImageRequestHandler + VNRecognizeTextRequest
///      - recognitionLanguages = config.ocrLanguages
///      - usesLanguageCorrection = false
///      - recognitionLevel = .accurate
///   4. 每个 observation 按空格 tokenize，每词单独 bounding_box_for_range
///   5. bbox 坐标翻转：Vision 左下原点 → 我们左上原点 (top = 1 - y - h)
///   6. 30+ 连续数字（编辑器行号）替换为单个空格
///   7. 写缓存
///
/// 性能要点：
///   - 每次 new 一个 VNRecognizeTextRequest，**不要复用**（内部状态会脏）
///   - 灰度 CVPixelBuffer 由 Coordinator 在调用前准备好（避免重复转换）
///   - 整个 OCR 过程包 autoreleasepool（Vision 会泄漏 Obj-C 临时对象）
///   - 全局 OCR 信号量 = 1（多显示器场景下避免 OCR 并发撞 CPU）
struct OCRService: Sendable {

    private let config: CaptureConfig
    private let cache: OCRCache
    private let reporter: UnimplementedReporter

    init(config: CaptureConfig, cache: OCRCache, reporter: UnimplementedReporter) {
        self.config = config
        self.cache = cache
        self.reporter = reporter
    }

    /// 对一张图做 OCR。
    /// `focus` 用来构造缓存 key（appName::windowTitle）。
    func recognize(image: CGImage, focus: FocusInfo) async throws -> OCRResult {
        throw reporter.notImplemented("OCRService.recognize")
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
