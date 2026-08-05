import SwiftUI

/// 通用的流水线示意图 —— 节点 + 连线,手工排版(归一化坐标),点节点看说明。
///
/// **刻意做成"数据描述 + 通用渲染器"两层**:每条 pipeline(Events / Portrait /
/// Personality / Writing style,以后还有 agent swarm)各自写一份 `PipelineFlow`
/// 常量,渲染、配色、交互全共用这一个 View。加新图 = 加一份数据,不碰画图代码。
///
/// 第一轮只画结构(静态)。实时状态(进度环 / 待审核徽标 / 失败红点 / 边上光点
/// 流动)留到第二轮 —— 节点 kind 和 id 已经预留好挂点。
struct PipelineFlow {

    /// 节点性质 —— 决定配色和图标。用户一眼要能分出"这步烧不烧 token"。
    enum NodeKind {
        /// 数据源(采集库 / 磁盘文件)。
        case source
        /// 确定性算法,不打 LLM。虚线框。
        case deterministic
        /// 走 LLM 的步骤。实线强调框 + 模型小片。
        case llm
        /// 人工闸门(staged 审核)。
        case gate
        /// 下游的**另一条** pipeline —— 本图只标"会被触发",不展开。
        case downstream
    }

    /// 连线性质。
    enum EdgeKind {
        /// 数据流:上一步的产物是下一步的输入。实线 + 箭头。
        case data
        /// 换行:上一行的末尾接下一行的开头。走直角折线(下 → 横 → 下),
        /// 直接连的话是一条横穿整张图的长斜线,谁也看不懂。
        case wrap
        /// 触发关系:不传数据,只是把下游标成待跑。虚线 + 箭头。
        case trigger
    }

    struct Node: Identifiable {
        let id: String
        let title: String
        let kind: NodeKind
        /// 节点右下角的小片(模型档位 / 产物路径之类)。nil = 不显示。
        var chip: String? = nil
        /// 点开看的完整说明。
        let detail: String
        /// 归一化坐标(0…1),(0,0) = 左上。渲染时乘以画布尺寸。
        let pos: CGPoint
    }

    struct Edge: Identifiable {
        var id: String { "\(from)->\(to)" }
        let from: String
        let to: String
        var kind: EdgeKind = .data
        /// 连线中点旁边的小字(比如 "approve")。nil = 不标。
        var label: String? = nil
    }

    let nodes: [Node]
    let edges: [Edge]
    /// 画布高度(pt)。宽度跟随卡片。
    let height: CGFloat

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
}

// MARK: - 渲染

struct PipelineFlowView: View {
    let flow: PipelineFlow

    /// 节点盒子尺寸 —— 固定,不随内容伸缩(布局是手排的,伸缩会把连线错开)。
    private static let nodeW: CGFloat = 176
    private static let nodeH: CGFloat = 46

