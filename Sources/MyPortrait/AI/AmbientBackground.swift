import SwiftUI

/// Ambient background for the chat surface: slowly drifting color blobs + a
/// cursor-following soft glow + grain. Designed to fill the whole content area
/// behind the chat. Use as `.background(AmbientBackground())`.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color.black

            // Animated drifting color blobs. TimelineView gives us a per-frame
            // clock without driving SwiftUI state ⇒ no view-tree invalidation.
            // 30 fps — blobs drift on 40+s cycles, so the human eye can't
            // tell, but the GPU saves half a heavy blur+screen pass per second.
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0/30.0, paused: false)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Canvas { gctx, size in
                    drawBlobs(into: &gctx, size: size, t: t)
                }
                .blur(radius: 60)
                .blendMode(.screen)
            }
            .opacity(0.65)

            // Subtle grain to break up the gradient smoothness.
            GrainOverlay()
                .opacity(0.045)
                .blendMode(.overlay)
                .allowsHitTesting(false)

            // Soft halo that follows the cursor.
            CursorHalo()
                .allowsHitTesting(false)
        }
        .compositingGroup()
        .ignoresSafeArea()
    }

    /// 4 large radial-gradient orbs that drift on individual Lissajous-ish
    /// paths. Period ≈ 30-60s so motion is just barely perceptible.
    private func drawBlobs(into ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let blobs: [(hue: Double, radius: CGFloat, periodX: Double, periodY: Double, phase: Double)] = [
            (0.74, 320, 47, 39, 0.0),   // violet
            (0.86, 280, 53, 41, 1.7),   // magenta
            (0.55, 360, 61, 49, 3.4),   // indigo / blue
            (0.50, 240, 43, 37, 5.1),   // cyan
        ]
        for b in blobs {
            let x = size.width  * (0.5 + 0.35 * sin((t / b.periodX) * .pi * 2 + b.phase))
            let y = size.height * (0.5 + 0.35 * cos((t / b.periodY) * .pi * 2 + b.phase))
            let color = Color(hue: b.hue, saturation: 0.55, brightness: 0.85)
            let rect = CGRect(x: x - b.radius, y: y - b.radius, width: b.radius * 2, height: b.radius * 2)
            let shading: GraphicsContext.Shading = .radialGradient(
                Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                center: CGPoint(x: x, y: y),
                startRadius: 0, endRadius: b.radius
            )
            ctx.fill(Path(ellipseIn: rect), with: shading)
        }
    }
}

// MARK: - Grain overlay

/// Procedural noise texture rendered once into an Image and tiled. Cheap and
/// it gives the gradient surface a film-like grain rather than plastic shine.
private struct GrainOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                // Render small white-ish dots at pseudo-random positions.
                // We deliberately don't animate this — static grain reads as
                // "texture", animated grain reads as TV static.
                var rng = SystemRandomNumberGenerator()
                let count = Int((size.width * size.height) / 1200)
                for _ in 0..<count {
                    let x = Double.random(in: 0..<Double(size.width), using: &rng)
                    let y = Double.random(in: 0..<Double(size.height), using: &rng)
                    let a = Double.random(in: 0.0..<0.5, using: &rng)
                    let r = CGRect(x: x, y: y, width: 1, height: 1)
                    ctx.fill(Path(r), with: .color(.white.opacity(a)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .drawingGroup()    // rasterise once; this view never re-renders.
        }
    }
}

// MARK: - Cursor-following halo

/// A 240-pt soft radial gradient that follows the mouse. Implemented via
/// `.onContinuousHover` so we only pay for redraws while the cursor is over
/// the content area.
private struct CursorHalo: View {
    @State private var location: CGPoint = .zero
    @State private var visible: Bool = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if visible {
                    // No `.animation(_:value:)` — animating the position of a
                    // 400-pt blurred radial fill on every mouse pixel was the
                    // single hottest path in the render loop. The halo now
                    // simply snaps to the cursor; eye still reads "follows
                    // smoothly" because the cursor itself moves smoothly.
                    RadialGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 200
                    )
                    .frame(width: 400, height: 400)
                    .position(location)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                location = p
                visible = true
            case .ended:
                visible = false
            }
        }
    }
}
