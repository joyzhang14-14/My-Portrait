import SwiftUI
import simd

/// 图谱画布:Canvas 全量重绘(边→球→hub 标签),手势(平移/缩放/hover/点选)。
///
/// P0 实测铁律:hub 标签走 `Canvas(symbols:)` 预光栅化,**禁止**逐帧
/// `ctx.resolve(Text)`(那样 5000 节点下掉 13% 帧)。
struct GraphCanvasView: View {
    let scene: GraphScene
    let positions: [SIMD2<Float>]
    @Binding var camera: GraphCamera
    @Binding var hoveredId: Int?
    /// 点到球(nil = 点空白)。P3 接浮窗/神经脉冲。
    var onTapNode: (Int?) -> Void = { _ in }

    /// 拖拽平移的累计量(DragGesture 给的是相对起点的总位移,要差分)。
    @State private var lastDragTranslation: CGSize = .zero
    /// 捏合缩放同理:相对手势起点的总倍率,要差分。
    @State private var lastMagnification: CGFloat = 1

    /// 命中网格:positions 变化时重建(O(n),微秒级)。
    private var hitGrid: GraphHitGrid {
        GraphHitGrid(positions: positions, radii: scene.nodes.map(\.radius))
    }

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            canvas(viewSize: viewSize)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(magnifyGesture(viewSize: viewSize))
                .gesture(tapGesture(viewSize: viewSize))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let world = camera.screenToWorld(p, viewSize: viewSize)
                        hoveredId = hitGrid.hit(world: world)
                    case .ended:
                        hoveredId = nil
                    }
                }
        }
    }

    // MARK: - Canvas

    private func canvas(viewSize: CGSize) -> some View {
        Canvas { ctx, size in
            guard positions.count == scene.nodes.count else { return }
            let zoom = camera.zoom
            let edgeShading = GraphicsContext.Shading.color(.gray.opacity(0.45))

            // --- 边(锥形橡皮筋:两端粗中间细) ---
            for e in scene.edges {
                let pa = camera.worldToScreen(positions[e.a], viewSize: size)
                let pb = camera.worldToScreen(positions[e.b], viewSize: size)
                // 视口剔除:两端都远在屏幕外的边跳过(粗略包围盒)
                if max(pa.x, pb.x) < -50 || min(pa.x, pb.x) > size.width + 50 ||
                   max(pa.y, pb.y) < -50 || min(pa.y, pb.y) > size.height + 50 { continue }
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
                dx /= len; dy /= len
                let nx = -dy, ny = dx
                let w = e.halfWidth * zoom
                let wm = w * GraphConstants.waistRatio
                let mx = (pa.x + pb.x) / 2, my = (pa.y + pb.y) / 2
                var p = Path()
                p.move(to: CGPoint(x: pa.x + nx * w, y: pa.y + ny * w))
                p.addQuadCurve(to: CGPoint(x: pb.x + nx * w, y: pb.y + ny * w),
                               control: CGPoint(x: mx + nx * wm, y: my + ny * wm))
                p.addLine(to: CGPoint(x: pb.x - nx * w, y: pb.y - ny * w))
                p.addQuadCurve(to: CGPoint(x: pa.x - nx * w, y: pa.y - ny * w),
                               control: CGPoint(x: mx - nx * wm, y: my - ny * wm))
                p.closeSubpath()
                ctx.fill(p, with: edgeShading)
            }

            // --- 球 ---
            for node in scene.nodes {
                let c = camera.worldToScreen(positions[node.id], viewSize: size)
                let r = node.radius * zoom
                if c.x + r < 0 || c.x - r > size.width || c.y + r < 0 || c.y - r > size.height {
                    continue
                }
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(node.color))
                // P1 的 hover 反馈:白色描边(P3 换成白色闪烁)
                if node.id == hoveredId {
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(0.85)),
                               lineWidth: max(1.5, 2 * zoom))
                }
            }

            // --- hub 常驻标题(symbols 预光栅化) ---
            for node in scene.nodes where node.kind.isHub {
                if let sym = ctx.resolveSymbol(id: node.id) {
                    let c = camera.worldToScreen(positions[node.id], viewSize: size)
                    let y = c.y + node.radius * zoom + 12
                    if c.x < -100 || c.x > size.width + 100 || y < -30 || y > size.height + 30 {
                        continue
                    }
                    ctx.draw(sym, at: CGPoint(x: c.x, y: y))
                }
            }
        } symbols: {
            ForEach(scene.nodes.filter { $0.kind.isHub }) { node in
                Text(node.title)
                    .font(.system(size: node.kind == .main ? 13 : 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .tag(node.id)
            }
        }
    }

    // MARK: - 手势

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let delta = CGSize(width: v.translation.width - lastDragTranslation.width,
                                   height: v.translation.height - lastDragTranslation.height)
                lastDragTranslation = v.translation
                camera.pan(byScreen: delta)
            }
            .onEnded { _ in lastDragTranslation = .zero }
    }

    private func magnifyGesture(viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let factor = v.magnification / lastMagnification
                lastMagnification = v.magnification
                camera.zoom(by: factor, anchor: v.startLocation, viewSize: viewSize)
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    private func tapGesture(viewSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { v in
                let world = camera.screenToWorld(v.location, viewSize: viewSize)
                onTapNode(hitGrid.hit(world: world))
            }
    }
}
