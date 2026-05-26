import SwiftUI
import AppKit
import EventKit

/// Matches Orphies' Settings → Connections layout:
///   ┌───────────────────────────────────┐
///   │ Description text                  │
///   │ Search bar                        │
///   │ 3-column grid of square tiles     │
///   │ Expanded panel below (if clicked) │
///   └───────────────────────────────────┘
struct ConnectionsView: View {
    /// 限制只展示某几个 category 的 tile —— onboarding "Connect an AI" 步用,
    /// 只让 AI/local 出现。nil = 全量。
    var categoryFilter: Set<Integration.Category>? = nil
    /// 内嵌进 onboarding 时把 "Connections" 标题 + 描述句藏掉,避免跟外层
    /// 标题打架。Settings 里走默认 true。
    var showsHeader: Bool = true

    @Environment(AppState.self) private var appState
    @State private var search: String = ""
    @State private var selectedId: String? = nil
    @State private var connecting: String? = nil
    @State private var loginError: String? = nil
    @State private var apiKeyDraft: String = ""
    // SMTP form drafts — only used by the `.smtp` integration panel.
    @State private var smtpHost: String = ""
    @State private var smtpPort: String = "587"
    @State private var smtpUser: String = ""
    @State private var smtpPass: String = ""
    @State private var smtpTestTo: String = ""
    // Currently-selected Obsidian vault path, mirrored from SecretStore.
    @State private var obsidianVaultPath: String? = ObsidianConfig.vaultPath

    /// 走 categoryFilter 限定后的全集。filteredTiles / selectedIntegration 都
    /// 基于这个,确保 onboarding 里点不出非 AI 的 tile。
    private var scopedTiles: [Integration] {
        guard let filter = categoryFilter else { return IntegrationRegistry.all }
        return IntegrationRegistry.all.filter { filter.contains($0.category) }
    }

