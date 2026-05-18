import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(SettingsKeys.launchAtLogin)       private var launchAtLogin = false
    @AppStorage(SettingsKeys.autoDownloadUpdates) private var autoUpdateApp = true
    @AppStorage(SettingsKeys.updateCheckMinutes)  private var updateCheckMinutes: Int = 60

    @State private var clearingCache = false
    @State private var scanResults: ScanResults? = nil

    var body: some View {
        SettingsPage("General", subtitle: "Startup and updates") {

            SettingsCard(title: "Startup") {
                SettingsRow("Auto-start",
                            description: "Open My Portrait automatically when you log in.",
                            icon: "power") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Updates") {
                SettingsRow("Auto-update app",
                            description: "Download and install app updates automatically.",
                            icon: "arrow.down.app") {
                    Toggle("", isOn: $autoUpdateApp).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Update check interval",
                            description: "How often (in minutes) to look for a new build. Min 1, max 1440.",
                            icon: "clock.arrow.circlepath") {
                    HStack(spacing: 4) {
                        TextField("", value: $updateCheckMinutes,
                                  formatter: Self.minutesFormatter)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            )
                            .frame(width: 70)
                        Text("min")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }

            SettingsCard(title: "Maintenance") {
                SettingsRow("Clear cache",
                            description: "Remove AI agent cache, old logs, and recovery artifacts.",
                            icon: "trash") {
                    Button(scanResults == nil ? "Scan" : "Re-scan") {
                        scanCache()
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                if let r = scanResults {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(r.entries, id: \.path) { entry in
                            HStack {
                                Image(systemName: "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.50))
                                Text(entry.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(entry.sizeLabel)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Delete all", role: .destructive) { runClearCache() }
                                .font(.system(size: 12, weight: .medium))
                                .disabled(clearingCache)
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }

    private static let minutesFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 1; f.maximum = 1440; f.allowsFloats = false
        return f
    }()

    // MARK: - Scan & clear (UI-level — wire to real paths in a follow-up)

    private struct ScanResults {
        struct Entry { let path: String; let sizeLabel: String }
        let entries: [Entry]
    }

    private func scanCache() {
        scanResults = ScanResults(entries: [
            .init(path: "~/Library/Application Support/MyPortrait/pi-rpc.log", sizeLabel: "182 KB"),
            .init(path: "~/Library/Application Support/MyPortrait/attachments", sizeLabel: "0 B"),
            .init(path: "~/Library/Application Support/MyPortrait/bun/install/cache", sizeLabel: "2.4 MB")
        ])
    }

    private func runClearCache() {
        clearingCache = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            clearingCache = false
            scanResults = nil
        }
    }
}
