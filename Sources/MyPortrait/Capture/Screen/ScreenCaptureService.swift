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

    private let ignore: IgnoreGate

    /// 被排除窗口区域的填充色。`SCStreamConfiguration.backgroundColor` 是
    /// `unowned(unsafe)`，必须用长生命周期常量，否则临时 CGColor 立即释放成野指针。
    private static let maskBackground = CGColor(gray: 0, alpha: 1)

    /// `nonisolated` 让 CaptureCoordinator (actor) 的 init 不必是 @MainActor。
    /// 实际的 SCK 调用方法仍然在 @MainActor 上跑（绕开 macOS 26 SCK XPC bug）。
    nonisolated init(config: CaptureConfig, reporter: UnimplementedReporter, ignore: IgnoreGate) {
        self.config = config
        self.reporter = reporter
        self.ignore = ignore
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
            // **第一次失败时主动请求授权**：CGRequestScreenCaptureAccess() 会弹
            // 标准系统对话框（如果没弹过 / 上次拒绝过会再弹一次）；如果用户已
            // 在 System Settings 给"另一个"MyPortrait 授过权但 cdhash 不匹配，
            // 这一次也会按当前 binary 的 cdhash 重新登记。
            // 调用本身是同步、非 XPC、纯 TCC 操作，不会触发崩溃路径。
            // 用户点 Allow 后，TCC entry 落地，下一次 preflight 就过。
            _ = CGRequestScreenCaptureAccess()
            // 不管对话框结果如何，本次仍然 fail —— 用户授权后需要再 toggle 一下。
            throw CaptureError.screenRecordingPermissionDenied
        }

        var lastError: Error?

        for attempt in 0..<3 {
            do {
                let (display, windows) = try await fetchDisplayAndWindows()
                // Content masking：命中 ignore 规则的窗口排除出捕获 buffer
                // （帧照拍，那些窗口在帧里变透明）。
                let excluded = windows.filter {
                    ignore.shouldMaskWindow(
                        appName: $0.owningApplication?.applicationName ?? "",
                        title: $0.title
                    )
                }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(display.width)
                cfg.height = Int(display.height)
                cfg.scalesToFit = false
                cfg.showsCursor = false
                cfg.capturesAudio = false
                // 被排除的窗口区域填不透明黑（默认是透明，存 JPG 时会被压平成白）。
                cfg.backgroundColor = Self.maskBackground

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

                // 重试前小睡（100ms），避免立即撞错。
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        throw CaptureError.captureFailed(underlying: lastError
            ?? NSError(domain: "MyPortrait.Capture", code: -1))
    }

    /// 旧的 SCDisplay 缓存已移除（masking 要每帧重新枚举窗口）。保留方法
    /// 供 sleep/wake / DRM watcher 调用，现在是 no-op。
    func invalidateStream() async {}

    // MARK: - 私有

    /// 每帧重新枚举：主显示器 + 当前所有屏上窗口。masking 要逐窗口判定排除，
    /// 窗口位置 / 开关每帧都在变，不能缓存。
    private func fetchDisplayAndWindows() async throws -> (SCDisplay, [SCWindow]) {
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
        return (display, content.windows)
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
