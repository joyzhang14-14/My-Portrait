import SwiftUI
import AppKit

/// Invisible NSView that becomes the window's first responder and captures
/// `keyDown` events directly. Bypasses every SwiftUI focus quirk — events
/// arrive in `keyDown(with:)` regardless of what ScrollView, TextField, or
/// other SwiftUI view "wants" them.
///
/// Usage:
///   .background(
///     KeyboardCapture(
///       onLeft:     { ... },
///       onRight:    { ... },
///       onAltLeft:  { ... },
///       onAltRight: { ... }
///     )
///   )
struct KeyboardCapture: NSViewRepresentable {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    var onAltLeft: () -> Void = {}
    var onAltRight: () -> Void = {}

    func makeNSView(context: Context) -> KeyboardCaptureNSView {
        let v = KeyboardCaptureNSView()
        v.onLeft = onLeft
        v.onRight = onRight
        v.onAltLeft = onAltLeft
        v.onAltRight = onAltRight
        return v
    }

    func updateNSView(_ nsView: KeyboardCaptureNSView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
        nsView.onAltLeft = onAltLeft
        nsView.onAltRight = onAltRight
    }
}

final class KeyboardCaptureNSView: NSView {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    var onAltLeft: () -> Void = {}
    var onAltRight: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Grab first responder once the view is in a window. async so the
        // window has finished setting up its responder chain first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let isAlt = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123:   // LeftArrow
            isAlt ? onAltLeft() : onLeft()
        case 124:   // RightArrow
            isAlt ? onAltRight() : onRight()
        default:
            super.keyDown(with: event)
        }
    }

    // Silence the system "beep" for unhandled keys we don't care about
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 123 || event.keyCode == 124 {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
