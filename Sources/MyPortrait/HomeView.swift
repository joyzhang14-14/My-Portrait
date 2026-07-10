import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatController.self) private var chat
    @Environment(ChatStore.self) private var chatStore
    @State private var prompt: String = ""
    @State private var setup = AISetup.shared
    @State private var contextChips: [ContextChip] = []
    @State private var pickerOpen: Bool = false
    @State private var configStore = ConfigStore.shared
    private var redactPII: Bool {
        get { configStore.current.chat.redactPii }
    }
    private func setRedactPII(_ v: Bool) {
        configStore.mutate { $0.chat.redactPii = v }
    }
    @State private var attachments: [Attachment] = []
    @State private var templates = TemplateLibrary.shared
    @State private var editingTemplate: SummaryTemplate? = nil

    private func runTemplate(_ t: SummaryTemplate) {
        let chips = [t.window.resolveChip()].compactMap { $0 }
        let redact = redactPII
        chat.send(t.prompt, chips: chips, redactPII: redact)
    }

    /// New chat 标题 "How can I help, <name>?" 的 <name> 部分。优先级:
    ///   1. personalInfo.alias(用户填的 preferred name / nickname)
    ///   2. personalInfo.firstName
    ///   3. 都空 → "How can I help?"(不带名字)
    static func greeting() -> String {
        let info = ConfigStore.shared.current.personalInfo
        let alias = info.alias.trimmingCharacters(in: .whitespaces)
        let first = info.firstName.trimmingCharacters(in: .whitespaces)
        let name = !alias.isEmpty ? alias : first
        return name.isEmpty ? "How can I help?" : "How can I help, \(name)?"
    }

    /// QUICK ACTIONS 区域显示的 chip。**根据最近 OCR 数据动态生成** ——
    /// SuggestionEngine 跑模式检测(coding / browsing / meeting / writing 等)
    /// 然后按模式产对应的模板。空(还没载入)/ DB 没数据时回退 Mock。
    /// view appear / 每 60s 重跑一次。
    @State private var dynamicSuggestions: [SuggestionEngine.Suggestion] = []

    /// Quick Actions 刷新:detached 跑 SQL,主线程只更新 state。
    private func refreshActivityChips() async {
        let suggestions = await Task.detached(priority: .utility) {
            let activity = TimelineDB().recentActivity(lookback: 3600)
            return SuggestionEngine.suggestions(from: activity)
        }.value
        await MainActor.run { self.dynamicSuggestions = suggestions }
    }

    /// Non-nil when the input has been pre-populated by clicking ✏️ Edit on
    /// a past user message. Send-on-Enter routes through editAndResend
    /// instead of send so the old turn is dropped, not duplicated.
    @State private var editingMessageId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let banner = setupBannerText {
                SetupBanner(text: banner, isError: setupIsError)
            }
            // 编辑模式时,顶部 sticky 一张闪烁渐变 pill,把当前在编辑的
            // entity slug 持续可见。会话标题以 "Edit: " 开头时显示。
            if let slug = editTargetSlug {
                EditContextPill(slug: slug)
                    .padding(.horizontal, 24)
                    .padding(.top, 0)
            }
            if chat.isLoadingConversation {
                ProgressView("Loading conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if chat.messages.isEmpty {
                ScrollView { greetingContent }
            } else {
                ChatTranscript(
                    messages: chat.messages,
                    isThinking: chat.isStreaming,
                    chipsLookup: { chat.contextChipsByMessage[$0] ?? [] },
                    attachmentsLookup: { chat.attachmentsByMessage[$0] ?? [] },
                    citationsLookup: { chat.citationsByMessage[$0] ?? [] },
                    onCopy: { msg in
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(plainTextOf(msg), forType: .string)
                    },
                    onRegenerate: { chat.regenerate($0) },
                    onEdit: { msg in
                        // Drop the user msg into the input and prep its chips
                        // for re-send; user can tweak then press Enter.
                        prompt = msg.text
                        contextChips = chat.contextChipsByMessage[msg.id] ?? []
                        editingMessageId = msg.id
                    }
                )
            }

            // 至少 2 张 pending draft 时,在输入框上方挂一条统一拍板栏。
            // 一张时单卡 Approve/Reject 已经够用,显示 batch bar 反而冗余。
            if chat.pendingEditDraftCount >= 2 {
                BatchApproveBar(count: chat.pendingEditDraftCount,
                                onApproveAll: { _ = chat.approveAllPendingEditDrafts() },
                                onRejectAll: { _ = chat.rejectAllPendingEditDrafts() })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            ChatInputBar(
                prompt: $prompt,
                providerName: appState.activeAI?.name ?? "Codex",
                providerSlug: appState.activeAI?.id.uppercased() ?? "OPENAI-CHATGPT",
                isConnected: appState.activeAI != nil,
                contextChips: $contextChips,
                pickerOpen: $pickerOpen,
                redactPII: Binding(get: { redactPII }, set: { setRedactPII($0) }),
                attachments: $attachments,
                isStreaming: chat.isStreaming,
                tokenTotal: chat.currentConvId.map { chat.tokenTotal(for: $0) } ?? 0,
                onSend: send,
                onStop: { chat.abort() },
                onChipTap: { chipText in
                    prompt = chipText
                    send()
                }
            )
        }
        .background(AmbientBackground())
        .task {
            AISetup.shared.ensureInstalled()
        }
        .task {
            // QUICK ACTIONS:首次 appear 立刻刷,然后每 60s 重跑一次。
            // 离开 view → task 自动取消,后台不再跑。
            await refreshActivityChips()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await refreshActivityChips()
            }
        }
        // ContentView 的窗口级 drop zone 在用户把文件 / 图片放到 chat pane
        // 任何空白处时 broadcast 一条通知,HomeView 这边接住并 append 到
        // 现有 @State,跟 ChatInputBar 里粘贴 / paperclip 拿到的 attachment
        // 走同一根队列。
        .onReceive(NotificationCenter.default.publisher(for: .chatAttachmentsDropped)) { note in
            guard let payload = note.object as? [Attachment] else { return }
            attachments.append(contentsOf: payload)
        }
        // 编辑标记是 per-conv 的:切对话/新建对话后旧消息 id 在新会话里
        // 不存在,残留会让 send() 走 editAndResend 静默 no-op,用户输入
        // 被清空丢失。切换即清,后续发送落普通 send 路径。
        .onChange(of: chat.currentConvId) { editingMessageId = nil }
    }

    /// 编辑会话提取出来的目标 entity slug。约定:会话标题形如
    /// "Edit: <slug>"(由 startEditConversation 设置)→ 显示 pill。
    private var editTargetSlug: String? {
        guard let convId = chat.currentConvId,
              let conv = chatStore.conversations.first(where: { $0.id == convId }) else {
            return nil
        }
        let prefix = "Edit: "
        guard conv.title.hasPrefix(prefix) else { return nil }
        let slug = String(conv.title.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    private var setupBannerText: String? {
        switch setup.state {
        case .checking:                  return "Checking AI runtime…"
        case .installingBun(let p):      return "Installing Bun runtime… \(Int(p * 100))%"
        case .installingPi:              return "Installing Pi agent…"
        case .error(let msg):            return "Setup failed: \(msg)"
        case .idle, .ready:              return nil
        }
    }

    private var setupIsError: Bool {
        if case .error = setup.state { return true }
        return false
    }

    // MARK: greeting (no messages yet)
    private var greetingContent: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                Text(Self.greeting())
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.96))
                Text("One-click summaries from your screen activity")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            .padding(.top, 36)

            let cols = [GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(templates.templates) { t in
                    TemplateCardView(
                        template: t,
                        onTap: { runTemplate(t) },
                        onEdit: { editingTemplate = t },
                        onDelete: { templates.delete(t.id) }
                    )
                }
                AddTemplateCard { editingTemplate = SummaryTemplate(
                    emoji: "✨", title: "New shortcut", subtitle: "",
                    prompt: "", window: .lastHours(1)
                ) }
            }
            .padding(.horizontal, 20)
            .sheet(item: $editingTemplate) { t in
                TemplateEditor(initial: t) { edited in
                    if templates.templates.contains(where: { $0.id == edited.id }) {
                        templates.update(edited)
                    } else {
                        templates.add(edited)
                    }
                    editingTemplate = nil
                } onCancel: {
                    editingTemplate = nil
                }
            }

            HStack(spacing: 6) {
                Text("QUICK ACTIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textPrimary.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            LazyVGrid(columns: cols, spacing: 8) {
                // 真有动态建议就用它(带 context chip);还没载入时回退 Mock 静态。
                if !dynamicSuggestions.isEmpty {
                    ForEach(dynamicSuggestions) { s in
                        ActivityChipView(
                            chip: ActivityChip(text: s.text, hint: s.preview)
                        ) {
                            // **关键**:把建议绑定的 context 范围一并塞进
                            // chips 再 send。不然 AI 拿不到 OCR/audio 数据
                            // 只能回 "I don't have visibility into your day"。
                            prompt = s.text
                            contextChips = [ContextChip(spec: s.context)]
                            send()
                        }
                    }
                } else {
                    ForEach(Mock.activityChips) { chip in
                        ActivityChipView(chip: chip) {
                            prompt = chip.text
                            // 静态兜底 chip 默认绑 lastMinutes(60),保底有数据
                            contextChips = [ContextChip(spec: .lastMinutes(60))]
                            send()
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        // 流式回复进行中 Enter 不发送(也**不清空输入框**,用户打的字留着,
        // 等流式结束再发)。ChatController.send 里还有一层同样的 guard 兜底。
        guard !chat.isStreaming, !chat.isLoadingConversation else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let chipsToSend = contextChips
        let attachmentsToSend = attachments
        let redact = redactPII
        prompt = ""
        contextChips = []
        attachments = []
        if let id = editingMessageId {
            editingMessageId = nil
            chat.editAndResend(id, newText: trimmed.isEmpty ? "(attachments only)" : trimmed,
                               chips: chipsToSend, attachments: attachmentsToSend, redactPII: redact)
        } else {
            chat.send(trimmed.isEmpty ? "(see attachments)" : trimmed,
                      chips: chipsToSend, attachments: attachmentsToSend, redactPII: redact)
        }
    }
}

/// "1.2K", "12K", "1.2M" — compact token counter shown in the chip row.
private func formatTokens(_ n: Int) -> String {
    if n < 1000 { return "\(n)" }
    if n < 10_000 { return String(format: "%.1fK", Double(n) / 1000) }
    if n < 1_000_000 { return "\(n / 1000)K" }
    return String(format: "%.1fM", Double(n) / 1_000_000)
}

/// Extract an assistant `ChatMessage`'s final text output for the clipboard.
/// Copies **only** the `.text` parts — the model's actual answer — and drops
/// thinking, tool commands/output, errors, and edit drafts. Users want the
/// clean reply, not the whole reasoning + execution trace.
private func plainTextOf(_ m: ChatMessage) -> String {
    if m.role == .user || m.parts.isEmpty { return m.text }
    return m.parts
        .compactMap { if case .text(_, let v) = $0 { return v } else { return nil } }
        .joined(separator: "\n\n")
}

/// Slim banner shown above the chat when AI setup is in progress or failed.
private struct SetupBanner: View {
    let text: String
    let isError: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        HStack(spacing: 8) {
            if !isError { ProgressView().controlSize(.small).tint(Theme.textSecondary) }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isError ? Color.red.opacity(0.9) : Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isError
                    ? Color.red.opacity(0.10)
                    : Color.primary.opacity(colorScheme == .light ? 0.04 : 0.04))
    }
}

// MARK: - Chat transcript

private struct ChatTranscript: View {
    let messages: [ChatMessage]
    let isThinking: Bool
    var chipsLookup: ((UUID) -> [ContextChip])? = nil
    var attachmentsLookup: ((UUID) -> [Attachment])? = nil
    var citationsLookup: ((UUID) -> [Citation])? = nil
    var onCopy: (ChatMessage) -> Void = { _ in }
    var onRegenerate: (UUID) -> Void = { _ in }
    var onEdit: (ChatMessage) -> Void = { _ in }

    /// 过滤空 assistant placeholder —— ChatController streaming 一启动就先
    /// 插入一条 content="" 的 assistant message,但 thinking 状态由底下独立
    /// ChatThinking 表达,placeholder 本身渲染就是个空 bubble,跟 thinking
    /// 并列形成 "两个 bubble" 的 bug。(#6)
    private var displayMessages: [ChatMessage] {
        // ChatMessage 用 text + parts;空 placeholder = 两者都空。
        messages.filter { !($0.role == .assistant && $0.text.isEmpty && $0.parts.isEmpty) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack:历史 bubble 不再全部常驻(长会话首开/滚动时只建
                // 可见部分)。配合 ChatBubble 的手写 Equatable + .equatable(),
                // 流式期间每个 delta tick 只有正在长的那条重跑 body,历史消息
                // 全部相等性短路 —— 之前闭包参数让 SwiftUI 无法自动短路,每个
                // tick 整条历史(几十条 markdown)全量重渲染。
                LazyVStack(alignment: .leading, spacing: 18) {
                    let visible = displayMessages
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, msg in
                        // The streaming assistant bubble is always the last
                        // assistant message; only it should glow.
                        let isLastAssistant = idx == visible.count - 1 && msg.role == .assistant
                        ChatBubble(
                            message: msg,
                            isStreaming: isLastAssistant && isThinking,
                            // 历史对话加载时不能把整条超高回复做入场动画：
                            // LazyVStack 会在动画中反复估高，形成布局死循环。
                            animatesEntrance: isThinking && idx == visible.count - 1,
                            chips: chipsLookup?(msg.id) ?? [],
                            attachments: attachmentsLookup?(msg.id) ?? [],
                            citations: citationsLookup?(msg.id) ?? [],
                            onCopy: { onCopy(msg) },
                            onRegenerate: { onRegenerate(msg.id) },
                            onEdit: { onEdit(msg) }
                        )
                        .equatable()
                        .id(msg.id)
                    }
                    if isThinking {
                        ChatThinking()
                            .id("thinking")
                    }
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 26)
            }
            .onChange(of: messages.count) {
                guard let last = messages.last else { return }
                // 等 LazyVStack 完成本轮挂载再滚。不要动画，也不要全局 bottom
                // anchor；两者都会让超高历史 bubble 反复参与尺寸估算。
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: isThinking) {
                if isThinking { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }
}

private struct ChatBubble: View, @MainActor Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    /// 只有最后一条(新追加的消息)播放入场动画;历史消息在 LazyVStack 下
    /// 滚回视口时直接以最终状态呈现,不重播。
    let animatesEntrance: Bool
    let chips: [ContextChip]
    let attachments: [Attachment]
    let citations: [Citation]
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    @State private var appear = false
    @State private var hover = false

    /// 闭包参数让 SwiftUI 无法自动做相等性比较(永远视为"变了"),手写 ==
    /// 只比真正影响渲染的值字段;闭包身份不影响渲染结果。配合 ForEach 里的
    /// .equatable(),流式期间历史消息全部短路不重渲。
    static func == (a: ChatBubble, b: ChatBubble) -> Bool {
        a.message == b.message && a.isStreaming == b.isStreaming
            && a.animatesEntrance == b.animatesEntrance
            && a.chips == b.chips && a.attachments == b.attachments
            && a.citations == b.citations
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BubbleAvatar(role: message.role, glowing: message.role == .assistant && isStreaming)
            VStack(alignment: .leading, spacing: 10) {
                // 标题行高度恒定 —— 之前 hover 时 BubbleActions 出现在 HStack
                // 里把行高从 11pt 字撑到按钮高,消息体被往下推一段,体感是
                // "鼠标一悬停消息往下滑"。改成 actions 走 overlay 不占布局位。
                HStack(spacing: 6) {
                    Text(message.role == .user ? "You" : "Assistant")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    // hover 时显示 copy / regenerate / edit。overlay 不参与
                    // 父 layout,显示/隐藏不会改变 bubble 任何尺寸。无动画。
                    if hover, !isStreaming {
                        BubbleActions(role: message.role,
                                      onCopy: onCopy,
                                      onRegenerate: onRegenerate,
                                      onEdit: onEdit)
                    }
                }

                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips) { chip in
                            ContextChipView(chip: chip, compact: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments) { att in
                            // 图片可点开 lightbox 由 AttachmentThumb 内部处理。
                            // onRemove 传空 closure —— 已发出消息的附件不可删。
                            // size=42 显小,直接传比外面 scaleEffect 包稳
                            // (scaleEffect 改视觉不改 hit-test region)。
                            AttachmentThumb(attachment: att,
                                            onRemove: {},
                                            size: 42)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if message.role == .user {
                    Text(.init(message.text))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.textPrimary.opacity(0.96))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(5)
                } else {
                    AssistantBody(parts: message.parts, fallbackText: message.text)
                    if !citations.isEmpty {
                        CitationFooter(citations: citations)
                    }
                }
            }
            .padding(.vertical, message.role == .assistant ? 14 : 6)
            .padding(.horizontal, message.role == .assistant ? 18 : 6)
            .background {
                if message.role == .assistant {
                    GlassPanel(tint: .purple, intensity: 0.04, strokeOpacity: 0.10, corner: 16)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 12)
        // **hover 触发范围 = 整条消息长方形**(包括留白),contentShape 让
        // padding 区域也参与 hit-test。之前 hover 只在文字 / glass panel 上
        // 起作用,鼠标 hover 在右侧 Spacer 区域时不触发,编辑/复制按钮怎么
        // 都点不到。
        .contentShape(Rectangle())
        .onAppear {
            if animatesEntrance {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appear = true }
            } else {
                // 历史消息直接以最终状态呈现:LazyVStack 下向上滚历史时旧
                // bubble 才首次 mount,重播淡入+上滑会逐条"弹入";入场动画
                // 只留给最后一条(新追加的消息)。
                appear = true
            }
        }
        // hover state 直接切换,不再裹 withAnimation —— actions 走 overlay
        // 已经不会影响布局,加动画反而引入"消息下滑"错觉。
        .onHover { hover = $0 }
    }
}

/// Numbered source list under an assistant bubble. Each row shows the
/// chip label + a brief detail (time range / match count / file size). The
/// AI is asked, via the context prompt header, to cite as `[N]`.
private struct CitationFooter: View {
    let citations: [Citation]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCES")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.textPrimary.opacity(0.40))
            ForEach(citations) { c in
                CitationRow(citation: c)
            }
        }
        .padding(.top, 8)
    }
}

private struct CitationRow: View {
    let citation: Citation
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Text("[\(citation.number)]")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.purple.opacity(0.85))
                .frame(minWidth: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(citation.label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                Text(citation.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
            }
            Spacer()
            Image(systemName: actionIcon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.85 : 0.40))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hover ? 0.05 : 0.02))
        )
        .contentShape(Rectangle())
        .onTapGesture { performAction() }
        .onHover { hover = $0 }
        .help(actionHelp)
    }

    private var actionIcon: String {
        switch citation.action {
        case .timeRange: return "clock.arrow.circlepath"
        case .file:      return "arrow.up.right.square"
        case .speaker:   return "person.wave.2"
        case .search:    return "magnifyingglass"
        }
    }
    private var actionHelp: String {
        switch citation.action {
        case .timeRange: return "Switch to Timeline at this moment"
        case .file:      return "Reveal in Finder"
        case .speaker:   return "Filter audio by this speaker"
        case .search:    return "Re-run this OCR search"
        }
    }
    private func performAction() {
        switch citation.action {
        case .timeRange(let start, _, _):
            NotificationCenter.default.post(name: .navigateToTimelineAt, object: start)
        case .file(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .speaker, .search:
            // Re-running these inside the chat is the next iteration's job.
            break
        }
    }
}

