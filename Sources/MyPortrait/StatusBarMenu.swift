import AppKit
import Combine
import Foundation

/// macOS 屏幕顶部状态栏菜单。是用户在 app 关窗后控制采集的入口。
///
/// 显示内容：
///   - 图标：基于当前状态变化（录制中 / 关闭 / Dev Mode）
///   - 菜单项：
///     * 屏幕采集 toggle
///     * 麦克风 toggle
///     * 打字采集 toggle
///     * 打开 ~/.portrait/ 文件夹
///     * Dev Mode 警告（仅 stub 命中时）
///     * 退出
///
/// 状态反应通过 Combine 订阅 CaptureSettings。用户操作直接修改 settings 字段，
/// 由 Services 那边的 sink 落到 coordinator/audio start/stop。
@MainActor
final class StatusBarMenu: NSObject, NSMenuDelegate {

    private let settings: CaptureSettings
    private let permissions: PermissionMonitor
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var cancellables: Set<AnyCancellable> = []

    /// Path to a user-supplied tray icon (Settings → Display → Tray icon).
    /// When non-empty, `refreshIcon` skips the state-driven SF Symbol and
    /// uses this image instead.
    private var customIconPath: String = ""

    // 菜单项缓存（要在状态变化时更新它们的 state / title）。
    private let screenToggle: NSMenuItem
    private let audioToggle: NSMenuItem
    /// Audio Capture 行下面挂的"Input device →"子菜单。菜单展开时
    /// (menuNeedsUpdate)动态重建,以反映最新设备列表 + 当前选中。
    private let inputDeviceMenuItem: NSMenuItem
    private let typingToggle: NSMenuItem
    private let statusHeader: NSMenuItem
    private let devModeBanner: NSMenuItem

    init(settings: CaptureSettings, permissions: PermissionMonitor) {
        self.settings = settings
        self.permissions = permissions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        self.statusHeader = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        self.statusHeader.isEnabled = false
        self.screenToggle = NSMenuItem(title: "Screen Capture", action: nil, keyEquivalent: "")
        self.audioToggle = NSMenuItem(title: "Audio Capture", action: nil, keyEquivalent: "")
        self.inputDeviceMenuItem = NSMenuItem(title: "Input device", action: nil, keyEquivalent: "")
        self.typingToggle = NSMenuItem(title: "Typing Capture", action: nil, keyEquivalent: "")
        self.devModeBanner = NSMenuItem(title: "⚠ Dev Mode (stub hits)", action: nil, keyEquivalent: "")
        self.devModeBanner.isEnabled = false
        self.devModeBanner.isHidden = true

        super.init()

        self.screenToggle.target = self
        self.screenToggle.action = #selector(toggleScreen)
        self.audioToggle.target = self
        self.audioToggle.action = #selector(toggleAudio)
        self.typingToggle.target = self
        self.typingToggle.action = #selector(toggleTyping)

        buildMenu()
        // 菜单每次打开前强制重算状态（menuNeedsUpdate）。Combine sink 时序不可靠
        // （settings 镜像层可能 desync），靠它会 stale；打开即刷新最稳。
        menu.delegate = self
        statusItem.menu = menu

        // 初始 icon。
        refreshIcon()

        // Combine 订阅：settings 任一字段 + 权限状态变化都刷新 icon + 菜单 state。
        // 菜单勾选要反映**真实录音状态**（开关 + 暂停 + 权限），所以权限变化也要订阅。
        Publishers.CombineLatest3(
            settings.$screenCaptureEnabled,
            settings.$audioCaptureEnabled,
            settings.$hasUnimplementedStubs
        )
        .sink { [weak self] _, _, _ in
            self?.refreshIcon()
            self?.refreshMenuState()
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            permissions.$screenRecording,
            permissions.$microphone,
            permissions.$accessibility
        )
        .sink { [weak self] _, _, _ in
            self?.refreshIcon()
            self?.refreshMenuState()
        }
        .store(in: &cancellables)

        // 健康状态变化 → 重画 icon(异常加红色徽标)
        HealthMonitor.shared.$unhealthy
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
    }

