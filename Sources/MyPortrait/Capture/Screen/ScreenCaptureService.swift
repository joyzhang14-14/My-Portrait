import CoreGraphics
import Foundation

/// ScreenCaptureKit 包装。负责单帧截图。
///
/// P1：只支持主显示器。
/// P5：多显示器、SCStream invalidation 防御（屏幕锁定/睡眠唤醒）。
///
/// 性能注意：
///   - SCDisplay handle 必须缓存，不要每帧重新枚举
///   - 每次 capture 必须包 autoreleasepool（My-Orphies 撞过 13GB RSS leak）
///   - 返回 CGImage 不拷贝像素（CoreGraphics 内部用 IOSurface）
actor ScreenCaptureService {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 抓主显示器一帧。
    ///
    /// 内部流程（P1 实现）：
    ///   1. 检查屏幕录制权限，无则 throw
    ///   2. 缓存 SCDisplay handle（首次调用枚举一次）
    ///   3. SCScreenshotManager.captureImage(contentFilter:configuration:)
    ///   4. 失败 → 3 次重试 + 重新枚举 → bail
    func captureMainDisplay() async throws -> CGImage {
        throw reporter.notImplemented("ScreenCaptureService.captureMainDisplay")
    }

    /// 停掉缓存的 SCStream handle，下次 capture 会懒重建。
    /// 屏幕锁定 / 睡眠唤醒 / DRM 触发时调。
    func invalidateStream() async {
        // P0：暂无可释放的资源
    }
}
