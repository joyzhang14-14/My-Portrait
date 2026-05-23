import Foundation

/// Background executor for pipes. Each fire:
///   1. Builds the screen context (if pipe.window != .none)
///   2. Creates a brand-new conversation in ChatStore titled after the pipe
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

    static func run(_ pipe: CronJob) {
        Task { await execute(pipe) }
    }

    /// Resolve a pipe's attached connections into environment variables that
    /// get injected into the spawned agent process — mirrors screenpipe's
    /// per-pipe `cmd.env(...)` credential injection.
    private static func connectionEnv(for pipe: CronJob) -> [String: String] {
        var env: [String: String] = [:]
        for id in pipe.connections {
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

    private static func execute(_ pipe: CronJob) async {
        guard AISetup.shared.isReady else { return }

        let startedAt = Date()

        // 1. Build context.
        let context: TimelineContext
        if let chip = pipe.window.resolveChip() {
            context = await Task.detached(priority: .userInitiated) {
                TimelineContextBuilder.build(chips: [chip])
            }.value
        } else {
            context = .empty
        }

        // 2. New conv in the store, titled after pipe + timestamp.
        let store = ChatStore.shared
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "HH:mm"
        let conv = store.createConversation(
            title: "🛰️ \(pipe.name) · \(stampFmt.string(from: startedAt))"
        )

        // 3. Persist user message + spawn one-shot agent.
        let userMsg = ChatMessage(role: .user, text: pipe.prompt, time: startedAt)
        var assistantBuf = ""
        var parts: [ContentPart] = []
        let assistantId = UUID()

        let (provider, model, refOverride) = providerResolver()
        do {
            let agent = try PiAgent(provider: provider, model: model,
                                    apiKeyRefOverride: refOverride,
                                    extraEnv: connectionEnv(for: pipe))
            try await agent.start()
            let pasted = context.markdown.isEmpty
                ? pipe.prompt
                : "\(context.markdown)\n\nUser question:\n\(pipe.prompt)"
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

        // 4. Record run on the pipe.
        let preview = String(assistantBuf.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
        let run = CronJobRun(convId: conv.id, startedAt: startedAt, preview: preview)
        CronJobStore.shared.appendRun(run, to: pipe.id)

        // 5. Notify (respects notifications.cronJobAlerts + mutedCronJobs).
        NotificationCenterService.shared.post(
            .pipeRun(pipeName: pipe.name, preview: preview)
        )
    }
}
