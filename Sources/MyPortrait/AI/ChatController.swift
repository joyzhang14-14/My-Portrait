import Foundation
import Observation

/// One-conversation chat session. Owns a `PiAgent` for the lifetime of the
/// conversation, appends/streams into `messages`, and exposes a single
/// `send(_:)` entrypoint the UI wires to its input bar.
///
/// This is a deliberately small surface so we can iterate the wire-up
/// without touching HomeView every time.
@MainActor
@Observable
final class ChatController {
    var messages: [ChatMessage] = []
    var isStreaming: Bool = false
    var lastError: String? = nil
    /// Lookup so the user bubble can render its chips. Keyed by message id.
    /// Not persisted; chips are an ephemeral UI artefact of the send action.
    var contextChipsByMessage: [UUID: [ContextChip]] = [:]
    /// Cumulative token usage per conversation. Updated on every turn that
    /// Pi reports usage for (and best-effort estimated otherwise).
    var tokenUsageByConv: [UUID: (input: Int, output: Int)] = [:]

    /// Currently displayed conversation id. `nil` means "no conv yet" — a
    /// new one is created lazily on the first `send`.
    private(set) var currentConvId: UUID? = nil

    private var agent: PiAgent?
    /// What provider+model the live agent was spawned for. Used to detect
    /// a mid-session change so we can kill and re-spawn on the next send.
    private var agentSpec: (Provider, String)? = nil
    private var assistantMessageID: UUID? = nil
    /// id of the trailing `.text` ContentPart that text_delta events should
    /// accumulate into. Reset every time a tool block lands.
    private var activeTextPartID: UUID? = nil
    /// Pending tokens, drained every `streamFlushInterval` to coalesce many
    /// per-token mutations into one SwiftUI invalidation per frame.
    private var pendingDelta: String = ""
    private var flushTask: Task<Void, Never>? = nil
    /// ~30 fps — fast enough to feel live, slow enough that material-backed
    /// bubbles don't melt the GPU.
    private let streamFlushInterval: UInt64 = 33_000_000  // ns
    /// Set during `send` so we know whether the upcoming user message is
    /// the first one (⇒ derive the conv title from it).
    private var pendingTitleFromFirstMessage: Bool = false

    private let store = ChatStore.shared
    /// Closure resolving the currently-selected provider + model + optional
    /// SecretStore key reference for that preset's API key (when the user
    /// has marked an AI preset as default). When ref is nil, ProviderAuth
    /// falls back to the standard per-provider keychain key.
    var providerResolver: () -> (Provider, String, String?) = {
        (.chatgpt, Provider.chatgpt.defaultModel, nil)
    }

    init() {}

    // MARK: - Conversation switching

    /// Re-run the user message immediately preceding `assistantMessageId`.
    /// The old assistant message + anything after it is dropped.
    func regenerate(_ assistantMessageId: UUID) {
        guard let aIdx = messages.firstIndex(where: { $0.id == assistantMessageId }),
              messages[aIdx].role == .assistant,
              let uIdx = (0..<aIdx).reversed().first(where: { messages[$0].role == .user })
        else { return }
        let userText = messages[uIdx].text
        let chips = contextChipsByMessage[messages[uIdx].id] ?? []

        // Drop the user msg + everything after (we'll re-add via send()).
        let removed = messages[uIdx...].map { $0.id }
        removed.forEach { contextChipsByMessage.removeValue(forKey: $0) }
        messages.removeSubrange(uIdx...)

        // Tearing down the agent forces a fresh conversation on Pi's side —
        // otherwise Pi has its own memory of the dropped turn.
        agent?.stop()
        agent = nil
        send(userText, chips: chips)
    }

    /// Rewrite a previous user message and re-run. Drops every message at or
    /// after its index, then re-sends with `newText`.
    func editAndResend(_ messageId: UUID, newText: String) {
        guard let uIdx = messages.firstIndex(where: { $0.id == messageId }),
              messages[uIdx].role == .user else { return }
        let chips = contextChipsByMessage[messageId] ?? []
        let removed = messages[uIdx...].map { $0.id }
        removed.forEach { contextChipsByMessage.removeValue(forKey: $0) }
        messages.removeSubrange(uIdx...)

        agent?.stop()
        agent = nil
        send(newText, chips: chips)
    }

