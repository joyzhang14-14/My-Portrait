import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var prompt: String = ""
    @State private var chat = ChatController()
    @State private var setup = AISetup.shared

    var body: some View {
        VStack(spacing: 0) {
            if let banner = setupBannerText {
                SetupBanner(text: banner, isError: setupIsError)
            }
            if chat.messages.isEmpty {
                ScrollView { greetingContent }
            } else {
                ChatTranscript(messages: chat.messages, isThinking: chat.isStreaming)
            }

            ChatInputBar(
                prompt: $prompt,
                providerName: appState.activeAI?.name ?? "ChatGPT",
                providerSlug: appState.activeAI?.id.uppercased() ?? "OPENAI-CHATGPT",
                isConnected: appState.activeAI != nil,
                onSend: send,
                onChipTap: { chipText in
                    prompt = chipText
                    send()
                }
            )
        }
        .background(Color.black)
        .task { AISetup.shared.ensureInstalled() }
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
                ForEach(Mock.suggestionCards) { card in
                    SuggestionCardView(card: card) {
                        prompt = card.title
                        send()
                    }
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 6) {
                Text("BASED ON YOUR ACTIVITY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(Mock.activityChips) { chip in
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
        guard !trimmed.isEmpty else { return }
        prompt = ""
        chat.send(trimmed)
    }
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(messages) { msg in
                        ChatBubble(message: msg)
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
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BubbleAvatar(role: message.role)
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(.init(message.text))     // initializer with `LocalizedStringKey` parses basic markdown
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

/// Shared avatar used by user, assistant, and the streaming-dots placeholder.
private struct BubbleAvatar: View {
    let role: ChatRole
    var body: some View {
        ZStack {
            if role == .assistant {
                LinearGradient(
                    colors: [Color(red: 0.55, green: 0.27, blue: 0.85),
                             Color(red: 0.30, green: 0.15, blue: 0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .clipShape(Circle())
            } else {
                Circle().fill(Color.white.opacity(0.14))
            }
            Image(systemName: role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: 34, height: 34)
    }
}

private struct ChatThinking: View {
    @State private var phase = 0
    private let dots = ["·  ·  ·", "•  ·  ·", "·  •  ·", "·  ·  •"]
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BubbleAvatar(role: .assistant)
            Text(dots[phase])
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 8)
                .onAppear {
                    Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                        Task { @MainActor in phase = (phase + 1) % dots.count }
                    }
                }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Suggestion cards / chips

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
    let onSend: () -> Void
    let onChipTap: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ChipButton(icon: "line.3.horizontal.decrease", label: "filter")
                Text(providerName.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isConnected ? .white.opacity(0.78) : .white.opacity(0.4))
                if !isConnected {
                    Text("(not connected)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.75))
                }
                Spacer()
                ModelPickerInline(slug: providerSlug)
            }
            .padding(.horizontal, 16)

            HStack(alignment: .center, spacing: 8) {
                // Auto-growing single-line-by-default field. Up to ~6 lines, then scrolls.
                TextField(
                    "",
                    text: $prompt,
                    prompt: Text("Ask about your screen…  (type @ for filters, paste images)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.32)),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10), lineWidth: 1))
                )
                .focused($focused)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                    onSend()
                    return .handled
                }

                HStack(spacing: 4) {
                    IconActionButton(icon: "shield") { /* TODO */ }
                    IconActionButton(icon: "paperclip") { /* TODO */ }
                    SendButton(action: onSend)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .onAppear { focused = true }
        // keep onChipTap referenced for compiler; chips are wired via greeting buttons
        .onChange(of: prompt) { _ = onChipTap }
    }
}

// MARK: - Input bar right-side actions

/// Generic icon button (shield / paperclip). 18pt symbol, hover lifts to white,
/// 6pt corner-rounded background on press.
private struct IconActionButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(hover ? 0.92 : 0.55))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(pressed ? 0.10 : (hover ? 0.05 : 0)))
                )
                .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                .onEnded   { _ in withAnimation(.easeOut(duration: 0.12)) { pressed = false } }
        )
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Primary send button — solid white background, hover brightens, click pops.
private struct SendButton: View {
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(pressed ? 0.85 : (hover ? 1.0 : 0.92)))
                )
                .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                .onEnded   { _ in withAnimation(.easeOut(duration: 0.12)) { pressed = false } }
        )
        .animation(.easeOut(duration: 0.12), value: hover)
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

private struct ModelPickerInline: View {
    let slug: String
    var body: some View {
        HStack(spacing: 8) {
            Text(slug)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
            HStack(spacing: 4) {
                Text("GPT-5.4")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}
