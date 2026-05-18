import SwiftUI

struct DisplaySettingsView: View {
    @AppStorage(SettingsKeys.theme)                  private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.chatAlwaysOnTop)        private var alwaysOnTop = false
    @AppStorage(SettingsKeys.translucentSidebar)     private var translucentSidebar = true
    @AppStorage(SettingsKeys.hideModelReasoning)     private var hideReasoning = false
    @AppStorage(SettingsKeys.showOverlayInRecording) private var showOverlayInRec = true
    @AppStorage(SettingsKeys.accentColor)            private var accent = AccentColor.purple.rawValue
    @AppStorage(SettingsKeys.appIconVariant)         private var iconVariant = AppIconVariant.default.rawValue
    @AppStorage(SettingsKeys.showInMenuBar)          private var showInMenuBar = true

    private var accentColor: Color { AccentColor(rawValue: accent)?.color ?? .purple }

    var body: some View {
        SettingsPage("Display", subtitle: "Theme, window behaviour, and personalization") {

            AppCustomizeCard(
                accent: $accent,
                iconVariant: $iconVariant,
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

/// Polished hero card at the top of the Display page: live icon preview +
/// accent picker (swatches) + icon variant + menu-bar toggle. Mirrors
/// Orphies' `app-customize-card.tsx`.
private struct AppCustomizeCard: View {
    @Binding var accent: String
    @Binding var iconVariant: String
    @Binding var showInMenuBar: Bool

    private var accentColor: Color { AccentColor(rawValue: accent)?.color ?? .purple }
    private var variant: AppIconVariant { AppIconVariant(rawValue: iconVariant) ?? .default }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                iconPreview
                VStack(alignment: .leading, spacing: 4) {
                    Text("App customize")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                    Text("Personalize how My Portrait looks in your dock and across the UI.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("ACCENT COLOR")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                HStack(spacing: 10) {
                    ForEach(AccentColor.allCases) { c in
                        AccentSwatch(color: c.color, isActive: accent == c.rawValue) {
                            accent = c.rawValue
                        }
                    }
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ICON VARIANT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                HStack(spacing: 10) {
                    ForEach(AppIconVariant.allCases) { v in
                        IconVariantTile(
                            variant: v,
                            accent: accentColor,
                            isActive: iconVariant == v.rawValue
                        ) { iconVariant = v.rawValue }
                    }
                    Spacer()
                }
            }

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
                                colors: [accentColor.opacity(0.40), accentColor.opacity(0.08)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: accentColor.opacity(0.15), radius: 16, x: 0, y: 6)
        )
    }

    @ViewBuilder private var iconPreview: some View {
        ZStack {
            switch variant {
            case .default:
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            case .dark:
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(accentColor.opacity(0.6), lineWidth: 1.5))
            case .monochrome:
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.08))
            case .gradient:
                RoundedRectangle(cornerRadius: 14)
                    .fill(AngularGradient(
                        colors: [accentColor, .pink, .blue, accentColor],
                        center: .center))
            }
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(variant == .monochrome ? accentColor : .white.opacity(0.95))
        }
        .frame(width: 64, height: 64)
        .shadow(color: accentColor.opacity(0.25), radius: 8, x: 0, y: 4)
    }
}

private struct AccentSwatch: View {
    let color: Color
    let isActive: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(
                Circle().stroke(
                    isActive ? Color.white.opacity(0.95) : Color.white.opacity(hover ? 0.4 : 0),
                    lineWidth: 1.5
                )
            )
            .scaleEffect(hover ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct IconVariantTile: View {
    let variant: AppIconVariant
    let accent: Color
    let isActive: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Group {
                        switch variant {
                        case .default:
                            RoundedRectangle(cornerRadius: 7)
                                .fill(LinearGradient(
                                    colors: [accent, accent.opacity(0.6)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                        case .dark:
                            RoundedRectangle(cornerRadius: 7).fill(Color.black)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent.opacity(0.6), lineWidth: 1))
                        case .monochrome:
                            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.10))
                        case .gradient:
                            RoundedRectangle(cornerRadius: 7).fill(AngularGradient(
                                colors: [accent, .pink, .blue, accent], center: .center))
                        }
                    }
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(variant == .monochrome ? accent : .white.opacity(0.95))
                }
                .frame(width: 38, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isActive ? Color.white.opacity(0.9) : Color.white.opacity(hover ? 0.3 : 0.10),
                                lineWidth: isActive ? 1.5 : 0.8)
                )

                Text(variant.label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(isActive ? .white.opacity(0.92) : .white.opacity(0.55))
            }
            .scaleEffect(hover ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
