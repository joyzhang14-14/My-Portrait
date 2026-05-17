import SwiftUI
import AppKit

@main
struct MyPortraitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        AppKeyboard.install()
    }

    var body: some Scene {
        WindowGroup("My Portrait") {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1200, height: 835)
        // NOTE: we deliberately do NOT use .windowStyle(.hiddenTitleBar) — on
        // some macOS versions it collapses the title bar to 0pt and takes the
        // traffic lights with it. Instead AppDelegate configures the NSWindow
        // manually: keeps traffic lights, hides the title text, lets content
        // extend under the title bar, and force-removes any NSToolbar that
        // SwiftUI tries to re-add after navigation changes.
    }
}

// MARK: - AppDelegate — forces proper macOS app status for SwiftPM-built executables.
//
// `swift run` produces a bare binary, not a `.app` bundle. By default macOS
// treats such processes as accessory apps that don't show in the Dock, can't
// be activated, and (most importantly here) don't reliably receive keyboard
// events through NSEvent monitors. The delegate fixes all three.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var chromeKeeper: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)        // Show in Dock, can be key window
        NSApp.activate(ignoringOtherApps: true)    // Bring to front

        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.styleMask.insert(.resizable)
                window.setContentSize(NSSize(width: 1200, height: 835))
                window.center()
                Self.applyChrome(to: window)
                window.makeKeyAndOrderFront(nil)
            }
        }

        // SwiftUI on macOS 26 quietly re-attaches an NSToolbar to the window on
        // navigation / state changes (the dark strip the user saw after
        // switching dates). Observers fire too late, so we poll every 0.4s
        // and strip any toolbar that snuck back. Cheap — just a property set.
        chromeKeeper = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            for w in NSApp.windows { Self.applyChrome(to: w) }
        }
    }

    /// Hide the title text, keep traffic lights, let content extend under the
    /// title bar, and forcibly remove any NSToolbar SwiftUI tries to add.
    static func applyChrome(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if window.toolbar != nil { window.toolbar = nil }

        // Make sure the traffic lights actually render — SwiftUI's default
        // chrome config on macOS 26 sometimes hides them when titleVisibility
        // is set to .hidden.
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - App-level keyboard monitor — broadcasts arrow keys via NotificationCenter

enum AppKeyboard {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // DIAGNOSTIC: prints to terminal — you should see this when pressing any key.
            // If you don't see it, the app isn't receiving keyboard events (sandboxing /
            // non-bundle status). If you DO see it, the rest of the chain is fine.
            print("[Keyboard] keyDown keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "")")

            // Don't intercept while typing in a text field
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
