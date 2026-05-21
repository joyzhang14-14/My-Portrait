import SwiftUI

/// In-app variant used when the user lands on the Settings tab in the main
/// window. Sub-section selection lives in the outer TimelineSidebar (so
/// the rail isn't empty), this view just renders the detail.
struct SettingsPane: View {
    @Binding var subsection: SettingsSubsection?
    var body: some View {
        Group {
            switch subsection ?? .display {
            case .display:       DisplaySettingsView()
            case .general:       GeneralSettingsView()
            case .aiModels:      AIModelsSettingsView()
            case .connections:   ConnectionsView()
            case .recordingScreen:  ScreenRecordingSettingsView()
            case .recordingAudio:   AudioRecordingSettingsView()
            case .recordingTyping:  TypingRecordingSettingsView()
            case .notifications: NotificationsSettingsView()
            case .memoryParameter: MemorySettingsView(tab: .parameter)
            case .memoryScheduler: MemorySettingsView(tab: .scheduler)
            case .memoryChangelog: MemorySettingsView(tab: .changelog)
            case .usage:         UsageSettingsView()
            case .privacy:       PrivacySettingsView()
            case .storage:       StorageSettingsView()
            case .speakers:      SpeakersSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SidebarBackdrop().ignoresSafeArea())
    }
}

/// Top-level scene for the macOS Settings window (opened via ⌘, from the
/// app menu). Self-contained layout: left rail with the 6 subsection rows,
/// right pane with the selected subsection.
struct SettingsScene: View {
    @State private var subsection: SettingsSubsection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(.ultraThinMaterial)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My Portrait")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 16)

            ForEach([SettingsSubsection.Group.app, .recording, .memory, .dataPrivacy], id: \.self) { grp in
                Text(grp.rawValue)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                VStack(spacing: 2) {
                    // Connections is only reachable from the in-app Settings
                    // tab (it needs AppState, which this standalone ⌘, window
                    // doesn't inject) — so it's excluded from this rail.
                    ForEach(SettingsSubsection.allCases.filter { $0.group == grp && $0 != .connections }) { s in
                        SettingsSidebarRow(
                            subsection: s,
                            isActive: subsection == s,
                            onTap: { subsection = s }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer()
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch subsection {
        case .display:       DisplaySettingsView()
        case .general:       GeneralSettingsView()
        case .aiModels:      AIModelsSettingsView()
        case .connections:
            // Unreachable from this window's rail (filtered out above);
            // the case only exists to keep the switch exhaustive.
            Text("Open Connections from the main window.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .recordingScreen:  ScreenRecordingSettingsView()
        case .recordingAudio:   AudioRecordingSettingsView()
        case .recordingTyping:  TypingRecordingSettingsView()
        case .notifications: NotificationsSettingsView()
        case .memoryParameter: MemorySettingsView(tab: .parameter)
        case .memoryScheduler: MemorySettingsView(tab: .scheduler)
        case .memoryChangelog: MemorySettingsView(tab: .changelog)
        case .usage:         UsageSettingsView()
        case .privacy:       PrivacySettingsView()
        case .storage:       StorageSettingsView()
        case .speakers:      SpeakersSettingsView()
        }
    }
}

/// Settings rail row. Active state matches the rest of the app's sidebars
/// (`scopeRow` etc.): blue accent fill + hairline accent border.
struct SettingsSidebarRow: View {
    let subsection: SettingsSubsection
    let isActive: Bool
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: subsection.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                    .frame(width: 20)
                Text(subsection.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.16)
                          : hover ? Theme.hover : .clear)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
