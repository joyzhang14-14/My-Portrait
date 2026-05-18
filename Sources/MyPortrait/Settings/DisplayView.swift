import SwiftUI

struct DisplaySettingsView: View {
    @AppStorage(SettingsKeys.theme)                 private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.chatAlwaysOnTop)       private var alwaysOnTop = false
    @AppStorage(SettingsKeys.translucentSidebar)    private var translucentSidebar = true
    @AppStorage(SettingsKeys.hideModelReasoning)    private var hideReasoning = false

    @AppStorage(SettingsKeys.smartBarEnabled)       private var smartBar = true
    @AppStorage(SettingsKeys.smartBarOverlaySize)   private var smartBarSize: Double = 1.0
    @AppStorage(SettingsKeys.smartBarShowShortcuts) private var smartBarShortcuts = true
    @AppStorage(SettingsKeys.smartBarShowCapture)   private var smartBarCapture = true
    @AppStorage(SettingsKeys.smartBarShowAudio)     private var smartBarAudio = true
    @AppStorage(SettingsKeys.smartBarShowMeeting)   private var smartBarMeeting = true
    @AppStorage(SettingsKeys.smartBarShowLyric)     private var smartBarLyric = false

    var body: some View {
        SettingsPage("Display", subtitle: "Theme, window behaviour, Smart Bar") {

            SettingsCard(title: "Appearance") {
                SettingsRow("Theme",
                            description: "Match the system or force light / dark.",
                            icon: "paintpalette") {
                    Picker("", selection: $theme) {
                        ForEach(AppTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingsDivider()
                SettingsRow("Translucent sidebar",
                            description: "Frosted glass effect on the left rail.",
                            icon: "rectangle.lefthalf.inset.filled") {
                    Toggle("", isOn: $translucentSidebar).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Chat") {
                SettingsRow("Always on top",
                            description: "Keep the chat window floating above other apps.",
                            icon: "macwindow.on.rectangle") {
                    Toggle("", isOn: $alwaysOnTop).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Hide model reasoning",
                            description: "Don't show the “Thinking…” card in the transcript.",
                            icon: "brain") {
                    Toggle("", isOn: $hideReasoning).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Smart Bar",
                footnote: "Smart Bar is the floating control strip Apple Vision–style overlay. Toggle individual indicators below."
            ) {
                SettingsRow("Show Smart Bar",
                            description: "Overlay showing Smart Bar controls.",
                            icon: "menubar.dock.rectangle") {
                    Toggle("", isOn: $smartBar).labelsHidden().toggleStyle(.switch)
                }
                if smartBar {
                    SettingsDivider()
                    SettingsRow("Overlay size",
                                description: "Size of the Smart Bar overlay.",
                                icon: "arrow.up.left.and.arrow.down.right") {
                        HStack(spacing: 8) {
                            Slider(value: $smartBarSize, in: 0.5...1.5)
                                .frame(width: 140)
                            Text(String(format: "%.2fx", smartBarSize))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Show shortcut hints",
                                indent: 28) {
                        Toggle("", isOn: $smartBarShortcuts).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Screen capture indicator",
                                indent: 28) {
                        Toggle("", isOn: $smartBarCapture).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Audio activity indicator",
                                indent: 28) {
                        Toggle("", isOn: $smartBarAudio).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Meeting button",
                                indent: 28) {
                        Toggle("", isOn: $smartBarMeeting).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Lyrics from local music app",
                                indent: 28) {
                        Toggle("", isOn: $smartBarLyric).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }
}
