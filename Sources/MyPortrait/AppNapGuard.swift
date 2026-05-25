import Foundation

/// macOS App Nap 防护的 RAII 包装。
///
/// macOS 会在 app 失焦 / 窗口被遮时 throttle 后台进程(定时器变粗、CPU 降级、
/// I/O 排队尾),后台跑的 Whisper / LLM / OCR batch 实际耗时可能慢 10-20 倍。
///
/// `ProcessInfo.beginActivity(.userInitiated.union(.latencyCritical), ...)` 告诉
/// 系统"这段时间这个任务对延迟敏感、别 throttle 我",返回 token,任务结束
/// `endActivity(token)` 释放。
///
/// 用法:
/// ```swift
/// let napGuard = AppNapGuard.acquire(reason: "Whisper transcription")
/// defer { napGuard.release() }
/// // ... 跑长任务 ...
/// ```
struct AppNapGuard {
    private let token: (any NSObjectProtocol)?

    /// 拿一个 activity token。reason 显示在 macOS 调试工具里,定位用。
    static func acquire(reason: String) -> AppNapGuard {
        let t = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: reason
        )
        return AppNapGuard(token: t)
    }

    /// 释放 token。idempotent(重复 release 是 no-op,因 endActivity 不能传 nil)。
    func release() {
        if let t = token {
            ProcessInfo.processInfo.endActivity(t)
        }
    }
}
