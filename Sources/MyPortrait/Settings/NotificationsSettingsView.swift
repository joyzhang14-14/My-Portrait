import SwiftUI

struct NotificationsSettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        SettingsPage("Notifications",
                     onResetCurrentPage: { config.mutate { $0.notifications = .init() } }) {

            SettingsCard(title: "App") {
                SettingsRow("New version available & update",
                            icon: "bell.badge") {
                    Toggle("", isOn: config.binding(\.notifications.appUpdates)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Memory pipelines") {
                SettingsRow("Pipeline progress",
                            info: "Informational banners — no action needed:\n\n⚙️  Run finished — what was processed (event processing, portrait distillation, personality refresh, writing capture, speech style)\n\n🔁  Resumed after interruption — app was closed mid-run, restarting on next tick",
                            icon: "gearshape.2") {
                    Toggle("", isOn: config.binding(\.notifications.schedulerAlerts)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Pipeline errors",
                            info: "Failure banners — may need your attention:\n\n🛑  Needs attention — action required (quota exhausted, auth revoked, model gone, DB corrupt, context overflow)\n\n🔁  Auto-recovering — transient failure (network blip, rate limit, schema parse), scheduler will retry on its own\n\n⚠️  Run failed — what was processed has problems",
                            icon: "exclamationmark.triangle") {
                    Toggle("", isOn: config.binding(\.notifications.pipelineErrorAlerts)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Diagnostics"
            ) {
                SettingsRow("Capture stalls",
                            info: "Alert when audio or screen capture stops unexpectedly.",
                            icon: "exclamationmark.triangle") {
                    Toggle("", isOn: config.binding(\.notifications.captureStalls)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Sign-in expiring",
                            info: "🔑  Warns you when a connected AI account needs signing in again.\n\nChecked once a day. Sign-ins that can be renewed automatically are renewed silently — you only hear about it when renewal fails and it genuinely needs you. When a sign-in lapses, every pipeline running on that provider stops until you reconnect it.",
                            icon: "key") {
                    Toggle("", isOn: config.binding(\.notifications.credentialExpiryAlerts)).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

