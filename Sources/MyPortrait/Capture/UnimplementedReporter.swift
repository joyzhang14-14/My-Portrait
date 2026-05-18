import Foundation
import os.log

/// 收集所有 `CaptureError.notImplemented` 命中事件。
///
/// 目的：stub 不允许静默通过 release。任何调用都必须落 log + 触发状态栏红点。
/// 详情见 memory: feedback-notimplemented-visibility。
///
/// 使用方式：调用方走 `reporter.notImplemented("Module.func")` helper，
/// 它会 fire-and-forget 上报，并返回一个可 throw 的 `CaptureError`。
///
/// 调用点保持同步 + 一行：
/// ```swift
/// throw reporter.notImplemented("ScreenCaptureService.captureMainDisplay")
/// ```
@MainActor
final class UnimplementedReporter: ObservableObject {

    /// 累计调用次数。SwiftUI / NSStatusItem 订阅这个值变化。
    @Published private(set) var callCount: Int = 0

    /// 最近一次命中。UI 工具栏可点击查看详情。
    @Published private(set) var lastEvent: Event?

    /// 是否曾经命中过 stub。release build 上线后这个永远应该是 false。
    var hasUnimplementedStubs: Bool { callCount > 0 }

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "stub")

    /// 主线程上报。通常不直接调用 —— 走 `notImplemented(_:)` helper。
    func report(component: String, file: String, line: Int) {
        let shortFile = (file as NSString).lastPathComponent
        let event = Event(component: component, file: shortFile, line: line, at: Date())
        logger.warning("notImplemented hit: \(component, privacy: .public) at \(shortFile, privacy: .public):\(line, privacy: .public)")
        callCount += 1
        lastEvent = event
    }

    struct Event: Identifiable, Sendable {
        let id = UUID()
        let component: String
        let file: String
        let line: Int
        let at: Date
    }
}

extension UnimplementedReporter {
    /// 调用点首选 helper：
    /// - 异步 fire-and-forget 上报（不阻塞调用方）
    /// - 立即返回一个可 throw 的 `CaptureError.notImplemented`
    /// - `[weak self]` 防御：reporter 被释放后 Task 不持有强引用
    /// - `.background` 优先级：不抢实际工作的调度
    nonisolated func notImplemented(
        _ component: String,
        file: String = #file,
        line: Int = #line
    ) -> CaptureError {
        Task(priority: .background) { [weak self] in
            await self?.report(component: component, file: file, line: line)
        }
        return CaptureError.notImplemented(component: component, file: file, line: line)
    }
}