extension Notification.Name {
    /// Posted by a citation row when the user wants to jump to the source's
    /// moment in the Timeline view. ContentView observes this to switch the
    /// sidebar selection + seek.
    static let navigateToTimelineAt = Notification.Name("MyPortrait.NavigateToTimelineAt")
    /// Posted by ContentView's window-wide drop zone when the user drops
    /// files / images anywhere on the chat pane. HomeView listens and
    /// appends them to its attachment strip. object = [Attachment].
    static let chatAttachmentsDropped = Notification.Name("MyPortrait.ChatAttachmentsDropped")
}

/// Hover toolbar on a chat bubble. User msgs show Copy + Edit; assistant
/// msgs show Copy + Regenerate. Compact glass pills.
private struct BubbleActions: View {
    let role: ChatRole
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    @State private var copied = false
    var body: some View {
        HStack(spacing: 4) {
            actionButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
            }
            if role == .assistant {
                actionButton(icon: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
            } else {
                actionButton(icon: "pencil", help: "Edit", action: onEdit)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        )
    }
    private func actionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.78))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bouncyIcon)
        .help(help)
    }
}

/// Sequentially renders text + tool blocks for an assistant message.
private struct AssistantBody: View {
    let parts: [ContentPart]
    let fallbackText: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if parts.isEmpty && !fallbackText.isEmpty {
                MarkdownView(source: fallbackText)
            }
            if ConfigStore.shared.display.compactToolBlocks || shouldForceCompactProcessBlocks {
                // 把连续的过程块(thinking/tool/error/editDraft)折叠成一个汇总栏,
                // 最终文本(.text)正常显示。collapsed 时不渲染内部块 → 历史消息更快。
                ForEach(compactSegments) { seg in
                    switch seg.kind {
                    case .text(let value):
                        MarkdownView(source: value)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    case .group(let blocks):
                        CompactStepsBar(blocks: blocks)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                    }
                }
            } else {
                ForEach(parts) { part in
                    renderPart(part)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: parts.count)
    }

