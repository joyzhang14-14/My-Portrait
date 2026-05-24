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
    private var sessionId: String?

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

    private var eventContinuation: AsyncStream<PiAgent.Event>.Continuation?
    let events: AsyncStream<PiAgent.Event>

    /// Cron job 等场景注入的额外环境变量(SMTP_*, OBSIDIAN_VAULT_PATH …),
    /// 跟 PiAgent.extraEnv 等价。空 = 走继承的 ProcessInfo 环境。
    private let extraEnv: [String: String]

    init(model: String, oneshot: Bool = false, extraEnv: [String: String] = [:]) {
        self.model = model.isEmpty ? "sonnet" : model
        self.oneshot = oneshot
        self.extraEnv = extraEnv
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
        args.append(contentsOf: ["-p", text])
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // 注入 cron job 的 connection 凭证(SMTP_*, OBSIDIAN_VAULT_PATH …),
        // 跟 PiAgent.start 那侧对齐。空 extraEnv = 不改环境,继承 parent。
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let cont = eventContinuation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.appendStdout(data)
        }
        // stderr 读完就丢,不写盘(防缓冲塞满阻塞子进程)。
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] p in
            self?.flushStdoutBuffer()
            // 进程结束 = 本轮结束。Conversation 还活着(stop 之前 events 流
            // 不 finish),下一次 sendPrompt 起新进程续上下文。
            cont?.yield(.agentEnd)
            // 子进程退出码 ≠ 0 且没在 result 里报错过 → 主动发个 error。
            // result 事件正常会带 is_error,这里兜底。
            if p.terminationStatus != 0 {
                self?.log.warning("claude CLI exited code \(p.terminationStatus, privacy: .public)")
            }
        }

        do {
            try proc.run()
        } catch {
            cont?.yield(.error("Failed to spawn claude: \(error.localizedDescription)"))
            cont?.yield(.agentEnd)
            return
        }
        currentProcess = proc
        cont?.yield(.agentStart)
    }

    func stop() {
        currentProcess?.terminate()
        currentProcess = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func abort() throws {
        currentProcess?.terminate()
        // 不 finish events 流 —— conversation 还能继续。
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
                sessionId = sid
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

    /// `claude` 二进制路径,找不到返回 nil。优先常见 brew / 用户 bin 路径,
    /// 都失败则走 `which claude` 兜底。
    static var claudeBinaryPath: String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        let fm = FileManager.default
        for p in candidates where fm.isExecutableFile(atPath: p) {
            return p
        }
        // PATH 兜底
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = ["which", "claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        } catch { }
        return nil
    }

    static var isInstalled: Bool { claudeBinaryPath != nil }
}
