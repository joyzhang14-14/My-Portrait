import SwiftUI
import AppKit
import os.log

@main
struct MyPortraitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        AppKeyboard.install()
    }

    var body: some Scene {
        // No WindowGroup — the AppDelegate creates the main window via
        // AppKit so SwiftUI doesn't insert any toolbar chrome of its own.
        // The `Settings` scene gives us the standard ⌘, → Settings flow
        // via the App menu without polluting the main sidebar.
        Settings {
            SettingsScene()
                .preferredColorScheme(.dark)
                .frame(minWidth: 880, minHeight: 580)
        }
    }
}

// MARK: - NSWindow subclass that refuses to ever have an NSToolbar

/// SwiftUI's NavigationSplitView keeps trying to install a sidebar-toggle
/// toolbar item, which forces an NSToolbar layer on the window. Overriding
/// the `toolbar` setter to no-op makes the window flat-out reject any
/// attempt to attach one. Combined with `.fullSizeContentView` + transparent
/// title bar, this leaves a single chrome layer: the title bar with the
/// traffic-light buttons floating over the content.
final class ChromelessWindow: NSWindow {
    override var toolbar: NSToolbar? {
        get { nil }
        set { /* refuse — keep nil forever */ }
    }
}

// MARK: - AppDelegate — owns the single app window

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: ChromelessWindow!
    var services: Services!
    var statusBarMenu: StatusBarMenu!

    private let lifecycleLog = Logger(subsystem: "com.myportrait", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 服务层先起（无 UI 依赖，可在权限请求前 init）
        services = Services()
        statusBarMenu = StatusBarMenu(settings: services.settings)

        // 确保磁盘目录结构存在
        do {
            try Storage.ensureExists()
        } catch {
            lifecycleLog.error("Storage.ensureExists failed: \(error.localizedDescription, privacy: .public)")
        }

        NSApp.setActivationPolicy(.regular)

        window = ChromelessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 835),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 500)
        window.backgroundColor = .black
        // Explicit unhide — some macOS 26 chrome configurations hide these
        // by default when the title bar is transparent.
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false

        // Host the SwiftUI ContentView inside the AppKit window.
        // Inject the Services container + captureSettings into the environment
        // so any descendant view can read \.services (db / coordinator / reporter)
        // or \.captureSettings (toggle bindings for the Settings UI).
        let hosting = NSHostingView(
            rootView: ContentView()
                .environment(\.services, services)
                .environment(\.captureSettings, services.settings)
                .environmentObject(services.settings)
                .preferredColorScheme(.dark)
        )
        hosting.autoresizingMask = [.width, .height]
        // Default sizingOptions let SwiftUI's intrinsic size feed back into the
        // window — when frames reload on a date switch the intrinsic size
        // transiently changes and the visible content "shrinks" vertically.
        // Empty options keeps the window size fixed regardless of content.
        hosting.sizingOptions = []
        window.contentView = hosting

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wire config → window/app chrome. Theme / always-on-top / app name
        // / Dock icon / launch-at-login all flow through this once ConfigStore
        // changes (vim edits or in-app toggles both fire the trampoline).
        ConfigApplier.shared.install(window: window)
        RetentionRunner.shared.start()

        // 3. 启动 services 生命周期管理。
        //    - compactor / transcriber 立即开始（空转零成本）
        //    - coordinator / audio **由 settings 驱动**：默认开关都 OFF →
        //      首启不弹屏幕录制 / 麦克风权限。用户在 Settings 面板打开后才启。
        services.startManagedLifecycle()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 进程退出前尽量优雅停止所有子系统（刷盘、关 SCStream、停 compaction、停录音）。
        // 同步等最多 ~1s，超时由系统 ~5s 后强制 kill 兜底。
        let sem = DispatchSemaphore(value: 0)
        let services = self.services
        Task.detached(priority: .userInitiated) {
            await services?.stopManagedLifecycle()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.0)
    }
}

// MARK: - App-level keyboard monitor — broadcasts arrow keys via NotificationCenter

enum AppKeyboard {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            print("[Keyboard] keyDown keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "")")
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            let isAlt = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 123:    // LeftArrow
                NotificationCenter.default.post(name: .leftArrowPressed, object: isAlt)
                return nil
            case 124:    // RightArrow
                NotificationCenter.default.post(name: .rightArrowPressed, object: isAlt)
                return nil
            default:
                return event
            }
        }
    }
}

extension Notification.Name {
    static let leftArrowPressed = Notification.Name("MyPortrait.LeftArrow")
    static let rightArrowPressed = Notification.Name("MyPortrait.RightArrow")
}
