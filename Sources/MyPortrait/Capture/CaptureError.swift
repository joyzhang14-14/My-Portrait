import Foundation

/// 采集层统一错误类型。所有 Capture/ 子模块抛错都走这里。
///
/// P0 阶段唯一有意义的 case 是 `notImplemented`。P1 起逐步补齐真实错误。
public enum CaptureError: Error, Sendable {

    /// stub 占位错误。永远带组件名 + file:line，便于排查"哪条路径还没填"。
    ///
    /// 调用方不要自己构造这个 case —— 走 `UnimplementedReporter.notImplemented(_:)`
    /// helper，它会同时上报到 reporter（log / 状态栏 / 计数）。
    case notImplemented(component: String, file: String, line: Int)

    // ── P1+ 待补 ──────────────────────────────────────────
    // case screenRecordingPermissionDenied
    // case microphonePermissionDenied
    // case displayNotFound(monitorId: String)
    // case drmBlocked(appName: String)
    // case diskFull(path: String)
    // case ocrFailed(underlying: Error)
    // case modelLoadFailed(modelName: String)
    // case dbWriteFailed(underlying: Error)
}

extension CaptureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .notImplemented(component, file, line):
            return "CaptureError.notImplemented(\(component) @ \(file):\(line))"
        }
    }
}
