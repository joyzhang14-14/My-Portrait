import Foundation

/// 采集层全部阈值/参数集中地。修改任何参数都来这里改。
///
/// 数值默认值直接抄 My-Orphies / screenpipe 的生产值。改之前要看 memory:
/// project-capture-storage-strategy 和 feedback-capture-performance-first。
struct CaptureConfig: Sendable {

    // MARK: - 帧调度

    /// P1 定时模式下的间隔。事件驱动模式（P2+）下被 EventSources 接管。
    var captureIntervalMs: Int = 1000

    /// 两次实际捕获之间的最小间隔（防抖）。任何调度路径都必须遵守。
    var minCaptureIntervalMs: Int = 200

    /// 连续跳帧（被 FrameComparer 判定为重复）允许的最长时间，超过强制保留一帧。
    var maxSkipDurationMs: Int = 10_000

    // MARK: - 帧去重 (FrameComparer)

    /// 比较前的下采样比例 —— 1920px 宽降到 480px。
    var frameDownscaleFactor: Int = 4

    /// Hellinger 直方图距离低于此值视为"相同"。0.02 ≈ 2% 像素差。
    var skipThreshold: Double = 0.02

    // MARK: - OCR

    /// 缓存条目存活时间（秒）。
    var ocrCacheTTLSeconds: TimeInterval = 300

    /// LRU 容量上限。
    var ocrCacheMaxEntries: Int = 100

    /// 计算 image hash 时的下采样比例。
    var ocrCacheHashDownscale: Int = 6

    /// Vision 识别语言。中文必须同时给简繁。
    var ocrLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]

    /// 关闭语言纠正 —— 屏幕上有大量代码/路径/品牌名，纠正会破坏内容。
    var ocrUseLanguageCorrection: Bool = false

    // MARK: - JPG 写盘 (SnapshotWriter)

    /// JPEG 压缩质量。0.80 ≈ screenpipe "balanced" 预设。
    var jpegQuality: Double = 0.80

    /// 最大宽度（保比例）。1920 ≈ balanced 预设。0 = 原生分辨率。
    var jpegMaxWidth: Int = 1920

    // MARK: - 存储

    /// 帧 JPG 根目录。运行时按日期再分子目录。
    var framesDir: URL

    /// MP4 块根目录（P3+）。
    var videoDir: URL

    /// 显示器 stable id。单显示器固定 "main"，多显示器 P5 才扩展。
    var monitorId: String

    // MARK: - 默认值

    static var `default`: CaptureConfig {
        CaptureConfig(
            framesDir: Storage.framesDir,
            videoDir: Storage.videoDir,
            monitorId: "main"
        )
    }
}
