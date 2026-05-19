import SwiftUI
import AppKit

/// Matches Orphies' Settings → Connections layout:
///   ┌───────────────────────────────────┐
///   │ Description text                  │
///   │ Search bar                        │
///   │ 3-column grid of square tiles     │
///   │ Expanded panel below (if clicked) │
///   └───────────────────────────────────┘
struct ConnectionsView: View {
    @Environment(AppState.self) private var appState
    @State private var search: String = ""
    @State private var selectedId: String? = nil
    @State private var connecting: String? = nil
    @State private var loginError: String? = nil
    @State private var apiKeyDraft: String = ""

    private var filteredTiles: [Integration] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return IntegrationRegistry.all }
        return IntegrationRegistry.all.filter { $0.name.lowercased().contains(q) }
    }

    private var selectedIntegration: Integration? {
        guard let id = selectedId else { return nil }
        return IntegrationRegistry.all.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connections")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))

                Text("Give AI access to your memory, and connect to the apps you use every day")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))

                searchField

                grid

                if let sel = selectedIntegration {
                    expandedPanel(for: sel)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }

    // search
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
            TextField("search connections…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
    }

    // grid
    private var grid: some View {
        let cols = [GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(filteredTiles) { tile in
                IntegrationTile(
                    integration: tile,
                    isConnected: appState.isConnected(tile.id),
                    isSelected: selectedId == tile.id
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedId = (selectedId == tile.id) ? nil : tile.id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func expandedPanel(for integration: Integration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IntegrationIcon(integration: integration, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(integration.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(integration.category.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if appState.isConnected(integration.id) {
                    StatusPill(text: appState.activeAIId == integration.id ? "ACTIVE" : "CONNECTED",
                               color: appState.activeAIId == integration.id ? .green : .white.opacity(0.6))
                }
                Spacer()
                Button { selectedId = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color.white.opacity(0.08))

            Text(descriptionFor(integration))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if let loginError, selectedId == integration.id {
                Text(loginError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.bottom, 2)
            }

            // API key input — appears for unconnected `.apiKey` integrations.
            if !appState.isConnected(integration.id),
               integration.signInMethod == .apiKey {
                SecureField("paste API key…", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
            }

            HStack(spacing: 8) {
                if appState.isConnected(integration.id) {
                    if integration.category == .ai && appState.activeAIId != integration.id {
                        Button("Make active for chat") { appState.activeAIId = integration.id }
                            .buttonStyle(SubtleButton())
                    }
                    Button("Disconnect", role: .destructive) {
                        disconnect(integration)
                    }
                    .buttonStyle(SubtleButton(destructive: true))
                } else {
                    Button(action: { startConnect(integration) }) {
                        HStack(spacing: 6) {
                            if connecting == integration.id {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: signInIcon(for: integration))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(signInLabel(for: integration))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(integration.accent.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .disabled(connecting != nil)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }

    /// Route the connect button to the right backend:
    ///   ChatGPT       → OAuth PKCE
    ///   Ollama        → probe localhost:11434
    ///   API-key       → save key to SecretStore
    ///   localApp      → NSWorkspace probe of the bundleId
    ///   systemAccess  → open System Settings → Privacy
    ///   other OAuth   → not wired yet; surfaces an inline error
    private func startConnect(_ integration: Integration) {
        loginError = nil
        if integration.id == "chatgpt" {
            connectChatGPT(integration)
        } else if integration.id == "ollama" {
            connectOllama(integration)
        } else if integration.signInMethod == .apiKey {
            connectAPIKey(integration)
        } else if integration.signInMethod == .localApp {
            connectLocalApp(integration)
        } else if integration.signInMethod == .systemAccess {
            connectSystemAccess(integration)
        } else {
            // OAuth providers we haven't wired per-provider flows for yet
            // (Notion, Linear, Spotify, Google Calendar…). Be honest about
            // the gap instead of fake-toggling.
            loginError = "\(integration.name) sign-in isn't available yet."
        }
    }

    /// Wipe the credential on disconnect so the next connect starts clean.
    private func disconnect(_ integration: Integration) {
        if integration.id == "chatgpt" { ChatGPTOAuth.logout() }
        if let p = Provider.from(integrationId: integration.id),
           let key = p.secretKey {
            SecretStore.shared.delete(key)
        }
        appState.toggleConnect(integration)
        // Re-write models.json without this provider so Pi stops listing it.
        try? PiInstaller.writeModelsJSON(providers: stillConfiguredProviders())
    }

    private func connectAPIKey(_ integration: Integration) {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            loginError = "Paste your API key first."
            return
        }
        guard let provider = Provider.from(integrationId: integration.id),
              let key = provider.secretKey else {
            loginError = "Provider not supported yet."
            return
        }
        do {
            try SecretStore.shared.set(key, value: Data(trimmed.utf8))
            apiKeyDraft = ""
            if !appState.isConnected(integration.id) { appState.toggleConnect(integration) }
            try PiInstaller.writeModelsJSON(providers: stillConfiguredProviders())
        } catch {
            loginError = error.localizedDescription
        }
    }

    private func connectOllama(_ integration: Integration) {
        connecting = integration.id
        Task {
            let ok = await probeOllama()
            await MainActor.run {
                connecting = nil
                if ok {
                    if !appState.isConnected(integration.id) {
                        appState.toggleConnect(integration)
                    }
                    try? PiInstaller.writeModelsJSON(providers: stillConfiguredProviders())
                } else {
                    loginError = "Couldn't reach Ollama at http://localhost:11434. Is it running?"
                }
            }
        }
    }

    private func probeOllama() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }

    /// Snapshot of providers the user is currently connected to. Used to
    /// rewrite models.json after a connect/disconnect.
    private func stillConfiguredProviders() -> [Provider] {
        var out: [Provider] = []
        if ChatGPTOAuth.isLoggedIn() { out.append(.chatgpt) }
        for id in appState.connectedIds {
            if let p = Provider.from(integrationId: id), !out.contains(p) {
                out.append(p)
            }
        }
        return out
    }

    private func connectChatGPT(_ integration: Integration) {
        connecting = integration.id
        Task {
            do {
                _ = try await ChatGPTOAuth.login()
                await MainActor.run {
                    if !appState.isConnected(integration.id) {
                        appState.toggleConnect(integration)
                    }
                    connecting = nil
                }
            } catch {
                await MainActor.run {
                    loginError = error.localizedDescription
                    connecting = nil
                }
            }
        }
    }

    /// LocalApp integrations (Claude Desktop, Cursor, Obsidian, …): check
    /// that the app is actually installed by asking NSWorkspace for the
    /// bundleId. No network, no fake delay.
    private func connectLocalApp(_ integration: Integration) {
        guard let bundleId = integration.bundleId else {
            loginError = "\(integration.name) doesn't expose a bundle ID we can probe."
            return
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
            appState.toggleConnect(integration)
            return
        }
        loginError = "\(integration.name) isn't installed (bundle \(bundleId) not found)."
    }

    /// SystemAccess integrations (Apple Calendar, Voice Memos, Apple
    /// Intelligence): TCC permission lives in System Settings → Privacy.
    /// Open the right pane and mark connected — the actual permission grant
    /// happens out of process; we trust the user's intent here.
    private func connectSystemAccess(_ integration: Integration) {
        let pane: String = {
            switch integration.id {
            case "apple-calendar":     return "Privacy_Calendars"
            case "voice-memos":        return "Privacy_Microphone"
            default:                   return "Privacy_AppleIntelligenceReport"
            }
        }()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
        appState.toggleConnect(integration)
    }

    private func signInIcon(for i: Integration) -> String {
        switch i.signInMethod {
        case .oauth: return "person.fill.badge.plus"
        case .apiKey: return "key.fill"
        case .localApp: return "arrow.down.app.fill"
        case .systemAccess: return "lock.open.fill"
        }
    }
    private func signInLabel(for i: Integration) -> String {
        switch i.signInMethod {
        case .oauth: return "Sign in with \(i.name)"
        case .apiKey: return "Add API key"
        case .localApp: return "Detect \(i.name)"
        case .systemAccess: return "Grant access"
        }
    }
    private func descriptionFor(_ i: Integration) -> String {
        switch i.id {
        case "chatgpt":     return "Sign in with your ChatGPT Plus / Pro account. No API key needed."
        case "claude":      return "Connect Claude Desktop via MCP. Lets Claude query your screen history."
        case "claude-code": return "Add this project to Claude Code's MCP registry."
        case "anthropic-api": return "Use your Anthropic API key. Pay-per-token, lowest latency."
        case "gemini":      return "Google AI Studio API key. Free tier available."
        case "perplexity":  return "Perplexity API for web-grounded answers."
        case "cursor":      return "Register MCP with Cursor's settings.json."
        case "warp":        return "Warp terminal AI integration."
        case "ollama":      return "Run open-source models on this Mac. Detects local Ollama install."
        case "lmstudio":    return "Local model runner with chat UI."
        case "msty":        return "Local AI chat app."
        case "obsidian":    return "Read & write your Obsidian vault as memory."
        case "notion":      return "Import Notion pages as context."
        case "linear":      return "Sync Linear issues."
        case "spotify":     return "Track listening history as part of activity."
        case "apple-calendar":      return "Access your local Calendar.app events."
        case "google-calendar":     return "OAuth into Google Calendar."
        case "voice-memos":         return "Read Voice Memos.app recordings."
        case "apple-intelligence":  return "On-device Apple Intelligence (macOS 26+, Apple Silicon)."
        default: return "Connect this integration to your AI."
        }
    }
}

// MARK: - Tile (3-col grid)

private struct IntegrationTile: View {
    let integration: Integration
    let isConnected: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                IntegrationIcon(integration: integration, size: 32)
                Text(integration.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.10)
                         : hover ? Color.white.opacity(0.05)
                         : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(
                            isSelected ? Color.white.opacity(0.4) : Color.white.opacity(0.10),
                            lineWidth: 1
                        )
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isConnected {
                    Circle().fill(Color.green)
                        .frame(width: 7, height: 7)
                        .padding(7)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct IntegrationIcon: View {
    let integration: Integration
    let size: CGFloat

    @State private var realIcon: NSImage? = nil

    var body: some View {
        ZStack {
            if let img = realIcon {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                // Brand-color letter glyph fallback (NOT an SF Symbol).
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(integration.accent)
                Text(integration.letter)
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(luminance(integration.accent) > 0.55 ? .black : .white)
            }
        }
        .frame(width: size, height: size)
        .task(id: integration.id) { await tryLoadRealIcon() }
    }

    private func tryLoadRealIcon() async {
        let bid = integration.bundleId
        let img = await Task.detached(priority: .userInitiated) {
            AppIconLoader.icon(forBundleId: bid)
        }.value
        if let img { self.realIcon = img }
    }

    /// Approximate perceived brightness — for choosing black vs white letter.
    private func luminance(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return 0.299 * Double(ns.redComponent) + 0.587 * Double(ns.greenComponent) + 0.114 * Double(ns.blueComponent)
    }
}

// MARK: - Shared bits

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }
}

private struct SubtleButton: ButtonStyle {
    var destructive: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? Color.red.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(destructive ? Color.red.opacity(0.4) : Color.white.opacity(0.18), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0.02)))
            )
    }
}
