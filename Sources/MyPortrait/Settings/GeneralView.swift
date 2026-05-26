import SwiftUI

struct GeneralSettingsView: View {
    @State private var config = ConfigStore.shared
    @State private var clearingCache = false
    @State private var scanResults: ScanResults? = nil
    /// 调试入口 —— 触发后弹出独立的 onboarding sheet。等流程跑顺再切到首启自动弹。
    @State private var showOnboarding: Bool = false

    var body: some View {
        SettingsPage("General", subtitle: "Startup and updates") {

            SettingsCard(title: "Startup") {
                SettingsRow("Auto-start",
                            description: "Open My Portrait automatically when you log in.",
                            icon: "power") {
                    Toggle("", isOn: config.binding(\.general.launchAtLogin)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Updates",
                         footnote: "Sparkle checks GitHub for new releases. EdDSA-signed appcast, hardened-runtime verified.") {
                SettingsRow("Auto-update app",
                            description: "Download and install app updates automatically.",
                            icon: "arrow.down.app") {
                    Toggle("", isOn: config.binding(\.general.autoDownloadUpdates)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Update check interval",
                            description: "How often (in minutes) to look for a new build. Min 1, max 1440.",
                            icon: "clock.arrow.circlepath") {
                    HStack(spacing: 4) {
                        TextField("", value: config.binding(\.general.updateCheckMinutes),
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
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                }
                SettingsDivider()
                SettingsRow("Check for updates now",
                            description: "Force Sparkle to query the GitHub appcast immediately.",
                            icon: "arrow.clockwise.circle") {
                    Button("Check now") { UpdaterService.shared.checkForUpdates() }
                        .font(.system(size: 12, weight: .medium))
                }
            }
            // 两个字段改完同步给 SPUUpdater(否则 toggle 是死配置)。
            .onChange(of: config.current.general.autoDownloadUpdates) { _, _ in
                UpdaterService.shared.applyConfig()
            }
            .onChange(of: config.current.general.updateCheckMinutes) { _, _ in
                UpdaterService.shared.applyConfig()
            }

            SettingsCard(title: "System") {
                SettingsRow("Chinese mirror",
                            description: "Use a CN-region mirror for model downloads.",
                            icon: "globe.asia.australia") {
                    Toggle("", isOn: config.binding(\.capture.system.chineseMirror))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            // CronJob 历史保留条数。改下拉立刻 applyHistoryLimit 把 runs.json
            // 裁短(选 10 → 每条 cronJob 最多留 10 条 run)。0 = no limit。
            SettingsCard(title: "Cron Jobs",
                         footnote: "Affects both the sidebar list and the on-disk runs.json. \"No limit\" lets runs.json grow forever — handy if you want a full log, costly otherwise.") {
                SettingsRow("History per cron job",
                            description: "How many recent runs to keep for each cron job.",
                            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    Picker("", selection: config.binding(\.general.cronJobHistoryLimit)) {
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("50").tag(50)
                        Text("No limit").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
            }
            .onChange(of: config.current.general.cronJobHistoryLimit) { _, _ in
                CronJobStore.shared.applyHistoryLimit()
            }

            // Onboarding 在 ContentView 首启自动弹(没走完就反复弹);这里
             // 给「已走完」的用户一个再看一次的入口。点这个不会重置首启 flag,
             // 只是临时显示一次 sheet。
            SettingsCard(title: "Onboarding",
                         footnote: "Re-open the welcome / permissions / personal info / connect flow. Settings already entered (API keys, etc.) stay as-is — this doesn't reset anything.") {
                SettingsRow("Replay onboarding",
                            description: "Open the onboarding sheet again — useful to grant a permission you skipped, or change your AI provider.",
                            icon: "sparkles") {
                    Button("Show") { showOnboarding = true }
                        .font(.system(size: 12, weight: .medium))
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
                                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
                                Text(entry.displayPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary.opacity(0.78))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(entry.sizeLabel)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
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
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
    }

    private static let minutesFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 1; f.maximum = 1440; f.allowsFloats = false
        return f
    }()

    // MARK: - Scan & clear (real filesystem)

    private struct ScanResults {
        struct Entry { let path: String; let displayPath: String; let bytes: Int64; let sizeLabel: String; let isDir: Bool }
        let entries: [Entry]
    }

    /// Scan the three known cache locations. Misses (file/dir doesn't
    /// exist) still show with "—" so the user knows we looked.
    private func scanCache() {
        let targets: [(path: String, isDir: Bool)] = [
            (AIPaths.supportDir.appendingPathComponent("attachments").path,         true),
            (AIPaths.supportDir.appendingPathComponent("bun/install/cache").path,   true),
        ]
        let home = NSHomeDirectory()
        let entries: [ScanResults.Entry] = targets.map { t in
            let bytes = CacheScanner.size(at: t.path, isDir: t.isDir)
            let display = t.path.hasPrefix(home) ? "~" + t.path.dropFirst(home.count) : t.path
            return .init(
                path: t.path,
                displayPath: String(display),
                bytes: bytes,
                sizeLabel: CacheScanner.format(bytes),
                isDir: t.isDir
            )
        }
        scanResults = ScanResults(entries: entries)
    }

    /// Delete every scanned target. Files are removed outright; directories
    /// are emptied but kept (so PiAgent / BunInstaller can still write into
    /// them without recreating the dir).
    private func runClearCache() {
        guard let r = scanResults else { return }
        clearingCache = true
        Task {
            await Task.detached(priority: .userInitiated) {
                for e in r.entries { CacheScanner.purge(path: e.path, isDir: e.isDir) }
            }.value
            clearingCache = false
            scanCache()      // refresh, every row should now read 0 B / —
        }
    }
}

/// Shared file-system helpers — `nonisolated` so they can run off the main actor.
enum CacheScanner {
    static func size(at path: String, isDir: Bool) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return -1 }
        let url = URL(fileURLWithPath: path)
        if !isDir {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return Int64(v?.totalFileAllocatedSize ?? 0)
        }
        guard let it = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                     options: [.skipsHiddenFiles], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in it {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func purge(path: String, isDir: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        if !isDir {
            try? fm.removeItem(atPath: path)
            return
        }
        // Empty the directory but keep the dir itself.
        if let children = try? fm.contentsOfDirectory(atPath: path) {
            for child in children {
                try? fm.removeItem(atPath: (path as NSString).appendingPathComponent(child))
            }
        }
    }

    static func format(_ n: Int64) -> String {
        if n < 0 { return "—" }
        if n == 0 { return "0 B" }
        let f = ByteCountFormatter(); f.allowedUnits = [.useAll]; f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}
