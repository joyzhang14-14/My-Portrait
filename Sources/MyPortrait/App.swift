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
        // Kill the native macOS title bar (the strip with "My Portrait" + traffic
        // lights). `.toolbar(.hidden)` alone doesn't remove this — it's a separate
        // window chrome layer. Hiding it lets the date controls sit at the top
        // without a duplicate header above them. Traffic lights still float.
        .windowStyle(.hiddenTitleBar)
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

        // Force initial window to the target size + ensure resizable.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.styleMask.insert(.resizable)
                window.setContentSize(NSSize(width: 1200, height: 835))
                window.center()
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
