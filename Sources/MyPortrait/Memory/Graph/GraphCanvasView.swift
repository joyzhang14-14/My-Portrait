import SwiftUI
import simd

/// 图谱画布:TimelineView 驱动的 Canvas 全量重绘(边→脉冲→球→hub 标签)。
/// 位置每帧从物理引擎的双缓冲快照读取;全静止时 TimelineView 暂停
/// (paused),重绘只由相机/hover 等状态变化触发 → CPU≈0。
///
/// 手势:
///   - 拖空白/主球 = 相机平移;拖末端球/hub = 拖球(物理 reheat,邻居跟着晃)
///   - 捏合 = 锚点缩放;hover = 白色闪烁;点击 = onTapNode(浮窗/脉冲)
///
/// P0 实测铁律:hub 标签走 `Canvas(symbols:)` 预光栅化,**禁止**逐帧
/// `ctx.resolve(Text)`(那样 5000 节点下掉 13% 帧)。
/// ⚠️ Canvas 闭包必须保持精简(只调 draw* helper)—— 内联全部绘制代码会
/// 让 Swift 类型检查超时(编译错 "unable to type-check in reasonable time")。
struct GraphCanvasView: View {
    let scene: GraphScene
    let engine: GraphPhysicsEngine
    /// 物理休眠且无进行中动画 → true,暂停 TimelineView 的逐帧重绘。
    let paused: Bool
    /// 神经脉冲时间表(hub 点击时一次算好)+ 起跑时刻。空 = 无脉冲。
    let pulses: [GraphPulse]
    let pulseStart: Date
    @Binding var camera: GraphCamera
    @Binding var hoveredId: Int?
    /// 点到球(nil = 点空白)。root 据此开浮窗(leaf)或触发脉冲(hub)。
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
            SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: paused)) { tl in
                canvas(viewSize: viewSize, date: tl.date)
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

    // MARK: - Canvas(闭包只做分发,绘制在 draw* helper 里)

    private func canvas(viewSize: CGSize, date: Date) -> some View {
        Canvas { ctx, size in
            let snap = engine.readSnapshot()
            guard snap.count == scene.nodes.count else { return }
            drawEdges(ctx, snap: snap, size: size)
            drawPulses(ctx, snap: snap, size: size, date: date)
            drawBalls(ctx, snap: snap, size: size, date: date)
            drawLabels(ctx, snap: snap, size: size)
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

    // MARK: - 边

    private func drawEdges(_ ctx: GraphicsContext, snap: [SIMD2<Float>], size: CGSize) {
        switch GraphConstants.edgeStyle {
        case .line:
            // 纯线模式(2026-07-01 反馈:锥形卡顿且效果不明显,先用等宽细线)。
            // 全部边合进**一条 Path 一次 stroke**:同一路径内重叠只画一遍
            // (天然不加深),无离屏层,像素量最小 —— 也是修卡顿的关键
            // (旧方案的 drawLayer 每帧强制全屏离屏合成)。
            var linePath = Path()
            for e in scene.edges {
                let pa = camera.worldToScreen(snap[e.a], viewSize: size)
                let pb = camera.worldToScreen(snap[e.b], viewSize: size)
                if culled(pa, pb, size) { continue }
                linePath.move(to: pa)
                linePath.addLine(to: pb)
            }
            // 线宽锚定屏幕像素,拉近拉远等粗(Obsidian 式)。
            ctx.stroke(linePath, with: .color(.gray.opacity(0.45)),
                       lineWidth: GraphConstants.lineEdgeWidth)

        case .taperedFill:
            // 锥形橡皮筋(两端粗中间细),保留可切回(GraphConstants.edgeStyle)。
            let edgeShading = GraphicsContext.Shading.color(.gray.opacity(0.45))
            let zoom = camera.zoom
            for e in scene.edges {
                let pa = camera.worldToScreen(snap[e.a], viewSize: size)
                let pb = camera.worldToScreen(snap[e.b], viewSize: size)
                if culled(pa, pb, size) { continue }
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
                dx /= len; dy /= len
                let nx = -dy, ny = dx
                // 线宽锚定屏幕像素;上限 = 球的屏幕半径(缩远时线不比球粗)。
                let wa = min(e.halfWidthA, scene.nodes[e.a].radius * zoom)
                let wb = min(e.halfWidthB, scene.nodes[e.b].radius * zoom)
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
        }
    }

    private func culled(_ pa: CGPoint, _ pb: CGPoint, _ size: CGSize) -> Bool {
        max(pa.x, pb.x) < -50 || min(pa.x, pb.x) > size.width + 50 ||
        max(pa.y, pb.y) < -50 || min(pa.y, pb.y) > size.height + 50
    }

    // MARK: - 神经脉冲:||| 三条垂直细白杠沿线飞(07-01 反馈定稿)

    /// 每条杠长度 = 该处连线的**概念粗细**(锥形宽度函数的微积分局部值,
    /// 即使边画成细线,信号也带出神经形状)。全部杠合一条 Path 一次 stroke。
    private func drawPulses(_ ctx: GraphicsContext, snap: [SIMD2<Float>],
                            size: CGSize, date: Date) {
        guard !pulses.isEmpty else { return }
        let zoom = camera.zoom
        let elapsed = date.timeIntervalSince(pulseStart)
        var tickPath = Path()
        for p in pulses {
            let t = (elapsed - p.start) / p.duration
            guard t >= 0, t <= 1 else { continue }
            let e = scene.edges[p.edgeIndex]
            let forward = (e.a == p.fromNode)
            let to = forward ? e.b : e.a
            let pa = camera.worldToScreen(snap[p.fromNode], viewSize: size)
            let pb = camera.worldToScreen(snap[to], viewSize: size)
            var dx = pb.x - pa.x, dy = pb.y - pa.y
            let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
            dx /= len; dy /= len
            let nx = -dy, ny = dx
            // 行进方向上的锥形宽度端点(fromNode 侧在前)
            let wFrom = min(forward ? e.halfWidthA : e.halfWidthB,
                            scene.nodes[p.fromNode].radius * zoom)
            let wTo = min(forward ? e.halfWidthB : e.halfWidthA,
                          scene.nodes[to].radius * zoom)
            let wm = min(wFrom, wTo) * GraphConstants.waistRatio
            for k in 0..<GraphConstants.pulseTickCount {
                // 三条杠沿行进方向错开 spacing,居中于脉冲位置
                let off = (Double(k) - Double(GraphConstants.pulseTickCount - 1) / 2)
                    * GraphConstants.pulseTickSpacing
                let tk = min(max(t + off / len, 0), 1)
                let x = pa.x + (pb.x - pa.x) * tk
                let y = pa.y + (pb.y - pa.y) * tk
                // 二次贝塞尔宽度插值(与锥形轮廓同公式):局部半宽
                let u = 1 - tk
                let halfLen = max(u * u * wFrom + 2 * u * tk * wm + tk * tk * wTo,
                                  GraphConstants.pulseTickMinHalfLen)
                tickPath.move(to: CGPoint(x: x - nx * halfLen, y: y - ny * halfLen))
                tickPath.addLine(to: CGPoint(x: x + nx * halfLen, y: y + ny * halfLen))
            }
        }
        ctx.stroke(tickPath, with: .color(.white.opacity(0.9)),
                   lineWidth: GraphConstants.pulseTickStrokeWidth)
    }

    // MARK: - 球

    private func drawBalls(_ ctx: GraphicsContext, snap: [SIMD2<Float>],
                           size: CGSize, date: Date) {
        let zoom = camera.zoom
        let now = date.timeIntervalSinceReferenceDate
        for node in scene.nodes {
            let c = camera.worldToScreen(snap[node.id], viewSize: size)
            let r = node.radius * zoom
            if c.x + r < 0 || c.x - r > size.width || c.y + r < 0 || c.y - r > size.height {
                continue
            }
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(node.color))
            // hover 白色闪烁(正弦脉动,持续 hover 持续闪 —— 需求 §5)
            if node.id == hoveredId {
                let a = 0.35 + 0.35 * sin(now * GraphConstants.hoverBlinkHz * 2 * .pi)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(a)))
            }
        }
    }

    // MARK: - 标签

    private func drawLabels(_ ctx: GraphicsContext, snap: [SIMD2<Float>], size: CGSize) {
        let zoom = camera.zoom
        // hub 常驻标题(symbols 预光栅化)
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
        // 末端球 hover 标题(仅 1 个,inline resolve 无 batching 问题)
        if let h = hoveredId, h < scene.nodes.count, !scene.nodes[h].kind.isHub {
            let node = scene.nodes[h]
            let c = camera.worldToScreen(snap[h], viewSize: size)
            let label = ctx.resolve(
                Text(node.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95)))
            ctx.draw(label, at: CGPoint(x: c.x, y: c.y + node.radius * zoom + 12))
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
