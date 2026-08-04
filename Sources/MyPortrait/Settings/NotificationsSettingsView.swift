import SwiftUI

struct NotificationsSettingsView: View {
    @State private var config = ConfigStore.shared
    @State private var cronStore = CronJobStore.shared

    var body: some View {
        SettingsPage("Notifications",
                     subtitle: "Control which alerts My Portrait sends you",
                     onResetCurrentPage: { config.mutate { $0.notifications = .init() } }) {

            SettingsCard(title: "App") {
                SettingsRow("New version available",
                            icon: "bell.badge") {
                    Toggle("", isOn: config.binding(\.notifications.appUpdates)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Cron Jobs") {
                SettingsRow("Cron job run notifications",
                            icon: "antenna.radiowaves.left.and.right") {
                    Toggle("", isOn: config.binding(\.notifications.cronJobAlerts)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Memory pipelines") {
                SettingsRow("Pipeline progress",
                            icon: "gearshape.2") {
                    Toggle("", isOn: config.binding(\.notifications.schedulerAlerts)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Pipeline errors",
                            icon: "exclamationmark.triangle") {
                    Toggle("", isOn: config.binding(\.notifications.pipelineErrorAlerts)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Diagnostics"
            ) {
                SettingsRow("Capture stalls",
                            icon: "exclamationmark.triangle") {
                    Toggle("", isOn: config.binding(\.notifications.captureStalls)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: "Muted cronJobs"
            ) {
                // 数据源是 CronJobStore 的 per-CronJob.muted 字段。
                let muted = cronStore.cronJobs.filter { $0.muted }
                if muted.isEmpty {
                    Text("No muted cronJobs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary.opacity(0.5))
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
        }
    }
}

