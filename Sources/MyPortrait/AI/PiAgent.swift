import Foundation

/// One Pi-coding-agent subprocess. Spawned with `bun <cli.js> --mode rpc`,
/// communicates over line-delimited JSON on stdin/stdout.
///
/// Protocol (subset we use, mirroring Orphies' usage):
///   stdin →  `{"type":"prompt","message":"<user text>","id":"<uuid>"}`
///   stdin →  `{"type":"abort"}`
///   stdout ← `{"type":"response", "success":true, ...}`             (cmd ack)
///   stdout ← `{"type":"agent_start"|"agent_end", ...}`              (turn lifecycle)
///   stdout ← `{"type":"text_delta", "delta":"..."}`                 (token stream)
///   stdout ← `{"type":"tool_execution_start", "toolCallId":..., "toolName":..., "args":...}`
///   stdout ← `{"type":"tool_execution_end",   "toolCallId":..., "result":{...}, "isError":bool}`
///   stdout ← `{"type":"thinking_start"|"thinking_end", ...}`
///   stdout ← `{"type":"message_start"|"message_end", "message":{...}}`
///
/// One agent serves one conversation. Caller is responsible for `stop()` when
/// the conversation is closed.
final class PiAgent: @unchecked Sendable {

    enum Event: @unchecked Sendable {
        case textDelta(String)
        case toolStart(id: String, name: String, args: [String: Any])
        case toolEnd(id: String, result: String, isError: Bool)
        case thinkingStart
        case thinkingEnd
        case agentStart
        case agentEnd
        case error(String)
        case raw([String: Any])     // anything we don't model yet
    }

    enum SpawnError: LocalizedError {
        case missingBun
        case missingPi
        case missingToken
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingBun:        return "Bun runtime is not installed."
            case .missingPi:         return "Pi agent is not installed."
            case .missingToken:      return "ChatGPT not signed in."
            case .launchFailed(let m): return "Failed to start Pi: \(m)"
            }
        }
    }

    private let process: Process
    private var stdin: FileHandle?            // assigned in start()
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let model: String
    private var stdoutBuffer = Data()
    private let bufLock = NSLock()

    /// Continuation used to drive the AsyncStream of events.
    private var eventContinuation: AsyncStream<Event>.Continuation?

    /// Live event stream — call once after `start()`.
    let events: AsyncStream<Event>

    init(model: String) throws {
        guard BunInstaller.isInstalled else { throw SpawnError.missingBun }
        guard PiInstaller.isInstalled else { throw SpawnError.missingPi }

        self.model = model
        self.process = Process()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { c in cont = c }
        self.eventContinuation = cont
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Spawn the Pi process with the ChatGPT OAuth token in the environment.
    func start() async throws {
        let token: String
        do { token = try await ChatGPTOAuth.validToken() }
        catch { throw SpawnError.missingToken }

        let stdinPipe = Pipe()
        process.executableURL = AIPaths.bunBinary
        process.arguments = [
            AIPaths.piCliJS.path,
            "--mode", "rpc",
            "--provider", "openai-chatgpt",
            "--model", model
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        env["OPENAI_CHATGPT_TOKEN"] = token
        env["BUN_INSTALL"] = AIPaths.bunDir.path
        env["HOME"] = NSHomeDirectory()
        process.environment = env

        // Stream stdout — line-delimited JSON.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.appendStdout(data)
        }
        // Drain stderr so the process doesn't block on a full pipe; log on demand.
        stderrPipe.fileHandleForReading.readabilityHandler = { _ in /* swallow */ }

        process.terminationHandler = { [weak self] _ in
            self?.eventContinuation?.finish()
        }

        do {
            try process.run()
        } catch {
            throw SpawnError.launchFailed(error.localizedDescription)
        }
        self.stdin = stdinPipe.fileHandleForWriting
    }

    func stop() {
        eventContinuation?.finish()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            // Try graceful abort first, then SIGTERM.
            try? send(["type": "abort"])
            process.terminate()
        }
    }

    // MARK: - Sending

    func sendPrompt(_ message: String, id: String = UUID().uuidString) throws {
        try send(["type": "prompt", "message": message, "id": id])
    }

    func abort() throws { try send(["type": "abort"]) }

    private func send(_ obj: [String: Any]) throws {
        guard let stdin else { throw SpawnError.launchFailed("stdin not ready") }
        let data = try JSONSerialization.data(withJSONObject: obj)
        var line = data
        line.append(0x0A)
        try stdin.write(contentsOf: line)
    }

    // MARK: - Stdout parsing

    private func appendStdout(_ chunk: Data) {
        bufLock.lock()
        stdoutBuffer.append(chunk)
        // Split on \n, dispatch each complete line.
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<nl]
            stdoutBuffer.removeSubrange(...nl)
            if lineData.isEmpty { continue }
            dispatch(line: Data(lineData))
        }
        bufLock.unlock()
    }

    private func dispatch(line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return
        }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "text_delta":
            if let d = obj["delta"] as? String { emit(.textDelta(d)) }
        case "agent_start":
            emit(.agentStart)
        case "agent_end":
            emit(.agentEnd)
        case "thinking_start":
            emit(.thinkingStart)
        case "thinking_end":
            emit(.thinkingEnd)
        case "tool_execution_start":
            let id   = obj["toolCallId"] as? String ?? ""
            let name = obj["toolName"]   as? String ?? "unknown"
            let args = obj["args"]       as? [String: Any] ?? [:]
            emit(.toolStart(id: id, name: name, args: args))
        case "tool_execution_end":
            let id      = obj["toolCallId"] as? String ?? ""
            let isError = obj["isError"]    as? Bool   ?? false
            let result  = Self.extractText(obj["result"]) ?? ""
            emit(.toolEnd(id: id, result: result, isError: isError))
        case "response":
            // Command ack — surface only failures.
            if let success = obj["success"] as? Bool, !success {
                let err = obj["error"] as? String ?? "command failed"
                emit(.error(err))
            }
        default:
            emit(.raw(obj))
        }
    }

    private func emit(_ ev: Event) {
        eventContinuation?.yield(ev)
    }

    /// Pi packs tool results as `{ content: [{ type:"text", text:"..."}, ...] }`.
    private static func extractText(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        guard let dict = v as? [String: Any] else { return nil }
        if let arr = dict["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }
}

