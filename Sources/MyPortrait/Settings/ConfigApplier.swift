import SwiftUI
import AppKit
import Observation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Watches `ConfigStore` and pushes every chrome-level setting (theme,
/// always-on-top, window title, custom Dock icon, launch-at-login, …)
/// into the system APIs that actually have effect. Lives for the app
/// lifetime; installed once from `AppDelegate.applicationDidFinishLaunching`.
@MainActor
final class ConfigApplier {
    static let shared = ConfigApplier()

    /// Weakly-held reference to the main window. Set by AppDelegate after
    /// the window is created so we can update `.level` / `.title`.
    weak var mainWindow: NSWindow?

    /// Set by AppDelegate at launch so we can drive show/hide + custom icon.
    weak var statusBar: StatusBarMenu?

    private var registered = false
    // 这些字段用 sentinel "<<UNAPPLIED>>" 初始化,确保 install() 里第一次
    // applyAll 走 if x != lastX 路径全部 apply。否则启动时 dock icon /
    // tray icon / window title 都不会按 config 重 apply,重启后 customize
    // 看着完全不生效。
    private static let unapplied = "<<UNAPPLIED>>"
    private var lastTheme: String = ConfigApplier.unapplied
    private var lastAlwaysOnTop: Bool? = nil
    private var lastDockIcon: String = ConfigApplier.unapplied
    private var lastTrayIcon: String = ConfigApplier.unapplied
    private var lastShowInMenuBar: Bool? = nil
    private var lastAppName: String = ConfigApplier.unapplied
    private var lastLaunchAtLogin: Bool? = nil

    private init() {}

    /// Set up the observation loop. Called once at app launch.
    func install(window: NSWindow, statusBar: StatusBarMenu? = nil) {
        guard !registered else { return }
        registered = true
        mainWindow = window
        self.statusBar = statusBar
        // **不 snapshot** —— lastXxx 已用 sentinel 初始化,applyAll 第一次
        // 跑会全部应用一遍(包括 customize 的 dock/tray icon)。这才是
        // 重启后能看到 customize 生效的关键。
        applyAll()
        trampoline()
    }

    /// Re-applies every setting. Re-invoked from `withObservationTracking`
    /// whenever any read config field changes.
    private func trampoline() {
        withObservationTracking {
            // READ every field we care about so the closure re-fires.
            _ = ConfigStore.shared.display.theme
            _ = ConfigStore.shared.display.chatAlwaysOnTop
            _ = ConfigStore.shared.display.customDockIcon
            _ = ConfigStore.shared.display.customTrayIcon
            _ = ConfigStore.shared.display.showInMenuBar
            _ = ConfigStore.shared.display.appName
            _ = ConfigStore.shared.general.launchAtLogin
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyAll()
                self?.trampoline()    // re-arm for the next change
            }
        }
    }

    /// Diff against the last-applied snapshot + push changed fields to the
    /// system. Cheap to call every tick — no-ops when nothing moved.
    func applyAll() {
        let display = ConfigStore.shared.display
        let general = ConfigStore.shared.general

        // Theme
        if display.theme != lastTheme {
            lastTheme = display.theme
            switch display.theme {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
            default:      NSApp.appearance = nil    // follow system
            }
        }

        // Always on top
        if lastAlwaysOnTop != display.chatAlwaysOnTop {
            lastAlwaysOnTop = display.chatAlwaysOnTop
            mainWindow?.level = display.chatAlwaysOnTop ? .floating : .normal
        }

        // App name → window title
        if display.appName != lastAppName {
            lastAppName = display.appName
            mainWindow?.title = display.appName.isEmpty ? "" : display.appName
        }

        // Custom Dock icon —— NSImage(contentsOfFile:) 是同步磁盘 IO,放主线程
        // 会卡(且 applyAll 是 ConfigStore observation 触发的,改 config 时
        // 频繁跑)。后台读完回主线程赋图。
        if display.customDockIcon != lastDockIcon {
            lastDockIcon = display.customDockIcon
            if display.customDockIcon.isEmpty {
                NSApp.applicationIconImage = nil   // revert to bundle default
            } else {
                let p = display.customDockIcon
                Task.detached(priority: .userInitiated) {
                    let img = NSImage(contentsOfFile: p)
                    await MainActor.run {
                        if let img { NSApp.applicationIconImage = img }
                    }
                }
            }
        }

        // Tray icon — user-supplied PNG path replaces the SF Symbol.
        if display.customTrayIcon != lastTrayIcon {
            lastTrayIcon = display.customTrayIcon
            statusBar?.setCustomIconPath(display.customTrayIcon)
        }

        // Status-bar visibility
        if lastShowInMenuBar != display.showInMenuBar {
            lastShowInMenuBar = display.showInMenuBar
            statusBar?.setVisible(display.showInMenuBar)
        }

        // Launch at login
        if lastLaunchAtLogin != general.launchAtLogin {
            lastLaunchAtLogin = general.launchAtLogin
            applyLaunchAtLogin(general.launchAtLogin)
        }
    }

    /// Registers / unregisters the app with macOS login items via
    /// `SMAppService.mainApp`. Available on macOS 13+.
    private func applyLaunchAtLogin(_ on: Bool) {
        #if canImport(ServiceManagement)
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Best-effort — surface in console only. Common failure mode is
            // running an unsigned dev build, which SM rejects.
            NSLog("Launch at login toggle failed: \(error.localizedDescription)")
        }
        #endif
    }
}
