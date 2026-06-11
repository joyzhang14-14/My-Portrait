import Foundation
import os.log

/// Claude Code CLI 子进程包装,跟 PiAgent 同接口(都实现 ChatAgent),
/// ChatController 按 provider 分发。
///
/// 工作模式:
///   - 每一轮 sendPrompt() 启一个 `claude --print --output-format stream-json
///     --include-partial-messages --permission-mode bypassPermissions --model <m>
///     -p <prompt>` 一次性子进程。
///   - 第一轮从 system/init 事件抓 session_id,后续轮加 `-r <session_id>`
///     续上下文(Claude Code 自己管会话状态)。
///
/// 认证:依赖用户在终端跑过 `claude login`(走 Pro/Max 订阅,不是 API key)。
/// 本 agent 不存任何凭证。
final class ClaudeCodeAgent: @unchecked Sendable, ChatAgent {

    private let log = Logger(subsystem: "com.myportrait", category: "claude-code-agent")
    private let model: String
    /// true = 每轮 sendPrompt 都不复用 session_id(memory pipeline 用,每条
    /// prompt 是独立任务,串上下文反而污染);false = 多轮续会话(chat 用)。
    private let oneshot: Bool
    /// 多轮续会话:第一次响应里抓出来,后续 sendPrompt 用 `-r <sid>` 续。
    /// init 时如果上层传了已有 sid(从 ChatStore 读),直接拿来用 —— 切走
    /// 再切回时不丢上下文。
    private var sessionId: String?
    /// 抓到新 sid / sid 变化时通知上层 —— ChatController 把它写回
    /// ChatStore 的 `claude_session_id` 列。closure 在调用 sendPrompt
    /// 的 actor 上下文跑,需要自己 hop 回 main。
    private let onSessionId: ((String) -> Void)?

    private var currentProcess: Process?
    private var stdoutBuffer = Data()
    private let bufLock = NSLock()
    /// 每个 content_block 的 index → 类型("thinking"/"text"/"tool_use")。
    /// 用来在 content_block_stop 时正确发对应的 end 事件。
    private var currentBlockType: [Int: String] = [:]
    /// 每个 content_block index → 那个 block 对应的 tool_use id(start 时记)。
    /// input_json_delta 通过 index 找回 id,再累积 partial_json。
    private var toolIdByIndex: [Int: String] = [:]
    /// 每个 tool_use id → 已累积的 input partial_json。content_block_stop
    /// 时解析这串拿到完整 args,再 yield 一个带 args 的 toolStart 给 UI。
    private var pendingToolInput: [String: String] = [:]
    /// 每个 tool_use id → tool name(content_block_start 时记下,
    /// content_block_stop yield toolStart 时一起用)。
    private var pendingToolName: [String: String] = [:]

    /// 本轮收尾闸门:`.agentEnd` 必须等「stdout 读到 EOF」和「进程退出」都
    /// 发生后才发 —— 两个回调跑在不同 GCD 队列,先后无保证;termination 先
    /// 到时内核管道里可能还压着最后一段 text_delta / result,提前 agentEnd
    /// 会让 ChatController 把回复尾巴丢在 assistantMessageID==nil 守卫上
    /// (表现:偶发回复末尾缺一截,回复越长越容易命中)。
    /// `endGeneration` 防上一轮的迟到回调(防御性 terminate 旧进程时,它的
    /// terminationHandler 可能晚于新一轮 reset 才跑)污染新一轮状态。
    private let endLock = NSLock()
    private var stdoutEOF = false
    private var procExited = false
    private var endFired = false
    private var endGeneration = 0

    private var eventContinuation: AsyncStream<PiAgent.Event>.Continuation?
    let events: AsyncStream<PiAgent.Event>

    /// Cron job 等场景注入的额外环境变量(SMTP_*, OBSIDIAN_VAULT_PATH …),
    /// 跟 PiAgent.extraEnv 等价。空 = 走继承的 ProcessInfo 环境。
    private let extraEnv: [String: String]