    /// Protect historical conversations with unusually large hidden process
    /// payloads even when the user has disabled compact tool blocks.
    private var shouldForceCompactProcessBlocks: Bool {
        if parts.count > 24 { return true }
        var outputBytes = 0
        for case .tool(let block) in parts {
            outputBytes += block.output.utf8.count
            if outputBytes > 64 * 1_024 { return true }
        }
        return false
    }

    /// 把 parts 切成 segments:连续的非文本块归入一个 group,文本块独立 ——
    /// 保持原始顺序(过程块在前 / 最终回答在后是常见结构,交错也能正确处理)。
    private var compactSegments: [CompactSegment] {
        var result: [CompactSegment] = []
        var buffer: [ContentPart] = []
        func flush() {
            guard let first = buffer.first else { return }
            result.append(CompactSegment(id: "g-\(first.id)", kind: .group(buffer)))
            buffer.removeAll()
        }
        for part in parts {
            if case .text(let pid, let value) = part {
                flush()
                result.append(CompactSegment(id: "t-\(pid)", kind: .text(value)))
            } else {
                buffer.append(part)
            }
        }
        flush()
        return result
    }

    @ViewBuilder
    private func renderPart(_ part: ContentPart) -> some View {
        switch part {
        case .text(_, let value):
            MarkdownView(source: value)
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .tool(let block):
            ToolCard(block: block)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
        case .thinking(let block):
            // Skip the chain-of-thought card entirely when the user
            // has flipped Display → "Hide thinking blocks".
            if !ConfigStore.shared.display.hideModelReasoning {
                ThinkingCard(block: block)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        case .error(let block):
            ErrorCard(block: block)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
        case .editDraft(let block):
            EditDraftCard(block: block)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
        }
    }
}

/// 一段渲染单元:要么一段最终文本,要么一组被折叠的过程块。
private struct CompactSegment: Identifiable {
    enum Kind {
        case text(String)
        case group([ContentPart])
    }
    let id: String
    let kind: Kind
}

/// 把一条回复里连续的「过程块」(thinking + tool + error + editDraft)折叠成一个
/// 汇总栏。collapsed 时只渲染统计 header(read/ran/failed),**不渲染内部块** ——
/// 历史消息因此不必一次性渲染几十张 card,前端流畅很多;展开后才创建具体块视图。
/// 流式生成中(有 running 块)默认展开看实时进度,完成后自动折叠。
private struct CompactStepsBar: View {
    let blocks: [ContentPart]
    @State private var expanded: Bool
    @State private var didAutoCollapse = false

    init(blocks: [ContentPart]) {
        self.blocks = blocks
        _expanded = State(initialValue: blocks.contains { CompactStepsBar.isRunning($0) })
    }

    private static func isRunning(_ p: ContentPart) -> Bool {
        switch p {
        case .tool(let b):     return b.isRunning
        case .thinking(let b): return b.isRunning
        default:               return false
        }
    }
    private var anyRunning: Bool { blocks.contains { CompactStepsBar.isRunning($0) } }

    private var readCount: Int {
        blocks.filter { if case .tool(let b) = $0 { return b.name == "read" } else { return false } }.count
    }
    private var ranCount: Int {
        blocks.filter { if case .tool(let b) = $0 { return b.name != "read" } else { return false } }.count
    }
    private var failedCount: Int {
        blocks.filter { if case .tool(let b) = $0 { return b.isError } else { return false } }.count
    }

