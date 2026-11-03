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

    /// 强调色:琥珀(表盘夜光 / 台灯)。只用在选中、主操作和那一个关键数字上;
    /// 浅色主题用深一档,保证当文字用时对比度够。
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 0.72, green: 0.45, blue: 0.06, alpha: 1)
            : NSColor(red: 0.91, green: 0.64, blue: 0.24, alpha: 1)
    })

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

/// Sidebar / main pane 的「静态」背景:中性灰阶,上浅下深一点点,没有色光晕。
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
                LinearGradient(colors: [Color(white: 0.98), Color(white: 0.955)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        // 拖窗只认这层底图 —— 窗口的 isMovableByWindowBackground 已经关掉
        // (见 App.swift),否则按住任意按钮拖动都会把整个窗口拽走。
        // 盖在底图之上的一切(卡片 / 按钮 / 列表行)因此天然不拖窗。
        .gesture(WindowDragGesture())
    }
}

// MARK: - 拖窗防护

extension View {
    /// 挡住「按住拖动 = 拖窗」。
    ///
    /// 右侧画布那一层挂了 `WindowDragGesture()`(见 ContentView.mainSplit),
    /// 靠的是"子视图手势优先于父视图"—— Button 自带按压手势所以天然免疫,
    /// 但 **Menu / Picker 这类下拉触发区不认领拖拽**,不挡的话在它们身上按住
    /// 拖会把整个窗口拽走。
    ///
    /// `DragGesture()` 的 minimumDistance 是默认的 10pt:点击(零位移)照常
    /// 穿过去交给控件,只有真的拖起来才被这条空手势吃掉。
    func blocksWindowDrag() -> some View {
        gesture(DragGesture().onChanged { _ in })
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
