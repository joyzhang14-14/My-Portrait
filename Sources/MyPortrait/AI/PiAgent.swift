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
final class PiAgent: @unchecked Sendable, ChatAgent {

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
        /// Provider 凭证缺失(OAuth 未登录 / API key 没贴)。associated value
        /// 是 provider 的展示名,确保错误文案里出现的是真正用的那个 provider,
        /// 而不是 ChatGPT/Codex 一刀切。
        case missingToken(provider: String)
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingBun:        return "Bun runtime is not installed."
            case .missingPi:         return "Pi agent is not installed."
            case .missingToken(let p):
                return "\(p) credential missing — set it up in Connections."
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
    /// 最近 ~8KB stderr 输出。Pi 异常退出时附在 .error 里给用户/我们看,
    /// 不写盘(避免 pi-rpc.log 那种无界增长)。
    private var stderrTail = Data()
    private let stderrLock = NSLock()
    /// 进程退出前是否已经发过 agentEnd / message_end 的状态。terminationHandler
    /// 据此决定是否要补一个 .error 给 ChatController(避免"thinking…"死循环)。
    private var sawTurnEnd = false

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
    /// cronJobs to pass connection credentials (SMTP_*, OBSIDIAN_VAULT_PATH, …)
    /// to the agent — mirrors screenpipe's `cmd.env(...)` injection.
    private let extraEnv: [String: String]

    /// Pi session jsonl 路径。非 nil → spawn 时挂 `--session <path>`,pi 把
    /// 历史 message replay 回 agent 上下文(同 conv 多轮 / 切走再切回都靠
    /// 这条)。nil → pi 起新 session,本进程退出就丢。chat 路径必传,memory
    /// pipeline / cron job 的一次性任务保持 nil。
    private let sessionPath: String?

    init(provider: Provider = .chatgpt, model: String? = nil,
         apiKeyRefOverride: String? = nil,
         extraEnv: [String: String] = [:],
         sessionPath: String? = nil) throws {
        guard BunInstaller.isInstalled else { throw SpawnError.missingBun }
        guard PiInstaller.isInstalled else { throw SpawnError.missingPi }

        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.apiKeyRefOverride = apiKeyRefOverride
        self.extraEnv = extraEnv
        self.sessionPath = sessionPath
        self.process = Process()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { c in cont = c }
        self.eventContinuation = cont
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Spawn the Pi process. 凭证注入策略(Pi 0.60 起两种):
    ///   - Codex(ChatGPT OAuth):写 `~/.pi/agent/auth.json` 的
    ///     `openai-codex` entry,Pi 自己读 + 自己 refresh
    ///   - 其它(anthropic / openai / google API key):仍走 env var
    ///     (Pi 0.60 的 getEnvApiKey 内置认 OPENAI_API_KEY /
    ///      ANTHROPIC_API_KEY / GEMINI_API_KEY)
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
        } catch { throw SpawnError.missingToken(provider: provider.displayName) }

        // Codex 走 auth.json,需要拿到完整的 OAuth tokens(access + refresh
        // + expires),不止 access token。从 ChatGPTOAuth 重新读一遍。
        if provider == .chatgpt {
            try await Self.writeCodexAuth()
        }