    /// Abort the current streaming response. Pi keeps the conversation alive
    /// so the next prompt still works.
    func abort() {
        try? agent?.abort()
        flushPending()
        isStreaming = false
        assistantMessageID = nil
        activeTextPartID = nil
        persist()
    }

    /// Drop the live Pi agent and load `convId`'s messages from disk.
    /// Use `nil` to clear the view (e.g. when "New chat" is pressed).
    func switchTo(_ convId: UUID?) {
        agent?.stop()
        agent = nil
        assistantMessageID = nil
        activeTextPartID = nil
        isStreaming = false
        lastError = nil
        currentConvId = convId
        if let convId {
            messages = store.loadMessages(for: convId)
        } else {
            messages = []
        }
    }

    /// Start a fresh conversation row in the store. Returns the new id so the
    /// sidebar can select it.
    @discardableResult
    func newConversation() -> UUID {
        let conv = store.createConversation()
        switchTo(conv.id)
        return conv.id
    }

    /// Send a user prompt with optional timeline context chips. Each chip
    /// is resolved into an OCR block that is prepended (as a `[Screen context]`
    /// section) to the actual text sent to Pi. The user bubble visually
    /// shows the chips so the user can verify what was injected.
    /// Lookup so the user bubble can render attachments. Not persisted.
    var attachmentsByMessage: [UUID: [Attachment]] = [:]
    /// Sources the AI may reference via `[1]`, `[2]` etc. Keyed by the
    /// assistant message id. Populated when the user sends with chips.
    var citationsByMessage: [UUID: [Citation]] = [:]
    /// Pending citations to attach to the next assistant placeholder.
    private var pendingCitations: [Citation] = []

    func send(_ text: String, chips: [ContextChip] = [], attachments: [Attachment] = [], redactPII: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard AISetup.shared.isReady else {
            lastError = "Setup not finished — Bun/Pi still installing."
            return
        }
        guard ChatGPTOAuth.isLoggedIn() else {
            lastError = "Sign in to ChatGPT from Connections first."
            return
        }

        if currentConvId == nil {
            _ = newConversation()
            pendingTitleFromFirstMessage = true
        } else if messages.isEmpty {
            pendingTitleFromFirstMessage = true
        }

        // Resolve chips → context block (heavy: SQLite read). Do it on a
        // background hop and then deliver from the main actor.
        Task { [weak self] in
            guard let self else { return }
            let context: TimelineContext = await Task.detached(priority: .userInitiated) {
                TimelineContextBuilder.build(chips: chips, redactPII: redactPII)
            }.value

            await MainActor.run {
                // User bubble carries display text + chips + attachments
                // for visual receipt.
                var msg = ChatMessage(role: .user, text: trimmed, time: Date())
                if !chips.isEmpty {
                    msg.parts = [.text(id: UUID(), value: trimmed)]
                }
                self.messages.append(msg)
                self.contextChipsByMessage[msg.id] = chips
                self.attachmentsByMessage[msg.id] = attachments
                self.pendingCitations = context.citations
                self.lastError = nil

                if self.pendingTitleFromFirstMessage, let convId = self.currentConvId {
                    self.store.renameConversation(convId, to: Self.titleFromText(trimmed))
                    self.pendingTitleFromFirstMessage = false
                }

                // What Pi actually sees: context block ++ attachment refs ++ user question.
                var sections: [String] = []
                if !context.markdown.isEmpty { sections.append(context.markdown) }
                if !attachments.isEmpty {
                    let lines = attachments.map { a in
                        "- \(a.kind == .image ? "image" : "file"): `\(a.promptPath)`"
                    }
                    sections.append("[User attached files — use your read / bash tools to inspect them]\n" + lines.joined(separator: "\n"))
                }
                sections.append(sections.isEmpty ? trimmed : "User question:\n\(trimmed)")
                let pasted = sections.joined(separator: "\n\n")
                Task { await self.deliver(pasted) }
            }
        }
    }

    private static func titleFromText(_ s: String) -> String {
        let oneLine = s
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 40 ? String(oneLine.prefix(40)) + "…" : oneLine
    }