    private var filteredTiles: [Integration] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scopedTiles }
        return scopedTiles.filter { $0.name.lowercased().contains(q) }
    }

    private var selectedIntegration: Integration? {
        guard let id = selectedId else { return nil }
        return scopedTiles.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeader {
                    Text("Connections")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Text("Give AI access to your memory, and connect to the apps you use every day")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }

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
        .background(SidebarBackdrop().ignoresSafeArea())
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
                        // 切 tile 清掉上一个 tile 留下的报错(如 "Claude Code
                        // doesn't expose a bundle ID"),避免出现在不相关 tile
                        // 的展开面板里。
                        loginError = nil
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
                .buttonStyle(.bouncyIcon)
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

            // SMTP form — appears for the unconnected `.smtp` integration.
            if !appState.isConnected(integration.id),
               integration.signInMethod == .smtp {
                VStack(spacing: 8) {
                    smtpField("SMTP host (e.g. smtp.gmail.com)", text: $smtpHost)
                    smtpField("Port (e.g. 587)", text: $smtpPort)
                    smtpField("Username / email", text: $smtpUser)
                    smtpSecureField("Password / app password", text: $smtpPass)
                    smtpField("Test recipient (blank = send to yourself)", text: $smtpTestTo)
                }
            }

            // Obsidian vault path — cronJobs need the git repo location, which
            // the `.localApp` probe alone doesn't tell us.
            if integration.id == "obsidian" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OBSIDIAN VAULT PATH")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 8) {
                        Text(obsidianVaultPath ?? "No vault selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(obsidianVaultPath == nil ? 0.4 : 0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { pickObsidianVault() }
                            .buttonStyle(SubtleButton())
                    }
                }
            }

            HStack(spacing: 8) {
                if appState.isConnected(integration.id) {
                    // "Make active for chat" 移除了 —— 实际激活是从 chat picker
                    // 里选,在这放只是多余按钮。
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
                    .buttonStyle(.bouncyIcon)
                    .disabled(connecting != nil)
                }
                Spacer()
            }
        }
        .padding(16)
        .glassCard()
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
        } else if integration.id == "notion" {
            connectNotion(integration)
        } else if integration.signInMethod == .apiKey {
            connectAPIKey(integration)
        } else if integration.signInMethod == .smtp {
            connectSMTP(integration)
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
        if integration.signInMethod == .smtp {
            SecretStore.shared.delete(SMTPCredentials.ref(for: integration.id))
        }
        if integration.id == "obsidian" {
            SecretStore.shared.delete(ObsidianConfig.vaultPathRef)
        }
        if integration.id == "notion" {
            NotionConfig.deleteToken()
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

    /// Notion Internal Integration Token 流:用户从 notion.so/profile/integrations
    /// 拷的 `ntn_...` / `secret_...` token,粘进 apiKeyDraft 后调本函数。先用
    /// `GET /v1/users/me` 校验 token + 列权限,通过才存 SecretStore + 亮绿点。
    /// 校验失败不存,token 错的话用户当场看见 "Unauthorized" 而不是连完了后续静默失败。
    private func connectNotion(_ integration: Integration) {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            loginError = "Paste your Notion integration token first (starts with `ntn_` or `secret_`)."
            return
        }
        connecting = integration.id
        Task { @MainActor in
            defer { connecting = nil }
            do {
                try await verifyNotionToken(trimmed)
                try NotionConfig.setToken(trimmed)
                apiKeyDraft = ""
                if !appState.isConnected(integration.id) {
                    appState.toggleConnect(integration)
                }
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    /// `GET /v1/users/me` —— Notion 文档里 token 自检的标准 endpoint。
    /// 200 = ok,401 = token 错,其它 = 网络/服务异常。
    private func verifyNotionToken(_ token: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/users/me")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Notion", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response from Notion."])
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw NSError(domain: "Notion", code: 401, userInfo: [
                NSLocalizedDescriptionKey:
                    "Notion rejected the token (401 Unauthorized). Double-check the token from notion.so/profile/integrations."
            ])
        default:
            throw NSError(domain: "Notion", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey:
                    "Notion returned HTTP \(http.statusCode). Try again in a moment."
            ])
        }
    }

    /// SMTP integration: collect host / port / user / password, then — like
    /// screenpipe's `test()` — actually send one verification email. Only if
    /// that succeeds do we save the credentials as a single JSON blob in
    /// SecretStore under `smtp:<id>`. The password never touches UserDefaults.
    private func connectSMTP(_ integration: Integration) {
        let host = smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = smtpUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = smtpPass
        guard !host.isEmpty, !port.isEmpty, !user.isEmpty, !pass.isEmpty else {
            loginError = "Fill in host, port, username and password."
            return
        }
        guard let portNum = Int(port) else {
            loginError = "Port must be a number (e.g. 465 or 587)."
            return
        }
        // From = username; To = test recipient, defaulting to self.
        let toTrimmed = smtpTestTo.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = toTrimmed.isEmpty ? user : toTrimmed

        connecting = integration.id
        Task {
            do {
                try await SMTPClient.sendTestEmail(host: host, port: portNum,
                                                   username: user, password: pass,
                                                   from: user, to: recipient)
                let creds = SMTPCredentials(host: host, port: port,
                                            username: user, password: pass,
                                            testRecipient: toTrimmed)
                try SecretStore.shared.setJSON(SMTPCredentials.ref(for: integration.id), creds)
                await MainActor.run {
                    smtpHost = ""; smtpPort = "587"; smtpUser = ""; smtpPass = ""; smtpTestTo = ""
                    connecting = nil
                    if !appState.isConnected(integration.id) { appState.toggleConnect(integration) }
                }
            } catch {
                await MainActor.run {
                    connecting = nil
                    loginError = "Test email failed — credentials not saved. \(error.localizedDescription)"
                }
            }
        }
    }

    private func smtpField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
    }

    private func smtpSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
    }

    /// Open an NSOpenPanel to pick the Obsidian vault directory and save its
    /// path to SecretStore. Independent of the `.localApp` install probe.
    private func pickObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as vault"
        panel.message = "Select your Obsidian vault folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ObsidianConfig.setVaultPath(url.path)
            obsidianVaultPath = url.path
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
        // claude-code:真发一句 "hi" 看 CLI 能不能拿到回复。仅"binary 存在"
        // 不够 —— 用户可能没 `claude login`、登录态过期、模型 API 挂等。
        if integration.id == "claude-code" {
            connecting = integration.id
            Task { @MainActor in
                defer { connecting = nil }
                do {
                    _ = try await ClaudeCodeAgent.probeConnection()
                    appState.toggleConnect(integration)
                } catch {
                    loginError = error.localizedDescription
                }
            }
            return
        }
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
    /// Apple Calendar 走 EventKit:第一次调用 requestFullAccessToEvents 系统
    /// 会弹原生权限弹窗;之后如果用户拒了再点 Connect,我们就跳系统设置让
    /// 他改。当前 .systemAccess 只剩 apple-calendar 一个 tile —— 其它假
    /// systemAccess tile(Voice Memos / Apple Intelligence)已经从
    /// IntegrationRegistry 删掉。
    private func connectSystemAccess(_ integration: Integration) {
        guard integration.id == "apple-calendar" else {
            // 未来如果再加 systemAccess tile 走这里;现在不应触发。
            loginError = "\(integration.name) is not wired yet."
            return
        }
        connectCalendar(integration)
    }

    /// Apple Calendar 真接 EventKit。三种 TCC 状态:
    ///   - notDetermined → requestFullAccessToEvents 弹原生权限对话框
    ///   - authorized / fullAccess → 直接 toggleConnect 亮绿点
    ///   - denied / restricted → 跳系统设置(API 不能再弹了)
    private func connectCalendar(_ integration: Integration) {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            if !appState.isConnected(integration.id) { appState.toggleConnect(integration) }
        case .notDetermined:
            connecting = integration.id
            let store = EKEventStore()
            store.requestFullAccessToEvents { granted, err in
                DispatchQueue.main.async {
                    self.connecting = nil
                    if granted {
                        if !self.appState.isConnected(integration.id) {
                            self.appState.toggleConnect(integration)
                        }
                    } else {
                        self.loginError = err?.localizedDescription
                            ?? "Calendar access was not granted."
                    }
                }
            }
        case .denied, .restricted, .writeOnly:
            // 走过一次拒了或只给了 write-only —— EventKit 不再弹,
            // 只能跳系统设置让用户手动改。
            loginError = "Calendar access is \(status == .writeOnly ? "write-only" : "denied"). Opening System Settings — turn on full access for My Portrait."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    private func signInIcon(for i: Integration) -> String {
        switch i.signInMethod {
        case .oauth: return "person.fill.badge.plus"
        case .apiKey: return "key.fill"
        case .localApp: return "arrow.down.app.fill"
        case .systemAccess: return "lock.open.fill"
        case .smtp: return "envelope.fill"
        }
    }
    private func signInLabel(for i: Integration) -> String {
        switch i.signInMethod {
        case .oauth: return "Sign in with \(i.name)"
        case .apiKey: return "Add API key"
        case .localApp: return "Detect \(i.name)"
        case .systemAccess: return "Grant access"
        case .smtp: return "Save SMTP settings"
        }
    }
    private func descriptionFor(_ i: Integration) -> String {
        switch i.id {
        case "chatgpt":     return "Sign in with your ChatGPT Plus / Pro account (uses the Codex OAuth flow). No API key needed."
        case "openai-byok": return "Paste a raw OpenAI API key (sk-...). Pay-per-token via api.openai.com, no ChatGPT subscription needed."
        case "claude-code": return "Use your Claude Code CLI (Pro/Max subscription quota). Requires `claude login` done in Terminal first."
        case "anthropic-api": return "Use your Anthropic API key. Pay-per-token, lowest latency."
        case "gemini":      return "Google AI Studio API key. Free tier available."
        case "perplexity":  return "Perplexity API for web-grounded answers."
        case "deepseek":    return "DeepSeek API key. OpenAI-compatible endpoint, cheap pay-per-token."
        case "ollama":      return "Run open-source models on this Mac. Detects local Ollama install."
        case "obsidian":    return "Read & write your Obsidian vault as memory."
        case "notion":      return "Internal Integration Token. Create one at notion.so/profile/integrations, copy the `ntn_...` / `secret_...` token, paste below. Only pages you share with the integration will be visible."
        case "email-smtp":  return "Let cronJobs send email via your SMTP server. Credentials stay encrypted on this Mac."
        case "apple-calendar":      return "Access your local Calendar.app events."
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.16)
                         : hover ? Theme.hover
                         : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                            isSelected ? Theme.accent.opacity(0.45) : Theme.stroke,
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
        .buttonStyle(.bouncyIcon)
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
            } else if let asset = integration.assetName {
                if integration.assetFullBleed {
                    // asset 已是完整 app-icon,直接铺满 + 圆角裁切。
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
                } else {
                    // 真品牌 SVG/PNG 资源 —— 白底原色,跟 macOS app icon 视觉一致。
                    RoundedRectangle(cornerRadius: size * 0.22)
                        .fill(Color.white)
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.18)
                }
            } else {
                // 品牌色底块 + 优先 SF Symbol(若提供),否则用 letter 字形。
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(integration.accent)
                if let symbol = integration.iconSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.50, weight: .semibold))
                        .foregroundStyle(luminance(integration.accent) > 0.55 ? .black : .white)
                } else {
                    Text(integration.letter)
                        .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                        .foregroundStyle(luminance(integration.accent) > 0.55 ? .black : .white)
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: integration.id) { await tryLoadRealIcon() }
    }

    private func tryLoadRealIcon() async {
        // 先清旧 —— 切 tile 时 SwiftUI 复用同一份 IntegrationIcon View 实例,
        // @State realIcon 会保留上一个 integration 的图。新 integration 没
        // bundleId / NSWorkspace 探不到时,不清就会一直显示上一个图(展开面
        // 板里选 Email 还看到 Spotify 的图标就是这个)。
        self.realIcon = nil
        let bid = integration.bundleId
        let img = await Task.detached(priority: .userInitiated) {
            AppIconLoader.icon(forBundleId: bid)
        }.value
        self.realIcon = img
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
