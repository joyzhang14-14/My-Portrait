import SwiftUI

struct GeneralSettingsView: View {
    @State private var config = ConfigStore.shared
    /// 调试入口 —— 触发后弹出独立的 onboarding sheet。等流程跑顺再切到首启自动弹。
    @State private var configStoreGen = ConfigStore.shared
    /// Permissions 卡片用。3s 轮询 TCC,用户在系统设置里改完这里自动跟上。
    @StateObject private var permissionMonitor = PermissionMonitor()
    /// 合盖 helper(SMAppService 后台项)是否已批准 —— 不是 TCC,单独轮询。
    @State private var helperApproved = false

    var body: some View {
        SettingsPage("General",
                     onResetCurrentPage: { config.mutate { $0.general = .init() } }) {

            SettingsCard(title: "Startup") {
                SettingsRow("Auto-start",
                            info: "Open My Portrait automatically when you log in.",
                            icon: "power") {
                    Toggle("", isOn: config.binding(\.general.launchAtLogin)).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Updates") {
                SettingsRow("Current version",
                            icon: "info.circle") {
                    VersionChip(text: Self.currentVersionString)
                }
                SettingsDivider()
                SettingsRow("Auto-update app",
                            icon: "arrow.down.app") {
                    Toggle("", isOn: config.binding(\.general.autoDownloadUpdates)).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Check for updates now",
                            icon: "arrow.clockwise.circle") {
                    Button("Check now") { UpdaterService.shared.checkForUpdates() }
                        .font(.system(size: 12, weight: .medium))
                }
            }
            // autoDownloadUpdates 的同步由 UpdaterService.observeConfig() 常驻监听
            //(这里以前挂过 onChange,但页面不在屏幕上时没人监听,vim 改
            // TOML 热加载后配置就是死的 —— 已收编进 service 本体)。
            // 检查间隔已写死 10 分钟,不再可配。

            // CronJob 历史保留条数。改下拉立刻 applyHistoryLimit 把 runs.json
            // 裁短(选 10 → 每条 cronJob 最多留 10 条 run)。0 = no limit。
            SettingsCard(title: "Cron Jobs") {
                SettingsRow("History per cron job",
                            info: "How many recent runs to keep for each cron job.",
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

            permissionsCard

            // Onboarding 在 ContentView 首启自动弹(没走完就反复弹);这里
             // 给「已走完」的用户一个再看一次的入口。点这个不会重置首启 flag,
             // 只是临时显示一次 sheet。
             //
             // 08-09:只在 dev mode 下露出 —— 普通用户走完一次就不该再见到它。
             // 少给的那条补救路径(漏授权 / 换供应商)上面 Permissions 卡里
             // 每一项都有自己的授权按钮,不靠重走 onboarding。
            if DevMode.isOn {
                SettingsCard(title: "Onboarding") {
                    SettingsRow("Replay onboarding",
                                info: "Opens the setup steps again.",
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

            if DevMode.isAvailable { devModeCard }
        }
    }

    // MARK: - Dev mode

    /// 只在 `~/.portrait-dev` 存在时渲染 —— 别人装的 app 里这张卡不存在。
    /// 判据故意用目录而不是密钥,理由见 `DevMode` 顶部。
    private var devModeCard: some View {
        SettingsCard(title: "Dev mode") {
            SettingsRow(
                DevMode.isOn ? "Currently using demo data" : "Use demo data",
                description: DevMode.isOn ? DevMode.rootURL.path : nil,
                info: "Points the app's UI at ~/.portrait-dev — made-up events, portrait and chats for debugging a fresh install or recording a demo. Screen/audio/typing capture and the memory pipeline keep reading and writing your real ~/.portrait the whole time. Capture, privacy, storage, scheduler and memory settings stay on your real config and become read-only.",
                icon: "hammer"
            ) {
                // 一键切换:改标志 → 刷盘 → 立刻重启。
                // **不做"开关 + 稍后重启"两步** —— 数据路径在进程内是冻结的
                // (见 DevMode.isOn),拨完开关到重启之间那段时间界面说的和实际
                // 用的根本不是一套,除了制造困惑没有任何用处。
                Button(DevMode.isOn ? "Switch back to my data" : "Switch to demo data") {
                    switchMode(to: !DevMode.isOn)
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    /// 切 dev mode 并重启。
    ///
    /// **必须 await saveNowAndWait**:`saveNow` 是 fire-and-forget Task,会被
    /// 紧接着的 NSApp.terminate 杀掉,配置没真落盘 —— 跟 AppCustomizeCard 的
    /// saveAndRestart 踩的是同一个坑。
    private func switchMode(to on: Bool) {
        DevMode.setEnabled(on)
        Task { @MainActor in
            await ConfigStore.shared.saveNowAndWait()
            AppRelaunch.run()
        }
    }

    // MARK: - Permissions

    /// 「你给过 App 哪些权限」一览。清单和 onboarding 共用 `PermissionCatalog`,
    /// 交互规矩也一样:给了显示 Granted,没给显示 Not granted + 授权入口。
    ///
    /// 这页存在的理由:权限是在 onboarding 里一次性给的,之后用户既想不起来
    /// 自己给了什么,也不知道某个功能不工作是因为少了哪项权限。
    private var permissionsCard: some View {
        SettingsCard(title: "Permissions") {
            let items = PermissionCatalog.items(monitor: permissionMonitor,
                                                helperApproved: helperApproved)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { SettingsDivider() }
                SettingsRow(item.title, info: item.why, icon: item.icon) {
                    HStack(spacing: 8) {
                        PermissionStatusPill(state: item.state)
                        if !item.state.isGranted {
                            if let request = item.request {
                                Button("Allow") { request() }
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Button("Open Settings") { item.openSettings() }
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }
        }
        .onAppear { permissionMonitor.start() }
        .onDisappear { permissionMonitor.stop() }
        // helper 是 SMAppService 后台项,不在 PermissionMonitor 的 TCC 轮询里 ——
        // 按同样的 3s 节奏自己查,用户在系统设置里批准完状态灯自动变绿。
        // .task 随视图消失自动取消,不用手动 stop。
        .task {
            while !Task.isCancelled {
                helperApproved = SleepHelperClient.shared.isApproved
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

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
