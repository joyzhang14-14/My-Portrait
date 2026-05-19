import SwiftUI

struct NotificationsSettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        SettingsPage("Notifications",
                     subtitle: "Control which alerts My Portrait sends you") {

            SettingsCard(title: "App") {
                SettingsRow("New version available",
                            description: "Notify when a new build is ready to install.",
                            icon: "bell.badge") {
                    Toggle("", isOn: config.binding(\.notifications.appUpdates)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "AI") {
                SettingsRow("Pipe suggestions",
                            description: "AI automation ideas based on your data.",
                            icon: "sparkles") {
                    HStack(spacing: 6) {
                        Picker("", selection: config.binding(\.notifications.pipeSuggestionInterval)) {
                            ForEach(SuggestionInterval.allCases) { i in
                                Text(i.label).tag(i.rawValue)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden()
                        .disabled(!config.current.notifications.pipeSuggestions)
                        .frame(width: 110)
                        Toggle("", isOn: config.binding(\.notifications.pipeSuggestions)).labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingsDivider()
                SettingsRow("Pipe notifications",
                            description: "Alerts from installed pipes.",
                            icon: "antenna.radiowaves.left.and.right") {
                    Toggle("", isOn: config.binding(\.notifications.pipeAlerts)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Diagnostics",
                footnote: "May produce false positives — useful while iterating on the capture engine."
            ) {
                SettingsRow("Capture stalls",
                            description: "Alert when audio or screen capture stops unexpectedly.",
                            icon: "exclamationmark.triangle") {
                    HStack(spacing: 6) {
                        ExperimentalBadge()
                        Toggle("", isOn: config.binding(\.notifications.captureStalls)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsCard(
                title: "Muted pipes",
                footnote: "Pipes added here won't trigger any notifications, no matter their configuration."
            ) {
                if config.current.notifications.mutedPipes.isEmpty {
                    Text("No muted pipes.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(config.current.notifications.mutedPipes, id: \.self) { name in
                        SettingsRow(name, icon: "speaker.slash") {
                            Button("Unmute") {
                                config.mutate { $0.notifications.mutedPipes.removeAll { $0 == name } }
                                
                            }
                            .font(.system(size: 11))
                        }
                        if name != config.current.notifications.mutedPipes.last { SettingsDivider() }
                    }
                }
            }
        }
    }
}

private struct ExperimentalBadge: View {
    var body: some View {
        Text("EXPERIMENTAL")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Color.orange.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().stroke(Color.orange.opacity(0.45), lineWidth: 0.8))
    }
}
