import SwiftUI

struct NotificationsSettingsView: View {
    @State private var config = ConfigStore.shared
    @State private var cronStore = CronJobStore.shared

    var body: some View {
        SettingsPage("Notifications",
                     onResetCurrentPage: { config.mutate { $0.notifications = .init() } }) {

            SettingsCard(title: "App") {
                SettingsRow("New version available & update",
                            icon: "bell.badge") {
                    Toggle("", isOn: config.binding(\.notifications.appUpdates)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Cron Jobs") {
                SettingsRow("Cron job run notifications",
                            icon: "antenna.radiowaves.left.and.right") {
                    Toggle("", isOn: config.binding(\.notifications.cronJobAlerts)).labelsHidden().toggleStyle(.switch)
                }
                // 静音的 cronJob 直接续在同一张卡里。数据源是
                // CronJobStore 的 per-CronJob.muted 字段。
                let muted = cronStore.cronJobs.filter { $0.muted }
                SettingsDivider()
                if muted.isEmpty {
                    Text("No muted cronJobs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(muted) { job in
                        SettingsRow(job.name, icon: "speaker.slash") {
                            Button("Unmute") {
                                cronStore.setMuted(job.id, false)
                            }
                            .font(.system(size: 11))
                        }
                        if job.id != muted.last?.id { SettingsDivider() }
                    }
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

