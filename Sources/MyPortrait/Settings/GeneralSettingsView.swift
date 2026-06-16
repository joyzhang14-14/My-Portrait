import SwiftUI

struct GeneralSettingsView: View {
    @State private var config = ConfigStore.shared
    /// 调试入口 —— 触发后弹出独立的 onboarding sheet。等流程跑顺再切到首启自动弹。
    @State private var configStoreGen = ConfigStore.shared

    var body: some View {
        SettingsPage("General", subtitle: "Startup and updates",
                     onResetCurrentPage: { config.mutate { $0.general = .init() } }) {

            SettingsCard(title: "Startup") {
                SettingsRow("Auto-start",
                            description: "Open My Portrait automatically when you log in.",
                            icon: "power") {
                    Toggle("", isOn: config.binding(\.general.launchAtLogin)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Updates") {
                SettingsRow("Current version",
                            description: "Build currently installed. \"Check now\" below queries GitHub appcast for newer builds.",
                            icon: "info.circle") {
                    VersionChip(text: Self.currentVersionString)
                }
                SettingsDivider()
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
            // 两个字段的同步由 UpdaterService.observeConfig() 常驻监听
            //(这里以前挂过 onChange,但页面不在屏幕上时没人监听,vim 改
            // TOML 热加载后配置就是死的 —— 已收编进 service 本体)。

            // CronJob 历史保留条数。改下拉立刻 applyHistoryLimit 把 runs.json
            // 裁短(选 10 → 每条 cronJob 最多留 10 条 run)。0 = no limit。
            SettingsCard(title: "Cron Jobs") {
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

            SettingsCard(title: "Imports") {
                SettingsRow("Auto-scan everything from imports",
                            description: "Scan all import sources (screenpipe, Claude Code, Codex) automatically when you open the Import page. Off → each source waits until you press its Scan button.",
                            icon: "arrow.triangle.2.circlepath") {
                    Toggle("", isOn: config.binding(\.general.autoScanImports)).labelsHidden().toggleStyle(.switch)
                }
            }

            // Onboarding 在 ContentView 首启自动弹(没走完就反复弹);这里
             // 给「已走完」的用户一个再看一次的入口。点这个不会重置首启 flag,
             // 只是临时显示一次 sheet。
            SettingsCard(title: "Onboarding") {
                SettingsRow("Replay onboarding",
                            description: "Opens the setup steps again — handy for granting a permission you skipped or switching your AI provider.",
                            icon: "sparkles") {
                    Button("Show") {
                        // **走 ContentView 同款 if/else 全屏切换**,不用 sheet。
                        // sheet 模式两个 bug:① attached sheet 主窗口在背后能看到
                        // ② dismiss 后 NSHostingView 重算 intrinsic size 收缩窗口。
                        // 把 onboardingCompleted 设 false → ContentView 立刻把
                        // mainContent 换成 OnboardingView 填满整个窗口;onboarding
                        // finish callback 把 flag 设回 true → 切回 mainContent。
                        configStoreGen.mutate { $0.general.onboardingCompleted = false }
                        configStoreGen.saveNow()
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private static let minutesFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 1; f.maximum = 1440; f.allowsFloats = false
        return f
    }()

    /// 显示给用户的版本号 —— 只显示 marketing version
    /// (CFBundleShortVersionString,"1.0.82" 之类)。Build number
    /// (CFBundleVersion)是 Sparkle 内部比版本用的,用户不关心,不显示。
    private static let currentVersionString: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }()

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

/// 版本号小药丸 —— Settings → General → Current version 用。
/// fill/stroke 跟 colorScheme 切:light 主题底色奶白,之前钉死
/// `Color.white.opacity(0.05)` 在白底上完全不可见。
private struct VersionChip: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let fill   = colorScheme == .light ? Color.black.opacity(0.05) : Color.white.opacity(0.05)
        let stroke = colorScheme == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.10)
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(stroke, lineWidth: 1)
                    )
            )
    }
}
