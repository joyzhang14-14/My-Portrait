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

    /// 本轮 AI 跑过的 `--ai-draft-write-body` 相对路径队列。toolEnd 时只
    /// 记录(不插卡片),agentEnd 才把卡片追加到 assistant 消息**末尾**,
    /// 这样卡片始终在 AI 回复完整出来之后才出现,不会夹在 bash blocks 中间。
    private var pendingDraftRelPathsThisTurn: [String] = []

    /// 本对话是否已经触发过「相关条目扫」第二轮。每个 chat 最多一次
    /// LLM scan,防止用户每次 approve 都烧 token。第二轮出来一批 drafts
    /// 后,用户用 Approve all 统一拍板,后续不再 trigger。switchTo 时重置。
    private var relatedScanFiredThisConv: Bool = false

    /// 顶住 App Nap 的活动 token —— streaming 期间持有,把 chat 的
    /// @MainActor 事件循环从背景态节流里救出来,否则用户切走窗口后
    /// agent 输出的 bash/text 全部"卡住",等切回来才一次性补上。
    /// streaming 一启动就 begin,agentEnd / error / abort 时 end。
    private var streamingActivityToken: (any NSObjectProtocol)?

    private func beginStreamingActivity() {
        guard streamingActivityToken == nil else { return }
        streamingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Chat streaming in flight")
    }

    private func endStreamingActivity() {
        if let t = streamingActivityToken {
            ProcessInfo.processInfo.endActivity(t)
            streamingActivityToken = nil
        }
    }

    private let store = ChatStore.shared
    /// Closure resolving the currently-selected provider + model + optional
    /// SecretStore key reference for that preset's API key (when the user
    /// has marked an AI preset as default). When ref is nil, ProviderAuth
    /// falls back to the standard per-provider keychain key.
    /// 返回当前 conv 应该用的 (provider, model, apiKeyRef)。
    /// 接收当前 convId(可能 nil = 还没有 conv);ContentView 注入时先查
    /// chatStore 看这条 conv 有没有锁定的 providerId/model,有就用,否则
    /// fallback 到全局 appState。
    var providerResolver: (UUID?) -> (Provider, String, String?) = { _ in
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
        endStreamingActivity()
        assistantMessageID = nil
        activeTextPartID = nil
        persist()
    }

    /// Drop the live Pi agent and load `convId`'s messages from disk.
    /// Use `nil` to clear the view (e.g. when "New chat" is pressed).
    func switchTo(_ convId: UUID?) {
        // **切走前先 persist 当前 conv 的内存消息** —— 否则 streaming 中
        // 切对话:agent 被 stop 不会再触发 agentEnd → persist() 永远不调 →
        // 用户消息 + 部分 assistant 回复只在内存里 → 下面被 loadMessages
        // 的 B 覆盖 → 切回来从磁盘读发现啥都没有。
        // 先 flushPending 把已 buffer 的 delta 落入 messages,再 persist。
        flushPending()
        persist()

        agent?.stop()
        agent = nil
        assistantMessageID = nil
        activeTextPartID = nil
        isStreaming = false
        endStreamingActivity()
        lastError = nil
        currentConvId = convId
        // 离开当前 conv → 编辑模式标记失效(未消费就丢)。
        pendingEditOriginalURL = nil
        // 每个对话独立计数,新对话允许再次扫一次相关条目。
        relatedScanFiredThisConv = false
        if let convId {
            messages = store.loadMessages(for: convId)
            // 🔒 Capture-on-switch:切到一个还没 lock 的 conv(老 conv 或
            // 锁状态下没机会改的),立刻把当前全局快照写进它的 lock,这样
            // 后面切走改全局 → 切回时 picker 仍然显示这个 conv 当时的值。
            // 只 capture 一次,lock 已有就跳过。
            let lock = store.conversationModel(id: convId)
            if lock.providerId == nil || lock.model == nil {
                let (provider, model, _) = providerResolver(convId)
                store.updateConversationModel(
                    convId,
                    providerId: provider.integrationId,
                    model: model
                )
            }
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
                } else if let convId = self.currentConvId {
                    // RECENTS 顶部 = 真发消息(saveMessages 不再自动 touch,
                    // 切对话 / picker 改 model 不算"活动")。第一条消息走 rename
                    // 路径已经 UPDATE updated_at,这里只补后续 send。
                    self.store.touchConversation(convId)
                }

                // What Pi actually sees:
                //   [first turn only] SKILL preamble teaching it about `mp-query`
                //   + chip-pinned context block (if user used @-picker)
                //   + attachment refs
                //   + user question
                var sections: [String] = []
                let isFirstTurnOfConv = (self.messages.count == 1)
                if isFirstTurnOfConv {
                    sections.append(MPQuerySkill.preamble)
                }
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
        } else if let convId = currentConvId {
            // 同 send() —— 真发消息时 bump RECENTS。
            store.touchConversation(convId)
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
            beginStreamingActivity()
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
            endStreamingActivity()
        }
    }

    /// 按 provider 校验前置条件,失败返回错误文案,可成功返回 nil。
    /// 在 send() / sendEditRequest() 进入异步前先 fail-fast。
    private func providerPrecheckError() -> String? {
        let (provider, _, _) = providerResolver(currentConvId)
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
        let (provider, model, apiKeyRef) = providerResolver(currentConvId)

        // 🔒 Capture-on-first-use:这个 conv 发消息时,如果还没写过 lock
        // (老 conv,或者 picker 锁状态下用户无法手动改),立刻把这次实际
        // 用的 provider/model 写进 conv。下次切回这个 conv,picker 显示
        // 不会被全局新值串掉。
        // 只 capture 一次 —— lock 已有就跳过(让用户手动切换的选择优先)。
        if let convId = currentConvId {
            let lock = store.conversationModel(id: convId)
            if lock.providerId == nil || lock.model == nil {
                store.updateConversationModel(
                    convId,
                    providerId: provider.integrationId,
                    model: model
                )
            }
        }
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
            // 从 store 读上次抓到的 sid → 切走再切回不丢上下文。回调把
            // 新 sid(以及 Claude 自动 fork session 时换的 sid)写回 store。
            let storedSid = currentConvId.flatMap { store.claudeSessionId(for: $0) }
            let convId = currentConvId
            a = ClaudeCodeAgent(
                model: model,
                initialSessionId: storedSid,
                onSessionId: { [weak self] sid in
                    Task { @MainActor [weak self] in
                        guard let self, let convId else { return }
                        self.store.updateClaudeSessionId(convId, sid)
                    }
                }
            )
        default:
            // 每条 conv 一个 pi session jsonl。首次没记录 → 现派一个,写回
            // store(后续切走再切回直接用)。pi 拿到 --session <path>:
            // 文件存在 → SessionManager.open() replay 历史;不存在 → 按
            // 这个路径建新 session。所以双向都 ok。
            var sessionPath: String? = nil
            if let convId = currentConvId {
                if let p = store.piSessionPath(for: convId) {
                    sessionPath = p
                } else {
                    let p = AIPaths.piSessionPath(for: convId).path
                    store.updatePiSessionPath(convId, p)
                    sessionPath = p
                }
            }
            a = try PiAgent(provider: provider, model: model,
                            apiKeyRefOverride: apiKeyRef,
                            sessionPath: sessionPath)
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
            // 把本轮排队的 draft 卡片都追加到 assistant 消息**末尾**,确保
            // 卡片在所有 bash / 文字之后才出现。assistantMessageID 还在
            // (清空在下面),appendEditDraftBlock 能找到当前消息。
            for rel in pendingDraftRelPathsThisTurn {
                appendEditDraftBlock(originalRelPath: rel)
            }
            pendingDraftRelPathsThisTurn.removeAll()
            // 防御:agent 在 .agentEnd 之前偶尔会漏发对应的 .thinkingEnd /
            // .toolEnd(Pi 自动压 context、Claude 直接 final 等),让前端永远
            // 卡在 "Thinking…" / "Running…" 转圈。这里把仍在 running 的块
            // 强制 close。
            closeRunningPartsOnCurrentAssistant()
            isStreaming = false
            endStreamingActivity()
            assistantMessageID = nil
            activeTextPartID = nil
            persist()
        case .error(let msg):
            flushPending()
            lastError = msg
            appendErrorBlock(msg)
            closeRunningPartsOnCurrentAssistant()
            isStreaming = false
            endStreamingActivity()
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
                    // output 优先 —— `draft body written: <rel>` 是 AIEditCLI
                    // 在程序运行后打印的,路径是 shell 展开后的真实值;
                    // command 字符串可能含未展开的 $TARGET 之类变量(AI 喜
                    // 欢这么写省字),解出来是字面量会扑空。command 当兜底。
                    if let rel = Self.parseDraftWriteBodyRel(fromOutput: b.output)
                        ?? Self.parseDraftWriteBodyRel(fromCommand: b.command) {
                        // 不在这里插卡片 —— 排到队列,等 agentEnd 一起追到末尾,
                        // 这样卡片永远在 AI 文字结束之后才出现,不会夹在 bash 中。
                        if !pendingDraftRelPathsThisTurn.contains(rel) {
                            pendingDraftRelPathsThisTurn.append(rel)
                        }
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
    ///
    /// 第一次 approve 触发 triggerRelatedScan —— AI 一次性扫所有相关条目
    /// 提一批 drafts;后续 approve 不再触发任何 LLM(每个对话最多一次扫)。
    /// 用户对那批 drafts 用 Approve all 统一拍板。
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
        // 第一次成功 approve → 启动唯一一次相关条目扫。
        if block.state == .approved, !relatedScanFiredThisConv {
            relatedScanFiredThisConv = true
            triggerRelatedScan(approvedRelPath: block.originalRelPath,
                               approvedSummary: block.summary ?? block.request)
        }
    }

    /// 给 AI 发一段 follow-up,要它顺 --ai-find-related 扫双向引用,对真
    /// 需要同向调整的相关条目**一次性**全部提出 drafts。每份 draft 会自动
    /// 通过 finishTool 钩子变成新的 EditDraftCard。用户用 Approve all
    /// 按钮一键拍板,后续 approve 不再触发 LLM(relatedScanFiredThisConv
    /// 守门)。
    private func triggerRelatedScan(approvedRelPath: String, approvedSummary: String) {
        let binPath = Bundle.main.executablePath ?? "MyPortrait"
        let followUp = """
        The user APPROVED the edit to `\(approvedRelPath)`.
        Edit summary: \(approvedSummary)

        SECOND ROUND — find ALL other entries needing the SAME factual
        correction, and propose drafts for them ALL IN THIS ONE TURN:

        1. Call `\(binPath) --ai-find-related \(approvedRelPath)` to list
           entries linked via evidence_event_ids / distilled_into.
        2. For EACH related entry, `--ai-read <rel>` and judge if it needs
           the same kind of edit to stay consistent with the approved one.
        3. For EACH entry that DOES need the same edit, propose a draft
           (begin → write-body → set-summary → preview).
        4. If no related entries need changes, say so and stop.

        STRICT — same rules as before: only --ai-draft-* writes, body-only,
        never edit frontmatter, never touch unrelated entries. **Do all
        drafts in this single turn** — the user will approve them in BULK
        in the UI (Approve all button). You will NOT get another follow-up,
        so don't hold back drafts for later.
        """
        Task { await self.deliver(followUp) }
    }

    /// 一键 Approve 当前对话里所有 pending draft。给用户「统一拍板」按钮调。
    /// 返回成功落盘的数量(.approved 翻成功)。失败的留在 .failed 状态。
    @discardableResult
    func approveAllPendingEditDrafts() -> Int {
        var approved = 0
        for mIdx in messages.indices {
            for pIdx in messages[mIdx].parts.indices {
                guard case .editDraft(var block) = messages[mIdx].parts[pIdx],
                      block.state == .pending else { continue }
                let url = Storage.rootURL.appendingPathComponent(block.originalRelPath)
                do {
                    try EditDraft.approve(originalURL: url)
                    block.state = .approved
                    approved += 1
                } catch {
                    block.state = .failed
                    block.errorMessage = error.localizedDescription
                }
                messages[mIdx].parts[pIdx] = .editDraft(block)
            }
        }
        if approved > 0 { persist() }
        return approved
    }

    /// 一键 Reject 当前对话里所有 pending draft。
    @discardableResult
    func rejectAllPendingEditDrafts() -> Int {
        var rejected = 0
        for mIdx in messages.indices {
            for pIdx in messages[mIdx].parts.indices {
                guard case .editDraft(var block) = messages[mIdx].parts[pIdx],
                      block.state == .pending else { continue }
                let url = Storage.rootURL.appendingPathComponent(block.originalRelPath)
                do {
                    try EditDraft.reject(originalURL: url)
                    block.state = .rejected
                    rejected += 1
                } catch {
                    block.state = .failed
                    block.errorMessage = error.localizedDescription
                }
                messages[mIdx].parts[pIdx] = .editDraft(block)
            }
        }
        if rejected > 0 { persist() }
        return rejected
    }

    /// 当前对话里 pending 状态的 draft 数。UI 用来决定「Approve all」按钮
    /// 是否显示 + 显示几张。
    var pendingEditDraftCount: Int {
        var n = 0
        for msg in messages {
            for part in msg.parts {
                if case .editDraft(let b) = part, b.state == .pending { n += 1 }
            }
        }
        return n
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

    /// 兜底:把当前 assistant 消息里仍处于 running 状态的 thinking / tool block
    /// 强制收尾。.agentEnd / .error 时调一次,防 agent 漏发 thinkingEnd/toolEnd
    /// 导致 UI 永远停在 "Thinking…" / "Running…" 的转圈。
    private func closeRunningPartsOnCurrentAssistant() {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        for pIdx in messages[mIdx].parts.indices {
            switch messages[mIdx].parts[pIdx] {
            case .thinking(var b) where b.isRunning:
                b.isRunning = false
                messages[mIdx].parts[pIdx] = .thinking(b)
            case .tool(var b) where b.isRunning:
                b.isRunning = false
                messages[mIdx].parts[pIdx] = .tool(b)
            default: break
            }
        }
    }

    /// cron job 在后台跑、把流式增量写进 DB 时调(CronJobExecutor.onConvUpdated)。
    /// 只有当用户**正在看这条 conv**、且 ChatController 自己没在跑 agent
    /// (cron conv 由 executor 驱动,ChatController 这边 agent==nil / 不
    /// streaming)时,从磁盘重读 → UI 像普通 chat 一样逐段刷出 thinking / bash。
    /// 自己在 streaming 的话绝不动 messages,免得踩自己的 live 状态。
    func liveReloadIfViewing(_ convId: UUID) {
        guard currentConvId == convId, !isStreaming, agent == nil else { return }
        messages = store.loadMessages(for: convId)
    }

    /// Flush the current message list to disk under `currentConvId`.
    private func persist() {
        guard let convId = currentConvId else { return }
        store.saveMessages(messages, for: convId)
    }

    /// Build a short human-readable summary of a tool's args. For bash that's
    /// the command itself; for everything else we just JSON-encode.
    private static func summarizeArgs(name: String, args: [String: Any]) -> String {
        // Pi 的工具名都是小写(bash/read),Claude Code 用大写驼峰
        // (Bash/Read/Edit/Glob/...);统一 lowercase 后再 match。
        let lname = name.lowercased()
        if lname == "bash", let cmd = args["command"] as? String { return cmd }
        if lname == "read", let path = args["file_path"] as? String ?? args["path"] as? String {
            return path
        }
        if lname == "write" || lname == "edit",
           let path = args["file_path"] as? String { return path }
        if let json = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
           let s = String(data: json, encoding: .utf8) {
            return s
        }
        return ""
    }
}

