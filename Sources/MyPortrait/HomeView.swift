import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatController.self) private var chat
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
    @State private var suggestions = SuggestionEngine.shared
    @State private var templates = TemplateLibrary.shared
    @State private var editingTemplate: SummaryTemplate? = nil

    private func runTemplate(_ t: SummaryTemplate) {
        let chips = [t.window.resolveChip()].compactMap { $0 }
        let redact = redactPII
        chat.send(t.prompt, chips: chips, redactPII: redact)
    }

    /// AI-generated chips if we have any, else the seed list.
    private var displayedActivityChips: [ActivityChip] {
        if suggestions.items.isEmpty {
            return Mock.activityChips
        }
        return suggestions.items.map { ActivityChip(text: $0, hint: nil) }
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
            if chat.messages.isEmpty {
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

            ChatInputBar(
                prompt: $prompt,
                providerName: appState.activeAI?.name ?? "ChatGPT",
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
            // Refresh on first show if cache is missing / stale.
            if suggestions.items.isEmpty || suggestions.isStale {
                suggestions.refresh()
            }
        }
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
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                Text("How can I help, Joy?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                Text("One-click summaries from your screen activity")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
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
                Text("BASED ON YOUR ACTIVITY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                Button { suggestions.refresh() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .rotationEffect(.degrees(suggestions.state == .loading ? 360 : 0))
                        .animation(
                            suggestions.state == .loading
                                ? .linear(duration: 1.0).repeatForever(autoreverses: false)
                                : .default,
                            value: suggestions.state
                        )
                }
                .buttonStyle(.plain)
                .help("Refresh suggestions")
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(displayedActivityChips) { chip in
                    ActivityChipView(chip: chip) {
                        prompt = chip.text
                        send()
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
            chat.editAndResend(id, newText: trimmed.isEmpty ? "(attachments only)" : trimmed)
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

/// Flatten an assistant `ChatMessage`'s mixed parts (text + tool blocks +
/// thinking) into one plain-text string suitable for the clipboard.
private func plainTextOf(_ m: ChatMessage) -> String {
    if m.role == .user || m.parts.isEmpty { return m.text }
    var out: [String] = []
    for part in m.parts {
        switch part {
        case .text(_, let v):
            out.append(v)
        case .tool(let b):
            out.append("$ \(b.command)")
            if !b.output.isEmpty { out.append(b.output) }
        case .thinking(let b):
            if !b.text.isEmpty { out.append("[thinking] \(b.text)") }
        case .error(let b):
            out.append("[error] \(b.message)")
        }
    }
    return out.joined(separator: "\n\n")
}

/// Slim banner shown above the chat when AI setup is in progress or failed.
private struct SetupBanner: View {
    let text: String
    let isError: Bool
    var body: some View {
        HStack(spacing: 8) {
            if !isError { ProgressView().controlSize(.small).tint(.white.opacity(0.6)) }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isError ? Color.red.opacity(0.9) : Color.white.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isError ? Color.red.opacity(0.10) : Color.white.opacity(0.04))
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                        // The streaming assistant bubble is always the last
                        // assistant message; only it should glow.
                        let isLastAssistant = idx == messages.count - 1 && msg.role == .assistant
                        ChatBubble(
                            message: msg,
                            isStreaming: isLastAssistant && isThinking,
                            chips: chipsLookup?(msg.id) ?? [],
                            attachments: attachmentsLookup?(msg.id) ?? [],
                            citations: citationsLookup?(msg.id) ?? [],
                            onCopy: { onCopy(msg) },
                            onRegenerate: { onRegenerate(msg.id) },
                            onEdit: { onEdit(msg) }
                        )
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
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: isThinking) {
                if isThinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let chips: [ContextChip]
    let attachments: [Attachment]
    let citations: [Citation]
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    @State private var appear = false
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BubbleAvatar(role: message.role, glowing: message.role == .assistant && isStreaming)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(message.role == .user ? "You" : "Assistant")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    if hover, !isStreaming {
                        BubbleActions(role: message.role,
                                      onCopy: onCopy,
                                      onRegenerate: onRegenerate,
                                      onEdit: onEdit)
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .trailing)))
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
                            AttachmentThumb(attachment: att, onRemove: {})
                                .scaleEffect(0.78, anchor: .leading)
                                .frame(width: 42, height: 42)
                                .allowsHitTesting(false)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if message.role == .user {
                    Text(.init(message.text))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.96))
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
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appear = true }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.18)) { hover = h }
        }
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
                .foregroundStyle(.white.opacity(0.40))
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
                    .foregroundStyle(.white.opacity(0.85))
                Text(citation.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            Image(systemName: actionIcon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(hover ? 0.85 : 0.40))
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
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
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
            ForEach(parts) { part in
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
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: parts.count)
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
                        .foregroundStyle(.white.opacity(0.95))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() }
                } label: {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if showDetails {
                Divider().background(Color.white.opacity(0.10))
                ScrollView {
                    Text(block.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
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
            return "Re-sign in to ChatGPT from Connections to continue."
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
    @State private var expanded: Bool = true
    @State private var didAutoCollapse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, !block.text.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                ScrollView {
                    Text(block.text)
                        .font(.system(size: 12, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
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
                    .foregroundStyle(.white.opacity(0.75))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                if block.isRunning {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.7))
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
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
        block.isRunning ? Color.cyan.opacity(0.40) : Color.white.opacity(0.10)
    }
}

/// Compact tool card — mirrors Orphies behaviour:
///   - Running: header + spinner + live command + live output
///   - Finished: collapses after a short delay to a single-line friendly label
///     ("Ran `pwd && ls`", "Read App.swift") that the user can click to expand.
private struct ToolCard: View {
    let block: ToolBlock
    @State private var expanded: Bool = true
    /// Set to true once we've kicked off the auto-collapse so we don't run the
    /// timer every time SwiftUI rebuilds the view.
    @State private var didScheduleAutoCollapse: Bool = false

    /// Delay between a tool finishing and the card collapsing to a one-liner.
    private static let autoCollapseDelay: TimeInterval = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                if !block.command.isEmpty {
                    Divider().background(Color.white.opacity(0.08))
                    Text(block.command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !block.output.isEmpty {
                    Divider().background(Color.white.opacity(0.08))
                    ScrollView {
                        Text(block.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
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
                    .foregroundStyle(.white.opacity(0.75))
                if expanded {
                    Text(block.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text(friendlyLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                statusBadge
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, expanded ? 9 : 10)
        }
        .buttonStyle(.plain)
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
        if block.isError    { return Color.red.opacity(0.40) }
        if block.isRunning  { return Color.purple.opacity(0.45) }
        return Color.white.opacity(0.12)
    }

    @ViewBuilder private var statusBadge: some View {
        if block.isRunning {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white.opacity(0.7))
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
                .foregroundStyle(.white.opacity(0.95))
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
                        .foregroundStyle(.white.opacity(0.95))
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
                    .foregroundStyle(.white.opacity(0.55))
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
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(template.subtitle.isEmpty ? template.window.label : template.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
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
        .buttonStyle(.plain)
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
                    .foregroundStyle(.white.opacity(hover ? 0.85 : 0.45))
                Text("New shortcut")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(hover ? 0.75 : 0.45))
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
        .buttonStyle(.plain)
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

private struct SuggestionCardView: View {
    let card: SuggestionCard
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.emoji).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(card.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
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
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
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
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let hint = chip.hint {
                    Text(hint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
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
        .buttonStyle(.plain)
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
                        .foregroundStyle(.white.opacity(0.45))
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
                TextField(
                    "",
                    text: $prompt,
                    prompt: Text("Ask about your screen…  (type @ for filters, paste images)")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.30)),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused($focused)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                    onSend()
                    return .handled
                }
                .onChange(of: prompt) { oldValue, newValue in
                    // Strip the typed `@` and pop the picker so the input
                    // doesn't carry a stray character.
                    if newValue.count > oldValue.count,
                       newValue.hasSuffix("@") {
                        prompt = String(newValue.dropLast())
                        withAnimation(.easeOut(duration: 0.15)) { pickerOpen = true }
                    }
                }
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
    @State private var hover = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.75))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
        .onHover { hover = $0 }
    }
    @ViewBuilder private var content: some View {
        if attachment.kind == .image, let img = NSImage(contentsOf: attachment.url) {
            Image(nsImage: img)
                .resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.7))
        } else {
            VStack(spacing: 4) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                Text(attachment.displayName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 50)
            }
            .frame(width: 56, height: 52)
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
                .foregroundStyle(tint ?? .white.opacity(hover ? 0.95 : 0.55))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(tint != nil ? 0.80 : (hover ? 0.80 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke((tint ?? Color.white).opacity(tint != nil ? 0.45 : (hover ? 0.18 : 0)), lineWidth: 0.6)
                        )
                )
                .scaleEffect(pressed ? 0.90 : (hover ? 1.04 : 1.0))
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
                    .foregroundStyle(.white.opacity(enabled ? 0.97 : 0.45))
                    .offset(x: pressed ? 1 : 0, y: pressed ? 1 : 0)
            }
            .scaleEffect(pressed ? 0.92 : (hover ? 1.04 : 1.0))
        }
        .buttonStyle(.plain)
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
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Compact chip in the input bar: "PROVIDER · model ▾". Click → popover with
/// two sections (Provider / Model) the user can flip without leaving the chat.
private struct ProviderModelPicker: View {
    @Environment(AppState.self) private var appState
    @State private var open = false
    @State private var hover = false

    private var activeIntegration: Integration? { appState.activeAI }
    private var activeProvider: Provider? {
        activeIntegration.flatMap { Provider.from(integrationId: $0.id) }
    }
    private var activeModel: String {
        guard let id = activeIntegration?.id else { return "" }
        return appState.currentModel(forIntegrationId: id)
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(activeIntegration?.id.uppercased() ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                Text(activeModel.isEmpty ? "—" : activeModel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(hover ? 0.85 : 0.50))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hover ? 0.05 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PickerPopover { open = false }
                .environment(appState)
        }
    }
}

private struct PickerPopover: View {
    @Environment(AppState.self) private var appState
    let onDismiss: () -> Void

    private var connectedProviders: [Integration] {
        IntegrationRegistry.all.filter {
            appState.isConnected($0.id) && Provider.from(integrationId: $0.id) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("PROVIDER")
            if connectedProviders.isEmpty {
                Text("No AI providers connected.\nGo to Connections to add one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(connectedProviders) { i in
                    pickerRow(
                        title: i.name,
                        subtitle: i.id,
                        icon: "circle.fill",
                        iconColor: i.accent,
                        active: appState.activeAIId == i.id
                    ) {
                        appState.activeAIId = i.id
                    }
                }
            }

            if let activeId = appState.activeAIId,
               let provider = Provider.from(integrationId: activeId) {
                Divider().background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)
                sectionHeader("MODEL")
                ForEach(provider.availableModels, id: \.self) { m in
                    pickerRow(
                        title: m,
                        subtitle: "",
                        icon: nil,
                        iconColor: nil,
                        active: appState.currentModel(forIntegrationId: activeId) == m,
                        mono: true
                    ) {
                        appState.setModel(m, forIntegrationId: activeId)
                        onDismiss()
                    }
                }
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
            .foregroundStyle(.white.opacity(0.45))
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
                        .foregroundStyle(.white.opacity(0.95))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.40))
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
        .buttonStyle(.plain)
    }
}
