import SwiftUI

/// Shared visual language for My Portrait — dark, glass, ambient.
///
/// `Theme` holds semantic colour / spacing tokens so every surface pulls from
/// the same palette instead of hand-rolling `.white.opacity(...)` everywhere.
/// `.glassCard()` wraps content in the floating frosted-glass card that the
/// sidebar (and, progressively, the main panes) are built from.
enum Theme {

    // MARK: Text — three legibility tiers on a dark backdrop
    static let textPrimary   = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary  = Color.white.opacity(0.36)

    // MARK: Interactive surfaces
    static let hover  = Color.white.opacity(0.06)
    static let active = Color.white.opacity(0.10)
    static let stroke = Color.white.opacity(0.10)

    /// Blue accent — close to the indigo ambient-background blob so
    /// highlights feel native to the gradient behind them.
    static let accent = Color(hue: 0.60, saturation: 0.70, brightness: 0.98)

    // MARK: Spacing scale — use these instead of magic numbers
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    // MARK: Corner radii
    enum Radius {
        static let card: CGFloat = 14
        static let row:  CGFloat = 8
        static let chip: CGFloat = 6
    }
}

// MARK: - Glass card

/// Floating frosted-glass card: frosted material + a faint tint wash + a
/// hairline gradient stroke + a soft drop shadow so the card visibly lifts
/// off the dark backdrop behind it.
struct GlassCardModifier: ViewModifier {
    var tint: Color = .white
    var corner: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(tint.opacity(0.05))
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.16), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.8)
                }
            )
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

extension View {
    /// Wrap content in a floating frosted-glass card. See `GlassCardModifier`.
    func glassCard(tint: Color = .white,
                   corner: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassCardModifier(tint: tint, corner: corner))
    }
}

// MARK: - Sidebar backdrop

/// Calm dark backdrop for the sidebar / main panes — a near-black vertical
/// gradient with a faint violet glow top-left, giving the glass cards
/// something to float over without paying for the animated
/// `AmbientBackground`.
///
/// `.ignoresSafeArea()` lives inside the body (same as `AmbientBackground`)
/// so that when used via `.background(SidebarBackdrop())` it reliably fills
/// the whole window — including under the transparent title bar — instead of
/// leaving a black strip at the top.
struct SidebarBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Theme.accent.opacity(0.13), .clear],
                center: .topLeading, startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Bouncy button

/// Button style that renders the label exactly like `.plain` (no chrome of
/// its own — the label keeps whatever background it already has) and gives
/// every press an unmistakable, springy bounce:
///   - the label scales down on press and springs back past 1.0 on release
///     (low damping ⇒ a visible overshoot bounce)
///   - any SF Symbol inside also plays its native `.bounce` effect
///
/// Drop-in replacement for `.buttonStyle(.plain)` on any button.
struct BouncyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .symbolEffect(.bounce, value: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.86 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.40),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BouncyIconButtonStyle {
    /// `.buttonStyle(.bouncyIcon)` — see `BouncyIconButtonStyle`.
    static var bouncyIcon: BouncyIconButtonStyle { BouncyIconButtonStyle() }
}
