import SwiftUI
import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let hosting = NSHostingView(rootView: ContentView().preferredColorScheme(.dark))
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
