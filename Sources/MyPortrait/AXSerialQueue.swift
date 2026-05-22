import Foundation

/// 全 app 唯一的 Accessibility 调用串行队列。
///
/// macOS 的 AX API 对「多线程并发调用」不安全 —— 多个子系统
/// （`TypingObserver` / `FocusProbe`）各自在后台队列并发调 `AXUIElement*`
/// C API 时，框架内部状态会打架。实测过两种症状:
///   - 主线程 `__ulock_wait` 死锁(早期 main + actor 池并发)
///   - 后台队列 `_dispatch_assert_queue_fail` 崩溃(两条后台队列并发)
///
/// 解法:全 app 所有 AX 调用都串到这一条队列上 —— 永不并发。
enum AXSerialQueue {
    static let shared = DispatchQueue(label: "com.myportrait.ax.serial")
}