    private var summaryText: String {
        var segs: [String] = []
        if readCount > 0 { segs.append("read \(readCount) file\(readCount == 1 ? "" : "s")") }
        if ranCount  > 0 { segs.append("ran \(ranCount) command\(ranCount == 1 ? "" : "s")") }
        var s = segs.joined(separator: " · ")
        if failedCount > 0 { s += (s.isEmpty ? "" : " · ") + "failed \(failedCount)" }
        if s.isEmpty {
            // 这组只有 thinking,没有工具调用。
            let n = blocks.count
            s = anyRunning ? "Working…" : "\(n) step\(n == 1 ? "" : "s")"
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { part in
                        blockView(part)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.85)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
        )
        .onChange(of: anyRunning) {
            // 流式完成 → 自动折叠成汇总栏(像 ToolCard 那样)。
            if !anyRunning, !didAutoCollapse {
                didAutoCollapse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeOut(duration: 0.25)) { expanded = false }
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.20)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.7))
                Text(summaryText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
                if anyRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                }
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(.bouncyIcon)
    }

    @ViewBuilder
    private func blockView(_ part: ContentPart) -> some View {
        switch part {
        case .text(_, let value):
            MarkdownView(source: value)
        case .tool(let block):
            ToolCard(block: block)
        case .thinking(let block):
            if !ConfigStore.shared.display.hideModelReasoning {
                ThinkingCard(block: block)
            }
        case .error(let block):
            ErrorCard(block: block)
        case .editDraft(let block):
            EditDraftCard(block: block)
        }
    }
}

/// chat 输入框上方的「统一拍板」横条 —— 第二轮相关条目扫之后,如果有
/// 2+ 张 pending draft,这条出现,让用户一键 Approve all / Reject all。
/// 已 approve / rejected / failed 的不算 pending,不影响 count。
private struct BatchApproveBar: View {
    let count: Int
    let onApproveAll: () -> Void
    let onRejectAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinearGradient(
                    colors: [.cyan, .purple, .pink],
                    startPoint: .leading, endPoint: .trailing))
            Text("\(count) drafts pending review")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer(minLength: 8)
            Button(action: onRejectAll) {
                Label("Reject all", systemImage: "xmark")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            Button(action: onApproveAll) {
                Label("Approve all", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .opacity(0.85)
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [.cyan.opacity(0.10), .purple.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(LinearGradient(
                        colors: [.cyan, .purple, .pink],
                        startPoint: .leading, endPoint: .trailing).opacity(0.50),
                        lineWidth: 0.8)
            }
        )
    }
}

/// 编辑会话顶部的渐变 pill —— 持续可见地告诉用户「现在在编辑哪个 entity」。
/// 走 LinearGradient + ultraThin material 玻璃质感,sparkles 旋转图标 +
/// 缓慢呼吸动画,跟主 chat 风格一致但有「持续焦点」的暗示。
private struct EditContextPill: View {
    let slug: String
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LinearGradient(
                    colors: [.cyan, .purple, .pink],
                    startPoint: .leading, endPoint: .trailing))
                .symbolEffect(.pulse, options: .repeating, value: pulse)
            Text("EDITING")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Theme.textPrimary.opacity(0.62))
            Text(slug)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.98))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 10)
            Text("Body-only · approval required")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.50))
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .opacity(0.85)
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [.cyan.opacity(0.14), .purple.opacity(0.12), .pink.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(LinearGradient(
                        colors: [.cyan, .purple, .pink],
                        startPoint: .leading, endPoint: .trailing).opacity(0.60),
                        lineWidth: 1.0)
            }
        )
        .onAppear { pulse.toggle() }
    }
}

/// AI 提议的编辑 draft 卡片。漂亮、清晰、有状态反馈:
/// - 顶部:闪烁渐变 header,sparkles + 「Proposed edit」+ slug pill
/// - 用户原话需求 / AI 一句总结
/// - 「After」是默认展开的(用户直接看新内容,markdown 渲染);「Show original」
///   折叠 disclosure 展开原 body
/// - 底部:Approve(绿,主色)/Reject(红,bordered);state 切换时按钮收起,
///   显示已批准 / 已拒绝徽章,带 spring 动画
private struct EditDraftCard: View {
    let block: EditDraftBlock
    @Environment(ChatController.self) private var chat
    @State private var showOriginal: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let summary = block.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .padding(.horizontal, 14)
            }
            if !block.request.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Request")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                        .padding(.top, 1)
                    Text(block.request)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textPrimary.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
            }
            Divider().background(Color.primary.opacity(0.12)).padding(.horizontal, 14)
            afterBlock
            originalDisclosure
            footer
        }
        .padding(.vertical, 14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentGradient)
            Text("Proposed edit")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: entityIcon)
                    .font(.system(size: 9, weight: .medium))
                Text(slugLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Theme.textPrimary.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.10), lineWidth: 0.6))
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    private var afterBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green.opacity(0.85))
                Text("AFTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            // 全文直出,不嵌 ScrollView —— 否则跟外层 chat ScrollView 抢
            // 手势,稍快滑动整段卡片就跟着窗口飞。
            Text(block.afterBody)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.22), lineWidth: 0.6))
                )
        }
        .padding(.horizontal, 14)
    }

    private var originalDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { showOriginal.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showOriginal ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(showOriginal ? "HIDE ORIGINAL" : "SHOW ORIGINAL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            .buttonStyle(.plain)
            if showOriginal {
                Text(block.beforeBody.isEmpty ? "(empty)" : block.beforeBody)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.62))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.18), lineWidth: 0.6))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var footer: some View {
        switch block.state {
        case .pending:
            HStack(spacing: 10) {
                Spacer()
                Button {
                    chat.rejectEditDraft(blockId: block.id)
                } label: {
                    Label("Reject", systemImage: "xmark")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                Button {
                    chat.approveEditDraft(blockId: block.id)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }
            .padding(.horizontal, 14)
        case .approved:
            statusBadge(label: "Approved", icon: "checkmark.seal.fill", color: .green)
        case .rejected:
            statusBadge(label: "Rejected", icon: "xmark.seal.fill", color: .red)
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                statusBadge(label: "Failed", icon: "exclamationmark.triangle.fill", color: .orange)
                if let msg = block.errorMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.85))
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    private func statusBadge(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var slugLabel: String {
        (block.originalRelPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
    }
    private var entityIcon: String {
        block.originalRelPath.hasPrefix("events/") ? "doc.text" : "person.crop.rectangle"
    }
    private var accentGradient: LinearGradient {
        LinearGradient(colors: [.cyan, .purple, .pink],
                       startPoint: .leading, endPoint: .trailing)
    }
    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .opacity(0.85)
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: [.cyan.opacity(0.10), .purple.opacity(0.10), .pink.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 14)
                .stroke(accentGradient.opacity(0.45), lineWidth: 0.9)
        }
    }
}

/// Friendly error card for quota / rate / auth / network failures. Click to
/// reveal the raw error message.
private struct ErrorCard: View {
    let block: ErrorBlock
    @State private var showDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() }
                } label: {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                }
                .buttonStyle(.bouncyIcon)
            }
            .padding(12)

            if showDetails {
                Divider().background(Color.primary.opacity(0.14))
                ScrollView {
                    Text(block.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.65))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.45), lineWidth: 0.8)
                )
        )
    }

    private var tint: Color {
        switch block.kind {
        case .creditsExhausted, .dailyLimit, .rateLimit: return .orange
        case .authExpired, .modelNotAllowed:             return .yellow
        case .network:                                   return .blue
        case .other:                                     return .red
        }
    }

    private var icon: String {
        switch block.kind {
        case .rateLimit:         return "tortoise.fill"
        case .dailyLimit:        return "calendar.badge.exclamationmark"
        case .creditsExhausted:  return "creditcard.trianglebadge.exclamationmark"
        case .modelNotAllowed:   return "lock.fill"
        case .authExpired:       return "key.slash"
        case .network:           return "wifi.exclamationmark"
        case .other:             return "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch block.kind {
        case .rateLimit:         return "Slow down"
        case .dailyLimit:        return "Daily limit reached"
        case .creditsExhausted:  return "Out of credits"
        case .modelNotAllowed:   return "Model unavailable"
        case .authExpired:       return "Sign-in expired"
        case .network:           return "Network problem"
        case .other:             return "Error"
        }
    }

    private var subtitle: String {
        switch block.kind {
        case .rateLimit:
            return "Too many requests — wait a moment and try again."
        case .dailyLimit:
            if let r = block.resetsAt { return "Resets at \(r). Try a smaller prompt or wait." }
            return "You've used your ChatGPT daily quota. Wait or upgrade."
        case .creditsExhausted:
            return "Your account is out of credits. Top up your plan."
        case .modelNotAllowed:
            return "The selected model isn't on your plan. Switch in Connections."
        case .authExpired:
            return "Re-sign in to Codex from Connections to continue."
        case .network:
            return "Couldn't reach OpenAI. Check your connection and retry."
        case .other:
            return "Something went wrong. Click below for details."
        }
    }
}

/// Reasoning / chain-of-thought card. Streams the thinking text while
/// `isRunning`; collapses to a one-line "Thought for Ns" once done.
private struct ThinkingCard: View {
    let block: ThinkingBlock
    @State private var expanded: Bool
    @State private var didAutoCollapse: Bool