    /// Tear down the Pi process when the user closes the conversation.
    func close() {
        agent?.stop()
        agent = nil
    }

    // MARK: - Internals

    private func deliver(_ text: String) async {
        do {
            try await ensureAgent()
            try agent?.sendPrompt(text)
            isStreaming = true
            // Prepare an empty assistant bubble we'll stream parts into.
            let placeholder = ChatMessage(role: .assistant, text: "", parts: [], time: Date())
            messages.append(placeholder)
            assistantMessageID = placeholder.id
            activeTextPartID = nil
            // Attach any citations seeded by the last `send(chips:)` call so
            // the assistant bubble can render its footnote footer.
            if !pendingCitations.isEmpty {
                citationsByMessage[placeholder.id] = pendingCitations
                pendingCitations = []
            }
        } catch {
            lastError = error.localizedDescription
            isStreaming = false
        }
    }

    private func ensureAgent() async throws {
        let (provider, model, apiKeyRef) = providerResolver()
        // If the live agent's provider/model no longer matches what the user
        // picked, tear it down so the new pick takes effect.
        if let agent, let spec = agentSpec, (spec.0 != provider || spec.1 != model) {
            agent.stop()
            self.agent = nil
            self.agentSpec = nil
        }
        if agent != nil { return }
        let a = try PiAgent(provider: provider, model: model, apiKeyRefOverride: apiKeyRef)
        try await a.start()
        agent = a
        agentSpec = (provider, model)
        // Spawn a long-lived consumer for this agent's event stream.
        Task { [weak self] in
            guard let stream = self?.agent?.events else { return }
            for await event in stream { await self?.handle(event) }
        }
    }

    private func handle(_ event: PiAgent.Event) async {
        switch event {
        case .textDelta(let delta):
            // Buffer the delta; a single flush task drains the buffer at
            // streamFlushInterval to coalesce N per-token writes into one
            // mutation per frame.
            pendingDelta += delta
            scheduleFlush()
        case .assistantFinalText(let text):
            // Fallback: only used when no streaming happened.
            flushPending()
            if currentTextLength() == 0 { appendText(text) }
        case .agentEnd:
            flushPending()
            isStreaming = false
            assistantMessageID = nil
            activeTextPartID = nil
            persist()
        case .error(let msg):
            flushPending()
            lastError = msg
            appendErrorBlock(msg)
            isStreaming = false
            persist()
        case .toolStart(let id, let name, let args):
            // Make sure any pending text lands BEFORE the tool block so order
            // stays correct (text → tool → text).
            flushPending()
            startTool(callId: id, name: name, args: args)
        case .toolEnd(let id, let result, let isError):
            finishTool(callId: id, result: result, isError: isError)
        case .thinkingStart:
            flushPending()
            startThinking()
        case .thinkingDelta(let delta):
            appendThinking(delta)
        case .thinkingEnd(let finalText, let durationMs):
            finishThinking(finalText: finalText, durationMs: durationMs)
        case .usage(let input, let output):
            addUsage(input: input, output: output)
        default:
            break
        }
    }

    // MARK: - Token usage

    private func addUsage(input: Int, output: Int) {
        guard let convId = currentConvId else { return }
        let prev = tokenUsageByConv[convId] ?? (0, 0)
        tokenUsageByConv[convId] = (prev.input + input, prev.output + output)
    }

