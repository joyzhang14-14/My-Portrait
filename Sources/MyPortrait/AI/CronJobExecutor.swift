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
        guard AISetup.shared.isReady else { return }

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

        // 3. Persist user message + spawn one-shot agent.
        let userMsg = ChatMessage(role: .user, text: cronJob.prompt, time: startedAt)
        var assistantBuf = ""
        var parts: [ContentPart] = []
        let assistantId = UUID()

        let (provider, model, refOverride) = providerResolver()
        do {
            let agent = try PiAgent(provider: provider, model: model,
                                    apiKeyRefOverride: refOverride,
                                    extraEnv: connectionEnv(for: cronJob))
            try await agent.start()
            let pasted = context.markdown.isEmpty
                ? cronJob.prompt
                : "\(context.markdown)\n\nUser question:\n\(cronJob.prompt)"
            try agent.sendPrompt(pasted)

            iter: for await event in agent.events {
                switch event {
                case .textDelta(let d):            assistantBuf += d
                case .assistantFinalText(let t):   if assistantBuf.isEmpty { assistantBuf = t }
                case .agentEnd:                    break iter
                case .error(let m):
                    assistantBuf += "\n\n⚠️ \(m)"
                    break iter
                default: break
                }
            }
            agent.stop()
        } catch {
            assistantBuf = "⚠️ CronJob couldn't start: \(error.localizedDescription)"
        }

        parts.append(.text(id: UUID(), value: assistantBuf))
        let assistantMsg = ChatMessage(
            id: assistantId, role: .assistant,
            text: assistantBuf, parts: parts, time: Date()
        )

        store.saveMessages([userMsg, assistantMsg], for: conv.id)

        // 4. Record run on the cron job.
        let preview = String(assistantBuf.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
        let run = CronJobRun(convId: conv.id, startedAt: startedAt, preview: preview)
        CronJobStore.shared.appendRun(run, to: cronJob.id)

        // 5. 通知:只发 LLM 在回复末尾显式写出的 `### Notify` 区块内容。
        //    没写就不打扰用户(LLM 自己判断"这次没什么值得通知的事")。
        if let body = Self.extractNotifyBody(from: assistantBuf) {
            NotificationCenterService.shared.post(
                .cronJobRun(jobName: cronJob.name, body: body, convId: conv.id)
            )
        }
    }

    /// 抓回复里最后一个 `### Notify` 区块之后到结尾的文本。容忍大小写差异
    /// 和首尾空白。返回 nil = LLM 没写 → 跳过通知。
    static func extractNotifyBody(from buf: String) -> String? {
        guard let range = buf.range(of: "### Notify",
                                    options: [.caseInsensitive, .backwards])
        else { return nil }
        let tail = buf[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}
