import SwiftUI

/// Shared visual language for My Portrait — glass, ambient, theme-aware.
///
/// `Theme` holds semantic colour / spacing tokens so every surface pulls from
/// the same palette instead of hand-rolling `.white.opacity(...)` everywhere.
/// `.glassCard()` wraps content in the floating frosted-glass card that the
/// sidebar (and, progressively, the main panes) are built from.
///
/// **Light/Dark**:所有 text/surface token 走 macOS NSColor semantic colors,
/// 系统 appearance(NSApp.appearance = .aqua/.darkAqua)切换自动响应。
/// 极少数视觉效果(glow / accent)颜色基本相同跨主题,不写 dynamic。
enum Theme {

    // MARK: Text — 3 tiers,跟随 system appearance 自动切。
    static let textPrimary   = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary  = Color(nsColor: .tertiaryLabelColor)

    // MARK: Interactive surfaces —— dynamic 灰阶,light/dark 都看得清。
    static let hover  = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor.black.withAlphaComponent(0.05)
            : NSColor.white.withAlphaComponent(0.06)
    })
    static let active = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor.black.withAlphaComponent(0.09)
            : NSColor.white.withAlphaComponent(0.10)
    })
    static let stroke = Color(nsColor: .separatorColor)

    /// Blue accent — close to the indigo ambient-background blob so
    /// highlights feel native to the gradient behind them. 不分主题。
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

/// Floating frosted-glass card: ultraThinMaterial + a faint tint wash + a
/// hairline gradient stroke + a soft drop shadow so the card visibly lifts
/// off the backdrop behind it.
///
/// **Light/Dark aware**:stroke / shadow / tint 全部跟着 colorScheme 切。
/// Light 用 black 颜色的低透明描边 + 柔和 shadow,Dark 用 white 描边 + 更深
/// shadow,跨主题保持"漂浮卡片"语义。
struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color = .white
    var corner: CGFloat = Theme.Radius.card

    private var strokeColors: [Color] {
        if colorScheme == .light {
            return [Color.black.opacity(0.08), Color.black.opacity(0.03)]
        }
        return [Color.white.opacity(0.16), Color.white.opacity(0.04)]
    }
    private var shadowColor: Color {
        colorScheme == .light ? .black.opacity(0.06) : .black.opacity(0.35)
    }
    private var tintOpacity: CGFloat {
        // Light 下白色 tint 让卡更亮;Dark 下保留原值。
        colorScheme == .light ? 0.45 : 0.05
    }

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(tint.opacity(tintOpacity))
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: strokeColors,
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.8)
                }
            )
            .shadow(color: shadowColor, radius: 12, x: 0, y: 6)
    }
}

extension View {
    /// Wrap content in a floating frosted-glass card. See `GlassCardModifier`.
    func glassCard(tint: Color = .white,
                   corner: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassCardModifier(tint: tint, corner: corner))
    }

    /// macOS 26+ 真 Liquid Glass(`.glassEffect()`),老系统 fallback `glassCard()`。
    /// 用在 Timeline 侧边栏的 ACTIVE APPS / AUDIO 两张卡 —— 这俩离主内容
    /// 最近,折射 / 高光最容易被用户注意到。其它卡仍走 .glassCard。
    @ViewBuilder
    func liquidGlassCard(corner: CGFloat = Theme.Radius.card) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            self.glassCard(corner: corner)
        }
    }
}

// MARK: - Sidebar backdrop

/// Sidebar / main pane 的「静态」背景。Dark 走近黑 + 紫色 glow,Light 走奶白
/// + 浅薰衣草 glow —— 跨主题都给 glass 卡一个能"浮起来"的底色。
///
/// `.ignoresSafeArea()` lives inside the body (same as `AmbientBackground`)
/// so that when used via `.background(SidebarBackdrop())` it reliably fills
/// the whole window — including under the transparent title bar — instead of
/// leaving a black strip at the top.
struct SidebarBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .light {
                // Light:奶白 → 极浅薰衣草。底色暖,跟 ultraThinMaterial 玻璃
                // 卡叠加后高级感强,不像纯白那么平。
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.96, blue: 0.99),
                        Color(red: 0.93, green: 0.92, blue: 0.96),
                    ],
                    startPoint: .top, endPoint: .bottom)
                // 浅薰衣草 glow,比 dark 强一些(light 底色亮,glow 不强看不出)。
                RadialGradient(
                    colors: [Color(hue: 0.72, saturation: 0.30, brightness: 0.92).opacity(0.40), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 420)
            } else {
                // Dark:原近黑 + 紫色 glow。
                LinearGradient(
                    colors: [Color(white: 0.10), Color(white: 0.05)],
                    startPoint: .top, endPoint: .bottom)
                RadialGradient(
                    colors: [Theme.accent.opacity(0.13), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 340)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Bouncy button

/// Button style that renders the label exactly like `.plain` (no chrome of
/// its own — the label keeps whatever background it already has) and plays a
/// one-shot SF Symbol `.bounce` animation each time the button is pressed,
/// plus a brief dim on press for tactile feedback.
///
/// Drop-in replacement for `.buttonStyle(.plain)` on any button.
struct BouncyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BouncyLabel(configuration: configuration)
    }

    /// A nested View is needed so we can hold `@State` — the press counter
    /// drives `.symbolEffect`, firing one bounce per press-down.
    private struct BouncyLabel: View {
        let configuration: Configuration
        @State private var taps = 0

        var body: some View {
            configuration.label
                .symbolEffect(.bounce, value: taps)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { taps += 1 }
                }
        }
    }
}

extension ButtonStyle where Self == BouncyIconButtonStyle {
    /// `.buttonStyle(.bouncyIcon)` — see `BouncyIconButtonStyle`.
    static var bouncyIcon: BouncyIconButtonStyle { BouncyIconButtonStyle() }
}