    init(block: ThinkingBlock) {
        self.block = block
        // 运行中默认展开看进度;已完成的(历史 / 折叠汇总栏里 lazy 插入)初始就
        // collapsed —— 避免「首帧展开再 onAppear 收起」的高度闪烁(在 ScrollView
        // 里会把视角向上弹)。
        _expanded = State(initialValue: block.isRunning)
        _didAutoCollapse = State(initialValue: !block.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, !block.text.isEmpty {
                Divider().background(Color.primary.opacity(0.12))
                ScrollView {
                    Text(block.text)
                        .font(.system(size: 12, design: .default))
                        .foregroundStyle(Theme.textPrimary.opacity(0.72))
                        .italic()
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.85)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accentStroke, lineWidth: 0.8)
                )
        )
        .onChange(of: block.isRunning) {
            if !block.isRunning, !didAutoCollapse {
                didAutoCollapse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.25)) { expanded = false }
                }
            }
        }
        .onAppear {
            if !block.isRunning { expanded = false; didAutoCollapse = true }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.20)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.75))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textPrimary.opacity(0.82))
                Spacer()
                if block.isRunning {
                    ProgressView().controlSize(.small).tint(Theme.textSecondary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.bouncyIcon)
    }

    private var label: String {
        if block.isRunning { return "Thinking…" }
        if let ms = block.durationMs {
            let secs = max(1, ms / 1000)
            return "Thought for \(secs)s"
        }
        return "Thought"
    }

    private var accentStroke: Color {
        // running 用 cyan(语义色,跨主题都看得清);idle 用 Color.primary
        // (= 系统 labelColor,light 下黑、dark 下白,自动跟 colorScheme 切)。
        // 之前钉死 Color.white.opacity(0.10),light 模式下完全看不见框线。
        block.isRunning ? Color.cyan.opacity(0.40) : Color.primary.opacity(0.18)
    }
}

/// Compact tool card — mirrors Orphies behaviour:
///   - Running: header + spinner + live command + live output
///   - Finished: collapses after a short delay to a single-line friendly label
///     ("Ran `pwd && ls`", "Read App.swift") that the user can click to expand.
private struct ToolCard: View {
    let block: ToolBlock
    @State private var expanded: Bool
    /// Set to true once we've kicked off the auto-collapse so we don't run the
    /// timer every time SwiftUI rebuilds the view.
    @State private var didScheduleAutoCollapse: Bool

    /// Delay between a tool finishing and the card collapsing to a one-liner.
    private static let autoCollapseDelay: TimeInterval = 2.0

    init(block: ToolBlock) {
        self.block = block
        // 运行中默认展开看进度;已完成的(历史 / 折叠汇总栏里 lazy 插入)初始就
        // collapsed —— 避免「首帧展开再 onAppear 收起」的高度闪烁(在 ScrollView
        // 里会把视角向上弹)。
        _expanded = State(initialValue: block.isRunning)
        _didScheduleAutoCollapse = State(initialValue: !block.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                if !block.command.isEmpty {
                    Divider().background(Color.primary.opacity(0.12))
                    Text(block.command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.88))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !block.output.isEmpty {
                    Divider().background(Color.primary.opacity(0.12))
                    ScrollView {
                        Text(block.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.78))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.85)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accentStroke, lineWidth: 0.8)
                )
        )
        .onChange(of: block.isRunning) {
            // Tool just finished — start the auto-collapse timer once.
            if !block.isRunning, !didScheduleAutoCollapse {
                didScheduleAutoCollapse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCollapseDelay) {
                    withAnimation(.easeOut(duration: 0.25)) { expanded = false }
                }
            }
        }
        .onAppear {
            // Card was inserted already-finished (e.g. message re-rendered):
            // skip the live phase, jump straight to collapsed.
            if !block.isRunning {
                expanded = false
                didScheduleAutoCollapse = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.20)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconFor(block.name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.75))
                if expanded {
                    Text(block.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textPrimary.opacity(0.8))
                } else {
                    Text(friendlyLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                statusBadge
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, expanded ? 9 : 10)
        }
        .buttonStyle(.bouncyIcon)
    }

    // MARK: - Friendly label (collapsed)

    /// One-line human summary. Matches Orphies' `friendlyToolLabel`.
    private var friendlyLabel: String {
        switch block.name {
        case "bash", "shell":
            let cmd = block.command.replacingOccurrences(of: "\n", with: " ")
            let head = cmd.count > 60 ? String(cmd.prefix(60)) + "…" : cmd
            return cmd.isEmpty ? "Ran command" : "Ran `\(head)`"
        case "read":
            return "Read \(fileName(block.command))"
        case "edit":
            return "Edited \(fileName(block.command))"
        case "write":
            return "Wrote \(fileName(block.command))"
        case "grep", "rg":
            return "Searched for `\(block.command.prefix(40))`"
        case "find", "ls":
            return "Listed files"
        default:
            return block.name
        }
    }

    private func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private var accentStroke: Color {
        // error / running 用语义色(红 / 紫,跨主题都看得清);idle 用
        // Color.primary 自动跟 colorScheme,light 下黑边 dark 下白边。
        if block.isError    { return Color.red.opacity(0.40) }
        if block.isRunning  { return Color.purple.opacity(0.45) }
        return Color.primary.opacity(0.18)
    }

    @ViewBuilder private var statusBadge: some View {
        if block.isRunning {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.textSecondary)
        } else if block.isError {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(Color.red.opacity(0.85))
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(Color.green.opacity(0.85))
        }
    }

    private func iconFor(_ name: String) -> String {
        switch name {
        case "bash", "shell": return "terminal.fill"
        case "read":          return "doc.text"
        case "write", "edit": return "pencil"
        case "grep", "rg":    return "magnifyingglass"
        default:              return "wrench.and.screwdriver"
        }
    }
}

/// Big gradient orb. The breathing + halo animations only run while
/// `glowing == true` (i.e. the assistant is actively streaming). Static
/// bubbles render a still orb — crucial because every message in the
/// transcript renders an avatar; running 60fps Canvases for all of them
/// melted the GPU during long sessions.
private struct BubbleAvatar: View {
    let role: ChatRole
    var glowing: Bool = false

    var body: some View {
        if glowing {
            animatedOrb
        } else {
            staticOrb
        }
    }

