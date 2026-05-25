import Foundation

/// Tracks every live `PiAgent` subprocess so a single "Stop" action can kill
/// them all — the emergency brake for runaway LLM token spend.
///
/// PiAgent registers itself once its process is running and unregisters on
/// `stop()` / deinit. `stopAll()` terminates every agent still alive.
///
/// Thread-safe (NSLock) because PiAgent is not actor-isolated and spawns from
/// whatever context the pipeline runs on.
final class PiAgentRegistry: @unchecked Sendable {
    static let shared = PiAgentRegistry()
    private init() {}

    private final class WeakBox {
        weak var agent: PiAgent?
        init(_ a: PiAgent) { agent = a }
    }

    private let lock = NSLock()
    private var boxes: [WeakBox] = []

    func register(_ agent: PiAgent) {
        lock.lock(); defer { lock.unlock() }
        boxes.removeAll { $0.agent == nil }
        boxes.append(WeakBox(agent))
    }

    func unregister(_ agent: PiAgent) {
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
}