    /// Public read for the UI. If Pi never reported usage for this conv but
    /// messages exist, fall back to a rough chars/4 estimate so the badge
    /// doesn't show 0 when there's clearly traffic.
    func tokenTotal(for convId: UUID) -> Int {
        if let u = tokenUsageByConv[convId] { return u.input + u.output }
        let chars = messages.reduce(0) { $0 + $1.text.count + $1.parts.reduce(0) { acc, p in
            switch p {
            case .text(_, let v):    return acc + v.count
            case .tool(let b):       return acc + b.command.count + b.output.count
            case .thinking(let b):   return acc + b.text.count
            case .error(let b):      return acc + b.message.count
            }
        } }
        return chars / 4   // ~4 chars per token
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.streamFlushInterval ?? 33_000_000)
            await MainActor.run { self?.flushPending() }
        }
    }

    private func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        let batch = pendingDelta
        pendingDelta = ""
        if !batch.isEmpty { appendText(batch) }
    }

    // MARK: - Parts mutation

    private func appendText(_ delta: String) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }

        // If the trailing part is the active text part, append to it.
        // Otherwise create a new text part — happens after a tool block.
        if let activeID = activeTextPartID,
           let pIdx = messages[mIdx].parts.lastIndex(where: { $0.id == activeID }),
           case .text(let id, let value) = messages[mIdx].parts[pIdx] {
            messages[mIdx].parts[pIdx] = .text(id: id, value: value + delta)
        } else {
            let newID = UUID()
            messages[mIdx].parts.append(.text(id: newID, value: delta))
            activeTextPartID = newID
        }
        // Keep `text` mirror in sync — used for things like Recents preview.
        messages[mIdx].text = messages[mIdx].parts.compactMap {
            if case .text(_, let v) = $0 { return v } else { return nil }
        }.joined(separator: "\n\n")
    }

    private func currentTextLength() -> Int {
        guard let msgID = assistantMessageID,
              let m = messages.first(where: { $0.id == msgID }) else { return 0 }
        return m.parts.reduce(0) { acc, part in
            if case .text(_, let v) = part { return acc + v.count }
            return acc
        }
    }

    private func startTool(callId: String, name: String, args: [String: Any]) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        let block = ToolBlock(
            id: UUID(),
            toolCallId: callId,
            name: name,
            command: Self.summarizeArgs(name: name, args: args),
            output: "",
            isRunning: true,
            isError: false
        )
        messages[mIdx].parts.append(.tool(block))
        // Next text_delta should start a fresh text part below the tool.
        activeTextPartID = nil
    }

    private func finishTool(callId: String, result: String, isError: Bool) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        // Find the matching running block (latest one for this callId).
        for pIdx in messages[mIdx].parts.indices.reversed() {
            if case .tool(var b) = messages[mIdx].parts[pIdx], b.toolCallId == callId {
                b.output = result
                b.isRunning = false
                b.isError = isError
                messages[mIdx].parts[pIdx] = .tool(b)
                return
            }
        }
    }

    // MARK: - Thinking blocks

    private func startThinking() {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        let block = ThinkingBlock(id: UUID(), text: "", isRunning: true, durationMs: nil)
        messages[mIdx].parts.append(.thinking(block))
        activeTextPartID = nil
    }

    private func appendThinking(_ delta: String) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        // Append to the latest thinking part if it's still running.
        for pIdx in messages[mIdx].parts.indices.reversed() {
            if case .thinking(var b) = messages[mIdx].parts[pIdx], b.isRunning {
                b.text += delta
                messages[mIdx].parts[pIdx] = .thinking(b)
                return
            }
        }
        // No running block — open a new one (some providers skip thinking_start).
        startThinking()
        appendThinking(delta)
    }

    private func appendErrorBlock(_ message: String) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        let block = ErrorBlock.classify(message)
        messages[mIdx].parts.append(.error(block))
        activeTextPartID = nil
    }

    private func finishThinking(finalText: String?, durationMs: Int?) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        for pIdx in messages[mIdx].parts.indices.reversed() {
            if case .thinking(var b) = messages[mIdx].parts[pIdx], b.isRunning {
                if let finalText, !finalText.isEmpty { b.text = finalText }
                b.isRunning = false
                b.durationMs = durationMs
                messages[mIdx].parts[pIdx] = .thinking(b)
                return
            }
        }
    }

    /// Flush the current message list to disk under `currentConvId`.
    private func persist() {
        guard let convId = currentConvId else { return }
        store.saveMessages(messages, for: convId)
    }

    /// Build a short human-readable summary of a tool's args. For bash that's
    /// the command itself; for everything else we just JSON-encode.
    private static func summarizeArgs(name: String, args: [String: Any]) -> String {
        if name == "bash", let cmd = args["command"] as? String { return cmd }
        if name == "read", let path = args["path"] as? String { return path }
        if let json = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
           let s = String(data: json, encoding: .utf8) {
            return s
        }
        return ""
    }
}

