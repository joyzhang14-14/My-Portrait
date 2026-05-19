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

    private var registered = false
    private var lastTheme: String = ""
    private var lastAlwaysOnTop: Bool = false
    private var lastDockIcon: String = ""
    private var lastAppName: String = ""
    private var lastLaunchAtLogin: Bool = false

    private init() {}

    /// Set up the observation loop. Called once at app launch.
    func install(window: NSWindow) {
        guard !registered else { return }
        registered = true
        mainWindow = window
        // Snapshot current values so the first pass through the trampoline
        // doesn't fire onChange handlers for stuff that's already correct.
        let c = ConfigStore.shared.display
        lastTheme         = c.theme
        lastAlwaysOnTop   = c.chatAlwaysOnTop
        lastDockIcon      = c.customDockIcon
        lastAppName       = c.appName
        lastLaunchAtLogin = ConfigStore.shared.general.launchAtLogin
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
        if display.chatAlwaysOnTop != lastAlwaysOnTop {
            lastAlwaysOnTop = display.chatAlwaysOnTop
            mainWindow?.level = display.chatAlwaysOnTop ? .floating : .normal
        }

        // App name → window title
        if display.appName != lastAppName {
            lastAppName = display.appName
            mainWindow?.title = display.appName.isEmpty ? "" : display.appName
        }

        // Custom Dock icon
        if display.customDockIcon != lastDockIcon {
            lastDockIcon = display.customDockIcon
            if display.customDockIcon.isEmpty {
                NSApp.applicationIconImage = nil   // revert to bundle default
            } else if let img = NSImage(contentsOfFile: display.customDockIcon) {
                NSApp.applicationIconImage = img
            }
        }

        // Launch at login
        if general.launchAtLogin != lastLaunchAtLogin {
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
