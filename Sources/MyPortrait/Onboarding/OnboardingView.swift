import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hid
import UserNotifications

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
    private let totalSteps = 5

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
    @State private var notification:    PermStatus = .unknown
    /// UI 刷新 trigger —— Input Monitoring / Notification 不在 PermissionMonitor 里,
    /// 用 timer 拉一次。
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
                permRow(
                    icon: "bell",
                    title: "Notifications",
                    why: "Optional. Used for completion alerts when AI cron jobs finish.",
                    status: notification,
                    action: { requestNotification() },
                    openSettings: { openNotificationSettings() }
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
        Task { @MainActor in
            self.notification = await checkNotification()
        }
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

    @MainActor
    private func checkNotification() async -> PermStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    private func requestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in self.refreshExtraPerms() }
        }
    }

    private func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
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

// MARK: - Step 5: Finish

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
