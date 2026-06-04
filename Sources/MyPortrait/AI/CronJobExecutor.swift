import Foundation

/// Background executor for cronJobs. Each fire:
///   1. Builds the screen context (if cronJob.window != .none)
///   2. Creates a brand-new conversation in ChatStore titled after the cron job
///   3. Spawns a one-shot PiAgent, sends prompt+context, accumulates text
///   4. Persists the assistant reply into the conv + appends a CronJobRun
///      with a 120-char preview pointing at the conv
///
/// Doesn't reuse the live ChatController so user's open chat is undisturbed.
@MainActor
enum CronJobExecutor {
    /// Override at boot — supplies the same provider+model as the chat.
    static var providerResolver: () -> (Provider, String, String?) = {
        (.chatgpt, Provider.chatgpt.defaultModel, nil)
    }

    /// Override at boot(ContentView)。cron 每次把流式增量落盘后调一次,
    /// 让正在前端查看这条 conv 的 ChatController live 重读 —— 否则用户点进
    /// 正在跑的 cron conv 只看到点进去那一刻的快照(永远卡在 Thinking)。
    static var onConvUpdated: (UUID) -> Void = { _ in }

    static func run(_ cronJob: CronJob) {
        Task { await execute(cronJob) }
    }

    /// Resolve a cronJob's attached connections into environment variables that
    /// get injected into the spawned agent process — mirrors screenpipe's
    /// per-cron-job `cmd.env(...)` credential injection.
    private static func connectionEnv(for cronJob: CronJob) -> [String: String] {
        var env: [String: String] = [:]
        for id in cronJob.connections {
            switch id {
            case "email-smtp":
                if let creds: SMTPCredentials = SecretStore.shared.getJSON(
                        SMTPCredentials.ref(for: id), as: SMTPCredentials.self) {
                    env["SMTP_HOST"] = creds.host
                    env["SMTP_PORT"] = creds.port
                    env["SMTP_USER"] = creds.username
                    env["SMTP_PASS"] = creds.password
                }
            case "obsidian":
                if let path = ObsidianConfig.vaultPath {
                    env["OBSIDIAN_VAULT_PATH"] = path
                }
            default:
                break
            }
        }
        return env
    }

