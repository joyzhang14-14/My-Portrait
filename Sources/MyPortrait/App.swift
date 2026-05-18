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
        // Deliberately no WindowGroup — the AppDelegate creates the window
        // directly via AppKit so SwiftUI / NavigationSplitView can't insert
        // any toolbar chrome of its own. Settings { EmptyView() } is just a
        // valid placeholder scene; nothing visible attaches to it.
        Settings { EmptyView() }
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
    var devModeIndicator: DevModeStatusItem!

    private let lifecycleLog = Logger(subsystem: "com.myportrait", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 服务层先起（无 UI 依赖，可在权限请求前 init）
        services = Services()
        devModeIndicator = DevModeStatusItem(reporter: services.reporter)

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
        // Inject the Services container into the environment so any descendant
        // view can read \.services to access db / coordinator / reporter.
        let hosting = NSHostingView(
            rootView: ContentView()
                .environment(\.services, services)
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

        // 3. 启动采集流水线（异步，不阻塞 UI 显示）。
        // P0 stub 会 throw notImplemented —— 由 reporter 上报、状态栏亮红点。
        // app 不崩。
        let coordinator = services.coordinator
        Task.detached(priority: .userInitiated) { [lifecycleLog] in
            do {
                try await coordinator.start()
            } catch {
                lifecycleLog.error("coordinator.start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 进程退出前尽量优雅停止采集（刷盘、关 SCStream）。
        // 同步等最多 ~1s，超时由系统 ~5s 后强制 kill 兜底。
        let sem = DispatchSemaphore(value: 0)
        let coordinator = services?.coordinator
        Task.detached(priority: .userInitiated) {
            await coordinator?.stop()
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
