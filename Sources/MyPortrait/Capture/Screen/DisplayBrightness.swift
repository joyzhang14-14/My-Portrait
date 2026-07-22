import CoreGraphics
import Foundation

/// 读主显示器亮度(0–1)—— pauseAtMinBrightness gate 用。
///
/// macOS 没有公开 API 读亮度(IOKit 的 IODisplay 参数在 Apple Silicon 上失效),
/// 走系统私有框架 DisplayServices(MonitorControl 等工具同款做法;dlopen 的是
/// 系统自带框架,不引第三方依赖)。
///
/// 读不到(符号缺失 / 外接不可控显示器返回错误)一律 fail-open:
/// `isAtMinimum()` 返回 false → 不跳帧,采集照常。
enum DisplayBrightness {
    private typealias GetBrightnessFn =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    /// dlopen 一次性解析,进程生命周期内复用。失败(理论上不该发生,系统
    /// 自带框架)则永远 nil → fail-open。
    private static let getBrightness: GetBrightnessFn? = {
        guard let h = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ), let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()

    /// 当前主显示器亮度 0–1;读不到返回 nil。
    static func current() -> Float? {
        guard let fn = getBrightness else { return nil }
        var v: Float = -1
        guard fn(CGMainDisplayID(), &v) == 0, v >= 0 else { return nil }
        return v
    }

    /// 亮度是否已调到最低(滑块 0)。0.005 是浮点余量,不是"低亮度"阈值 ——
    /// 只有真正打到底才算(07-21 用户定稿:亮度=最低时停采)。
    static func isAtMinimum() -> Bool {
        guard let v = current() else { return false }
        return v <= 0.005
    }
}
