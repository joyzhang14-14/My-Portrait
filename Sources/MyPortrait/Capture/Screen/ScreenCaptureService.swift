import CoreGraphics
import Foundation
import ScreenCaptureKit
import os.log

/// ScreenCaptureKit 包装。负责单帧截图。
///
/// **@MainActor 是有意为之**：macOS 26 (Tahoe) 上 SCK 内部的 XPC decoder 有
/// "bad range / dispatch_assert_queue" 已知问题（用户日志：
/// `NSXPCDecoder validateAllowedClass` warning 后接 EXC_BREAKPOINT in
/// libdispatch）。把 SCK 调用统一钉在 main thread 是 Apple 自己 sample 的惯例
/// 写法（ScreenCaptureKitSample 等），能稳定绕开这条路径。
///
/// 性能：SCK 重活在 replayd 进程外做，我们这边只是 await 一个 XPC 请求；
/// 不会真阻塞 main thread 几十毫秒，UI 不会卡。
@MainActor
final class ScreenCaptureService {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "screen")

    private var cachedDisplay: SCDisplay?

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 抓主显示器一帧。失败重试 3 次。
    func captureMainDisplay() async throws -> CGImage {
        var lastError: Error?

        for attempt in 0..<3 {
            do {
                let display = try await getOrFetchMainDisplay()
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = Int(display.width)
                cfg.height = Int(display.height)
                cfg.scalesToFit = false
                cfg.showsCursor = false
                cfg.capturesAudio = false

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: cfg
                )
                return cgImage
            } catch {
                lastError = error
                logger.warning("captureMainDisplay attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")

                // 权限拒绝不重试，立刻抛。
                if Self.isPermissionDenied(error) {
                    throw CaptureError.screenRecordingPermissionDenied
                }

                // 重置缓存 → 下次调用会重新枚举。
                cachedDisplay = nil

                // 重试前小睡（100ms），避免立即撞错。
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        throw CaptureError.captureFailed(underlying: lastError
            ?? NSError(domain: "MyPortrait.Capture", code: -1))
    }

    /// 停掉缓存的 SCDisplay handle，下次 capture 会懒重建。
    func invalidateStream() async {
        cachedDisplay = nil
    }

    // MARK: - 私有

    private func getOrFetchMainDisplay() async throws -> SCDisplay {
        if let cached = cachedDisplay {
            return cached
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if Self.isPermissionDenied(error) {
                throw CaptureError.screenRecordingPermissionDenied
            }
            throw error
        }

        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first
        else {
            throw CaptureError.displayNotFound(monitorId: config.monitorId)
        }

        cachedDisplay = display
        return display
    }

    /// ScreenCaptureKit 报权限错误时，NSError code 是 -3801（kSCStreamErrorUserDeclined）。
    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            return true
        }
        let desc = ns.localizedDescription.lowercased()
        return desc.contains("permission") || desc.contains("not authorized") || desc.contains("declined")
    }
}
