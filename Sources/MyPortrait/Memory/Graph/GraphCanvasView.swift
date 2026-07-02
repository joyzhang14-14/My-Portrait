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
    /// 被拖球的实时指针世界坐标(引用盒)。⚠️ 不能用 @State 存值:
    /// 120Hz 指针事件逐个写 @State 会在 TimelineView 60fps 之外再触发
    /// 全画布重绘+视图 diff —— 拖球卡而平移不卡的真凶(07-02 实测)。
    /// class 挂在 @State 上只保身份,改字段不惊动 SwiftUI,渲染每帧读。
    private final class DragWorldBox {
        var world: SIMD2<Float>?
        /// 被拖球对主球的禁区半径(hub=主球+隐形圆+净空;叶=主球+球径+pad)。
        /// 07-02 交互修:物理会把闯进来的球顶回去而渲染钉指针,两边打架
        /// 显示成"球在主球里、叶和线在外面";指针目标先夹出禁区,两边一致。
        var minDist: Float = 0
        /// 本段手势的起点(自愈用:手势被系统取消时 onEnded 不回调,
        /// 状态机会卡在上一段拖拽 —— 新手势起点变了即强制复位)。
        var startLoc: CGPoint? = nil
        /// 被拖球是叶时 = 球径(>0 时目标位还要夹出全部 hub 球,07-02
        /// 不重叠底线:指针不能把 event 球钉进任何 folder 球里)。
        var leafBallR: Float = 0
    }
    @State private var dragWorldBox = DragWorldBox()
    @State private var lastMagnification: CGFloat = 1

    /// hub 节点预筛(init 一次):symbols 闭包每帧执行,在里面对全量
    /// nodes 做 filter 是每帧 O(n) 分配(07-01 拖拽卡顿优化)。
    private let hubNodes: [GraphNode]
    /// 同色批量填充组(init 一次,07-02 拖 Unclassified 卡顿优化):
    /// 951 次逐球 fill(每次还新建 Color)是 Debug 主线程大头;气泡模型
    /// 下同家同色、圆间不相交 → 每家并一条 Path 一次 fill(11 次替代
    /// 951 次)。组内大球在前(半径降序,同色重叠无感,家内 hub 先画)。
    private let colorGroups: [(color: Color, nodes: [Int])]

    init(scene: GraphScene, engine: GraphPhysicsEngine, paused: Bool,
         pulses: [GraphPulse], pulseStart: Date,
         camera: Binding<GraphCamera>, hoveredId: Binding<Int?>,
         onTapNode: @escaping (Int?) -> Void = { _ in }) {
        self.scene = scene
        self.engine = engine
        self.paused = paused
        self.pulses = pulses
        self.pulseStart = pulseStart
        self._camera = camera
        self._hoveredId = hoveredId
        self.onTapNode = onTapNode
        self.hubNodes = scene.nodes.filter { $0.kind.isHub }
        let order = scene.nodes.indices.sorted {
            scene.nodes[$0].radius > scene.nodes[$1].radius
        }
        var groupOf: [SIMD3<Double>: Int] = [:]
        var groups: [(color: Color, nodes: [Int])] = []
        for i in order {
            let key = scene.nodes[i].colorRGB
            if let g = groupOf[key] {
                groups[g].nodes.append(i)
            } else {
                groupOf[key] = groups.count
                groups.append((color: scene.nodes[i].color, nodes: [i]))
            }
        }
        self.colorGroups = groups
    }

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            // 显式 SwiftUI. 前缀:项目自己有个叫 TimelineView 的时间线视图,撞名。
            // 帧率上限 60:物理本就 60Hz,ProMotion 120Hz 只是白画一倍
            //(950 球全量重绘,Debug 下主线程被画满 → 拖拽卡,07-02 实测)。
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { tl in
                canvas(viewSize: viewSize, date: tl.date)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(viewSize: viewSize))
            .simultaneousGesture(magnifyGesture(viewSize: viewSize))
            .gesture(tapGesture(viewSize: viewSize))
            .onContinuousHover { phase in
                // 拖拽中不做 hover 命中(无意义且每事件都是一次全量扫)。
                guard dragMode == .idle else { return }
                switch phase {
                case .active(let p):
                    hoveredId = hitTest(screen: p, viewSize: viewSize)
                case .ended:
                    hoveredId = nil
                }
            }
        }
    }

    /// 屏幕点 → 命中的节点。**线性扫,零分配**:网格(GraphHitGrid)是
    /// 「建一次查多次」的摊销结构,这里每个指针事件只查一次,建 Dictionary
    /// 的分配/哈希反而是大头(Debug 未特化下拖拽卡顿的元凶之一)。
    /// ≤5000 节点一圈 simd 距离检查是 µs 级。
    private func hitTest(screen: CGPoint, viewSize: CGSize) -> Int? {
        let snap = engine.readSnapshot()
        guard snap.count == scene.nodes.count else { return nil }
        let world = camera.screenToWorld(screen, viewSize: viewSize)
        var best: Int? = nil
        var bestD = Float.greatestFiniteMagnitude
        for i in snap.indices {
            let d = simd_length(snap[i] - world)
            if d <= Float(scene.nodes[i].radius) + 4, d < bestD {
                bestD = d
                best = i
            }
        }
        return best
    }

    // MARK: - Canvas(闭包只做分发,绘制在 draw* helper 里)

    private func canvas(viewSize: CGSize, date: Date) -> some View {
        Canvas { ctx, size in
            var snap = engine.readSnapshot()
            guard snap.count == scene.nodes.count else { return }
            // 被拖球直接钉在实时指针位置(球/边/标签同源一致),
            // 物理 tick 慢时拖拽也不掉帧;从引用盒读,写入不惊动 SwiftUI
            if case .node(let di) = dragMode, let w = dragWorldBox.world, di < snap.count {
                snap[di] = w
                // 显示级清障(07-02:极速拖拽仍见重叠 —— 渲染位领先物理
                // 一个 tick,清障还没赶到):画之前把与被拖球重叠的球在
                // **本帧数据**里推出,与被画位置零时差;物理下 tick 跟上。
                let rd = Float(scene.nodes[di].radius)
                for j in 1..<snap.count where j != di {
                    let d = snap[j] - w
                    let dist = simd_length(d)
                    let minD = rd + Float(scene.nodes[j].radius) + 1
                    if dist < minD {
                        snap[j] = w + (dist > 1 ? d / dist : SIMD2<Float>(1, 0)) * minD
                    }
                }
            }
            drawEdges(ctx, snap: snap, size: size)
            drawPulses(ctx, snap: snap, size: size, date: date)
            drawBalls(ctx, snap: snap, size: size, date: date)
            drawLabels(ctx, snap: snap, size: size)
        } symbols: {
            ForEach(hubNodes) { node in
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
                // hub↔主球 = 橡皮筋(07-02 用户点名恢复,仅这 ≤11 条;
                // 当年卡顿是 960 条全锥形+离屏层,几条无感);叶边保持细线
                if e.b == 0, scene.nodes[e.a].kind.isHub {
                    drawTaperedEdge(ctx, e: e, pa: pa, pb: pb)
                } else {
                    linePath.move(to: pa)
                    linePath.addLine(to: pb)
                }
            }
            // 线宽锚定屏幕像素,拉近拉远等粗(Obsidian 式)。
            ctx.stroke(linePath, with: .color(.gray.opacity(0.45)),
                       lineWidth: GraphConstants.lineEdgeWidth)

        case .taperedFill:
            // 全锥形模式(保留可切回:GraphConstants.edgeStyle)。
            for e in scene.edges {
                let pa = camera.worldToScreen(snap[e.a], viewSize: size)
                let pb = camera.worldToScreen(snap[e.b], viewSize: size)
                if culled(pa, pb, size) { continue }
                drawTaperedEdge(ctx, e: e, pa: pa, pb: pb)
            }
        }
    }

    /// 锥形橡皮筋(两端粗中间细,二次贝塞尔腰身)。
    private func drawTaperedEdge(_ ctx: GraphicsContext, e: GraphEdge,
                                 pa: CGPoint, pb: CGPoint) {
        let zoom = camera.zoom
        var dx = pb.x - pa.x, dy = pb.y - pa.y
        let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
        dx /= len; dy /= len
        let nx = -dy, ny = dx
        // 橡皮筋是实体,宽度随缩放走(世界单位×zoom,07-02 反馈:锚屏幕
        // 像素的话缩得很小时连接处显得巨大);上限仍 = 球的屏幕半径。
        // 单边锥形(07-02 定稿):只有主球端(b)粗,连到对面球(a)最细。
        // 拉伸变细(07-02:像橡皮筋被拉长):粗端不变,细端 ÷ 拉伸比。
        let wb = min(e.halfWidthB, scene.nodes[e.b].radius) * zoom
        let stretch = max(Double(len) / zoom / max(e.restLength, 1), 1)
        let wa = wb * GraphConstants.waistRatio / stretch
        let wm = wa
        let mx = (pa.x + pb.x) / 2, my = (pa.y + pb.y) / 2
        var p = Path()
        p.move(to: CGPoint(x: pa.x + nx * wa, y: pa.y + ny * wa))
        p.addQuadCurve(to: CGPoint(x: pb.x + nx * wb, y: pb.y + ny * wb),
                       control: CGPoint(x: mx + nx * wm, y: my + ny * wm))
        p.addLine(to: CGPoint(x: pb.x - nx * wb, y: pb.y - ny * wb))
        p.addQuadCurve(to: CGPoint(x: pa.x - nx * wa, y: pa.y - ny * wa),
                       control: CGPoint(x: mx - nx * wm, y: my - ny * wm))
        p.closeSubpath()
        ctx.fill(p, with: .color(.gray.opacity(0.45)))
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
            for k in 0..<GraphConstants.pulseTickCount {
                // 三条杠沿行进方向错开 spacing,居中于脉冲位置
                let off = (Double(k) - Double(GraphConstants.pulseTickCount - 1) / 2)
                    * GraphConstants.pulseTickSpacing
                let tk = min(max(t + off / len, 0), 1)
                let x = pa.x + (pb.x - pa.x) * tk
                let y = pa.y + (pb.y - pa.y) * tk
                // 杠全长 = 连线**实际渲染粗细** × pulseTickLengthScale
                //(07-01 二次反馈:不能用锥形概念宽度,线改细后严重超标)。
                let halfLen = localHalfWidth(edge: e, forward: forward, t: tk,
                                             fromNode: p.fromNode, toNode: to,
                                             screenLen: Double(len))
                    * GraphConstants.pulseTickLengthScale
                tickPath.move(to: CGPoint(x: x - nx * halfLen, y: y - ny * halfLen))
                tickPath.addLine(to: CGPoint(x: x + nx * halfLen, y: y + ny * halfLen))
            }
        }
        ctx.stroke(tickPath, with: .color(.white.opacity(0.9)),
                   lineWidth: GraphConstants.pulseTickStrokeWidth)
    }

    /// 该处连线的**实际渲染半宽**:line 模式 = 线宽/2(常数);
    /// taperedFill 模式 = 锥形轮廓的二次贝塞尔局部插值(微积分局部值,屏幕空间)。
    private func localHalfWidth(edge e: GraphEdge, forward: Bool, t: Double,
                                fromNode: Int, toNode: Int,
                                screenLen: Double) -> Double {
        switch GraphConstants.edgeStyle {
        case .line:
            // hub↔主球现在画的是单边锥形 —— 杠长实时取该处锥形宽度
            //(07-02 反馈:不能写死细线宽);其余边仍是等粗细线。
            if e.b == 0, scene.nodes[e.a].kind.isHub {
                let zoom = camera.zoom
                let mainW = min(e.halfWidthB, scene.nodes[e.b].radius) * zoom
                let stretch = max(Double(screenLen) / zoom / max(e.restLength, 1), 1)
                let tipW = mainW * GraphConstants.waistRatio / stretch
                let wFrom = fromNode == e.b ? mainW : tipW
                let wTo = fromNode == e.b ? tipW : mainW
                let u = 1 - t
                return u * u * wFrom + 2 * u * t * tipW + t * t * wTo
            }
            return GraphConstants.lineEdgeWidth / 2
        case .taperedFill:
            let zoom = camera.zoom
            let wFrom = min(forward ? e.halfWidthA : e.halfWidthB,
                            scene.nodes[fromNode].radius * zoom)
            let wTo = min(forward ? e.halfWidthB : e.halfWidthA,
                          scene.nodes[toNode].radius * zoom)
            let wm = min(wFrom, wTo) * GraphConstants.waistRatio
            let u = 1 - t
            return u * u * wFrom + 2 * u * t * wm + t * t * wTo
        }
    }

    // MARK: - 球

    private func drawBalls(_ ctx: GraphicsContext, snap: [SIMD2<Float>],
                           size: CGSize, date: Date) {
        let zoom = camera.zoom
        let now = date.timeIntervalSinceReferenceDate
        // 同色一条 Path 一次 fill(07-02 拖拽卡顿优化:替代 951 次逐球
        // fill;气泡不相交 → 跨家遮挡不存在,组内同色重叠无感)
        for group in colorGroups {
            var path = Path()
            for oi in group.nodes {
                let node = scene.nodes[oi]
                let c = camera.worldToScreen(snap[node.id], viewSize: size)
                let r = node.radius * zoom
                if c.x + r < 0 || c.x - r > size.width || c.y + r < 0 || c.y - r > size.height {
                    continue
                }
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            if !path.isEmpty {
                ctx.fill(path, with: .color(group.color))
            }
        }
        // hover 白色闪烁(正弦脉动,持续 hover 持续闪 —— 需求 §5)
        if let hid = hoveredId, hid >= 0, hid < scene.nodes.count {
            let node = scene.nodes[hid]
            let c = camera.worldToScreen(snap[hid], viewSize: size)
            let r = node.radius * zoom
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let a = 0.35 + 0.35 * sin(now * GraphConstants.hoverBlinkHz * 2 * .pi)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(a)))
        }
    }

    // MARK: - 标签

    private func drawLabels(_ ctx: GraphicsContext, snap: [SIMD2<Float>], size: CGSize) {
        let zoom = camera.zoom
        // LOD 淡出(07-01 反馈):缩小到一定程度 hub/主球文字渐暗直至消失。
        let fade = min(max((zoom - GraphConstants.labelFadeZoomLo)
                           / (GraphConstants.labelFadeZoomHi - GraphConstants.labelFadeZoomLo),
                           0), 1)
        if fade > 0.01 {
            var lctx = ctx
            lctx.opacity = fade
            // hub 常驻标题(symbols 预光栅化)
            for node in hubNodes {
                if let sym = lctx.resolveSymbol(id: node.id) {
                    let c = camera.worldToScreen(snap[node.id], viewSize: size)
                    let y = c.y + node.radius * zoom + 12
                    if c.x < -100 || c.x > size.width + 100 || y < -30 || y > size.height + 30 {
                        continue
                    }
                    lctx.draw(sym, at: CGPoint(x: c.x, y: y))
                }
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
                // 自愈(07-02:没停稳时再拖另一颗会卡):上一段手势被取消时
                // onEnded 不来,dragMode 卡在旧球;起点变了 = 新手势,强制收尾。
                if dragMode != .idle, dragWorldBox.startLoc != v.startLocation {
                    if case .node = dragMode { engine.endDrag() }
                    dragMode = .idle
                    dragWorldBox.world = nil
                    dragWorldBox.minDist = 0
                    dragWorldBox.leafBallR = 0
                    lastDragTranslation = .zero
                }
                if dragMode == .idle {
                    dragWorldBox.startLoc = v.startLocation
                    // 起点定模式:球(非主球)= 拖球;空白/主球 = 平移。
                    // 主球钉死原点(大脑不动),拖它等于拖整个世界 → 归平移。
                    if let idx = hitTest(screen: v.startLocation, viewSize: viewSize), idx > 0 {
                        dragMode = .node(idx)
                        let node = scene.nodes[idx]
                        if let br = node.hubBubbleRadius {
                            var maxLeafR = 0.0
                            for n in scene.nodes where !n.kind.isHub && n.hubIndex == idx {
                                maxLeafR = max(maxLeafR, n.radius)
                            }
                            dragWorldBox.minDist = Float(GraphConstants.mainRadius + br + maxLeafR)
                                + GraphConstants.mainCollisionPadding
                        } else {
                            dragWorldBox.minDist = Float(GraphConstants.mainRadius + node.radius)
                                + GraphConstants.mainCollisionPadding
                            dragWorldBox.leafBallR = Float(node.radius)
                        }
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
                    var w = camera.screenToWorld(v.location, viewSize: viewSize)
                    // 叶拖拽:先夹出全部 folder/分区球(≤11 次距离检查/事件)
                    let ballR = dragWorldBox.leafBallR
                    if ballR > 0 {
                        let snap = engine.readSnapshot()
                        for h in hubNodes where h.id != 0 && h.id < snap.count {
                            let c = snap[h.id]
                            let minD = Float(h.radius) + ballR
                                + GraphConstants.mainCollisionPadding
                            let dv = w - c
                            let dd = simd_length(dv)
                            if dd < minD {
                                w = dd > 1 ? c + dv / dd * minD : c + SIMD2<Float>(minD, 0)
                            }
                        }
                    }
                    // 主球禁区:目标位按最小距离径向夹紧(见 DragWorldBox.minDist)
                    let m = dragWorldBox.minDist
                    let r = simd_length(w)
                    if m > 0, r < m {
                        w = r > 1 ? w / r * m : SIMD2<Float>(m, 0)
                    }
                    dragWorldBox.world = w   // 引用盒:不触发 SwiftUI 更新
                    engine.drag(to: w)
                case .idle:
                    break
                }
            }
            .onEnded { _ in
                if case .node = dragMode { engine.endDrag() }
                dragMode = .idle
                dragWorldBox.world = nil
                dragWorldBox.minDist = 0
                dragWorldBox.leafBallR = 0
                dragWorldBox.startLoc = nil
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
