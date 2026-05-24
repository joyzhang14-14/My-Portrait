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

    /// 当前会话用的 agent。可能是 PiAgent(BYOK / OAuth provider)或
    /// ClaudeCodeAgent(Claude Code CLI 子进程)。统一靠 ChatAgent 协议。
    private var agent: (any ChatAgent)?
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

    /// startEditConversation 设的标记 —— 下一次用户调 send() 时,改走
    /// sendEditRequest(自动包 edit-mode priming)。第一条消息发出后清空,
    /// 后续消息走普通 send(对话已有完整上下文)。
    private var pendingEditOriginalURL: URL? = nil

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
        // 离开当前 conv → 编辑模式标记失效(未消费就丢)。
        pendingEditOriginalURL = nil
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

        // 编辑模式拦截:startEditConversation 设了 pendingEditOriginalURL,
        // 第一条消息走 edit-mode priming。chips / attachments 在 edit 模式
        // 没意义(已经把 entity 全文塞进 prompt),忽略它们。
        if let editURL = pendingEditOriginalURL {
            pendingEditOriginalURL = nil
            sendEditRequest(originalURL: editURL, request: trimmed)
            return
        }

        if let reason = providerPrecheckError() {
            lastError = reason; return
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

    // MARK: - Edit mode

    /// 开一个新的「编辑某个 event/portrait」对话。返回新 conv id;UI 把侧栏
    /// 选中切过去。不污染日常 chat —— 每次点编辑按钮都是新 session。
    @discardableResult
    func startEditConversation(originalURL: URL) -> UUID {
        let conv = store.createConversation()
        let slug = originalURL.deletingPathExtension().lastPathComponent
        store.renameConversation(conv.id, to: "Edit: \(slug)")
        switchTo(conv.id)
        // switchTo 清掉了 pendingEditOriginalURL,所以这里重设。下一次 send()
        // 会消费它,自动走 sendEditRequest 路线。
        pendingEditOriginalURL = originalURL
        return conv.id
    }

    /// 发起一轮编辑请求。用户气泡只显示 `request`(干净);送给 PiAgent 的
    /// 提示自动包了 edit-mode system priming + 当前文件内容 + 受控工具用
    /// 法。AI 用 `--ai-draft-*` 工具落 draft,user 在 UI 里 approve/reject。
    func sendEditRequest(originalURL: URL, request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let reason = providerPrecheckError() {
            lastError = reason; return
        }

        if currentConvId == nil { _ = startEditConversation(originalURL: originalURL) }

        // 读当前文件内容塞进 prompt。失败就保留 placeholder 让 AI 用 --ai-read 自己拉。
        let currentContent: String
        if let data = try? Data(contentsOf: originalURL),
           let s = String(data: data, encoding: .utf8) {
            currentContent = s
        } else {
            currentContent = "(read failed — call --ai-read to fetch)"
        }

        // 相对路径:AI 的工具用这个寻址。
        let rel = Self.relativeToPortraitRoot(originalURL)
        let binPath = Bundle.main.executablePath ?? "MyPortrait"

        // 可见的 user bubble = 干净 request。
        var msg = ChatMessage(role: .user, text: trimmed, time: Date())
        msg.parts = [.text(id: UUID(), value: trimmed)]
        messages.append(msg)
        lastError = nil

        if pendingTitleFromFirstMessage, let convId = currentConvId {
            store.renameConversation(convId, to: Self.titleFromText(trimmed))
            pendingTitleFromFirstMessage = false
        }

        // invisible system priming + entity context + user request
        let priming = Self.editSystemPrompt(
            binPath: binPath, rel: rel,
            currentContent: currentContent, request: trimmed)
        Task { await self.deliver(priming) }
    }

    private static func relativeToPortraitRoot(_ url: URL) -> String {
        let root = Storage.rootURL.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
    }

    /// edit-mode 给 AI 的指令文本。**完整 prompt**:工具用法 + 严格规则 +
    /// 当前 entity 内容 + 用户原话需求。
    private static func editSystemPrompt(
        binPath: String, rel: String, currentContent: String, request: String
    ) -> String {
        """
        You are editing ONE entry in the user's personal memory system.
        Your only job is to propose a body edit that fulfills the user's
        request. You CANNOT touch the original file directly — only the
        --ai-draft-* CLI below writes to the staging area, which the user
        will manually approve or reject in the UI.

        TARGET: \(rel)

        CURRENT CONTENT (frontmatter + body):
        ─────────────────────────────────────────
        \(currentContent)
        ─────────────────────────────────────────

        USER REQUEST: \(request)

        AVAILABLE TOOLS (call via Bash, use `\(binPath)` as the binary):

          read / search (zero side effects):
            \(binPath) --ai-read <rel-path>
            \(binPath) --ai-grep <pattern>
            \(binPath) --ai-find-related <rel-path>

          draft (writes to ~/.portrait/.edit_draft/, NOT the original):
            \(binPath) --ai-draft-begin <rel-path> --request-file <tmpfile>
            \(binPath) --ai-draft-write-body <rel-path> --body-file <tmpfile>
            \(binPath) --ai-draft-set-summary <rel-path> --summary "<short>"
            \(binPath) --ai-draft-preview <rel-path>

        WORKFLOW for this turn:
          1. Read the user request. Decide what body content (markdown after
             the frontmatter `---`) needs to change to satisfy it.
          2. Write the FULL new body markdown into a tmpfile under /tmp/.
          3. Write the user's verbatim request into another tmpfile.
          4. Call --ai-draft-begin with --request-file pointing at #3.
          5. Call --ai-draft-write-body with --body-file pointing at #2.
          6. Call --ai-draft-set-summary with a one-line summary of what
             you changed (this lands in the file's frontmatter as an
             edit_note on approve).
          7. Call --ai-draft-preview to show the user before/after.
          8. Stop. Say one short sentence confirming the draft is ready
             for review.

        STRICT RULES:
        - NEVER use Write/Edit on files under ~/.portrait/events/ or
          ~/.portrait/portrait/ — that bypasses approval.
        - Only modify the BODY (markdown after `---`). Do not edit
          frontmatter fields — they are system-owned.
        - One draft per turn. Do not chain multiple edits.
        - If the request is unclear or unfulfillable, say so and stop;
          do not invent changes.
        """
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

    /// 按 provider 校验前置条件,失败返回错误文案,可成功返回 nil。
    /// 在 send() / sendEditRequest() 进入异步前先 fail-fast。
    private func providerPrecheckError() -> String? {
        let (provider, _, _) = providerResolver()
        switch provider {
        case .chatgpt:
            guard AISetup.shared.isReady else {
                return "Setup not finished — Bun/Pi still installing."
            }
            guard ChatGPTOAuth.isLoggedIn() else {
                return "Sign in to Codex from Connections first."
            }
            return nil
        case .claudeCode:
            guard ClaudeCodeAgent.isInstalled else {
                return "Claude Code CLI not found. Install with `brew install claude` or check ~/.local/bin."
            }
            return nil
        default:
            guard AISetup.shared.isReady else {
                return "Setup not finished — Bun/Pi still installing."
            }
            // 凭证缺失 → spawn 时 ProviderAuth 抛错走 .error 通道。
            return nil
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
        let a: any ChatAgent
        switch provider {
        case .claudeCode:
            // 不走 Pi,直接 spawn `claude` CLI 子进程。
            a = ClaudeCodeAgent(model: model)
        default:
            a = try PiAgent(provider: provider, model: model, apiKeyRefOverride: apiKeyRef)
        }
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
            case .editDraft(let b):  return acc + b.request.count + b.beforeBody.count + b.afterBody.count
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
                // 如果是成功的 `--ai-draft-write-body <rel>` 调用 → 自动追加
                // 一张 EditDraftBlock 卡片到对话流(用户在卡片上 approve/reject)。
                // 两条识别路径(取第一条命中的):
                //   1. command 包含 --ai-draft-write-body(PiAgent 把 bash
                //      命令塞进 args["command"],summarizeArgs 还原)。
                //   2. output 里有 AIEditCLI 落 draft 时打的成功行
                //      "draft body written: <rel>"(ClaudeCodeAgent 等不
                //      暴露 bash 命令字符串时兜底)。
                if !isError {
                    if let rel = Self.parseDraftWriteBodyRel(fromCommand: b.command)
                        ?? Self.parseDraftWriteBodyRel(fromOutput: b.output) {
                        appendEditDraftBlock(originalRelPath: rel)
                    }
                }
                return
            }
        }
    }

    /// 从 ToolBlock.command(summarizeArgs 输出的 bash 命令文本)里抠出
    /// `--ai-draft-write-body <rel>` 后的相对路径。匹不到 → nil。
    private static func parseDraftWriteBodyRel(fromCommand command: String) -> String? {
        guard let range = command.range(of: "--ai-draft-write-body ") else { return nil }
        let tail = command[range.upperBound...]
        // 取下一个空格前的 token,trim 引号。
        let token = tail.prefix(while: { !$0.isWhitespace })
        let unquoted = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return unquoted.isEmpty ? nil : unquoted
    }

    /// 从 ToolBlock.output 里识别 `--ai-draft-write-body` 落盘成功 ——
    /// AIEditCLI.draftWriteBody 成功时 print "draft body written: <rel>"。
    /// agent 没暴露 bash command 字符串时(如 ClaudeCodeAgent)用这条。
    private static func parseDraftWriteBodyRel(fromOutput output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "draft body written: "
            guard trimmed.hasPrefix(prefix) else { continue }
            let rel = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !rel.isEmpty { return rel }
        }
        return nil
    }

    /// 追加一张 EditDraftBlock 到当前 assistant 消息。读 draft 现成内容
    /// (before/after/meta),失败也插入一张 .failed 卡片提示。
    private func appendEditDraftBlock(originalRelPath: String) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        let originalURL = Storage.rootURL.appendingPathComponent(originalRelPath)
        let block: EditDraftBlock
        do {
            let (before, after) = try EditDraft.preview(originalURL: originalURL)
            let meta = try EditDraft.readMeta(originalURL: originalURL)
            block = EditDraftBlock(
                id: UUID(),
                originalRelPath: originalRelPath,
                request: meta.request,
                summary: meta.summary,
                beforeBody: before,
                afterBody: after,
                state: .pending,
                errorMessage: nil)
        } catch {
            block = EditDraftBlock(
                id: UUID(),
                originalRelPath: originalRelPath,
                request: "(meta unreadable)",
                summary: nil,
                beforeBody: "", afterBody: "",
                state: .failed,
                errorMessage: error.localizedDescription)
        }
        messages[mIdx].parts.append(.editDraft(block))
        activeTextPartID = nil   // 后续 text delta 起新 part
    }

    // MARK: - EditDraft 公开 API(UI 卡片按钮调)

    /// 用户点 Approve。成功 → block.state=.approved + 删 draft 文件。
    /// 失败 → block.state=.failed + errorMessage 显示原因。
    func approveEditDraft(blockId: UUID) {
        guard let located = locateEditDraftBlock(blockId: blockId) else { return }
        var block = located.2
        guard block.state == .pending else { return }
        let originalURL = Storage.rootURL.appendingPathComponent(block.originalRelPath)
        do {
            try EditDraft.approve(originalURL: originalURL)
            block.state = .approved
        } catch {
            block.state = .failed
            block.errorMessage = error.localizedDescription
        }
        messages[located.0].parts[located.1] = .editDraft(block)
        persist()
        // Approve 成功 → 自动触发第二轮:让 AI 扫相关条目找出同向需改的,
        // 给每个生成独立 draft 卡片(用户逐个 approve/reject)。失败 / 已被
        // 翻成其他状态的不触发。
        if block.state == .approved {
            triggerRelatedScan(approvedRelPath: block.originalRelPath,
                               approvedSummary: block.summary ?? block.request)
        }
    }

    /// 给 AI 发一段 follow-up,要它顺 --ai-find-related 扫双向引用,对真
    /// 需要同向调整的相关条目各起一份新 draft。每份新 draft 会自动通过
    /// finishTool 钩子变成新的 EditDraftCard 等用户拍板。
    private func triggerRelatedScan(approvedRelPath: String, approvedSummary: String) {
        let binPath = Bundle.main.executablePath ?? "MyPortrait"
        let followUp = """
        The user APPROVED the edit to `\(approvedRelPath)`.
        Edit summary: \(approvedSummary)

        Now do the SECOND ROUND — find any other entries that should change
        in the same direction (e.g., same factual correction):

        1. Call `\(binPath) --ai-find-related \(approvedRelPath)` to list
           entries linked to this one via evidence_event_ids / distilled_into
           (both directions).
        2. For EACH related entry, read it (`\(binPath) --ai-read <rel>`)
           and judge if it needs the same kind of edit to stay consistent.
        3. If it does, propose a draft using the same --ai-draft-* workflow:
           begin → write-body → set-summary → preview. Each proposed draft
           will surface as its own approval card; the user will accept or
           reject them individually.
        4. If no related entries need changes, say so and stop.

        STRICT — same rules as before: only --ai-draft-* writes, body-only,
        one draft per related entry, never edit frontmatter, never touch
        unrelated entries.
        """
        Task { await self.deliver(followUp) }
    }

    /// 用户点 Reject。删 draft 文件,原文件不动。
    func rejectEditDraft(blockId: UUID) {
        guard let located = locateEditDraftBlock(blockId: blockId) else { return }
        var block = located.2
        guard block.state == .pending else { return }
        let originalURL = Storage.rootURL.appendingPathComponent(block.originalRelPath)
        do {
            try EditDraft.reject(originalURL: originalURL)
            block.state = .rejected
        } catch {
            block.state = .failed
            block.errorMessage = error.localizedDescription
        }
        messages[located.0].parts[located.1] = .editDraft(block)
        persist()
    }

    private func locateEditDraftBlock(blockId: UUID) -> (Int, Int, EditDraftBlock)? {
        for (mIdx, msg) in messages.enumerated() {
            for (pIdx, part) in msg.parts.enumerated() {
                if case .editDraft(let b) = part, b.id == blockId {
                    return (mIdx, pIdx, b)
                }
            }
        }
        return nil
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

