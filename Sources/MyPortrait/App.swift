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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)        // Show in Dock, can be key window
        NSApp.activate(ignoringOtherApps: true)    // Bring to front

        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.styleMask.insert(.resizable)
                window.setContentSize(NSSize(width: 1200, height: 835))
                window.center()

                // Per Apple's macOS 15+ pattern: transparent title bar + fullSize
                // content view, then let SwiftUI's .toolbarVisibility(.hidden,
                // for: .windowToolbar) kill the NSToolbar layer above it. This
                // combination floats the traffic lights over the content
                // without leaving a chrome strip.
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false

                window.makeKeyAndOrderFront(nil)
            }
        }
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
