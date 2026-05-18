import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(SettingsKeys.launchAtLogin)       private var launchAtLogin = false
    @AppStorage(SettingsKeys.updateCheckInterval) private var updateInterval = UpdateInterval.daily.rawValue
    @AppStorage(SettingsKeys.autoDownloadUpdates) private var autoDownload = true

    @State private var clearingCache = false

    var body: some View {
        SettingsPage("General", subtitle: "Startup and updates") {

            SettingsCard(title: "Startup") {
                SettingsRow("Launch at login",
                            description: "Open My Portrait when your Mac starts up.",
                            icon: "power") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Updates",
                         footnote: "Set to “never” to disable update checks entirely.") {
                SettingsRow("Check for updates",
                            description: "How often to look for a new build.",
                            icon: "arrow.down.circle") {
                    Picker("", selection: $updateInterval) {
                        ForEach(UpdateInterval.allCases) { i in Text(i.label).tag(i.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingsDivider()
                SettingsRow("Download in the background",
                            description: "Apply the update next time you quit.",
                            icon: "arrow.down.app") {
                    Toggle("", isOn: $autoDownload).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Maintenance") {
                SettingsActionRow(
                    "Clear cache",
                    description: "Wipe agent cache, old logs, and recovery artifacts.",
                    buttonLabel: clearingCache ? "Cleared" : "Clear",
                    buttonIcon: clearingCache ? "checkmark" : "trash",
                    role: .destructive
                ) { runClearCache() }
            }

        }
    }

    private func runClearCache() {
        // UI-only placeholder for now — wire to real disk paths in a follow-up.
        clearingCache = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { clearingCache = false }
    }
}