    // MARK: - 真实录音状态（= 意图开关 && 没暂停 && 权限已授）

    /// capture 开关的单一真相是 ConfigStore，不读 settings 镜像（镜像可能 desync）。
    private var screenCaptureWanted: Bool { ConfigStore.shared.capture.screen.enabled }
    private var audioCaptureWanted: Bool { ConfigStore.shared.capture.audio.enabled }

    /// 屏幕**实际**是否在录。菜单勾选 / 图标 tooltip 用这个，不用裸的 toggle 意图。
    private var screenRecordingActive: Bool {
        screenCaptureWanted && permissions.screenRecording.isGranted
    }

    /// 麦克风**实际**是否在录。
    private var audioRecordingActive: Bool {
        audioCaptureWanted && permissions.microphone.isGranted
    }

    /// 打字采集开关意图（单一真相 ConfigStore）。
    private var typingCaptureWanted: Bool { ConfigStore.shared.capture.typingCaptureEnabled }

    /// 打字采集**实际**是否在跑。需要 Accessibility 权限。
    private var typingCaptureActive: Bool {
        typingCaptureWanted && permissions.accessibility.isGranted
    }

    // MARK: - NSMenuDelegate

    /// AppKit 在菜单显示前调用 —— 此刻强制按 ConfigStore 当前值重算所有 state。
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
        rebuildInputDeviceSubmenu()
    }

    /// 用 AudioDevicesMonitor 的最新设备列表 + 当前 preferredUID 重建子菜单。
    /// menuNeedsUpdate 每次菜单展开都调,保证显示最新插拔状态。
    private func rebuildInputDeviceSubmenu() {
        let monitor = AudioDevicesMonitor.shared
        let preferred = ConfigStore.shared.current.capture.audio.preferredInputDeviceUID
        let systemAudioOn = ConfigStore.shared.current.capture.audio.captureSystemAudio
        let activeUID = monitor.activeUID
        let devices = monitor.devices

        let submenu = NSMenu()

        // Follow system default 项 —— 空 UID 时打勾。
        let followItem = NSMenuItem(
            title: "Follow system default",
            action: #selector(pickInputDevice(_:)), keyEquivalent: ""
        )
        followItem.target = self
        followItem.representedObject = ""   // 空 UID = follow system
        followItem.state = preferred.isEmpty ? .on : .off
        submenu.addItem(followItem)

        if !devices.isEmpty { submenu.addItem(.separator()) }

        for d in devices {
            // 名称 + 在录的设备右边加 "● recording" 视觉提示
            let title: String = (d.id == activeUID && !activeUID.isEmpty)
                ? "\(d.name)  ● recording"
                : d.name
            let item = NSMenuItem(title: title,
                                  action: #selector(pickInputDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = d.id
            item.state = (preferred == d.id) ? .on : .off
            // SF Symbol icon
            if let img = NSImage(systemSymbolName: d.transport.icon, accessibilityDescription: nil) {
                img.isTemplate = true
                item.image = img
            }
            submenu.addItem(item)
        }

        // System audio 是并行 loopback 路 —— 跟 mic 同时存在,不是替代。
        // 放在分隔线下方,文案用 "Also" 强调"叠加"语义,避免被当成单选项。
        submenu.addItem(.separator())
        let sysItem = NSMenuItem(
            title: "Also capture system audio",
            action: #selector(toggleSystemAudio(_:)), keyEquivalent: ""
        )
        sysItem.target = self
        sysItem.state = systemAudioOn ? .on : .off
        if let img = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) {
            img.isTemplate = true
            sysItem.image = img
        }
        submenu.addItem(sysItem)

        // 顶部标题既反映 mic 选择,也反映 system audio 是否在录
        let micPart: String
        if preferred.isEmpty {
            micPart = "follow system"
        } else if let d = devices.first(where: { $0.id == preferred }) {
            micPart = d.name
        } else {
            micPart = "locked, disconnected"
        }
        let summary = systemAudioOn
            ? "Input  (\(micPart) + system audio)"
            : "Input  (\(micPart))"
        inputDeviceMenuItem.title = summary
        inputDeviceMenuItem.submenu = submenu
    }

    @objc private func pickInputDevice(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        ConfigStore.shared.mutate { $0.capture.audio.preferredInputDeviceUID = uid }
        // Services.observePreferredInputDevice 会自动重启 audio engine。
    }

    @objc private func toggleSystemAudio(_ sender: NSMenuItem) {
        ConfigStore.shared.mutate {
            $0.capture.audio.captureSystemAudio.toggle()
        }
        // Services 已有 observe → 会自动重启 audio engine 应用新设置。
    }

    // MARK: - 菜单构造

    private func buildMenu() {
        menu.addItem(statusHeader)
        menu.addItem(.separator())

        menu.addItem(screenToggle)
        menu.addItem(audioToggle)
        menu.addItem(inputDeviceMenuItem)   // → submenu(每次 menuNeedsUpdate 重建)
        menu.addItem(typingToggle)
        menu.addItem(.separator())

        // 版本号行 —— 灰色 disabled item,用户看一眼就知道当前装的是哪版。
        // 从 Info.plist 读 CFBundleShortVersionString(marketing version)。
        let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "Version \(versionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let openWindow = NSMenuItem(
            title: "Open My Portrait", action: #selector(openMainWindow), keyEquivalent: "o"
        )
        openWindow.target = self
        menu.addItem(openWindow)

        let openDir = NSMenuItem(
            title: "Open ~/.portrait/", action: #selector(openPortraitDir), keyEquivalent: ""
        )
        openDir.target = self
        menu.addItem(openDir)
        menu.addItem(.separator())

        menu.addItem(devModeBanner)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit My Portrait", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        refreshMenuState()
    }

    // MARK: - 状态刷新

    /// Hide / show the entire status-bar item. Called by ConfigApplier
    /// in response to `display.showInMenuBar`.
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Apply a user-supplied PNG / icon path (Settings → Display → Tray icon).
    /// Empty string reverts to the state-driven SF Symbol.
    func setCustomIconPath(_ path: String) {
        customIconPath = path
        refreshIcon()
    }

    private func refreshIcon() {
        let unhealthy = HealthMonitor.shared.unhealthy
        if unhealthy {
            // 健康异常 —— 用红色感叹号 SF Symbol 替代默认 icon,**最显眼**。
            let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            if let warn = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                  accessibilityDescription: "MyPortrait health warning")?
                              .withSymbolConfiguration(conf) {
                warn.isTemplate = false
                statusItem.button?.image = warn
                statusItem.button?.contentTintColor = .systemRed
            }
        } else {
            statusItem.button?.contentTintColor = nil
            // User-supplied icon takes precedence.
            if !customIconPath.isEmpty,
               let img = NSImage(contentsOfFile: customIconPath) {
                img.size = NSSize(width: 18, height: 18)
                // **isTemplate = false** 关键 —— template 模式系统把图当 alpha
                // mask 用文字色绘制(黑/白),用户上传的彩色 PNG 会被压成剪影。
                // 跟默认 character icon 同款处理,彩图原样渲染。仿 My-Orphies
                // customize.rs:222 "Force template OFF so colours render"。
                img.isTemplate = false
                statusItem.button?.image = img
            } else if let character = NSImage(named: "MenuBarIcon") {
                // 默认菜单栏图标：项目角色立绘。
                // **isTemplate = false 是关键**：角色图是彩色的，设 true 会被系统
                // 压成黑白剪影。彩图直接原样渲染。
                character.size = NSSize(width: 18, height: 18)
                character.isTemplate = false
                statusItem.button?.image = character
            }
        }
        // 采集状态不再压进图标本身（角色图是固定的），改由 tooltip 表达。

        let toolTip: String
        if unhealthy {
            let faulty = HealthMonitor.shared.faults.keys.sorted().joined(separator: ", ")
            toolTip = "⚠ Capture issue: \(faulty)\n(see ~/.portrait/logs/health.log)"
        } else if screenRecordingActive || audioRecordingActive || typingCaptureActive {
            var parts: [String] = []
            if screenRecordingActive { parts.append("Screen") }
            if audioRecordingActive { parts.append("Audio") }
            if typingCaptureActive { parts.append("Typing") }
            toolTip = "Capture: \(parts.joined(separator: " + "))"
        } else {
            toolTip = "Capture off"
        }
        statusItem.button?.toolTip = toolTip
    }

    private func refreshMenuState() {
        // 勾 = 真实在录。开关 on 但权限没给 / 暂停中 → 不勾（对得上"没录音"）。
        screenToggle.state = screenRecordingActive ? .on : .off
        audioToggle.state = audioRecordingActive ? .on : .off
        typingToggle.state = typingCaptureActive ? .on : .off

        // 开关 on 但实际没录 → 标题给出原因，别让用户以为坏了。
        screenToggle.title = Self.toggleTitle(
            base: "Screen Capture",
            wanted: screenCaptureWanted,
            active: screenRecordingActive,
            permission: permissions.screenRecording
        )
        audioToggle.title = Self.toggleTitle(
            base: "Audio Capture",
            wanted: audioCaptureWanted,
            active: audioRecordingActive,
            permission: permissions.microphone
        )
        typingToggle.title = Self.toggleTitle(
            base: "Typing Capture",
            wanted: typingCaptureWanted,
            active: typingCaptureActive,
            permission: permissions.accessibility
        )

        if screenRecordingActive || audioRecordingActive || typingCaptureActive {
            var parts: [String] = []
            if screenRecordingActive { parts.append("Screen") }
            if audioRecordingActive { parts.append("Audio") }
            if typingCaptureActive { parts.append("Typing") }
            statusHeader.title = "Recording: \(parts.joined(separator: " + "))"
        } else {
            statusHeader.title = "Capture off"
        }

        devModeBanner.isHidden = !settings.hasUnimplementedStubs
    }

    /// 开关想开但实际没录时，标题补一句原因（权限没给）。
    private static func toggleTitle(
        base: String,
        wanted: Bool,
        active: Bool,
        permission: PermissionMonitor.Status
    ) -> String {
        guard wanted, !active else { return base }
        if !permission.isGranted {
            return "\(base) (no permission)"
        }
        return base
    }

    // MARK: - 菜单项动作

    @objc private func toggleScreen() {
        let next = !ConfigStore.shared.capture.screen.enabled
        ConfigStore.shared.mutate { $0.capture.screen.enabled = next }
        refreshMenuState()
    }

    @objc private func toggleAudio() {
        let next = !ConfigStore.shared.capture.audio.enabled
        ConfigStore.shared.mutate { $0.capture.audio.enabled = next }
        refreshMenuState()
    }

    /// 打字采集总开关 —— 跟 Settings → Recording 的「Typing Capture」是同一个
    /// `typing_capture_enabled` 字段。翻转后 Services 那边的 sink 会启停
    /// TypingObserver。
    @objc private func toggleTyping() {
        let next = !ConfigStore.shared.capture.typingCaptureEnabled
        ConfigStore.shared.mutate { $0.capture.typingCaptureEnabled = next }
        refreshIcon()
        refreshMenuState()
    }

    @objc private func openMainWindow() {
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    @objc private func openPortraitDir() {
        NSWorkspace.shared.open(Storage.rootURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
