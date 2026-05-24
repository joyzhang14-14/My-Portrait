import Foundation

/// memory pipeline 用的 LLM agent 工厂。按 provider 在 PiAgent / ClaudeCodeAgent
/// 之间分发。memory 任务跟 chat 不同 —— 每条 prompt 是独立的(评 impact、抽 tag、
/// 蒸馏 portrait...),没有"续会话"的概念,所以 ClaudeCodeAgent 走 oneshot 模式
/// 防止 session 上下文污染下一个任务。
enum MemoryAgentFactory {
    /// 返回一个还没 start() 的 ChatAgent;调用方负责 start / defer stop。
    static func make(provider: Provider, model: String) throws -> any ChatAgent {
        switch provider {
        case .claudeCode:
            return ClaudeCodeAgent(model: model, oneshot: true)
        default:
            return try PiAgent(provider: provider, model: model)
        }
    }
}