        let stdinPipe = Pipe()
        process.executableURL = AIPaths.bunBinary
        var piArgs: [String] = [
            AIPaths.piCliJS.path,
            "--mode", "rpc",
            "--provider", provider.piName,
            "--model", model
        ]
        // chat 路径每条 conv 一个固定 session jsonl。pi 的 SessionManager.open
        // 会在文件存在时 replay 历史 message,不存在时按这个路径创建新 session。
        // 双向都覆盖到 → 不用提前 touch 文件。
        if let sessionPath {
            piArgs.append(contentsOf: ["--session", sessionPath])
        }
        process.arguments = piArgs
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        // Codex 不通过 env(Pi 0.60 没给它 env 入口,只能走 auth.json)。
        // 其它 provider:沿用 env var 注入,Pi 0.60 的 getEnvApiKey 认 OPENAI_API_KEY
        // / ANTHROPIC_API_KEY / GEMINI_API_KEY 这三个 builtin。
        if provider != .chatgpt, !provider.apiKeyEnv.isEmpty {
            env[provider.apiKeyEnv] = credential
        }
        env["BUN_INSTALL"] = AIPaths.bunDir.path
        env["HOME"] = NSHomeDirectory()
        // 把 ~/.portrait/bin 加进 PATH,让 pi-coding-agent 的 bash 能直接调
        // `mp-query`(symlink 到 app 主二进制)拿屏幕数据。SKILL.md 风格。
        let existingPATH = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(AIPaths.binDir.path):\(existingPATH)"
        // Connection credentials supplied by the cron job runner.
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
        }
        // stderr 留最近 ~8KB 在内存(ring buffer 模拟:超长就截到 tail),
        // 用于异常退出时给用户看为什么挂的。不写盘,无界增长是个大坑。
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.stderrLock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 8 * 1024 {
                self.stderrTail = self.stderrTail.suffix(8 * 1024)
            }
            self.stderrLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // 在 bufLock 下读 sawTurnEnd(它的写在 appendStdout 里也持锁),建立
            // happens-before,消除跟 stdout readabilityHandler 的数据竞争 / UB。
            // ⚠️ 不要在这里 `availableData` 排空 stdout —— 父进程仍持有管道写端时
            // availableData 会永久阻塞等 EOF,导致 terminationHandler 挂死、
            // eventContinuation 永不 finish、chat 永远卡「thinking…」(概率性)。
            self.bufLock.lock()
            let done = self.sawTurnEnd
            self.bufLock.unlock()
            // 进程异常退出且没发过 turn-end 事件 → ChatController 不知道
            // 怎么收尾,会一直转圈。补一个 .error 把 stderr tail 带回去。
            if !done {
                self.stderrLock.lock()
                let tail = String(data: self.stderrTail, encoding: .utf8) ?? ""
                self.stderrLock.unlock()
                let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg: String
                if proc.terminationStatus != 0 {
                    msg = "Pi agent crashed (exit code \(proc.terminationStatus))."
                        + (trimmed.isEmpty ? "" : "\n\nstderr:\n\(trimmed.suffix(2000))")
                } else {
                    msg = "Pi agent exited before responding."
                        + (trimmed.isEmpty ? "" : "\n\nstderr:\n\(trimmed.suffix(2000))")
                }
                self.eventContinuation?.yield(.error(msg))
                self.eventContinuation?.yield(.agentEnd)
            }
            self.eventContinuation?.finish()
        }

        do {
            try process.run()
        } catch {
            throw SpawnError.launchFailed(error.localizedDescription)
        }
        self.stdin = stdinPipe.fileHandleForWriting
        // Register so the "Stop" emergency brake can find + kill this agent.
        PiAgentRegistry.shared.register(self)
    }

    func stop() {
        PiAgentRegistry.shared.unregister(self)
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

    /// ChatAgent 协议要求的 1-arg 版本 —— delegate 给带 id 的实现。
    func sendPrompt(_ text: String) throws {
        try sendPrompt(text, id: UUID().uuidString)
    }

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
            sawTurnEnd = true
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
            sawTurnEnd = true
            // Fallback path for providers that don't emit text_delta
            // (notably openai-codex-responses). Extract assistant text from
            // the final message.content array, or surface errorMessage.
            guard let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant" else { break }
            let stopReason = msg["stopReason"] as? String
            if stopReason == "error" {
                let err = (msg["errorMessage"] as? String) ?? "LLM error"
                emit(.error(err))
            } else if stopReason == "length" {
                // 输出被截断(碰 max_tokens / 模型自己 stop=length)。**不能**当
                // 完整结果处理 —— partial buffer 会让 downstream parser 拿到半截
                // JSON 解出畸形 / 缺字段结构污染落盘。一律当 error,ErrorClassifier
                // 会把这归到 .streamTruncated(桶 A,scheduler 自动 backoff 重跑)。
                emit(.error("output truncated (stopReason=length)"))
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

    /// 写 Pi 0.60 的 `~/.pi/agent/auth.json`,把 ChatGPT OAuth tokens 塞进
    /// `openai-codex` entry。Pi 自己后续负责 refresh(它认 refresh + expires)。
    /// 与现有 entries 合并,不会覆盖别人的(比如 anthropic API key)。
    fileprivate static func writeCodexAuth() async throws {
        // 拿到当前一定有效的全套 tokens(自动 refresh 过期的)。
        let tokens = try await ChatGPTOAuth.validTokens()

        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(
            at: authPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 读现有 auth.json(可能没有 / 损坏 → 当空 dict)。
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: authPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        // Pi 0.60 schema(从 dist/utils/oauth/openai-codex.js 反向工程):
        //   { type: "oauth", access: <jwt>, refresh: <token>, expires: <ms> }
        // expires 是 unix milliseconds(注意 ChatGPTOAuth 里 expiresAt 是
        // 秒,× 1000)。
        let expiresMs: Int64
        if let secs = tokens.expiresAt {
            expiresMs = Int64(secs * 1000)
        } else {
            // 没有 expiresAt 字段就保守给 1 小时,让 Pi 早点 refresh。
            expiresMs = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        }
        root["openai-codex"] = [
            "type": "oauth",
            "access": tokens.accessToken,
            "refresh": tokens.refreshToken,
            "expires": expiresMs,
        ] as [String: Any]

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authPath, options: .atomic)
        // Pi 自己写时 chmod 0600,我们对齐。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: authPath.path)
    }

    /// Same shape as a tool result but applied to a top-level message.
    private static func extractAssistantText(_ msg: [String: Any]) -> String? {
        guard let arr = msg["content"] as? [[String: Any]] else { return nil }
        let parts = arr.compactMap { $0["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

}

