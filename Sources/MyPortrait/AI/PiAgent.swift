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
        /// Final assistant text from a `message_end` event (used when the wire
        /// API doesn't stream deltas, e.g. openai-codex-responses).
        case assistantFinalText(String)
        case toolStart(id: String, name: String, args: [String: Any])
        case toolEnd(id: String, result: String, isError: Bool)
        case thinkingStart
        case thinkingDelta(String)
        case thinkingEnd(finalText: String?, durationMs: Int?)
        case agentStart
        case agentEnd
        case error(String)
        /// Token usage reported by Pi on `message_end`. Best-effort: 0s when
        /// the provider doesn't report (e.g. ChatGPT OAuth often returns 0 on
        /// the codex-responses wire, in which case we estimate from text length).
        case usage(input: Int, output: Int)
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
    private let provider: Provider
    private let model: String
    private var stdoutBuffer = Data()
    private let bufLock = NSLock()

    /// Continuation used to drive the AsyncStream of events.
    private var eventContinuation: AsyncStream<Event>.Continuation?

    /// Live event stream — call once after `start()`.
    let events: AsyncStream<Event>

    /// SecretStore key whose value should override the provider's default
    /// credential. Set when the user spawned us through an AI preset that
    /// carries its own `apiKeyRef`. `nil` falls back to ProviderAuth's
    /// per-provider key (apikey:anthropic, apikey:openai, …).
    private let apiKeyRefOverride: String?

    /// Extra environment variables injected into the spawned process. Used by
    /// pipes to pass connection credentials (SMTP_*, OBSIDIAN_VAULT_PATH, …)
    /// to the agent — mirrors screenpipe's `cmd.env(...)` injection.
    private let extraEnv: [String: String]

    init(provider: Provider = .chatgpt, model: String? = nil,
         apiKeyRefOverride: String? = nil,
         extraEnv: [String: String] = [:]) throws {
        guard BunInstaller.isInstalled else { throw SpawnError.missingBun }
        guard PiInstaller.isInstalled else { throw SpawnError.missingPi }

        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.apiKeyRefOverride = apiKeyRefOverride
        self.extraEnv = extraEnv
        self.process = Process()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { c in cont = c }
        self.eventContinuation = cont
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Spawn the Pi process. Resolves the right credential for `provider`
    /// (OAuth token / API key / nothing) and injects it as the env var Pi
    /// expects. If `apiKeyRefOverride` was set (preset path), prefer the
    /// value stored under that SecretStore key over the provider default.
    func start() async throws {
        let credential: String
        do {
            if let ref = apiKeyRefOverride,
               let data = SecretStore.shared.get(ref),
               let s = String(data: data, encoding: .utf8), !s.isEmpty {
                credential = s
            } else {
                credential = try await ProviderAuth.resolveEnvValue(for: provider)
            }
        } catch { throw SpawnError.missingToken }

        let stdinPipe = Pipe()
        process.executableURL = AIPaths.bunBinary
        process.arguments = [
            AIPaths.piCliJS.path,
            "--mode", "rpc",
            "--provider", provider.piName,
            "--model", model
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        if !provider.apiKeyEnv.isEmpty {
            env[provider.apiKeyEnv] = credential
        }
        env["BUN_INSTALL"] = AIPaths.bunDir.path
        env["HOME"] = NSHomeDirectory()
        // Connection credentials supplied by the pipe runner.
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env

        // Anchor Pi's cwd to the user's home so bash / file tools have a
        // meaningful working directory. Without this, the cwd inherits from
        // the launching app — which for an Xcode-launched .app is the
        // DerivedData "Build/Products/Debug" path.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // Stream stdout — line-delimited JSON.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.appendStdout(data)
            // Mirror raw Pi traffic to a logfile so we can debug offline.
            Self.appendLog(prefix: "[OUT]", data: data)
        }
        // Mirror stderr to the same logfile.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Self.appendLog(prefix: "[ERR]", data: data)
        }

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

        // Pi wraps streaming events inside `message_update.assistantMessageEvent`
        // for the openai-codex-responses wire. Peel one layer and dispatch
        // the inner event through the same switch.
        if type == "message_update", let inner = obj["assistantMessageEvent"] as? [String: Any] {
            dispatchInner(inner)
            return
        }
        dispatchInner(obj)
    }

    private func dispatchInner(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        switch type {
        case "text_delta":
            if let d = obj["delta"] as? String { emit(.textDelta(d)) }
        case "text_start", "text_end":
            break  // boundary markers — already conveyed by deltas
        case "agent_start":
            emit(.agentStart)
        case "agent_end":
            emit(.agentEnd)
        case "thinking_start":
            emit(.thinkingStart)
        case "thinking_delta":
            if let d = obj["delta"] as? String { emit(.thinkingDelta(d)) }
        case "thinking_end":
            let finalText = obj["content"] as? String
            let dur = obj["durationMs"] as? Int
            emit(.thinkingEnd(finalText: finalText, durationMs: dur))
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
        case "message_end":
            // Fallback path for providers that don't emit text_delta
            // (notably openai-codex-responses). Extract assistant text from
            // the final message.content array, or surface errorMessage.
            guard let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant" else { break }
            if (msg["stopReason"] as? String) == "error" {
                let err = (msg["errorMessage"] as? String) ?? "LLM error"
                emit(.error(err))
            } else if let text = Self.extractAssistantText(msg) {
                emit(.assistantFinalText(text))
            }
            if let usage = msg["usage"] as? [String: Any] {
                let input  = (usage["input"]  as? Int) ?? 0
                let output = (usage["output"] as? Int) ?? 0
                if input > 0 || output > 0 {
                    emit(.usage(input: input, output: output))
                }
            }
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

    /// Same shape as a tool result but applied to a top-level message.
    private static func extractAssistantText(_ msg: [String: Any]) -> String? {
        guard let arr = msg["content"] as? [[String: Any]] else { return nil }
        let parts = arr.compactMap { $0["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: - Debug logfile

    /// `~/Library/Application Support/MyPortrait/pi-rpc.log`
    private static let logURL = AIPaths.supportDir.appendingPathComponent("pi-rpc.log")
    private static let logQueue = DispatchQueue(label: "MyPortrait.PiAgent.log")

    static func appendLog(prefix: String, data: Data) {
        logQueue.async {
            try? AIPaths.ensureExists()
            let line = "\n--- \(prefix) " + ISO8601DateFormatter().string(from: Date()) + " ---\n"
            let blob = (line.data(using: .utf8) ?? Data()) + data
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) {
                    h.seekToEndOfFile()
                    try? h.write(contentsOf: blob)
                    try? h.close()
                }
            } else {
                try? blob.write(to: logURL)
            }
        }
    }
}

