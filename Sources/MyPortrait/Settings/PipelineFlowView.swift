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
    private static let nodeW: CGFloat = 196
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

    /// 上一个节点的底边中点 → 下一个节点的顶边中点。同一列走直线,跨列走
    /// 三次贝塞尔(控制点垂直拉开),避免斜穿过别的节点。
    private func drawEdge(ctx: GraphicsContext, size: CGSize,
                          from a: PipelineFlow.Node, to b: PipelineFlow.Node,
                          kind: PipelineFlow.EdgeKind) {
        let p0 = CGPoint(x: a.pos.x * size.width,
                         y: a.pos.y * size.height + Self.nodeH / 2)
        let p1 = CGPoint(x: b.pos.x * size.width,
                         y: b.pos.y * size.height - Self.nodeH / 2)
        var path = Path()
        path.move(to: p0)
        if abs(p0.x - p1.x) < 0.5 {
            path.addLine(to: p1)
        } else {
            let dy = (p1.y - p0.y) * 0.55
            path.addCurve(to: p1,
                          control1: CGPoint(x: p0.x, y: p0.y + dy),
                          control2: CGPoint(x: p1.x, y: p1.y - dy))
        }
        let color = Color.primary.opacity(kind == .data ? 0.28 : 0.18)
        let style: StrokeStyle = kind == .data
            ? StrokeStyle(lineWidth: 1.4, lineCap: .round)
            : StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4])
        ctx.stroke(path, with: .color(color), style: style)

        // 箭头 —— 贴在终点上方,朝下。
        var head = Path()
        head.move(to: CGPoint(x: p1.x - 4, y: p1.y - 5))
        head.addLine(to: CGPoint(x: p1.x, y: p1.y))
        head.addLine(to: CGPoint(x: p1.x + 4, y: p1.y - 5))
        ctx.stroke(head, with: .color(color),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

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

    private struct NodeStyle {
        let icon: String
        let tint: Color
        let dashed: Bool
        /// 浮窗里那行小字,告诉用户这一步的性质。
        let label: String
    }

    private static func style(for kind: PipelineFlow.NodeKind) -> NodeStyle {
        switch kind {
        case .source:
            return NodeStyle(icon: "externaldrive", tint: Color(red: 0.95, green: 0.55, blue: 0.20),
                             dashed: false, label: "CAPTURED DATA")
        case .deterministic:
            return NodeStyle(icon: "function", tint: Color.secondary,
                             dashed: true, label: "DETERMINISTIC · NO AI")
        case .llm:
            return NodeStyle(icon: "sparkles", tint: Theme.accent,
                             dashed: false, label: "AI STEP")
        case .gate:
            return NodeStyle(icon: "hand.raised", tint: Color(red: 0.98, green: 0.62, blue: 0.19),
                             dashed: false, label: "WAITS FOR YOU")
        case .downstream:
            return NodeStyle(icon: "arrow.turn.down.right",
                             tint: Color(red: 0.66, green: 0.45, blue: 0.95),
                             dashed: false, label: "ANOTHER PIPELINE")
        }
    }
}

// MARK: - 图例

/// 图例条 —— 四种节点性质各一个小样,放流程图下方。
struct PipelineFlowLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item("sparkles", Theme.accent, "AI step")
            item("function", .secondary, "Deterministic")
            item("hand.raised", Color(red: 0.98, green: 0.62, blue: 0.19), "Waits for you")
            item("arrow.turn.down.right", Color(red: 0.66, green: 0.45, blue: 0.95), "Another pipeline")
            Spacer(minLength: 0)
        }
    }

    private func item(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(Theme.textPrimary.opacity(0.55))
        }
    }
}

// MARK: - Events Processor 那条 pipeline 的图

extension PipelineFlow {

    /// Events Processor。**顺序与 `MemoryScheduler.runEventJob` 一一对应** ——
    /// 改调度器的步骤时这里也要跟着改,别让图跟代码走偏。
    static let eventsProcessor = PipelineFlow(
        nodes: [
            Node(
                id: "capture",
                title: "Captured day",
                kind: .source,
                chip: "~/.portrait",
                detail: "One UTC day of raw capture: screenshots and their OCR text, audio transcripts with speakers, and your typing events. This is the only input — nothing is invented later.",
                pos: CGPoint(x: 0.5, y: 0.05)
            ),
            Node(
                id: "raw",
                title: "Wait for the day to settle",
                kind: .deterministic,
                detail: "A day is only processed once it's over (UTC midnight) plus a 10-minute grace period, so late transcripts and OCR still land in time. Days that aren't ready yet are simply skipped and retried on the next tick.",
                pos: CGPoint(x: 0.5, y: 0.18)
            ),
            Node(
                id: "event",
                title: "Build events",
                kind: .llm,
                chip: "main model",
                detail: "Reads the whole day's timeline and clusters it into discrete events — one file per event under events/<day>/. This is where a scroll of raw activity turns into \"what actually happened\".",
                pos: CGPoint(x: 0.5, y: 0.31)
            ),
            Node(
                id: "impact",
                title: "Score impact",
                kind: .llm,
                chip: "main model",
                detail: "Every event gets an impact score — how much this mattered to you. The score is what later decides which events survive in your memory and how big they show up in the Neural Graph.",
                pos: CGPoint(x: 0.5, y: 0.44)
            ),
            Node(
                id: "weight",
                title: "Weights + daily budget",
                kind: .deterministic,
                detail: "Two pure algorithms, no AI:\n\n• Weights — every event decays over time (exponential half-life), recomputed across the whole tree.\n\n• Daily budget — a busy day can't flood your memory. If a day's total impact exceeds the cap it's scaled back down; quiet days are left alone. Peak events above the protection threshold are never scaled.",
                pos: CGPoint(x: 0.5, y: 0.57)
            ),
            Node(
                id: "classify",
                title: "Group into folders",
                kind: .llm,
                chip: "light model",
                detail: "Sorts events into project folders (events/_folders/*.json) — \"My Portrait\", \"UCI application\", and so on. Uses the light model because the decision is narrow: does this event belong in an existing folder, or does it need a new one?\n\nThis is the last step of the run.",
                pos: CGPoint(x: 0.5, y: 0.70)
            ),
            Node(
                id: "review",
                title: "Staged for review",
                kind: .gate,
                detail: "Nothing above is committed yet. The whole run — events, scores, folders — sits in a snapshot until you Approve or Reject it.\n\nReject restores the snapshot over the live tree, so folders roll back together with the events they grouped.",
                pos: CGPoint(x: 0.5, y: 0.83)
            ),
            Node(
                id: "distill",
                title: "Portraits Distiller",
                kind: .downstream,
                detail: "Once events land, the portrait distiller is marked pending — it turns events into long-term portrait entries (experiences, social, and so on) on its own schedule.",
                pos: CGPoint(x: 0.26, y: 0.96)
            ),
            Node(
                id: "personality",
                title: "Personality Refresher",
                kind: .downstream,
                detail: "Each processed day is also marked pending for the personality refresher, which re-derives your personality tags from that day's events, the rest of the portrait, and OCR.",
                pos: CGPoint(x: 0.74, y: 0.96)
            ),
        ],
        edges: [
            Edge(from: "capture", to: "raw"),
            Edge(from: "raw", to: "event"),
            Edge(from: "event", to: "impact"),
            Edge(from: "impact", to: "weight"),
            Edge(from: "weight", to: "classify"),
            Edge(from: "classify", to: "review"),
            Edge(from: "review", to: "distill", kind: .trigger),
            Edge(from: "review", to: "personality", kind: .trigger),
        ],
        height: 560
    )
}
