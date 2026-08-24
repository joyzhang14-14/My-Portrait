import Foundation

/// Pipeline owner 标签 —— 让 "Stop" 能只停某一条 pipeline 的 LLM 子进程,
/// 并发时不误杀别的 pipeline / chat。值在 PiAgentRegistry.$owner 这个
/// task-local 上传播。
enum PipelineOwner {
    static let event          = "event"
    static let distill        = "distill"
    static let personality    = "personality"
    static let writingCapture = "writing_capture"
    static let writingStyle   = "writing_style"
}

/// Tracks every live LLM agent(`PiAgent` / `ClaudeCodeAgent` —— 任何
/// `ChatAgent`)so "Stop" can kill them — the emergency brake for runaway
/// LLM token spend.
///
/// Agent 在 start() 里注册、stop() 里注销。`stopAll()` terminates every
/// agent; `stopGroup(owner)` only those tagged with a pipeline owner (chat
/// agents have owner == nil, so a per-pipeline Stop never touches chat).
///
/// ⚠️ 别按具体类型收窄:必须同时收 PiAgent 和 ClaudeCodeAgent,否则
/// Stop / 60-min 兜底会打空("killed 0 LLM process(es)"),任务杀不掉、
/// 进度条卡死。
///
/// Thread-safe (NSLock) because agents are not actor-isolated and spawn from
/// whatever context the pipeline runs on.
final class PiAgentRegistry: @unchecked Sendable {
    static let shared = PiAgentRegistry()
    private init() {}

    /// 当前 pipeline owner。pipeline 用 `$owner.withValue(PipelineOwner.event) { … }`
    /// 包住自己的运行,期间生成的 agent 都登记这个 owner。chat / cron 不绑 → nil。
    @TaskLocal static var owner: String?

    private final class WeakBox {
        weak var agent: (any ChatAgent)?
        let owner: String?
        init(_ a: any ChatAgent, owner: String?) { agent = a; self.owner = owner }
    }

    private let lock = NSLock()
    private var boxes: [WeakBox] = []

    func register(_ agent: any ChatAgent) {
        lock.lock(); defer { lock.unlock() }
        boxes.removeAll { $0.agent == nil }
        // 登记时读 task-local owner —— register 在 agent 的 start() 内同步调用,
        // 跑在绑了 owner 的 task 上下文里,读得到。
        boxes.append(WeakBox(agent, owner: Self.owner))
    }

    func unregister(_ agent: any ChatAgent) {
        lock.lock(); defer { lock.unlock() }
        boxes.removeAll { $0.agent == nil || $0.agent === agent }
    }

    /// Stop every live agent. Returns how many were stopped.
    @discardableResult
    func stopAll() -> Int {
        lock.lock()
        let live = boxes.compactMap { $0.agent }
        boxes.removeAll()
        lock.unlock()
        for a in live { a.stop() }
        return live.count
    }

    /// 只停某 owner 的 agent —— 精准 Stop,并发时不误杀别的 pipeline / chat。
    @discardableResult
    func stopGroup(_ owner: String) -> Int {
        lock.lock()
        let live = boxes.filter { $0.owner == owner }.compactMap { $0.agent }
        boxes.removeAll { $0.agent == nil || $0.owner == owner }
        lock.unlock()
        for a in live { a.stop() }
        return live.count
    }
}
