import SwiftUI
import simd

/// 图谱画布:TimelineView 驱动的 Canvas 全量重绘(边→球→hub 标签)。
/// 位置每帧从物理引擎的双缓冲快照读取;物理休眠时 TimelineView 暂停
/// (paused),重绘只由相机/hover 等状态变化触发 → CPU≈0。
///
/// 手势:
///   - 拖空白/主球 = 相机平移;拖末端球/hub = 拖球(物理 reheat,邻居跟着晃)
///   - 捏合 = 锚点缩放;hover = 命中高亮;点击 = onTapNode(P3 接浮窗/脉冲)
///
/// P0 实测铁律:hub 标签走 `Canvas(symbols:)` 预光栅化,**禁止**逐帧
/// `ctx.resolve(Text)`(那样 5000 节点下掉 13% 帧)。
struct GraphCanvasView: View {
    let scene: GraphScene
    let engine: GraphPhysicsEngine
    /// 物理休眠 → true,暂停 TimelineView 的逐帧重绘。
    let paused: Bool
    @Binding var camera: GraphCamera
    @Binding var hoveredId: Int?
    /// 点到球(nil = 点空白)。P3 接浮窗/神经脉冲。
    var onTapNode: (Int?) -> Void = { _ in }

    /// 一次拖拽手势的模式:起点落在球上=拖球,否则=平移相机。
    private enum DragMode: Equatable { case idle, pan, node(Int) }
    @State private var dragMode: DragMode = .idle
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            // 显式 SwiftUI. 前缀:项目自己有个叫 TimelineView 的时间线视图,撞名。
            SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: paused)) { _ in
                canvas(viewSize: viewSize)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(viewSize: viewSize))
            .simultaneousGesture(magnifyGesture(viewSize: viewSize))
            .gesture(tapGesture(viewSize: viewSize))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoveredId = hitTest(screen: p, viewSize: viewSize)
                case .ended:
                    hoveredId = nil
                }
            }
        }
    }

    /// 屏幕点 → 命中的节点。用当前快照建网格(O(n),µs 级,事件频率下无感)。
    private func hitTest(screen: CGPoint, viewSize: CGSize) -> Int? {
        let snap = engine.readSnapshot()
        guard snap.count == scene.nodes.count else { return nil }
        let world = camera.screenToWorld(screen, viewSize: viewSize)
        return GraphHitGrid(positions: snap, radii: scene.nodes.map(\.radius))
            .hit(world: world)
    }

    // MARK: - Canvas

    private func canvas(viewSize: CGSize) -> some View {
        Canvas { ctx, size in
            let snap = engine.readSnapshot()
            guard snap.count == scene.nodes.count else { return }
            let zoom = camera.zoom
            let edgeShading = GraphicsContext.Shading.color(.gray.opacity(0.45))

            // --- 边(锥形橡皮筋:两端粗中间细) ---
            for e in scene.edges {
                let pa = camera.worldToScreen(snap[e.a], viewSize: size)
                let pb = camera.worldToScreen(snap[e.b], viewSize: size)
                // 视口剔除:两端都远在屏幕外的边跳过(粗略包围盒)
                if max(pa.x, pb.x) < -50 || min(pa.x, pb.x) > size.width + 50 ||
                   max(pa.y, pb.y) < -50 || min(pa.y, pb.y) > size.height + 50 { continue }
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
                dx /= len; dy /= len
                let nx = -dy, ny = dx
                // 端宽逐端不同(= 各自球半径,builder 已截断 15):
                // 神经末梢从球体上「长」出来的视觉。腰部 = 细端 × waistRatio。
                let wa = e.halfWidthA * zoom
                let wb = e.halfWidthB * zoom
                let wm = min(wa, wb) * GraphConstants.waistRatio
                let mx = (pa.x + pb.x) / 2, my = (pa.y + pb.y) / 2
                var p = Path()
                p.move(to: CGPoint(x: pa.x + nx * wa, y: pa.y + ny * wa))
                p.addQuadCurve(to: CGPoint(x: pb.x + nx * wb, y: pb.y + ny * wb),
                               control: CGPoint(x: mx + nx * wm, y: my + ny * wm))
                p.addLine(to: CGPoint(x: pb.x - nx * wb, y: pb.y - ny * wb))
                p.addQuadCurve(to: CGPoint(x: pa.x - nx * wa, y: pa.y - ny * wa),
                               control: CGPoint(x: mx - nx * wm, y: my - ny * wm))
                p.closeSubpath()
                ctx.fill(p, with: edgeShading)
            }

            // --- 球 ---
            for node in scene.nodes {
                let c = camera.worldToScreen(snap[node.id], viewSize: size)
                let r = node.radius * zoom
                if c.x + r < 0 || c.x - r > size.width || c.y + r < 0 || c.y - r > size.height {
                    continue
                }
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(node.color))
                // P2 的 hover 反馈:白色描边(P3 换成白色闪烁)
                if node.id == hoveredId {
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(0.85)),
                               lineWidth: max(1.5, 2 * zoom))
                }
            }

            // --- hub 常驻标题(symbols 预光栅化) ---
            for node in scene.nodes where node.kind.isHub {
                if let sym = ctx.resolveSymbol(id: node.id) {
                    let c = camera.worldToScreen(snap[node.id], viewSize: size)
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

    private func dragGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragMode == .idle {
                    // 起点定模式:球(非主球)= 拖球;空白/主球 = 平移。
                    // 主球钉死原点(大脑不动),拖它等于拖整个世界 → 归平移。
                    if let idx = hitTest(screen: v.startLocation, viewSize: viewSize), idx > 0 {
                        dragMode = .node(idx)
                        engine.beginDrag(index: idx,
                                         at: camera.screenToWorld(v.location, viewSize: viewSize))
                    } else {
                        dragMode = .pan
                    }
                }
                switch dragMode {
                case .pan:
                    let delta = CGSize(width: v.translation.width - lastDragTranslation.width,
                                       height: v.translation.height - lastDragTranslation.height)
                    lastDragTranslation = v.translation
                    camera.pan(byScreen: delta)
                case .node:
                    engine.drag(to: camera.screenToWorld(v.location, viewSize: viewSize))
                case .idle:
                    break
                }
            }
            .onEnded { _ in
                if case .node = dragMode { engine.endDrag() }
                dragMode = .idle
                lastDragTranslation = .zero
            }
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
                onTapNode(hitTest(screen: v.location, viewSize: viewSize))
            }
    }
}
