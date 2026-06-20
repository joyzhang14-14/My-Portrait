import Foundation

/// XPC 协议 —— app(client)↔ PortraitSleepHelper(root LaunchDaemon)。
///
/// ⚠️ 这个文件在两个 target 里各有一份**逐字相同**的拷贝:
///   - app:    Sources/MyPortrait/Capture/Power/SleepHelperProtocol.swift
///   - helper: Sources/PortraitSleepHelper/SleepHelperProtocol.swift(本文件)
/// 为什么不抽成共享 target:双轨构建(SwiftPM + XcodeGen)下一个 .swift 文件只能属
/// 于一个 target,共享会让另一边编不过;抽共享 library 又是没必要的抽象层。XPC 的
/// `@objc` 协议本来就靠 selector + 显式 ObjC 名跨进程匹配,两份同名拷贝是标准做法
/// (验证过的 probe 也是这么干的)。**改一处必须同步改另一处。**
///
/// 显式 `@objc(PortraitSleepHelperProtocol)` 固定 ObjC runtime 名,保证 app 和
/// helper 两个 binary 里的协议解析到同一个 NSXPCInterface。
@objc(PortraitSleepHelperProtocol)
protocol PortraitSleepHelperProtocol {
    /// 以 root 跑 `pmset -c disablesleep <0/1>`,让机器合盖+插电也完全清醒(`true`)
    /// 或恢复正常睡眠(`false`)。reply 回 (生效后的状态, 诊断串) 供 app 端 log。
    /// 幂等 —— 重复同一状态是 no-op。
    /// ⚠️ reply 必须 `@Sendable` —— XPC 在**连接自己的队列**上回调它,不是主线程。
    /// 不标的话,在 @MainActor 的调用方(SleepHelperClient)里会被推断成 @MainActor
    /// 隔离,XPC 在非主队列回调时触发 `_dispatch_assert_queue_fail` 崩溃。
    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping @Sendable (Bool, String) -> Void)

    /// 轻量连通性探针:确认 helper 已被 launchd 拉起、XPC 通了、以什么 uid 在跑。
    func ping(withReply reply: @escaping @Sendable (String) -> Void)
}