    @ViewBuilder private var staticOrb: some View {
        ZStack {
            orbFill
            Image(systemName: role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 16, weight: role == .user ? .semibold : .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
        }
        .frame(width: 36, height: 36)
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
        .frame(width: 40, height: 40)
    }

    private var animatedOrb: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0/30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = CGFloat(1 + 0.04 * sin(t * 1.6))
            let pulse  = CGFloat(0.55 + 0.35 * sin(t * 3.0))
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.purple.opacity(0.55), Color.purple.opacity(0)],
                            center: .center, startRadius: 0, endRadius: 32
                        )
                    )
                    .frame(width: 70, height: 70)
                    .opacity(Double(pulse))
                    .blur(radius: 6)
                ZStack {
                    orbFill
                    Image(systemName: role == .user ? "person.fill" : "sparkles")
                        .font(.system(size: 16, weight: role == .user ? .semibold : .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                }
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                .scaleEffect(breath)
            }
        }
        .frame(width: 40, height: 40)
    }

    /// Pure-color fill shared between the static + animated paths.
    @ViewBuilder private var orbFill: some View {
        if role == .assistant {
            AngularGradient(
                colors: [
                    Color(red: 0.65, green: 0.35, blue: 1.0),
                    Color(red: 0.30, green: 0.55, blue: 1.0),
                    Color(red: 0.95, green: 0.40, blue: 0.85),
                    Color(red: 0.65, green: 0.35, blue: 1.0)
                ],
                center: .center
            )
            .clipShape(Circle())
            .overlay(
                Circle().fill(
                    LinearGradient(colors: [Color.white.opacity(0.20), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
        } else {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color.white.opacity(0.04))
            }
        }
    }
}

private struct ChatThinking: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BubbleAvatar(role: .assistant, glowing: true)
            HStack(spacing: 10) {
                OrbitingParticles()
                Text("thinking…")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(GlassPanel(tint: .purple, intensity: 0.04, strokeOpacity: 0.10, corner: 16))
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

/// Three colored orbs revolving on the same orbital circle, 120° apart,
/// each leaving a softly fading motion trail behind it. The whole rig
/// breathes (orbit radius modulates by ±10% on a 3-second cycle).
private struct OrbitingParticles: View {
    /// Orbital period in seconds.
    private let period: Double = 1.6
    /// Visual canvas size — orbit fits comfortably inside.
    private let size: CGFloat = 28
    /// Base orbit radius.
    private let radius: CGFloat = 9
    /// Number of trail samples drawn per orb (older = dimmer + smaller).
    private let trailSamples = 6
    /// Three orb colors. Picked to riff on the assistant avatar gradient.
    private let colors: [Color] = [
        Color(red: 0.75, green: 0.40, blue: 1.00),    // violet
        Color(red: 0.40, green: 0.85, blue: 1.00),    // cyan
        Color(red: 1.00, green: 0.45, blue: 0.80)     // magenta
    ]

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0/30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gctx, canvasSize in
                draw(into: &gctx, size: canvasSize, t: t)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }

    private func draw(into ctx: inout GraphicsContext, size canvasSize: CGSize, t: Double) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let breath = 1 + 0.10 * sin(t * 2 * .pi / 3.0)
        let r = radius * CGFloat(breath)
        let baseAngle = (t / period) * .pi * 2

        for (idx, color) in colors.enumerated() {
            let phase = Double(idx) * (2 * .pi / 3.0)

            // Trail samples — older positions, faded.
            for s in (1...trailSamples).reversed() {
                let lag = Double(s) * (period / 30.0)
                let angle = baseAngle - lag + phase
                let pos = CGPoint(
                    x: center.x + cos(angle) * r,
                    y: center.y + sin(angle) * r
                )
                let trailAlpha = (1.0 - Double(s) / Double(trailSamples)) * 0.4
                let trailRadius = 1.6 - Double(s) * 0.18
                let rect = CGRect(
                    x: pos.x - CGFloat(trailRadius),
                    y: pos.y - CGFloat(trailRadius),
                    width: CGFloat(trailRadius * 2),
                    height: CGFloat(trailRadius * 2)
                )
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(color.opacity(trailAlpha)))
            }

            // Head orb with a soft glow halo.
            let headAngle = baseAngle + phase
            let head = CGPoint(
                x: center.x + cos(headAngle) * r,
                y: center.y + sin(headAngle) * r
            )

            // Halo
            let haloRadius: CGFloat = 4.5
            let haloRect = CGRect(
                x: head.x - haloRadius,
                y: head.y - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )
            ctx.fill(
                Path(ellipseIn: haloRect),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                    center: head, startRadius: 0, endRadius: haloRadius
                )
            )

            // Solid head
            let headRect = CGRect(
                x: head.x - 1.8, y: head.y - 1.8,
                width: 3.6, height: 3.6
            )
            ctx.fill(Path(ellipseIn: headRect), with: .color(color))
        }
    }
}

/// Reusable frosted-glass panel used by bubbles and the input bar.
struct GlassPanel: View {
    var tint: Color = .white
    var intensity: Double = 0.05      // base fill alpha
    var strokeOpacity: Double = 0.12
    var corner: CGFloat = 14
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.85)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(tint.opacity(intensity))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(strokeOpacity * 1.2),
                                 Color.white.opacity(strokeOpacity * 0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
    }
}

// MARK: - Suggestion cards / chips

/// Renders one user-editable template as a 1/3-width tile. Hover surfaces
/// edit + delete; the tile body sends the prompt.
private struct TemplateCardView: View {
    let template: SummaryTemplate
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(template.emoji).font(.system(size: 18))
                    if template.schedule != .never {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.purple.opacity(0.8))
                            .help("Auto-runs " + template.schedule.label)
                    }
                    Spacer()
                    if hover {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textPrimary.opacity(0.65))
                        }
                        .buttonStyle(.bouncyIcon)
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textPrimary.opacity(0.65))
                        }
                        .buttonStyle(.bouncyIcon)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.92))
                        .lineLimit(1)
                    Text(template.subtitle.isEmpty ? template.window.label : template.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(hover ? 0.05 : 0.025))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit", action: onEdit)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

/// Trailing tile that opens a fresh template editor.
private struct AddTemplateCard: View {
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.85 : 0.45))
                Text("New shortcut")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.75 : 0.45))
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color.white.opacity(hover ? 0.30 : 0.14),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}

/// Modal editor for a SummaryTemplate. Lives in a .sheet — single text area
/// for the prompt + light metadata controls.
private struct TemplateEditor: View {
    @State var initial: SummaryTemplate
    let onSave: (SummaryTemplate) -> Void
    let onCancel: () -> Void

    private let windowOptions: [ContextWindow] = [
        .none, .lastMinutes(5), .lastMinutes(30),
        .lastHours(1), .lastHours(4), .lastHours(8), .today
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shortcut").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save")  { onSave(initial) }.keyboardShortcut(.defaultAction)
                    .disabled(initial.title.isEmpty || initial.prompt.isEmpty)
            }

            HStack(spacing: 8) {
                TextField("emoji", text: $initial.emoji).frame(width: 44)
                TextField("title", text: $initial.title)
            }
            .textFieldStyle(.roundedBorder)

            TextField("subtitle (optional)", text: $initial.subtitle)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $initial.prompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Context window").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $initial.window) {
                    ForEach(windowOptions, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text("Schedule").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                Picker("", selection: $initial.schedule) {
                    ForEach(cadenceOptions, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("Fires while the app is open. Each run starts a new conversation.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private let cadenceOptions: [Cadence] = [
        .never,
        .everyMinutes(30), .everyMinutes(60), .everyMinutes(180),
        .dailyAt(hour: 9), .dailyAt(hour: 17),
        .weeklyOn(weekday: 2, hour: 9)   // Mon 09:00 (standup)
    ]
}

private struct ActivityChipView: View {
    let chip: ActivityChip
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chip.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let hint = chip.hint {
                    Text(hint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(hover ? 0.04 : 0.02))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}

// MARK: - Chat input bar

private struct ChatInputBar: View {
    @Binding var prompt: String
    let providerName: String
    let providerSlug: String
    let isConnected: Bool
    @Binding var contextChips: [ContextChip]
    @Binding var pickerOpen: Bool
    @Binding var redactPII: Bool
    @Binding var attachments: [Attachment]
    let isStreaming: Bool
    let tokenTotal: Int
    let onSend: () -> Void
    let onStop: () -> Void
    let onChipTap: (String) -> Void

    @FocusState private var focused: Bool
    /// NSTextView 报回来的内容自然高度。空 ≈ 22pt(单行),涨到内容大小,
    /// 外面 clamp 在 [32, 4 * lineHeight ≈ 96] 之间 —— 超过 4 行就不再涨,
    /// 内部 NSScrollView 接管滚动。
    @State private var inputContentHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 10) {
            // Top chip row inside the glass panel
            HStack(spacing: 10) {
                ChipButton(icon: "line.3.horizontal.decrease", label: "filter")
                if !isConnected {
                    Text("(not connected)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.80))
                }
                if tokenTotal > 0 {
                    Text("\(formatTokens(tokenTotal)) tok")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                        .help("Estimated total tokens in this conversation")
                }
                Spacer()
                ProviderModelPicker()
            }

            // Context chips (only visible when user has picked at least one)
            if !contextChips.isEmpty {
                FlowChips(chips: contextChips) { id in
                    contextChips.removeAll { $0.id == id }
                }
            }
            // Attachment thumbnails (visible when user pasted / dropped files)
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { id in
                    attachments.removeAll { $0.id == id }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                // 自定义 NSTextView + NSScrollView 包装 —— SwiftUI 原生
                // TextField(axis:.vertical) 没法做"框矮+内部滚动",拉伸/
                // 截字都不对。ChatInputTextView 暴露:固定高度由外面 frame
                // 决定,内容超出自动出滚条 + 双指可滚,Enter 提交 / Shift+
                // Enter 换行,IME 期间 Enter 让给候选选词。
                ChatInputTextView(
                    text: $prompt,
                    measuredHeight: $inputContentHeight,
                    placeholder: "Ask about your screen…  (type @ for filters, paste images)",
                    font: .systemFont(ofSize: 14),
                    onSubmit: { onSend() },
                    onTextChange: { old, new in
                        // 输入 "@" 弹 picker,且把那个字符吃掉避免残留在
                        // prompt 里(原 onChange 同款逻辑)。
                        if new.count > old.count, new.hasSuffix("@") {
                            prompt = String(new.dropLast())
                            withAnimation(.easeOut(duration: 0.15)) { pickerOpen = true }
                        }
                    },
                    onAttachmentsPasted: { newAtts in
                        // ⌘V / 拖入文件 / 图片 → 直接 append 到 attachments,
                        // 上方的 AttachmentStrip 自动显示。用户能像之前 ⨉ 删。
                        attachments.append(contentsOf: newAtts)
                    }
                )
                // 高度 = clamp(测出的内容高, [32 单行, 96 ≈ 4 行])。涨够 4 行
                // 后封顶,内部 NSScrollView 接管滚动。
                .frame(height: min(max(inputContentHeight, 32), 96))
                .popover(isPresented: $pickerOpen, attachmentAnchor: .point(.topLeading),
                         arrowEdge: .bottom) {
                    ContextPickerView(
                        onPick: { chip in
                            contextChips.append(chip)
                            pickerOpen = false
                            focused = true
                        },
                        onDismiss: {
                            pickerOpen = false
                            focused = true
                        }
                    )
                    .padding(8)
                }

                HStack(spacing: 4) {
                    IconActionButton(icon: "at") {
                        withAnimation(.easeOut(duration: 0.15)) { pickerOpen.toggle() }
                    }
                    IconActionButton(
                        icon: redactPII ? "shield.lefthalf.filled" : "shield",
                        tint: redactPII ? Color(red: 0.55, green: 0.95, blue: 0.65) : nil,
                        help: redactPII ? "Privacy filter ON — emails / phones / keys redacted"
                                        : "Privacy filter OFF — toggle to redact PII before sending"
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) { redactPII.toggle() }
                    }
                    IconActionButton(icon: "paperclip", help: "Attach files") {
                        pickFiles()
                    }
                    if isStreaming {
                        StopButton(action: onStop)
                            .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        SendButton(action: onSend, enabled: !prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            GlassPanel(tint: .white, intensity: 0.03, strokeOpacity: 0.10, corner: 18)
                .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 12)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .padding(.top, 8)
        .onAppear { focused = true }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onPasteCommand(of: [.fileURL, .image, .png, .tiff]) { providers in
            _ = handleDrop(providers)
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                attachments.append(AttachmentStore.wrap(fileURL: url))
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var anyHandled = false
        for provider in providers {
            // Try a file URL first.
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        attachments.append(AttachmentStore.wrap(fileURL: url))
                    }
                }
                anyHandled = true
                continue
            }
            // Image data (e.g. screenshot in clipboard with no file URL).
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let a = AttachmentStore.save(data: data, suggestedName: nil, isImage: true) {
                            attachments.append(a)
                        }
                    }
                }
                anyHandled = true
            }
        }
        return anyHandled
    }
}

