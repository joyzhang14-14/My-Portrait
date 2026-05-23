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
                    HStack(spacing: 6) {
                        NotWiredBadge()
                        Toggle("", isOn: config.binding(\.notifications.appUpdates)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsCard(title: "Cron Jobs") {
                SettingsRow("Cron job run notifications",
                            description: "Show a system banner when an installed cronJob finishes a run.",
                            icon: "antenna.radiowaves.left.and.right") {
                    Toggle("", isOn: config.binding(\.notifications.cronJobAlerts)).labelsHidden().toggleStyle(.switch)
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
                        NotWiredBadge()
                        Toggle("", isOn: config.binding(\.notifications.captureStalls)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsCard(
                title: "Muted cronJobs",
                footnote: "Cron jobs added here won't trigger any notifications, no matter their configuration."
            ) {
                if config.current.notifications.mutedCronJobs.isEmpty {
                    Text("No muted cronJobs.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(config.current.notifications.mutedCronJobs, id: \.self) { name in
                        SettingsRow(name, icon: "speaker.slash") {
                            Button("Unmute") {
                                config.mutate { $0.notifications.mutedCronJobs.removeAll { $0 == name } }
                                
                            }
                            .font(.system(size: 11))
                        }
                        if name != config.current.notifications.mutedCronJobs.last { SettingsDivider() }
                    }
                }
            }
        }
    }
}

/// Pill that flags a toggle whose backend isn't connected yet. Used for
/// `appUpdates` (no auto-updater) and `captureStalls` (depends on the
/// Capture WIP).
private struct NotWiredBadge: View {
    var body: some View {
        Text("NOT WIRED")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Color.orange.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().stroke(Color.orange.opacity(0.45), lineWidth: 0.8))
            .help("UI saves the setting; no backend hooked up yet.")
    }
}
