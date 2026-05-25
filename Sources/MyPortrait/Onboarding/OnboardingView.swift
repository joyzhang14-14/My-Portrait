import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// 首次启动引导。**当前未自动接入** —— 在 Settings → General → Maintenance
/// 有个 "Preview onboarding" 按钮可以手动唤起。等流程跑顺再切到首启自动弹。
///
/// 5 步:
///   1. Welcome
///   2. Permissions(6 项)
///   3. Personal info(全选填)
///   4. Connect an AI(可跳过)
///   5. Done
///
/// 所有步都允许 Skip;最后一步 Finish **永远可点**(用户连不连都能过)。
struct OnboardingView: View {

    /// 关闭回调 —— 由调用方决定怎么 dismiss(.sheet binding 或 window close)。
    var onFinish: () -> Void

    @State private var step: Int = 0
    private let totalSteps = 8

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(SidebarBackdrop().ignoresSafeArea())
    }

    // MARK: - Header / progress

    private var progressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.white.opacity(0.10))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Step switch

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: PermissionsStep()
        case 2: PersonalInfoStep()
        case 3: ConnectAIStep()
        case 4: MemoryProviderStep()
        case 5: SchedulerStep()
        case 6: SpeakerTrainingStep()
        default: FinishStep()
        }
    }

    // MARK: - Footer (Back / Skip / Next / Finish)

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Spacer(minLength: 0)
            if step > 0 && step < totalSteps - 1 {
                Button("Skip") { advance() }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
            }
            Button(step == totalSteps - 1 ? "Finish" : "Next") {
                if step == totalSteps - 1 { onFinish() }
                else { advance() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.20))
    }

    private func advance() {
        guard step < totalSteps - 1 else { return }
        withAnimation(.easeInOut(duration: 0.18)) { step += 1 }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to My Portrait")
                .font(.system(size: 32, weight: .semibold))
            Text("A private, on-device AI memory system. It quietly captures what you do, then turns it into a long-term portrait that any chat model you connect can reference. Everything stays on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Captures screen + keyboard + audio with your permission")
                bullet("Builds a portrait you can read, edit, or delete at any time")
                bullet("Brings your own AI — ChatGPT, Claude, Gemini, DeepSeek, Ollama")
            }
            .padding(.top, 8)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 40)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green.opacity(0.75))
                .padding(.top, 2)
            Text(s).font(.system(size: 13))
        }
    }
}

// MARK: - Step 2: Permissions

/// macOS TCC permissions onboarding 关心的 6 项。每项有:
///   - 状态(granted / denied / unknown)实时刷新
///   - 一键请求按钮(没 API 的就跳系统设置)
private struct PermissionsStep: View {
    @StateObject private var monitor = PermissionMonitor()
    @State private var inputMonitoring: PermStatus = .unknown
    /// UI 刷新 trigger —— Input Monitoring 不在 PermissionMonitor 里,用 timer 拉一次。
    @State private var pollTask: Task<Void, Never>? = nil

