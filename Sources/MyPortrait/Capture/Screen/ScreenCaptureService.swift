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

    /// `nonisolated` 让 CaptureCoordinator (actor) 的 init 不必是 @MainActor。
    /// 实际的 SCK 调用方法仍然在 @MainActor 上跑（绕开 macOS 26 SCK XPC bug）。
    nonisolated init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 抓主显示器一帧。失败重试 3 次。
    func captureMainDisplay() async throws -> CGImage {
        // **Preflight 权限检查**：CGPreflightScreenCaptureAccess() 不触发 SCK XPC
        // 调用，纯本地查 TCC database。如果没授权，**根本不调 SCScreenshotManager**。
        //
        // 为什么不能省：SCK 一旦发起 XPC 请求（即使紧接着抛 permission denied），
        // 后续仍会通过 caulk.messenger 投递若干 reply 回调。我们 coordinator.stop()
        // 后这些 reply 落到已经 invalidated 的 dispatch queue → dispatch_assert
        // → 整进程崩。避免发请求是唯一稳的法子。
        if !CGPreflightScreenCaptureAccess() {
            throw CaptureError.screenRecordingPermissionDenied
        }

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
            } catch CaptureError.screenRecordingPermissionDenied {
                // **快速抛出，绝对不重试**：getOrFetchMainDisplay 已经把 NSError
                // 转成了我们自己的 enum，外层别再 wrap 一次也别 retry。
                // 重试只会让 SCK 多投递几个失败回调到 caulk，挤崩 dispatch queue。
                logger.warning("captureMainDisplay: screen recording permission denied — bailing without retry")
                throw CaptureError.screenRecordingPermissionDenied
            } catch {
                lastError = error
                logger.warning("captureMainDisplay attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")

                // 防御性：NSError 形式的权限错也不重试（理论上 getOrFetchMainDisplay
                // 已经转过了，但 SCScreenshotManager.captureImage 也可能直接抛）。
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
