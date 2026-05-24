import Foundation

/// 聊天 agent 接口 —— PiAgent 和 ClaudeCodeAgent 都实现这个,ChatController
/// 在 provider 上分发,不关心具体走哪条路。事件统一用 PiAgent.Event
/// (历史沉淀,UI 已对接好,直接复用比抽象一层 AgentEvent 干净)。
protocol ChatAgent: AnyObject, Sendable {
    /// 启动子进程 / 建立连接。stdin / stdout / 事件循环在这里就位。
    func start() async throws
    /// 发一条用户提示。
    func sendPrompt(_ text: String) throws
    /// 通知子进程停止(发 SIGTERM / 写 stop 命令)。
    func stop()
    /// 中断当前正在流式的回复(用户点 Cancel)。
    func abort() throws
    /// 事件流。生命周期跟 agent 一致,start() 之后开始有事件,stop 后 finish。
    var events: AsyncStream<PiAgent.Event> { get }
}