/// Horizontal scroll of attachment thumbnails above the input. Click × to remove.
private struct AttachmentStrip: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    AttachmentThumb(attachment: att) { onRemove(att.id) }
                        .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.75), value: attachments.count)
    }
}

private struct AttachmentThumb: View {
    let attachment: Attachment
    let onRemove: () -> Void
    /// 缩略图边长。默认 52(input bar 用),消息 bubble 里传 42 显小。
    /// 直接给 size 参数比外面套 scaleEffect+frame 稳 —— scaleEffect 只改
    /// 渲染不改 hit-test layout,Button 点击区域会跟视觉错位。
    var size: CGFloat = 52
    @State private var hover = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 图片 → 缩略图整体可点,直接调 ImageLightboxController 弹全屏。
            // 内部自管,调用方零参数(input bar / message bubble 都自动可点)。
            // 文件附件 → 裸 content,不响应点击。
            if attachment.kind == .image {
                Button {
                    ImageLightboxController.shared.show(attachment: attachment)
                } label: { content }
                    .buttonStyle(.plain)
                    .help("Click to view full size")
            } else {
                content
            }
            if hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.75))
                }
                .buttonStyle(.bouncyIcon)
                .offset(x: 6, y: -6)
            }
        }
        .onHover { hover = $0 }
    }
    @ViewBuilder private var content: some View {
        if attachment.kind == .image {
            // 异步降采样 + NSCache 缓存,避免 body 里同步全分辨率解码(流式时
            // 每帧重渲染都会重解一次)。AsyncDiskThumbnail 内部已 scaledToFill。
            // targetPixelSize 给屏幕 px(× 2 retina),稍大避免缩放糊。
            AsyncDiskThumbnail(path: attachment.url.path, targetPixelSize: size * 2)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.7))
        } else {
            VStack(spacing: 4) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(Theme.textPrimary.opacity(0.7))
                Text(attachment.displayName)
                    .font(.system(size: max(8, size * 0.17), design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size - 6)
            }
            .frame(width: size + 4, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.7))
            )
        }
    }
}

/// Wrapping row of `ContextChipView`s with a remove callback.
private struct FlowChips: View {
    let chips: [ContextChip]
    let onRemove: (UUID) -> Void
    var body: some View {
        // SwiftUI's HStack with .wrap is iOS17+. Use a simple WrapHStack via
        // Layout protocol — but for 1-6 chips a plain HStack with allowsTightening
        // is fine. Almost no one stacks > 4 chips.
        HStack(spacing: 6) {
            ForEach(chips) { c in
                ContextChipView(chip: c, onRemove: { onRemove(c.id) })
                    .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: chips.count)
    }
}

// MARK: - Input bar right-side actions

/// Generic icon button (shield / paperclip / @). 17pt symbol, hover lifts +
/// glass background appears, click pops. Optional `tint` makes it persist a
/// non-default color (used for "toggled on" states like the privacy shield).
private struct IconActionButton: View {
    let icon: String
    var tint: Color? = nil
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                // 没显式 tint 时用系统 label color(自动跟 light/dark 切),
                // 之前钉 .white 在 light 模式下整个图标几乎看不见。
                .foregroundStyle(tint ?? Theme.textPrimary.opacity(hover ? 0.95 : 0.55))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(tint != nil ? 0.80 : (hover ? 0.80 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke((tint ?? Color.primary).opacity(tint != nil ? 0.45 : (hover ? 0.18 : 0)), lineWidth: 0.6)
                        )
                )
                .scaleEffect(pressed ? 0.90 : (hover ? 1.04 : 1.0))
        }
        .buttonStyle(.bouncyIcon)
        .help(help ?? "")
        .onHover { hover = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                .onEnded   { _ in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressed = false } }
        )
        .animation(.easeOut(duration: 0.18), value: hover)
    }
}

/// Stop button — replaces SendButton while a turn is streaming. Red-tinted
/// gradient + breathing pulse to signal "interrupt".
private struct StopButton: View {
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.95, green: 0.35, blue: 0.45),
                                     Color(red: 0.70, green: 0.20, blue: 0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.7)
                    )
                    .shadow(color: Color.red.opacity(hover ? 0.55 : 0.30),
                            radius: hover ? 14 : 8, x: 0, y: 4)
                    .frame(width: 34, height: 34)
                // Filled square = "stop"
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 11, height: 11)
            }
            .scaleEffect(pressed ? 0.92 : (hover ? 1.04 : 1.0))
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                .onEnded   { _ in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressed = false } }
        )
        .animation(.easeOut(duration: 0.18), value: hover)
    }
}

/// Primary send button — purple→pink gradient orb with hover breathing,
/// click ripple, and a disabled state that drops to monochrome.
private struct SendButton: View {
    let action: () -> Void
    var enabled: Bool = true
    @State private var hover = false
    @State private var pressed = false
    @State private var ripple = false
    var body: some View {
        Button(action: {
            guard enabled else { return }
            ripple = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ripple = false }
            action()
        }) {
            ZStack {
                // Click ripple
                if ripple {
                    Circle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 2)
                        .scaleEffect(ripple ? 2.0 : 0.5)
                        .opacity(ripple ? 0 : 0.9)
                        .animation(.easeOut(duration: 0.55), value: ripple)
                        .frame(width: 32, height: 32)
                }
                // Background orb
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        enabled
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.65, green: 0.30, blue: 1.0),
                                     Color(red: 0.95, green: 0.35, blue: 0.65)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.7)
                    )
                    .shadow(color: enabled ? Color.purple.opacity(hover ? 0.55 : 0.30) : .clear,
                            radius: hover ? 14 : 8, x: 0, y: 4)
                    .frame(width: 34, height: 34)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(enabled ? 0.97 : 0.45))
                    .offset(x: pressed ? 1 : 0, y: pressed ? 1 : 0)
            }
            .scaleEffect(pressed ? 0.92 : (hover ? 1.04 : 1.0))
        }
        .buttonStyle(.bouncyIcon)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                .onEnded   { _ in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressed = false } }
        )
        .animation(.easeOut(duration: 0.18), value: hover)
    }
}

private struct ChipButton: View {
    let icon: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 12, design: .monospaced))
        }
        .foregroundStyle(Theme.textPrimary.opacity(0.75))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Compact chip in the input bar: "PROVIDER · model ▾". Click → popover with
