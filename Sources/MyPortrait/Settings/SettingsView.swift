import SwiftUI

/// In-app variant used when the user lands on the Settings tab in the main
/// window. Sub-section selection lives in the outer TimelineSidebar (so
/// the rail isn't empty), this view just renders the detail.
struct SettingsPane: View {
    @Binding var subsection: SettingsSubsection?
    var body: some View {
        Group {
            switch subsection ?? .general {
            case .general:       GeneralSettingsView()
            case .display:       DisplaySettingsView()
            case .recording:     RecordingSettingsView()
            case .notifications: NotificationsSettingsView()
            case .usage:         UsageSettingsView()
            case .privacy:       PrivacySettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
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
            Text("SETTINGS")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.40))
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(SettingsSubsection.allCases) { s in
                    SettingsSidebarRow(
                        subsection: s,
                        isActive: subsection == s,
                        onTap: { subsection = s }
                    )
                }
            }
            .padding(.horizontal, 8)
            Spacer()
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch subsection {
        case .general:       GeneralSettingsView()
        case .display:       DisplaySettingsView()
        case .recording:     RecordingSettingsView()
        case .notifications: NotificationsSettingsView()
        case .usage:         UsageSettingsView()
        case .privacy:       PrivacySettingsView()
        }
    }
}

/// Row used in `SettingsScene`'s left rail. Hover lift + purple-tinted
/// background when active.
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
                    .foregroundStyle(isActive ? .white.opacity(0.95) : .white.opacity(0.70))
                    .frame(width: 20)
                Text(subsection.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(activeFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var activeFill: AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(
                LinearGradient(colors: [Color.purple.opacity(0.30), Color.blue.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.white.opacity(hover ? 0.05 : 0))
    }
}
