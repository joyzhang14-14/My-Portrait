import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatController.self) private var chat
    @State private var prompt: String = ""
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
        .background(AmbientBackground())
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
                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                        // The streaming assistant bubble is always the last
                        // assistant message; only it should glow.
                        let isLastAssistant = idx == messages.count - 1 && msg.role == .assistant
                        ChatBubble(message: msg, isStreaming: isLastAssistant && isThinking)
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
    @State private var appear = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BubbleAvatar(role: message.role, glowing: message.role == .assistant && isStreaming)
            VStack(alignment: .leading, spacing: 10) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.45))

                if message.role == .user {
                    Text(.init(message.text))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.96))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(5)
                } else {
                    AssistantBody(parts: message.parts, fallbackText: message.text)
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
    }
}

/// Sequentially renders text + tool blocks for an assistant message.
private struct AssistantBody: View {
    let parts: [ContentPart]
    let fallbackText: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if parts.isEmpty && !fallbackText.isEmpty {
                Text(.init(fallbackText))
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.96))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(5)
            }
            ForEach(parts) { part in
                switch part {
                case .text(_, let value):
                    Text(.init(value))
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.96))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(5)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                case .tool(let block):
                    ToolCard(block: block)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: parts.count)
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
        VStack(spacing: 10) {
            // Top chip row inside the glass panel
            HStack(spacing: 10) {
                ChipButton(icon: "line.3.horizontal.decrease", label: "filter")
                Text(providerName.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(isConnected ? .white.opacity(0.80) : .white.opacity(0.40))
                if !isConnected {
                    Text("(not connected)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.80))
                }
                Spacer()
                ModelPickerInline(slug: providerSlug)
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

                HStack(spacing: 4) {
                    IconActionButton(icon: "shield") { /* TODO */ }
                    IconActionButton(icon: "paperclip") { /* TODO */ }
                    SendButton(action: onSend, enabled: !prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command])
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
        .onChange(of: prompt) { _ = onChipTap }
    }
}

// MARK: - Input bar right-side actions

/// Generic icon button (shield / paperclip). 17pt symbol, hover lifts +
/// glass background appears, click pop.
private struct IconActionButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.55))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(hover ? 0.80 : 0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(hover ? 0.18 : 0), lineWidth: 0.6)
                        )
                )
                .scaleEffect(pressed ? 0.90 : (hover ? 1.04 : 1.0))
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
