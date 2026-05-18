import SwiftUI

struct DisplaySettingsView: View {
    @AppStorage(SettingsKeys.theme)                  private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.chatAlwaysOnTop)        private var alwaysOnTop = false
    @AppStorage(SettingsKeys.translucentSidebar)     private var translucentSidebar = true
    @AppStorage(SettingsKeys.hideModelReasoning)     private var hideReasoning = false
    @AppStorage(SettingsKeys.showOverlayInRecording) private var showOverlayInRec = true

    var body: some View {
        SettingsPage("Display", subtitle: "Theme and window behaviour") {

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
