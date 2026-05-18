import CoreGraphics
import Foundation
import ScreenCaptureKit
import os.log

/// ScreenCaptureKit 包装。负责单帧截图。
///
/// P1：只支持主显示器。
/// P5：多显示器、SCStream invalidation 防御（屏幕锁定/睡眠唤醒）。
///
/// 性能注意：
///   - SCDisplay handle 缓存，不每帧重新枚举
///   - 单帧走 `SCScreenshotManager.captureImage`（macOS 14+），不开 SCStream 流
///   - 失败重试 3 次 + 重新枚举显示器 → 仍失败抛 `captureFailed`
actor ScreenCaptureService {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "screen")

    private var cachedDisplay: SCDisplay?

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 抓主显示器一帧。
    ///
    /// 流程：
    ///   1. 取缓存的 SCDisplay（首次调用枚举一次）
    ///   2. 构 SCContentFilter + SCStreamConfiguration
    ///   3. SCScreenshotManager.captureImage
    ///   4. 失败 → invalidate + 重新枚举 → 重试，最多 3 次
    ///
    /// 抛错：
    ///   - `screenRecordingPermissionDenied` 用户在系统设置拒绝权限
    ///   - `displayNotFound` 主显示器枚举失败（极少见）
    ///   - `captureFailed` 重试 3 次仍失败
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
    /// 屏幕锁定 / 睡眠唤醒 / DRM 触发时调。
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
            // shareableContent 没拿到屏幕录制权限就 throws。
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
    /// 不同 macOS 版本也可能用其他 code，宽松匹配。
    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        // SCStreamErrorDomain code -3801 = userDeclined
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            return true
        }
        // 错误描述兜底
        let desc = ns.localizedDescription.lowercased()
        return desc.contains("permission") || desc.contains("not authorized") || desc.contains("declined")
    }
}