/// two sections (Provider / Model) the user can flip without leaving the chat.
private struct ProviderModelPicker: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatController.self) private var chat
    @Environment(ChatStore.self) private var chatStore
    @State private var open = false
    @State private var hover = false

    /// 当前 conv 锁定的 provider id;无 lock → 走全局 appState。
    private var activeIntegrationId: String? {
        if let convId = chat.currentConvId,
           let conv = chatStore.conversations.first(where: { $0.id == convId }),
           let locked = conv.providerId {
            return locked
        }
        return appState.activeAIId
    }
    private var activeIntegration: Integration? {
        guard let id = activeIntegrationId else { return nil }
        return IntegrationRegistry.all.first { $0.id == id }
    }
    private var activeModel: String {
        guard let id = activeIntegrationId else { return "" }
        // conv 有 model lock → 用 lock;否则 fallback 全局。
        if let convId = chat.currentConvId,
           let conv = chatStore.conversations.first(where: { $0.id == convId }),
           let locked = conv.model, conv.providerId == id {
            return locked
        }
        return appState.currentModel(forIntegrationId: id)
    }
    /// 当前对话已有消息 → 锁定 provider。换 provider 等于 spawn 新子进程,
    /// 历史对话只在 UI 端,新进程啥都不知道,后续回复会驴唇不对马嘴。
    /// 想换 → 用户主动开新对话(左侧栏 + 按钮)。
    private var isLocked: Bool { !chat.messages.isEmpty }

    var body: some View {
        Button { if !isLocked { open.toggle() } } label: {
            HStack(spacing: 6) {
                Text(activeIntegration?.id.uppercased() ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(isLocked ? 0.30 : 0.55))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                Text(activeModel.isEmpty ? "—" : activeModel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(isLocked ? 0.45 : 0.92))
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textPrimary.opacity(0.40))
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textPrimary.opacity(hover ? 0.85 : 0.50))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hover && !isLocked ? 0.05 : 0))
            )
        }
        .buttonStyle(.bouncyIcon)
        .disabled(isLocked)
        .help(isLocked
              ? "Provider locked for this chat — start a new chat to switch."
              : "Switch provider / model")
        .onHover { hover = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PickerPopover { open = false }
                .environment(appState)
        }
    }
}

private struct PickerPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatController.self) private var chat
    @Environment(ChatStore.self) private var chatStore
    /// Ollama 本地模型列表(observable),当前 provider 是 Ollama 时给 MODEL 段用。
    @State private var ollamaStore = OllamaModelStore.shared
    let onDismiss: () -> Void

    /// Connections 里已连接的 provider。连了就显示,不再有 AI Models 页那层
    /// "可见性"过滤(已下线)。
    private var connectedProviders: [Integration] {
        IntegrationRegistry.all.filter {
            appState.isConnected($0.id)
            && Provider.from(integrationId: $0.id) != nil
        }
    }

    /// 当前 conv 的 provider 锁定值;nil = 没 conv 或没锁,回退全局 appState。
    private var effectiveActiveProviderId: String? {
        if let convId = chat.currentConvId,
           let conv = chatStore.conversations.first(where: { $0.id == convId }),
           let locked = conv.providerId {
            return locked
        }
        return appState.activeAIId
    }

    /// 当前 conv 的 model 锁定值;nil = 没 conv 或没锁,回退 appState.currentModel。
    private func effectiveModel(for integrationId: String) -> String {
        if let convId = chat.currentConvId,
           let conv = chatStore.conversations.first(where: { $0.id == convId }),
           let locked = conv.model, conv.providerId == integrationId {
            return locked
        }
        return appState.currentModel(forIntegrationId: integrationId)
    }

    /// 点 picker 时:有 conv → 写 conv lock + 同步全局(下次新 conv 继承);
    /// 没 conv → 只写全局,新建 conv 时会快照。
    private func applyProvider(_ id: String) {
        appState.activeAIId = id
        if let convId = chat.currentConvId {
            chatStore.updateConversationModel(
                convId,
                providerId: id,
                model: appState.currentModel(forIntegrationId: id)
            )
        }
    }

    private func applyModel(_ m: String, for integrationId: String) {
        appState.setModel(m, forIntegrationId: integrationId)
        if let convId = chat.currentConvId {
            chatStore.updateConversationModel(
                convId,
                providerId: integrationId,
                model: m
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("PROVIDER")
            if connectedProviders.isEmpty {
                Text("No AI providers connected.\nGo to Connections to add one.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(connectedProviders) { i in
                    pickerRow(
                        title: i.name,
                        subtitle: i.id,
                        icon: "circle.fill",
                        iconColor: i.accent,
                        active: effectiveActiveProviderId == i.id
                    ) {
                        applyProvider(i.id)
                    }
                }
            }

            if let activeId = effectiveActiveProviderId,
               let provider = Provider.from(integrationId: activeId) {
                Divider().background(Color.primary.opacity(0.12))
                    .padding(.vertical, 4)
                sectionHeader("MODEL")
                // Ollama 读用户本地实际安装的模型(observable);其它走写死的。
                let models = provider == .ollama ? ollamaStore.models : provider.availableModels
                ForEach(models, id: \.self) { m in
                    pickerRow(
                        title: m,
                        subtitle: "",
                        icon: nil,
                        iconColor: nil,
                        active: effectiveModel(for: activeId) == m,
                        mono: true
                    ) {
                        applyModel(m, for: activeId)
                        onDismiss()
                    }
                }
            }
        }
        // 当前 provider 是 Ollama → 拉一次本地模型列表。
        .task(id: effectiveActiveProviderId) {
            if effectiveActiveProviderId.flatMap(Provider.from(integrationId:)) == .ollama {
                await ollamaStore.refresh()
            }
        }
        .frame(width: 240)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
        )
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Theme.textPrimary.opacity(0.45))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }

    private func pickerRow(title: String, subtitle: String,
                           icon: String?, iconColor: Color?,
                           active: Bool, mono: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon, let iconColor {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                        .foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium,
                                      design: mono ? .monospaced : .default))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.40))
                    }
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.purple.opacity(0.9))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                Color.white.opacity(active ? 0.05 : 0)
            )
        }
        .buttonStyle(.bouncyIcon)
    }
}

// MARK: - Image Lightbox (full-screen, borderless NSWindow)

/// 单例:负责开 / 关全屏图片查看器。仿 Claude desktop —— 一个独立的
/// borderless NSWindow 盖在整个 screen 上,不受 SwiftUI view tree
/// 父布局限制(之前用 .overlay 只能盖 HomeView 区,侧栏还露出来)。
///
/// 关闭路径:点黑底背景 / 点右上角 × / 按 ESC / 调 close()。
@MainActor
final class ImageLightboxController {
    static let shared = ImageLightboxController()
    private var window: NSWindow?
    private init() {}

    func show(attachment: Attachment) {
        close()   // 旧的先关
        // 找到主 app window —— lightbox 只覆盖它的 frame,不占整个 screen。
        // 仿 Claude desktop:模态盒子限在 app 内,周围系统 UI 仍可见。
        // keyWindow 在 inactive app 切回来那一瞬可能为 nil,回退 mainWindow。
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        let w = LightboxWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = host.level             // 跟随父窗口层级,不抢系统其它 UI
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.ignoresMouseEvents = false
        w.hasShadow = false
        w.isReleasedWhenClosed = false   // 我们自己持引用 + 复用 close()
        w.contentView = NSHostingView(rootView:
            ImageLightboxView(attachment: attachment) { [weak self] in self?.close() }
        )
        // 加成 child window:lightbox 自动跟随主 window 的 move / minimize / close,
        // 不用我们另起监听。
        host.addChildWindow(w, ordered: .above)
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }

    func close() {
        if let w = window, let parent = w.parent {
            parent.removeChildWindow(w)
        }
        window?.orderOut(nil)
        window = nil
    }
}

/// borderless NSWindow 默认 canBecomeKey=false,override 让它能接键盘事件。
private final class LightboxWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Lightbox 的 SwiftUI 内容。被 NSHostingView 装进 LightboxWindow。
private struct ImageLightboxView: View {
    let attachment: Attachment
    let onClose: () -> Void
    private var image: NSImage? { NSImage(contentsOf: attachment.url) }

    var body: some View {
        ZStack {
            // 整屏深色背景 — 点哪儿都关闭。
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 10) {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                        // 吞 tap —— 只点背景才关闭。
                        .contentShape(Rectangle())
                        .onTapGesture { /* swallow */ }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("Could not load image")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Text(attachment.displayName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 18)
            }

            // 右上角关闭按钮(visible + 带 ESC 快捷键)。
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close (Esc)")
                    .padding(20)
                }
                Spacer()
            }
        }
    }
}