    init(model: String, oneshot: Bool = false, extraEnv: [String: String] = [:],
         initialSessionId: String? = nil,
         onSessionId: ((String) -> Void)? = nil) {
        self.model = model.isEmpty ? "sonnet" : model
        self.oneshot = oneshot
        self.extraEnv = extraEnv
        self.sessionId = initialSessionId
        self.onSessionId = onSessionId
        var c: AsyncStream<PiAgent.Event>.Continuation!
        self.events = AsyncStream { cont in c = cont }
        self.eventContinuation = c
    }

    // MARK: - ChatAgent

    func start() async throws {
        // claude --print 是 one-shot,每轮 sendPrompt 才真起子进程。这里只
        // 校验 CLI 装着,提前给用户一个清楚的错误。
        guard ClaudeCodeAgent.claudeBinaryPath != nil else {
            throw SpawnError.notInstalled
        }
    }

    func sendPrompt(_ text: String) throws {
        guard let bin = ClaudeCodeAgent.claudeBinaryPath else {
            throw SpawnError.notInstalled
        }
        // 上一轮可能还在跑(理论上 ChatController 会等结束,但防御一下)。
        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--model", model,
        ]
        if !oneshot, let sid = sessionId {
            args.append(contentsOf: ["-r", sid])
        }
        // ⚠️ prompt 通过 stdin 传,不走 `-p <text>` 的 argv —— 大 prompt
        // (Memory pipeline / 写作采集 OCR 几百 KB)会撞 macOS ARG_MAX(~256KB)。
        // `claude --print` 在没 `-p` 时从 stdin 读 prompt(实测验过)。
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // 注入 cron job 凭证 + 增强 PATH。GUI app 默认 PATH 极窄,claude
        // 内部 spawn node / npm / npx 时会找不到二进制 → 跑起来后秒退。
        // 把常见 dev bin 路径前置(用户实际 binary 所在目录优先级最高)。
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = [
            URL(fileURLWithPath: bin).deletingLastPathComponent().path,  // claude 二进制目录,优先
            AIPaths.binDir.path,  // ~/.portrait/bin —— mp-query wrapper 在这
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.claude/local",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env

        let stdinPipe = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdout
        proc.standardError = stderr

        let cont = eventContinuation
        // 重置本轮收尾闸门(见 endLock 注释),拿到本轮代际号。
        let gen: Int = {
            endLock.lock()
            defer { endLock.unlock() }
            endGeneration += 1
            stdoutEOF = false
            procExited = false
            endFired = false
            return endGeneration
        }()
        // 清上一轮可能残留的半行:防御性 terminate 旧进程后,它的收尾回调被
        // 代际校验丢弃,旧的 flush 不再执行(旧实现 termination 必 flush)——
        // 残尾会黏到本轮第一个 chunk,第一行(常是带 session_id 的
        // system/init)JSON 解析失败被静默丢弃,session 续接就断了。
        bufLock.lock()
        stdoutBuffer.removeAll()
        bufLock.unlock()
        // EOF(空 availableData)时 handler **自我清除** —— 否则 dispatch read
        // source 在 EOF 后以空 data 反复回调,每轮子进程退出都留一个空转烧 CPU
        // 的后台线程,直到下一轮 sendPrompt 替换 Pipe(聊完不动 = 烧数小时)。
        // 不能在 terminationHandler 里清:termination 可能先于尾部数据派发,
        // 提前清会丢回复结尾。EOF 空回调天然在全部数据之后,在这清恰好 ——
        // 也因此由它报「stdout 这一侧收完了」。
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.noteStreamClosed(.stdoutEOF, generation: gen, cont: cont)
                return
            }
            self?.appendStdout(data)
        }
        // stderr 读完就丢,不写盘(防缓冲塞满阻塞子进程)。
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        proc.terminationHandler = { [weak self] p in
            // 子进程退出码 ≠ 0:result 事件正常会带 is_error,这里只记日志兜底。
            if p.terminationStatus != 0 {
                self?.log.warning("claude CLI exited code \(p.terminationStatus, privacy: .public)")
            }
            // 进程结束 = 本轮结束,但 `.agentEnd` 经 noteStreamClosed 闸门:
            // 必须等 stdout EOF —— termination 与 readability 在不同队列,
            // 先后无保证,先发 agentEnd 会丢内核管道里还没投递的回复尾巴。
            // Conversation 还活着(stop 之前 events 流不 finish),下一次
            // sendPrompt 起新进程续上下文。
            self?.noteStreamClosed(.procExited, generation: gen, cont: cont)
        }

        do {
            try proc.run()
        } catch {
            // 直接收尾(进程没跑起来,termination 不会来);标记 endFired
            // 让可能到来的 EOF 回调(管道写端析构触发)不再做任何事。
            endLock.lock()
            endFired = true
            endLock.unlock()
            cont?.yield(.error("Failed to spawn claude: \(error.localizedDescription)"))
            cont?.yield(.agentEnd)
            return
        }
        currentProcess = proc
        cont?.yield(.agentStart)

        // 把 prompt 通过 stdin 喂给 claude --print 然后关掉 stdin(EOF
        // 触发 claude 开始处理)。写大块可能 block,派后台线程做。
        let stdinHandle = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                if let data = text.data(using: .utf8) {
                    try stdinHandle.write(contentsOf: data)
                }
                try stdinHandle.close()
            } catch {
                self?.log.warning("write prompt to stdin failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        forceKillCurrentProcess()
        currentProcess = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func abort() throws {
        forceKillCurrentProcess()
        // 不 finish events 流 —— conversation 还能继续。
    }

    /// 先 SIGTERM 给 2s 优雅退出窗口,还活着就 SIGKILL 强杀。
    /// claude --print 在大 prompt 时对 SIGTERM 响应可能 10s+,timeout 不能等。
    private func forceKillCurrentProcess() {
        guard let proc = currentProcess, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        // 后台 0.05s 心跳,2s 内不退 → SIGKILL。
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if !proc.isRunning { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - 收尾闸门(agentEnd gating)

    private enum EndSignal { case stdoutEOF, procExited }

    /// stdout EOF / 进程退出各报一次;两个都到齐才 flush 残行 + 发 `.agentEnd`。
    /// EOF 回调在 FileHandle 串行队列上天然排在全部数据回调之后,所以此刻
    /// flush 出的只可能是(罕见的)无换行残尾 —— 不会再与 appendStdout 并发
    /// 解析(旧实现 terminationHandler 直接 flush,与 readability 队列并发改
    /// 解析器状态)。
    private func noteStreamClosed(_ signal: EndSignal, generation: Int,
                                  cont: AsyncStream<PiAgent.Event>.Continuation?) {
        endLock.lock()
        guard generation == endGeneration else {   // 上一轮的迟到回调,丢弃
            endLock.unlock()
            return
        }
        switch signal {
        case .stdoutEOF:  stdoutEOF = true
        case .procExited: procExited = true
        }
        let fire = stdoutEOF && procExited && !endFired
        if fire { endFired = true }
        let needFallback = (signal == .procExited) && !fire && !endFired
        endLock.unlock()

        if fire {
            flushStdoutBuffer()
            cont?.yield(.agentEnd)
            return
        }
        if needFallback {
            // 进程已退但 EOF 未到:正常毫秒级就来;2s 还没来说明 read source
            // 异常(handler 被换/挂死),强制收尾,别让聊天永远转圈。
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.endLock.lock()
                let lateFire = generation == self.endGeneration && !self.endFired
                if lateFire { self.endFired = true }
                self.endLock.unlock()
                guard lateFire else { return }
                self.log.warning("stdout EOF never arrived after process exit; forcing agentEnd")
                self.flushStdoutBuffer()
                cont?.yield(.agentEnd)
            }
        }
    }

    // MARK: - stdout buffer + line splitting

    private func appendStdout(_ data: Data) {
        bufLock.lock()
        stdoutBuffer.append(data)
        // 按 \n(0x0A)切行,每行一个 JSON event。
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineRange = stdoutBuffer.startIndex..<nl
            let line = stdoutBuffer.subdata(in: lineRange)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            bufLock.unlock()
            parseLine(line)
            bufLock.lock()
        }
        bufLock.unlock()
    }

    private func flushStdoutBuffer() {
        bufLock.lock()
        let remaining = stdoutBuffer
        stdoutBuffer.removeAll()
        bufLock.unlock()
        if !remaining.isEmpty { parseLine(remaining) }
    }

    private func parseLine(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        process(obj)
    }

    // MARK: - stream-json → PiAgent.Event 映射

    private func process(_ obj: [String: Any]) {
        let cont = eventContinuation
        let type = (obj["type"] as? String) ?? ""
        switch type {
        case "system":
            if !oneshot,
               (obj["subtype"] as? String) == "init",
               let sid = obj["session_id"] as? String {
                // Claude Code 在 context 自动压缩 / 长会话 fork 时偶尔会换
                // sid,所以这里不能只抓第一次,要持续同步给 ChatStore。
                if sid != sessionId {
                    sessionId = sid
                    onSessionId?(sid)
                }
            }
            // 其它 system subtype(status / heartbeat 等)忽略。

        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return }
            let eventType = (event["type"] as? String) ?? ""
            let index = (event["index"] as? Int) ?? 0
            switch eventType {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any] else { return }
                let blockType = (block["type"] as? String) ?? ""
                currentBlockType[index] = blockType
                switch blockType {
                case "thinking":
                    cont?.yield(.thinkingStart)
                case "tool_use":
                    let id = (block["id"] as? String) ?? UUID().uuidString
                    let name = (block["name"] as? String) ?? "tool"
                    toolIdByIndex[index] = id
                    pendingToolInput[id] = ""
                    // 暂不 yield toolStart —— args 还在 input_json_delta 里
                    // 流,空字典发出去 UI 显示不出 bash 命令。等
                    // content_block_stop 时 args 攒全了再一次性 yield。
                    // tool_use 的 name 也记下来,stop 时一起用。
                    pendingToolName[id] = name
                case "text":
                    break  // text 走 delta 累积
                default: break
                }

            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { return }
                let deltaType = (delta["type"] as? String) ?? ""
                switch deltaType {
                case "text_delta":
                    if let s = delta["text"] as? String { cont?.yield(.textDelta(s)) }
                case "thinking_delta":
                    if let s = delta["thinking"] as? String { cont?.yield(.thinkingDelta(s)) }
                case "input_json_delta":
                    if let s = delta["partial_json"] as? String,
                       let toolId = toolIdByIndex[index] {
                        pendingToolInput[toolId, default: ""] += s
                    }
                case "signature_delta":
                    break  // thinking 的签名,不显示
                default: break
                }

            case "content_block_stop":
                if currentBlockType[index] == "thinking" {
                    cont?.yield(.thinkingEnd(finalText: nil, durationMs: nil))
                }
                // tool_use 块结束:input_json_delta 已经流完,从
                // pendingToolInput 里解出完整 args,这时才 yield toolStart。
                // 之前的设计是 start 时空 args + stop 时不更新,导致 UI
                // ToolBlock.command 永远是空,bash 命令完全看不到。
                if currentBlockType[index] == "tool_use",
                   let toolId = toolIdByIndex[index] {
                    let name = pendingToolName[toolId] ?? "tool"
                    let raw = pendingToolInput[toolId] ?? ""
                    var args: [String: Any] = [:]
                    if let data = raw.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        args = parsed
                    }
                    cont?.yield(.toolStart(id: toolId, name: name, args: args))
                    pendingToolInput.removeValue(forKey: toolId)
                    pendingToolName.removeValue(forKey: toolId)
                }
                currentBlockType.removeValue(forKey: index)
                toolIdByIndex.removeValue(forKey: index)

            case "message_start", "message_delta", "message_stop":
                break  // metadata only

            default: break
            }

        case "user":
            // tool_result 走在 user message 的 content 里。
            guard let msg = obj["message"] as? [String: Any],
                  let contents = msg["content"] as? [[String: Any]] else { return }
            for c in contents where (c["type"] as? String) == "tool_result" {
                let toolId = (c["tool_use_id"] as? String) ?? ""
                let isError = (c["is_error"] as? Bool) ?? false
                let resultText: String
                if let s = c["content"] as? String {
                    resultText = s
                } else if let arr = c["content"] as? [[String: Any]] {
                    resultText = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    resultText = ""
                }
                cont?.yield(.toolEnd(id: toolId, result: resultText, isError: isError))
                pendingToolInput.removeValue(forKey: toolId)
            }

        case "result":
            // 本轮总结。result 字段是 assistant 最终回复全文。
            if (obj["is_error"] as? Bool) == true {
                let msg = (obj["api_error_status"] as? String)
                    ?? (obj["result"] as? String)
                    ?? "Claude Code error"
                cont?.yield(.error(msg))
            } else if let finalText = obj["result"] as? String, !finalText.isEmpty {
                // 不发 assistantFinalText —— 已经走 text_delta 累积过了,再发会重复。
                // 留个 noop。
                _ = finalText
            }
            if let usage = obj["usage"] as? [String: Any] {
                let inT = (usage["input_tokens"] as? Int) ?? 0
                let outT = (usage["output_tokens"] as? Int) ?? 0
                cont?.yield(.usage(input: inT, output: outT))
            }

        default:
            // rate_limit_event 等 — 信息性,忽略。
            break
        }
    }

    // MARK: - 错误类型

    enum SpawnError: LocalizedError {
        case notInstalled
        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Claude Code CLI(`claude`)not found. Install with `brew install claude` (or check ~/.local/bin)."
            }
        }
    }

    // MARK: - 静态:CLI 探测

    /// `claude` 二进制路径,找不到返回 nil。
    ///
    /// 探测顺序:
    ///   1. 直接 stat 一组常见安装路径(Claude 官方 install script /
    ///      brew / npm global / bun / 用户自定义 ~/.local/bin)
    ///   2. 用户的登录 shell 跑 `command -v claude` —— GUI app 启动的
    ///      subprocess 默认 PATH 是 `/usr/bin:/bin:/usr/sbin:/sbin`,
    ///      不含 ~/.local/bin / /opt/homebrew/bin / npm-global 等,直接
    ///      `which claude` 会假阴。走登录 shell 才能拿到用户实际 PATH。
    ///
    /// 缓存策略:**成功路径**进程内只探测一次;**失败**带 5 分钟冷却后重探
    /// —— 失败不能永久缓存:用户装好 claude / 修好 PATH 后,cron job 的
    /// `guard isInstalled` 会静默 return(不留 conv 不留 run 记录),nil 黏到
    /// 进程退出等于 cron 无痕消失。冷却避免未装用户每次 send 都付 shell 探测。
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probedPath: String?
    nonisolated(unsafe) private static var lastFailedProbeAt: Date?

    static var claudeBinaryPath: String? {
        probeLock.lock()
        if let hit = probedPath {
            probeLock.unlock()
            return hit
        }
        if let failedAt = lastFailedProbeAt, Date().timeIntervalSince(failedAt) < 300 {
            probeLock.unlock()
            return nil
        }
        probeLock.unlock()
        let resolved = Self.probeBinaryPath()
        probeLock.lock()
        if let resolved {
            probedPath = resolved
            lastFailedProbeAt = nil
        } else {
            lastFailedProbeAt = Date()
        }
        probeLock.unlock()
        return resolved
    }

    private static func probeBinaryPath() -> String? {
        let fm = FileManager.default
        // 0. 终极兜底:用户在 ~/.portrait/config.toml 没办法表达完整路径
        // 时,用 env var MYPORTRAIT_CLAUDE_PATH 显式指定。能解奇葩装的
        // (nix / asdf / mise / 自编译)路径问题。
        if let override = ProcessInfo.processInfo.environment["MYPORTRAIT_CLAUDE_PATH"],
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            // Claude 官方 install script 默认路径(curl claude.ai/install.sh | bash)
            "\(home)/.claude/local/claude",
            // brew Apple Silicon / Intel
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            // 用户自己手动放的
            "\(home)/.local/bin/claude",
            // npm global(默认 / npm config set prefix=~/.npm-global)
            "\(home)/.npm-global/bin/claude",
            "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude",
            // bun global
            "\(home)/.bun/bin/claude",
        ]
        for p in candidates where fm.isExecutableFile(atPath: p) {
            return p
        }

        // 兜底 1:login shell(`-l -c`,加载 ~/.zprofile 等)解析 PATH,快。
        if let p = shellProbe(interactive: false) { return p }
        // 兜底 2:交互式 shell(`-l -i -c`,加载 ~/.zshrc / ~/.bashrc)。
        // nvm / asdf / mise / volta 的标准安装把 PATH 注入写在交互式 rc 里,
        // login shell 读不到 —— 这类用户的 claude 在 ~/.nvm/versions/.../bin
        // 下,只有 -i 能找到。可能几百 ms~秒级,但只在前面全部未命中(本来
        // 就要报"未安装")时才付这一次。
        return shellProbe(interactive: true)
    }

    /// 让用户的 shell 替我们解析 PATH 并 `command -v claude`。GUI app 子进程
    /// 的 PATH 是 `/usr/bin:/bin:...`,不含 dotfile 加的 dev bin 路径。
    private static func shellProbe(interactive: Bool) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.launchPath = shell
        proc.arguments = (interactive ? ["-l", "-i", "-c"] : ["-l", "-c"]) + ["command -v claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch { }
        return nil
    }

    static var isInstalled: Bool { claudeBinaryPath != nil }

    // MARK: - 真连通性测试

    enum ProbeError: LocalizedError {
        case notInstalled
        case timeout
        case cliError(String)
        case noReply
        var errorDescription: String? {
            switch self {
            case .notInstalled:    return "Claude Code CLI (`claude`) not found. Install with `brew install claude` or run the official install script."
            case .timeout:         return "Claude Code didn't respond in 30 seconds. Make sure you've run `claude login` in Terminal."
            case .cliError(let m): return "Claude Code CLI error: \(m)"
            case .noReply:         return "Claude Code exited without a reply. Try `claude --print hi` in Terminal to debug."
            }
        }
    }

    /// 真连通性测试:spawn claude + 发 "hi" + 等回复。
    ///   - 收到 textDelta / assistantFinalText / agentEnd(带过文本)→ true
    ///   - 30s 超时 / 进程报错 / 退出无回复 → throws
    /// 用在 Connections 页 Connect 按钮 —— 仅"binary 存在"不够,可能用户没
    /// `claude login`,登录态过期,模型 API 挂等。真发一句话才知道能不能用。
    @MainActor
    static func probeConnection() async throws -> Bool {
        guard isInstalled else { throw ProbeError.notInstalled }
        let agent = ClaudeCodeAgent(model: "haiku", oneshot: true)
        try await agent.start()
        try agent.sendPrompt("hi")

        do {
            let result = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { @Sendable in
                    var sawText = false
                    for await event in agent.events {
                        switch event {
                        case .textDelta(let s) where !s.isEmpty:           sawText = true
                        case .assistantFinalText(let s) where !s.isEmpty:  sawText = true
                        case .error(let msg):
                            throw ProbeError.cliError(msg)
                        case .agentEnd:
                            if sawText { return true }
                            throw ProbeError.noReply
                        default: continue
                        }
                    }
                    if sawText { return true }
                    throw ProbeError.noReply
                }
                group.addTask { @Sendable in
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw ProbeError.timeout
                }
                let r = try await group.next()!
                group.cancelAll()
                return r
            }
            agent.stop()
            return result
        } catch {
            agent.stop()
            throw error
        }
    }
}