    private static func execute(_ cronJob: CronJob) async {
        let (provider, _, _) = providerResolver()
        // Claude Code 不走 Pi,只要 CLI 装着就行;其它 provider 需要 Bun/Pi 装好。
        switch provider {
        case .claudeCode:
            guard ClaudeCodeAgent.isInstalled else { return }
        default:
            guard AISetup.shared.isReady else { return }
        }

        let startedAt = Date()

        // 1. Build context.
        let context: TimelineContext
        if let chip = cronJob.window.resolveChip() {
            context = await Task.detached(priority: .userInitiated) {
                TimelineContextBuilder.build(chips: [chip])
            }.value
        } else {
            context = .empty
        }

        // 2. New conv in the store, titled after cronJob + timestamp.
        let store = ChatStore.shared
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "HH:mm"
        let conv = store.createConversation(
            title: "🛰️ \(cronJob.name) · \(stampFmt.string(from: startedAt))"
        )

        // **必须立刻 appendRun**(LLM 跑完才登记的话,跑的几分钟里这条 conv
        // 会出现在 sidebar RECENTS 区 —— TimelineSidebar 反查 cronJobConvIds
        // 判定是不是 cron run)。LLM 失败 / app 中途退出也保证不会变成幽灵
        // RECENTS 项。preview 留空,跑完用 updateRunPreview 补。
        let runPlaceholder = CronJobRun(convId: conv.id, startedAt: startedAt, preview: "")
        CronJobStore.shared.appendRun(runPlaceholder, to: cronJob.id)

        // 3. Persist user message **right now** so user can open the conv
        //    while it's still running and see at least the prompt. 之前
        //    一直等到 LLM 全跑完才 save,过程中点进去看到的是空 conv,
        //    用户体验跟普通 chat 完全不对齐。
        let userMsg = ChatMessage(role: .user, text: cronJob.prompt, time: startedAt)
        let assistantId = UUID()
        var assistant = ChatMessage(
            id: assistantId, role: .assistant, text: "",
            parts: [], time: Date()
        )
        store.saveMessages([userMsg, assistant], for: conv.id)

        // 流式增量状态。所有 event 走同一个 mutate → persist 路径。
        var pendingText = ""
        var activeTextPartId: UUID? = nil
        var lastPersist = Date.distantPast
        let persistThrottle: TimeInterval = 0.35   // ~3 fps,够看见 thinking 字往外蹦

        func flushPending() {
            guard !pendingText.isEmpty else { return }
            if let id = activeTextPartId, let idx = assistant.parts.firstIndex(where: { p in
                if case .text(let pid, _) = p, pid == id { return true }
                return false
            }), case .text(let pid, let cur) = assistant.parts[idx] {
                assistant.parts[idx] = .text(id: pid, value: cur + pendingText)
            } else {
                let newId = UUID()
                activeTextPartId = newId
                assistant.parts.append(.text(id: newId, value: pendingText))
            }
            assistant.text += pendingText
            pendingText = ""
        }

        func persistNow(_ force: Bool = false) {
            let now = Date()
            if !force, now.timeIntervalSince(lastPersist) < persistThrottle { return }
            lastPersist = now
            store.saveMessages([userMsg, assistant], for: conv.id)
            // 通知前端:若正在看这条 conv,live 重读(像普通 chat 一样逐段刷)。
            Self.onConvUpdated(conv.id)
        }

        let (_, model, refOverride) = providerResolver()
        let envInjection = connectionEnv(for: cronJob)
        do {
            let agent: any ChatAgent
            switch provider {
            case .claudeCode:
                // claude --print 一次跑就退,本身就是 oneshot,不需要复用
                // session(也 oneshot=true 关续接,避免上轮污染下轮)。
                agent = ClaudeCodeAgent(model: model, oneshot: true, extraEnv: envInjection)
            default:
                agent = try PiAgent(provider: provider, model: model,
                                    apiKeyRefOverride: refOverride,
                                    extraEnv: envInjection)
            }
            try await agent.start()
            // 跟 ChatController.send 一致,首条 user message 前注入两个
            // SKILL preamble — cron agent 也需要知道 mp-query / mp-folders
            // 子命令存在,否则它只能用注入的固定时间窗,没法跨日/跨模态查
            // (e.g. mp-query memories --scope portrait / mp-query writing)。
            // 之前没注入是 cron 路径"惊艳感缺失"的主要原因之一。
            let skillPreamble = "\(MPQuerySkill.preamble)\n\n\(FoldersSkill.preamble)\n\n"
            let body = context.markdown.isEmpty
                ? cronJob.prompt
                : "\(context.markdown)\n\nUser question:\n\(cronJob.prompt)"
            let pasted = skillPreamble + body
            try agent.sendPrompt(pasted)

            // 跟普通 chat 一样接所有事件:text / tool / thinking / error。
            iter: for await event in agent.events {
                switch event {
                case .textDelta(let d):
                    pendingText += d
                    flushPending()
                    persistNow()

                case .assistantFinalText(let t):
                    if assistant.text.isEmpty {
                        pendingText += t
                        flushPending()
                        persistNow(true)
                    }

                case .toolStart(let id, let name, let args):
                    // text → tool → text 顺序:先把累积的文本落进上一段。
                    flushPending()
                    activeTextPartId = nil
                    let cmd = (args["command"] as? String)
                        ?? args.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                    let block = ToolBlock(
                        id: UUID(), toolCallId: id, name: name,
                        command: cmd, output: "",
                        isRunning: true, isError: false
                    )
                    assistant.parts.append(.tool(block))
                    persistNow(true)

                case .toolEnd(let id, let result, let isError):
                    if let idx = assistant.parts.firstIndex(where: { p in
                        if case .tool(let b) = p, b.toolCallId == id { return true }
                        return false
                    }), case .tool(var b) = assistant.parts[idx] {
                        b.output = result
                        b.isError = isError
                        b.isRunning = false
                        assistant.parts[idx] = .tool(b)
                    }
                    persistNow(true)

                case .thinkingStart:
                    flushPending()
                    activeTextPartId = nil
                    assistant.parts.append(.thinking(
                        ThinkingBlock(id: UUID(), text: "", isRunning: true, durationMs: nil)
                    ))
                    persistNow(true)

                case .thinkingDelta(let delta):
                    if let idx = assistant.parts.lastIndex(where: { p in
                        if case .thinking = p { return true } else { return false }
                    }), case .thinking(var b) = assistant.parts[idx] {
                        b.text += delta
                        assistant.parts[idx] = .thinking(b)
                    }
                    persistNow()

                case .thinkingEnd(let finalText, let durationMs):
                    if let idx = assistant.parts.lastIndex(where: { p in
                        if case .thinking = p { return true } else { return false }
                    }), case .thinking(var b) = assistant.parts[idx] {
                        if let finalText, !finalText.isEmpty, b.text.isEmpty {
                            b.text = finalText
                        }
                        b.isRunning = false
                        b.durationMs = durationMs
                        assistant.parts[idx] = .thinking(b)
                    }
                    persistNow(true)

                case .agentEnd:
                    flushPending()
                    break iter

                case .error(let m):
                    flushPending()
                    pendingText += "\n\n⚠️ \(m)"
                    flushPending()
                    break iter

                default: break
                }
            }
            agent.stop()
        } catch {
            pendingText += "⚠️ CronJob couldn't start: \(error.localizedDescription)"
            flushPending()
        }

        // 终态落盘(防 throttle 把最后一波 delta 丢了)。
        flushPending()
        // 把所有还卡在 running 的 thinking / tool block 强制 close ——
        // agent 在 .agentEnd 之前偶尔会漏发对应的 .thinkingEnd / .toolEnd
        // (Pi context 压缩、Claude 最后块直接 final 等场景),否则前端永远
        // 停在 "Thinking…" / "Running…" 转圈,即使通知都发出来了。
        for i in assistant.parts.indices {
            switch assistant.parts[i] {
            case .thinking(var b) where b.isRunning:
                b.isRunning = false
                assistant.parts[i] = .thinking(b)
            case .tool(var b) where b.isRunning:
                b.isRunning = false
                assistant.parts[i] = .tool(b)
            default: break
            }
        }
        persistNow(true)

        // 4. LLM 跑完了 —— 用真 preview 更新已有 run(占位 run 在 step 2 已建好)。
        let preview = String(assistant.text.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
        CronJobStore.shared.updateRunPreview(convId: conv.id, preview: preview)

        // 5. 通知:只发 LLM 在回复末尾显式写出的 `### Notify` 区块内容。
        //    没写就不打扰用户(LLM 自己判断"这次没什么值得通知的事")。
        if let body = Self.extractNotifyBody(from: assistant.text) {
            NotificationCenterService.shared.post(
                .cronJobRun(jobId: cronJob.id, jobName: cronJob.name, body: body, convId: conv.id)
            )
        }
    }

    /// 抓回复里最后一个 `### Notify` **区块标题(行首 markdown heading)** 之后
    /// 到结尾的文本。返回 nil = LLM 没写真正的区块 → 跳过通知。
    ///
    /// ⚠️ 必须限定**行首 heading**,不能裸 `range(of: "### Notify")`:LLM 解释
    /// 自己"这次不追加 ### Notify"时,那句话里**字面含** `### Notify`,旧逻辑会
    /// 把那句尾巴(一个句号/空白)当通知内容发出去 → 空/乱码通知。再要求提取出
    /// 的 body 含**实质字符**(字母/数字/CJK),只剩标点空白也不发。
    static func extractNotifyBody(from buf: String) -> String? {
        // (?m)^ 行首(可有缩进)+ 2~6 个 # + Notify 词界 + 可选冒号。
        let pattern = "(?m)^[ \\t]*#{2,6}[ \\t]*Notify\\b[ \\t]*:?[ \\t]*"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let ns = buf as NSString
        let matches = re.matches(in: buf, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        let tail = ns.substring(from: last.range.location + last.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 实质内容:至少一个字母/数字(Character.isLetter 含 CJK)。否则是空通知,不发。
        guard tail.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return tail
    }
}
