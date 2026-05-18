import SwiftUI

struct DisplaySettingsView: View {
    @AppStorage(SettingsKeys.theme)                  private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.chatAlwaysOnTop)        private var alwaysOnTop = false
    @AppStorage(SettingsKeys.translucentSidebar)     private var translucentSidebar = true
    @AppStorage(SettingsKeys.hideModelReasoning)     private var hideReasoning = false
    @AppStorage(SettingsKeys.showOverlayInRecording) private var showOverlayInRec = true
    @AppStorage(SettingsKeys.appName)                private var appName = "My Portrait"
    @AppStorage(SettingsKeys.customDockIcon)         private var dockIconPath = ""
    @AppStorage(SettingsKeys.customTrayIcon)         private var trayIconPath = ""
    @AppStorage(SettingsKeys.showInMenuBar)          private var showInMenuBar = true

    var body: some View {
        SettingsPage("Display", subtitle: "Theme, window behaviour, and personalization") {

            AppCustomizeCard(
                appName: $appName,
                dockIconPath: $dockIconPath,
                trayIconPath: $trayIconPath,
                showInMenuBar: $showInMenuBar
            )

            SettingsCard(title: "Appearance") {
                SettingsRow("Theme",
                            description: "Match the system or force light / dark.",
                            icon: "paintpalette") {
                    Picker("", selection: $theme) {
                        ForEach(AppTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 110)
                }
                SettingsDivider()
                SettingsRow("Translucent sidebar",
                            description: "Frosted glass effect on the left rail (macOS only).",
                            icon: "rectangle.lefthalf.inset.filled") {
                    Toggle("", isOn: $translucentSidebar).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Chat") {
                SettingsRow("Chat always on top",
                            description: "Keep the chat window floating above other apps.",
                            icon: "macwindow.on.rectangle") {
                    Toggle("", isOn: $alwaysOnTop).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Hide thinking blocks",
                            description: "Don't show the model's reasoning trace in the transcript.",
                            icon: "brain") {
                    Toggle("", isOn: $hideReasoning).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Recording overlays") {
                SettingsRow("Show overlay in screen recording",
                            description: "Include the chat overlay in captured frames.",
                            icon: "rectangle.dashed") {
                    Toggle("", isOn: $showOverlayInRec).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

// MARK: - App Customize card

/// Hero card at the top of the Display page. Mirrors Orphies'
/// `app-customize-card.tsx`:
///   1. Editable app name (max 32 chars)
///   2. Dock icon slot — Upload / Replace / Reset
///   3. Menu bar icon slot — same controls
///   4. Show-in-menu-bar toggle
///
/// Uploads write into `~/Library/Application Support/MyPortrait/customize/`
/// so the icons survive app restarts. Reset deletes the file.
private struct AppCustomizeCard: View {
    @Binding var appName: String
    @Binding var dockIconPath: String
    @Binding var trayIconPath: String
    @Binding var showInMenuBar: Bool

    private let maxNameLength = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App customize")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                    Text("Personalize the in-app display name and the Dock + menu bar icons.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("APP NAME (MAX \(maxNameLength) CHARS)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                TextField("My Portrait", text: Binding(
                    get: { appName },
                    set: { appName = String($0.prefix(maxNameLength)) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                )
                Text("macOS controls the name shown in the menu bar (next to the Apple logo). Changing it here updates the dock title + windows.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Color.white.opacity(0.08))

            IconSlot(
                title: "Dock icon",
                subtitle: "Shown in the Dock and the cmd-Tab switcher.",
                path: $dockIconPath,
                fileName: "dock.png"
            )

            IconSlot(
                title: "Menu bar icon",
                subtitle: "Used by the status item next to the clock.",
                path: $trayIconPath,
                fileName: "tray.png"
            )

            Divider().background(Color.white.opacity(0.08))

            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in menu bar")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Adds a status item next to the clock for quick chat.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $showInMenuBar).labelsHidden().toggleStyle(.switch)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.40), Color.purple.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.purple.opacity(0.12), radius: 16, x: 0, y: 6)
        )
    }
}

// MARK: - Icon slot (Dock / Menu bar)

private struct IconSlot: View {
    let title: String
    let subtitle: String
    @Binding var path: String
    /// On-disk file name to use when copying the picked image into our
    /// support dir (e.g. "dock.png" / "tray.png").
    let fileName: String

    @State private var preview: NSImage? = nil

    var body: some View {
        HStack(spacing: 14) {
            preview64
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    Button(action: pickFile) {
                        Label(path.isEmpty ? "Upload" : "Replace",
                              systemImage: "arrow.up.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    if !path.isEmpty {
                        Button(action: reset) {
                            Label("Reset", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11))
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear { loadPreview() }
        .onChange(of: path) { loadPreview() }
    }

    @ViewBuilder private var preview64: some View {
        Group {
            if let img = preview {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))
                    Text("default")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.14), lineWidth: 0.7))
    }

    // MARK: - File ops

    private func loadPreview() {
        guard !path.isEmpty, let img = NSImage(contentsOfFile: path) else {
            preview = nil; return
        }
        preview = img
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() != .OK, let _ = panel.url { return }
        guard panel.runModal() == .OK || panel.url != nil, let src = panel.url else { return }
        copyAndSet(src: src)
    }

    private func copyAndSet(src: URL) {
        let dir = AIPaths.supportDir.appendingPathComponent("customize", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            path = dest.path
        } catch {
            // Surface in a console log only; the UI just reverts to "default".
            path = ""
        }
    }

    private func reset() {
        if !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
        path = ""
        preview = nil
    }
}