    @State private var openNode: String? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 连线画在底层 —— Canvas 一次性画完所有边,比每条边一个 View 省。
                Canvas { ctx, size in
                    for e in flow.edges {
                        guard let a = flow.node(e.from), let b = flow.node(e.to) else { continue }
                        drawEdge(ctx: ctx, size: size, from: a, to: b, kind: e.kind)
                    }
                }
                ForEach(flow.nodes) { n in
                    nodeBox(n)
                        .frame(width: Self.nodeW, height: Self.nodeH)
                        .position(x: n.pos.x * geo.size.width,
                                  y: n.pos.y * geo.size.height)
                }
            }
        }
        .frame(height: flow.height)
    }

    // MARK: 边

    /// 三种走线:
    ///   - 同一行相邻 → 左边框中点到右边框中点,直线(横向流)
    ///   - 换行 → 从末节点底边下去,横向折回,再下到首节点顶边(直角 + 圆角)
    ///   - 其余(下一行分叉)→ 底边到顶边,三次贝塞尔
    private func drawEdge(ctx: GraphicsContext, size: CGSize,
                          from a: PipelineFlow.Node, to b: PipelineFlow.Node,
                          kind: PipelineFlow.EdgeKind) {
        let ax = a.pos.x * size.width, ay = a.pos.y * size.height
        let bx = b.pos.x * size.width, by = b.pos.y * size.height
        let halfW = Self.nodeW / 2, halfH = Self.nodeH / 2
        let color = Color.primary.opacity(kind == .trigger ? 0.18 : 0.28)
        let style: StrokeStyle = kind == .trigger
            ? StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4])
            : StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

        var path = Path()
        var tip = CGPoint.zero          // 箭头尖
        var facing = Facing.down

        if kind == .wrap {
            // 下 → 横 → 下。折点落在两行正中间。
            let midY = (ay + halfH + by - halfH) / 2
            let p0 = CGPoint(x: ax, y: ay + halfH)
            tip = CGPoint(x: bx, y: by - halfH)
            path.move(to: p0)
            path.addLine(to: CGPoint(x: ax, y: midY))
            path.addLine(to: CGPoint(x: bx, y: midY))
            path.addLine(to: tip)
        } else if abs(ay - by) < 0.5 {
            // 同一行 → 横着连。
            let p0 = CGPoint(x: ax + halfW, y: ay)
            tip = CGPoint(x: bx - halfW, y: by)
            path.move(to: p0)
            path.addLine(to: tip)
            facing = .right
        } else {
            let p0 = CGPoint(x: ax, y: ay + halfH)
            tip = CGPoint(x: bx, y: by - halfH)
            let dy = (tip.y - p0.y) * 0.55
            path.move(to: p0)
            path.addCurve(to: tip,
                          control1: CGPoint(x: p0.x, y: p0.y + dy),
                          control2: CGPoint(x: tip.x, y: tip.y - dy))
        }
        ctx.stroke(path, with: .color(color), style: style)

        var head = Path()
        switch facing {
        case .down:
            head.move(to: CGPoint(x: tip.x - 4, y: tip.y - 5))
            head.addLine(to: tip)
            head.addLine(to: CGPoint(x: tip.x + 4, y: tip.y - 5))
        case .right:
            head.move(to: CGPoint(x: tip.x - 5, y: tip.y - 4))
            head.addLine(to: tip)
            head.addLine(to: CGPoint(x: tip.x - 5, y: tip.y + 4))
        }
        ctx.stroke(head, with: .color(color),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    private enum Facing { case down, right }

    // MARK: 节点

    @ViewBuilder
    private func nodeBox(_ n: PipelineFlow.Node) -> some View {
        let s = Self.style(for: n.kind)
        Button {
            openNode = (openNode == n.id) ? nil : n.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: s.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(s.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let chip = n.chip {
                        Text(chip)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(s.tint.opacity(0.95))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(s.tint.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(s.tint.opacity(0.55),
                                          style: StrokeStyle(lineWidth: 1,
                                                             dash: s.dashed ? [3.5, 3] : []))
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { openNode == n.id },
            set: { if !$0 { openNode = nil } }
        ), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: s.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(s.tint)
                    Text(n.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                }
                Text(s.label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(s.tint.opacity(0.9))
                Text(n.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
    }

    struct NodeStyle {
        let icon: String
        let tint: Color
        let dashed: Bool
        /// 浮窗里那行小字,告诉用户这一步的性质。
        let label: String
        /// 图例里的短名。
        let short: String
    }

    static func style(for kind: PipelineFlow.NodeKind) -> NodeStyle {
        switch kind {
        case .source:
            return NodeStyle(icon: "externaldrive", tint: Color(red: 0.95, green: 0.55, blue: 0.20),
                             dashed: false, label: "CAPTURED DATA", short: "Captured data")
        case .deterministic:
            return NodeStyle(icon: "function", tint: Color.secondary,
                             dashed: true, label: "DETERMINISTIC · NO AI", short: "Deterministic")
        case .llm:
            return NodeStyle(icon: "sparkles", tint: Theme.accent,
                             dashed: false, label: "AI STEP", short: "AI step")
        case .gate:
            return NodeStyle(icon: "hand.raised", tint: Color(red: 0.98, green: 0.62, blue: 0.19),
                             dashed: false, label: "WAITS FOR YOU", short: "Waits for you")
        case .downstream:
            return NodeStyle(icon: "arrow.turn.down.right",
                             tint: Color(red: 0.66, green: 0.45, blue: 0.95),
                             dashed: false, label: "ANOTHER PIPELINE", short: "Another pipeline")
        }
    }
}

// MARK: - 图例

/// 图例条 —— **只列这张图里真出现过的节点性质**,顺序固定。
/// 不然换一条 pipeline 时图例会讲一堆图上根本没有的东西。
struct PipelineFlowLegend: View {
    let flow: PipelineFlow

    private static let order: [PipelineFlow.NodeKind] =
        [.source, .llm, .deterministic, .gate, .downstream]

    var body: some View {
        let present = Self.order.filter { k in
            flow.nodes.contains { sameKind($0.kind, k) }
        }
        HStack(spacing: 14) {
            ForEach(Array(present.enumerated()), id: \.offset) { _, k in
                let s = PipelineFlowView.style(for: k)
                HStack(spacing: 4) {
                    Image(systemName: s.icon).font(.system(size: 9)).foregroundStyle(s.tint)
                    Text(s.short).font(.system(size: 10))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// NodeKind 没有 Equatable(以后可能挂 associated value),手写比对。
    private func sameKind(_ a: PipelineFlow.NodeKind, _ b: PipelineFlow.NodeKind) -> Bool {
        switch (a, b) {
        case (.source, .source), (.deterministic, .deterministic), (.llm, .llm),
             (.gate, .gate), (.downstream, .downstream): return true
        default: return false
        }
    }
}

// MARK: - Events Processor 那条 pipeline 的图

extension PipelineFlow {

    /// Events Processor。**顺序与 `MemoryScheduler.runEventJob` 一一对应** ——
    /// 改调度器的步骤时这里也要跟着改,别让图跟代码走偏。
    ///
    /// 排版:两行各 3 个,左→右读,行尾用 `.wrap` 折回下一行行首;最后一行是
    /// 被触发的另外两条 pipeline。
    static let eventsProcessor = PipelineFlow(
        nodes: [
            Node(
                id: "capture",
                title: "Captured day",
                kind: .source,
                chip: "~/.portrait",
                detail: "One UTC day of raw capture: screenshots and their OCR text, audio transcripts with speakers, and your typing events. This is the only input — nothing is invented later.",
                pos: CGPoint(x: 0.17, y: 0.14)
            ),
            Node(
                id: "raw",
                title: "Day is over",
                kind: .deterministic,
                chip: "UTC + 10 min",
                detail: "A day is only picked up once it's actually over — UTC midnight plus a 10-minute grace period, so transcripts and OCR that are still finishing up land in time.\n\nDays that aren't ready yet are skipped and retried on the next tick (every 15 minutes).",
                pos: CGPoint(x: 0.5, y: 0.14)
            ),
            Node(
                id: "event",
                title: "Build events",
                kind: .llm,
                chip: "main model",
                detail: "Reads the whole day's timeline and clusters it into discrete events — one file per event under events/<day>/. This is where a scroll of raw activity turns into \"what actually happened\".",
                pos: CGPoint(x: 0.83, y: 0.14)
            ),
            Node(
                id: "impact",
                title: "Score impact",
                kind: .llm,
                chip: "main model",
                detail: "Every event gets an impact score — how much this mattered to you. That score is what later decides which events survive in your memory and how big they show up in the Neural Graph.",
                pos: CGPoint(x: 0.17, y: 0.52)
            ),
            Node(
                id: "weight",
                title: "Weights + daily budget",
                kind: .deterministic,
                detail: "Two pure algorithms, no AI:\n\n• Weights — every event decays over time (exponential half-life), recomputed across the whole tree.\n\n• Daily budget — a busy day can't flood your memory. If a day's total impact exceeds the cap it's scaled back down; quiet days are left alone. Peak events above the protection threshold are never scaled.",
                pos: CGPoint(x: 0.5, y: 0.52)
            ),
            Node(
                id: "classify",
                title: "Group into folders",
                kind: .llm,
                chip: "light model",
                detail: "Sorts events into project folders (events/_folders/*.json) — \"My Portrait\", \"UCI application\", and so on. Uses the light model because the decision is narrow: does this event belong in an existing folder, or does it need a new one?\n\nThis is the last step of the run.",
                pos: CGPoint(x: 0.83, y: 0.52)
            ),
            Node(
                id: "distill",
                title: "Portraits Distiller",
                kind: .downstream,
                detail: "Once events land, the portrait distiller is marked pending — it turns events into long-term portrait entries (experiences, social, and so on) on its own schedule.",
                pos: CGPoint(x: 0.3, y: 0.9)
            ),
            Node(
                id: "personality",
                title: "Personality Refresher",
                kind: .downstream,
                detail: "Each processed day is also marked pending for the personality refresher, which re-derives your personality tags from that day's events, the rest of the portrait, and OCR.",
                pos: CGPoint(x: 0.7, y: 0.9)
            ),
        ],
        edges: [
            Edge(from: "capture", to: "raw"),
            Edge(from: "raw", to: "event"),
            Edge(from: "event", to: "impact", kind: .wrap),
            Edge(from: "impact", to: "weight"),
            Edge(from: "weight", to: "classify"),
            Edge(from: "classify", to: "distill", kind: .trigger),
            Edge(from: "classify", to: "personality", kind: .trigger),
        ],
        height: 300
    )
}