    enum PermStatus { case granted, denied, unknown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Grant permissions")
                    .font(.system(size: 24, weight: .semibold))
                Text("Each one unlocks a specific capture layer. Skip any you don't want — the rest of the app keeps working.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                permRow(
                    icon: "rectangle.inset.filled.on.rectangle",
                    title: "Screen Recording",
                    why: "Required to capture what's on your screen for OCR and context.",
                    status: mapAppKit(monitor.screenRecording),
                    action: { monitor.requestScreenRecording() },
                    openSettings: { monitor.openSettings(for: .screen) }
                )
                permRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    why: "Required to read window titles, focus state, and global keyboard events.",
                    status: mapAppKit(monitor.accessibility),
                    action: { monitor.requestAccessibility() },
                    openSettings: { monitor.openSettings(for: .accessibility) }
                )
                permRow(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    why: "Required for the keystroke ledger — Accessibility alone isn't enough for global CGEventTap on macOS.",
                    status: inputMonitoring,
                    action: { requestInputMonitoring() },
                    openSettings: { openInputMonitoringSettings() }
                )
                permRow(
                    icon: "mic",
                    title: "Microphone",
                    why: "Required if you want voice transcription as part of memory.",
                    status: mapAppKit(monitor.microphone),
                    action: { monitor.requestMicrophone() },
                    openSettings: { monitor.openSettings(for: .microphone) }
                )
                permRow(
                    icon: "externaldrive",
                    title: "Full Disk Access",
                    why: "Required so we can read your Screenpipe history (if you use it). macOS won't ever let an app auto-prompt for this — you'll have to add My Portrait in System Settings manually.",
                    status: mapAppKit(monitor.fullDiskAccess),
                    action: nil,
                    openSettings: { monitor.openSettings(for: .fullDisk) }
                )
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            monitor.start()
            refreshExtraPerms()
            startPoll()
        }
        .onDisappear {
            monitor.stop()
            pollTask?.cancel()
        }
    }

    // MARK: row

    @ViewBuilder
    private func permRow(
        icon: String,
        title: String,
        why: String,
        status: PermStatus,
        action: (() -> Void)?,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    statusPill(status)
                }
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if status != .granted, let action {
                    Button("Allow") { action() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func statusPill(_ s: PermStatus) -> some View {
        let (label, color): (String, Color) = {
            switch s {
            case .granted: return ("Granted", .green)
            case .denied:  return ("Not granted", .orange)
            case .unknown: return ("Unknown", .gray)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.20))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func mapAppKit(_ s: PermissionMonitor.Status) -> PermStatus {
        switch s {
        case .granted:      return .granted
        case .denied:       return .denied
        case .notDetermined: return .unknown
        }
    }

    // MARK: Input Monitoring & Notification — 不在 PermissionMonitor 里,自己查

    private func refreshExtraPerms() {
        inputMonitoring = checkInputMonitoring()
    }

    private func startPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                refreshExtraPerms()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func checkInputMonitoring() -> PermStatus {
        // IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) — 不弹窗,纯查
        let t = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch t {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                       return .unknown
        }
    }

    private func requestInputMonitoring() {
        // IOHIDRequestAccess 第一次没 denied 过时会弹系统对话框。
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshExtraPerms()
    }

    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Step 3: Personal info

/// 紧凑版的 Personal info 表单。完全 optional —— 跳过等于全空,LLM prompt 不
/// 加 about-user 段。
private struct PersonalInfoStep: View {
    @State private var config = ConfigStore.shared
    @State private var newLanguage: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tell me about you (optional)")
                    .font(.system(size: 24, weight: .semibold))
                Text("Filled fields are passed to the memory pipeline as extra context. Empty fields are skipped. You can edit any of this later in Memories → Personal Info.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                groupCard("Name") {
                    formRow("First name") {
                        textField(\.personalInfo.firstName, placeholder: "Given name")
                    }
                    formRow("Middle name") {
                        textField(\.personalInfo.middleName, placeholder: "Optional")
                    }
                    formRow("Last name") {
                        textField(\.personalInfo.lastName, placeholder: "Family name")
                    }
                    formRow("Also goes by") {
                        textField(\.personalInfo.alias, placeholder: "Nickname / English name")
                    }
                }

                groupCard("Identity") {
                    formRow("Pronouns") {
                        Picker("", selection: config.binding(\.personalInfo.gender)) {
                            ForEach(PersonalInfoGender.allCases, id: \.self) { g in
                                Text(g.displayName).tag(g)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    formRow("Nationality") {
                        textField(\.personalInfo.nationality, placeholder: "e.g. Chinese")
                    }
                    formRow("Ethnicity") {
                        textField(\.personalInfo.ethnicity, placeholder: "Optional")
                    }
                    formRow("Date of birth") {
                        textField(\.personalInfo.birthDate, placeholder: "YYYY-MM-DD")
                    }
                }

                groupCard("Languages") {
                    languagesEditor
                }

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: helpers

    @ViewBuilder
    private func groupCard<Content: View>(_ title: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
    }

    @ViewBuilder
    private func formRow<Trailing: View>(_ label: String,
                                         @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 12)
            trailing()
        }
    }

    @ViewBuilder
    private func textField(_ kp: WritableKeyPath<MyPortraitConfig, String>,
                           placeholder: String) -> some View {
        TextField(placeholder, text: config.binding(kp))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
            .frame(width: 220)
    }

    @ViewBuilder
    private var languagesEditor: some View {
        let langs = config.current.personalInfo.languages
        VStack(alignment: .leading, spacing: 6) {
            if langs.isEmpty {
                Text("No languages added yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(langs.enumerated()), id: \.offset) { idx, lang in
                HStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                    Text(lang).font(.system(size: 12))
                    Spacer()
                    Button {
                        config.mutate { c in
                            guard idx < c.personalInfo.languages.count else { return }
                            c.personalInfo.languages.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("Add a language (e.g. English, 中文)", text: $newLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(addLanguage)
                Button("Add") { addLanguage() }
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addLanguage() {
        let v = newLanguage.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        config.mutate { c in
            if !c.personalInfo.languages.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                c.personalInfo.languages.append(v)
            }
        }
        newLanguage = ""
    }
}

// MARK: - Step 4: Connect AI

/// 列出 AI category 的 tile,点一个 → 展开 inline add 面板。我们不重写
/// connection 流程 —— 跑出 Settings → Connections 的同款 ConnectionsView,
/// 嵌进 onboarding 里走它自己的添加流程。
private struct ConnectAIStep: View {
    @Environment(AppState.self) private var appState

    /// 已连接的 AI integration 数。给底部那行小提示用。
    private var connectedCount: Int {
        IntegrationRegistry.all.filter {
            ($0.category == .ai || $0.category == .local) && appState.isConnected($0.id)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect an AI")
                    .font(.system(size: 24, weight: .semibold))
                Text("Pick a provider you already have access to. You'll bring your own credentials — My Portrait never resells AI usage. You can connect more later in Settings → Connections, and you can finish setup without connecting anything.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // 直接嵌入现有 ConnectionsView —— 用户点 tile → expand → add 流程
            // 跟 Settings 里完全一致,不重写。**限制只展示 AI/local 两类**,
            // 不出现 Notion/SMTP/Calendar 等。
            ConnectionsView(
                categoryFilter: [.ai, .local],
                showsHeader: false
            )
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Image(systemName: connectedCount > 0 ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(connectedCount > 0 ? .green : .secondary)
                Text(connectedCount > 0
                     ? "Connected \(connectedCount) provider\(connectedCount == 1 ? "" : "s") — you're good to go."
                     : "Nothing connected yet. You can skip this and connect later from Settings → Connections.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
        }
    }
}

// MARK: - Step 5: Memory AI provider

/// 选 memory pipeline 用哪个 provider + 主/轻两档 model。可选项跟 Settings →
/// Memory → Parameter 的 AI provider 段同源(只列已连接 + 未 disable 的)。
/// 全空时显示提示,可 Skip。
private struct MemoryProviderStep: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigStore.shared

    private var availableProviders: [Provider] {
        let aiCfg = config.current.aiModels
        return Provider.allCases.filter {
            appState.isConnected($0.integrationId)
            && !aiCfg.disabledProviderIds.contains($0.integrationId)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Memory AI model")
                    .font(.system(size: 24, weight: .semibold))
                Text("Which AI runs the memory pipeline — clustering raw activity into events, scoring importance, distilling your portrait, refreshing personality. Two model slots: a main model for heavy tasks, a lighter model for clustering / writing capture. You can change all of this later in Settings → Memory → Parameter.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                if availableProviders.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text("No connected AI provider yet. Go back to the previous step to connect one — or skip this and set it later in Settings → Memory → Parameter.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
                } else {
                    providerCard
                }

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var providerCard: some View {
        let providerId = config.current.memory.providerId
        let selectedProvider = Provider(rawValue: providerId) ?? availableProviders.first ?? .chatgpt
        let models = config.current.aiModels.visibleModels(
            forIntegrationId: selectedProvider.integrationId,
            available: selectedProvider.availableModels
        )

        VStack(alignment: .leading, spacing: 12) {
            row("Provider", desc: "Which AI service to use.") {
                Picker("", selection: config.binding(\.memory.providerId)) {
                    ForEach(availableProviders, id: \.rawValue) { p in
                        Text(Self.providerDisplayName(p)).tag(p.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Divider().overlay(Color.white.opacity(0.08))
            row("Main model", desc: "Heavy tasks: impact scoring, event clustering, portrait distillation.") {
                Picker("", selection: config.binding(\.memory.model)) {
                    ForEach(models, id: \.self) { m in Text(m).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Divider().overlay(Color.white.opacity(0.08))
            row("Light model", desc: "Lighter tasks: tag clustering, writing capture passes.") {
                Picker("", selection: config.binding(\.memory.modelLight)) {
                    ForEach(models, id: \.self) { m in Text(m).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func row<Trailing: View>(_ title: String,
                                     desc: String,
                                     @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    private static func providerDisplayName(_ p: Provider) -> String {
        switch p {
        case .chatgpt:     return "Codex (ChatGPT)"
        case .openaiBYOK:  return "OpenAI (API key)"
        case .anthropic:   return "Anthropic (API key)"
        case .ollama:      return "Ollama (local)"
        case .gemini:      return "Gemini (API key)"
        case .perplexity:  return "Perplexity (API key)"
        case .deepseek:    return "DeepSeek (API key)"
        case .claudeCode:  return "Claude Code CLI"
        }
    }
}

// MARK: - Step 6: Scheduler

/// 4 个自动调度器的频率配置(event / portrait / personality / writing capture)。
/// 每个只暴露 frequency 下拉 + 非 off 时的 timeOfDay TimePicker。weekly /
/// monthly 的 dayOfWeek / dayOfMonth 走默认值(周日 / 1 号),用户后续在
/// Settings 里调。
private struct SchedulerStep: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Automatic processing")
                    .font(.system(size: 24, weight: .semibold))
                Text("Each pipeline stage can run automatically on its own schedule, or stay manual-only. Times are local; weekly/monthly defaults to Sunday / the 1st (tune later in Settings → Memory → Scheduler).")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                schedulerCard(
                    title: "Event processing",
                    desc: "Clusters raw activity into events and scores their long-term importance.",
                    config: \.scheduler.event)
                schedulerCard(
                    title: "Portrait distillation",
                    desc: "Distills events into long-term portrait entries (one LLM call per category).",
                    config: \.scheduler.portrait)
                schedulerCard(
                    title: "Personality refresh",
                    desc: "Aggregates events + portraits + OCR into personality tags.",
                    config: \.scheduler.personality)
                schedulerCard(
                    title: "Writing capture",
                    desc: "Stages writing records from your typing for review. Approval is always manual.",
                    config: \.scheduler.writingCapture)
                schedulerCard(
                    title: "Speech style",
                    desc: "Distills how you talk and write (formality, language mix, recurring phrases) into the Speech Style portrait.",
                    config: \.scheduler.speechStyle)

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func schedulerCard(
        title: String,
        desc: String,
        config kp: WritableKeyPath<MyPortraitConfig, SchedulerConfig>
    ) -> some View {
        let freq = config.binding(kp.appending(path: \.frequency))
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Text("Frequency")
                    .font(.system(size: 12))
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: freq) {
                    Text("Off (manual only)").tag(SchedulerFrequency.off)
                    Text("Daily").tag(SchedulerFrequency.daily)
                    Text("Weekly").tag(SchedulerFrequency.weekly)
                    Text("Monthly").tag(SchedulerFrequency.monthly)
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer(minLength: 0)
            }

            if freq.wrappedValue != .off {
                HStack(spacing: 12) {
                    Text("Time")
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    timeOfDayPicker(binding: config.binding(kp.appending(path: \.timeOfDay)))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    /// "HH:mm" string ↔ DatePicker。同 SchedulerSettingsView 风格但更紧凑。
    @ViewBuilder
    private func timeOfDayPicker(binding: Binding<String>) -> some View {
        let date = Binding<Date>(
            get: {
                let parts = binding.wrappedValue.split(separator: ":")
                let h = Int(parts.first ?? "3") ?? 3
                let m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                var dc = DateComponents()
                dc.hour = h; dc.minute = m
                return Calendar.current.date(from: dc) ?? Date()
            },
            set: { newDate in
                let dc = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let h = dc.hour ?? 3, m = dc.minute ?? 0
                binding.wrappedValue = String(format: "%02d:%02d", h, m)
            }
        )
        DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
    }
}

// MARK: - Step 7: Speaker training

/// 自洽的声纹训练:**不依赖** Settings 里的 audio / speaker_id 开关。
/// 用户点 Start 时:
///   1. 记下 audio.enabled / speakerIdEnabled 的原值
///   2. 强制开 audio + speaker_id —— Services pipeline 自动起 AudioCaptureService
///   3. 30s 倒计时,期间 mic 正在采 + 分离
///   4. assign(name:) 后台轮询窗口里的声纹簇,主簇标用户名
///   5. trainer.phase 变 .success/.failure → 恢复原值
///
/// mic 权限没给 → 显示警告,Start 灰。其它情况一律可点。
private struct SpeakerTrainingStep: View {
    @State private var config = ConfigStore.shared
    @StateObject private var monitor = PermissionMonitor()
    /// 直接观察 trainer.phase 变化触发恢复逻辑。
    @State private var trainer = VoiceTrainer.shared
    @State private var showCountdown = false
    /// 训练前的 audio.enabled / speakerIdEnabled,完成时还原。
    @State private var prevAudioEnabled: Bool? = nil
    @State private var prevSpeakerIdEnabled: Bool? = nil

    private var name: String {
        config.current.capture.audio.userName.trimmingCharacters(in: .whitespaces)
    }
    private var micGranted: Bool { monitor.microphone == .granted }
    private var blocked: Bool { name.isEmpty || !micGranted || trainer.isRunning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Train your voice (optional)")
                    .font(.system(size: 24, weight: .semibold))
                Text("My Portrait separates speakers by voiceprint. Read a short passage now and future recordings can attribute lines to \"you\" instead of \"unknown cluster #3\". You can do this any time later from Settings → Speakers.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                card

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        // Phase 变 success/failure 时恢复 audio 设置。
        .onChange(of: phaseKey(trainer.phase)) { _, newKey in
            if newKey == "success" || newKey == "failure" {
                restoreAudioState()
            }
        }
        .sheet(isPresented: $showCountdown) {
            VoiceTrainingSheet(
                onFinish: {
                    showCountdown = false
                    trainer.assign(name: name)
                },
                onCancel: {
                    showCountdown = false
                    // 用户取消 → 没真训练,直接还原。
                    restoreAudioState()
                }
            )
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.purple.opacity(0.9))
                Text("Voice Training").font(.system(size: 14, weight: .semibold))
            }
            Text("Read a short passage aloud for ~30 seconds. My Portrait will briefly turn on your microphone for the training session and turn it back off when it's done.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Your name")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.70))
                TextField("e.g. Joy", text: config.binding(\.capture.audio.userName))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                    .frame(maxWidth: 220)
            }

            if !micGranted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Microphone permission needed — grant it in the Permissions step.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.orange.opacity(0.85))
            }

            HStack {
                statusLine
                Spacer()
                Button(action: startTraining) {
                    Text(trainer.isRunning ? "Training…" : "Start training")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(LinearGradient(
                                    colors: [Color.purple.opacity(0.45), Color.blue.opacity(0.28)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                        )
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .opacity(blocked ? 0.45 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7))
        )
    }

    @ViewBuilder private var statusLine: some View {
        switch trainer.phase {
        case .idle:
            EmptyView()
        case .matching:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Matching your voice — may take a few minutes…")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.60))
            }
        case .success(let n):
            Text("✓ Trained as \(n)")
                .font(.system(size: 11)).foregroundStyle(Color.green.opacity(0.90))
        case .failure(let msg):
            Text(msg)
                .font(.system(size: 11)).foregroundStyle(Color.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Audio toggle 临时拉起 / 还原

    private func startTraining() {
        guard !blocked else { return }
        // 记下原值。如果之前已 success/failure,这里 prevXxx 可能还残留之前那次
        // 的值;重新记一次覆盖。
        prevAudioEnabled = config.current.capture.audio.enabled
        prevSpeakerIdEnabled = config.current.capture.audio.speakerIdEnabled
        // 强制开 —— Services pipeline 会自动起 AudioCaptureService + 分离。
        config.mutate { c in
            c.capture.audio.enabled = true
            c.capture.audio.speakerIdEnabled = true
        }
        showCountdown = true
    }

    /// 恢复 audio.enabled / speakerIdEnabled 到训练前的值。idempotent —— 多次
    /// 调用(cancel + phase change)只生效一次。
    private func restoreAudioState() {
        guard let prevAudio = prevAudioEnabled,
              let prevSpk = prevSpeakerIdEnabled else { return }
        config.mutate { c in
            c.capture.audio.enabled = prevAudio
            c.capture.audio.speakerIdEnabled = prevSpk
        }
        prevAudioEnabled = nil
        prevSpeakerIdEnabled = nil
    }

    /// VoiceTrainer.Phase 不是 Equatable-keyed-by-case,onChange 需要个稳定 key。
    private func phaseKey(_ p: VoiceTrainer.Phase) -> String {
        switch p {
        case .idle: return "idle"
        case .matching: return "matching"
        case .success: return "success"
        case .failure: return "failure"
        }
    }
}

// MARK: - Step 8: Finish

private struct FinishStep: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 40)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.system(size: 32, weight: .semibold))
            Text("My Portrait is ready. It will start capturing in the background — open the chat anytime to talk to your portrait, or visit Settings → Memory to tune how it consolidates events.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                FinishHint(icon: "bubble.left.and.bubble.right", text: "Open the chat from the sidebar to ask anything.")
                FinishHint(icon: "person.text.rectangle", text: "Edit your portrait under Memories at any time.")
                FinishHint(icon: "lock.shield", text: "Everything you see can be deleted from Settings → Data & Privacy.")
            }
            .padding(.top, 8)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 40)
    }
}

private struct FinishHint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 18)
                .padding(.top, 1)
            Text(text).font(.system(size: 13))
        }
    }
}
