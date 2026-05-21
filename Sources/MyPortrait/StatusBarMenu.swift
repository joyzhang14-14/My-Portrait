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
        self.audioToggle = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
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
    }

    // MARK: - 真实录音状态（= 意图开关 && 没暂停 && 权限已授）

    /// capture 开关的单一真相是 ConfigStore，不读 settings 镜像（镜像可能 desync）。
    private var screenCaptureWanted: Bool { ConfigStore.shared.recording.screen.enabled }
    private var audioCaptureWanted: Bool { ConfigStore.shared.recording.audio.enabled }

    /// 屏幕**实际**是否在录。菜单勾选 / 图标 tooltip 用这个，不用裸的 toggle 意图。
    private var screenRecordingActive: Bool {
        screenCaptureWanted && permissions.screenRecording.isGranted
    }

    /// 麦克风**实际**是否在录。
    private var audioRecordingActive: Bool {
        audioCaptureWanted && permissions.microphone.isGranted
    }

    /// 打字采集开关意图（单一真相 ConfigStore）。
    private var typingCaptureWanted: Bool { ConfigStore.shared.recording.typingCaptureEnabled }

    /// 打字采集**实际**是否在跑。需要 Accessibility 权限。
    private var typingCaptureActive: Bool {
        typingCaptureWanted && permissions.accessibility.isGranted
    }

    // MARK: - NSMenuDelegate

    /// AppKit 在菜单显示前调用 —— 此刻强制按 ConfigStore 当前值重算所有 state。
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
    }

    // MARK: - 菜单构造

    private func buildMenu() {
        menu.addItem(statusHeader)
        menu.addItem(.separator())

        menu.addItem(screenToggle)
        menu.addItem(audioToggle)
        menu.addItem(typingToggle)
        menu.addItem(.separator())

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
        // User-supplied icon takes precedence.
        if !customIconPath.isEmpty,
           let img = NSImage(contentsOfFile: customIconPath) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true       // template auto-tints with menu-bar style
            statusItem.button?.image = img
        } else if let character = NSImage(named: "MenuBarIcon") {
            // 默认菜单栏图标：项目角色立绘。
            // **isTemplate = false 是关键**：角色图是彩色的，设 true 会被系统
            // 压成黑白剪影。彩图直接原样渲染。
            character.size = NSSize(width: 18, height: 18)
            character.isTemplate = false
            statusItem.button?.image = character
        }
        // 采集状态不再压进图标本身（角色图是固定的），改由 tooltip 表达。

        let toolTip: String
        if screenRecordingActive || audioRecordingActive || typingCaptureActive {
            var parts: [String] = []
            if screenRecordingActive { parts.append("Screen") }
            if audioRecordingActive { parts.append("Mic") }
            if typingCaptureActive { parts.append("Typing") }
            toolTip = "Recording: \(parts.joined(separator: " + "))"
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
            base: "Microphone",
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
            if audioRecordingActive { parts.append("Mic") }
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
        let next = !ConfigStore.shared.recording.screen.enabled
        ConfigStore.shared.mutate { $0.recording.screen.enabled = next }
        refreshMenuState()
    }

    @objc private func toggleAudio() {
        let next = !ConfigStore.shared.recording.audio.enabled
        ConfigStore.shared.mutate { $0.recording.audio.enabled = next }
        refreshMenuState()
    }

    /// 打字采集总开关 —— 跟 Settings → Recording 的「Capture typing」是同一个
    /// `typing_capture_enabled` 字段。翻转后 Services 那边的 sink 会启停
    /// TypingObserver。
    @objc private func toggleTyping() {
        let next = !ConfigStore.shared.recording.typingCaptureEnabled
        ConfigStore.shared.mutate { $0.recording.typingCaptureEnabled = next }
        refreshIcon()
        refreshMenuState()
    }

    @objc private func openPortraitDir() {
        NSWorkspace.shared.open(Storage.rootURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
