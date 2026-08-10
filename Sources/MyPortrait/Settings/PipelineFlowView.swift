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
        /// 侧向注释:从节点右边框水平出线到注释节点左边框,虚线。
        /// 语义是"解释/展开",不是流程的一步 —— 注释节点不再接回主干。
        case note
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
        /// 窄盒子(110pt,小图标 + 标题居中)—— 给类别注释列用。
        var narrow: Bool = false
        /// 自定义 SF Symbol,覆盖 kind 的默认图标。类别注释盒用它显示
        /// 与 Text 侧栏 PORTRAIT 分区一致的图标(Models.swift 同款)。
        var icon: String? = nil
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
    /// 窄盒子宽(narrow 节点)。放得下小图标 + 单行标题。
    private static let narrowW: CGFloat = 110

    private static func width(of n: PipelineFlow.Node) -> CGFloat {
        n.narrow ? narrowW : nodeW
    }

    @State private var openNode: String? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 连线画在底层 —— Canvas 一次性画完所有边,比每条边一个 View 省。
                Canvas { ctx, size in
                    for e in flow.edges {
                        guard let a = flow.node(e.from), let b = flow.node(e.to) else { continue }
                        drawEdge(ctx: ctx, size: size, from: a, to: b,
                                 kind: e.kind, label: e.label)
                    }
                }
                ForEach(flow.nodes) { n in
                    nodeBox(n)
                        .frame(width: Self.width(of: n), height: Self.nodeH)
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
                          kind: PipelineFlow.EdgeKind, label: String?) {
        let ax = a.pos.x * size.width, ay = a.pos.y * size.height
        let bx = b.pos.x * size.width, by = b.pos.y * size.height
        let halfH = Self.nodeH / 2
        let dashed = kind == .trigger || kind == .note
        let color = Color.primary.opacity(dashed ? 0.18 : 0.28)
        let style: StrokeStyle = dashed
            ? StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4])
            : StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

        var path = Path()
        var tip = CGPoint.zero          // 箭头尖
        var facing = Facing.down

        if kind == .note {
            // 侧向注释:右边框 → 左边框,水平方向的三次贝塞尔(控制点只在
            // x 上伸,y 各贴自己那端),上下方向的目标都走得顺。
            let p0 = CGPoint(x: ax + Self.width(of: a) / 2, y: ay)
            tip = CGPoint(x: bx - Self.width(of: b) / 2, y: by)
            let dx = (tip.x - p0.x) * 0.55
            path.move(to: p0)
            path.addCurve(to: tip,
                          control1: CGPoint(x: p0.x + dx, y: p0.y),
                          control2: CGPoint(x: tip.x - dx, y: tip.y))
            facing = .right
        } else if kind == .wrap {
            // 下 → 横 → 下。折点落在两行正中间。
            let midY = (ay + halfH + by - halfH) / 2
            let p0 = CGPoint(x: ax, y: ay + halfH)
            tip = CGPoint(x: bx, y: by - halfH)
            path.move(to: p0)
            path.addLine(to: CGPoint(x: ax, y: midY))
            path.addLine(to: CGPoint(x: bx, y: midY))
            path.addLine(to: tip)
        } else if abs(ay - by) < 0.5 {
            // 同一行 → 横着连。锚点用各自的盒宽(narrow 节点更窄)。
            let p0 = CGPoint(x: ax + Self.width(of: a) / 2, y: ay)
            tip = CGPoint(x: bx - Self.width(of: b) / 2, y: by)
            path.move(to: p0)
            path.addLine(to: tip)
            facing = .right
        } else if let label, !label.isEmpty, abs(ax - bx) < 0.5 {
            // 竖直 + 有条件小字 → **字嵌在箭头中间**:线断开一截,文字压在
            // 断口上居中。measure 出真实文字高度再决定断多宽,不写死。
            let p0 = CGPoint(x: ax, y: ay + halfH)
            tip = CGPoint(x: bx, y: by - halfH)
            let resolved = ctx.resolve(
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
            )
            let ts = resolved.measure(in: CGSize(width: Self.nodeW + 40, height: 60))
            let midY = (p0.y + tip.y) / 2
            let gap = ts.height / 2 + 4
            var seg = Path()
            seg.move(to: p0)
            seg.addLine(to: CGPoint(x: p0.x, y: midY - gap))
            seg.move(to: CGPoint(x: p0.x, y: midY + gap))
            seg.addLine(to: tip)
            ctx.stroke(seg, with: .color(color), style: style)
            ctx.draw(resolved, at: CGPoint(x: ax, y: midY), anchor: .center)
            drawHead(ctx: ctx, tip: tip, facing: .down, color: color)
            return
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

        drawHead(ctx: ctx, tip: tip, facing: facing, color: color)
    }

    private func drawHead(ctx: GraphicsContext, tip: CGPoint,
                          facing: Facing, color: Color) {
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
            HStack(spacing: n.narrow ? 5 : 8) {
                // narrow 盒子:小一号的图标(与 Text 侧栏 PORTRAIT 分区
                // 同款,见 Node.icon)+ 标题居中。
                Image(systemName: n.icon ?? s.icon)
                    .font(.system(size: n.narrow ? 11 : 12, weight: .medium))
                    .foregroundStyle(s.tint)
                    .frame(width: n.narrow ? 13 : 16)
                VStack(alignment: n.narrow ? .center : .leading, spacing: 1) {
                    Text(n.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                        .lineLimit(2)
                        .multilineTextAlignment(n.narrow ? .center : .leading)
                    if let chip = n.chip {
                        Text(chip)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(s.tint.opacity(0.95))
                    }
                }
                if !n.narrow { Spacer(minLength: 0) }
            }
            .padding(.horizontal, n.narrow ? 8 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: n.narrow ? .center : .leading)
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
                    Image(systemName: n.icon ?? s.icon)
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
                // 走 markdown —— 说明里的关键词加粗,给不逐字读的人扫。
                Text(Markdown.inline(n.detail))
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
    /// 排版:竖排主干,最后一行分叉到被触发的另外两条 pipeline。
    ///
    /// "等这一天过完" 是**闸门条件**不是步骤,所以做成第一条连线上的一行小字,
    /// 不占节点 —— 节点只留真正会产出东西的步骤。
    static let eventsProcessor = PipelineFlow(
        nodes: [
            Node(
                id: "capture",
                title: "Captured data",
                kind: .source,
                chip: "~/.portrait",
                detail: "One UTC day: screenshots + their OCR text, audio transcripts with speakers, your typing.\n\n**The only input.** Nothing is added later.",
                pos: CGPoint(x: 0.5, y: 0.05)
            ),
            Node(
                id: "event",
                title: "Build events",
                kind: .llm,
                chip: "main model",
                detail: "Clusters the day into events. **One Markdown file per event**, at `~/.portrait/events/<day>/`.\n\nStarts at **UTC midnight + 10 min** — the grace period lets late transcripts and OCR land. Not ready → retried every 15 min.",
                pos: CGPoint(x: 0.5, y: 0.196)
            ),
            Node(
                id: "merge",
                title: "Merge repeats",
                kind: .llm,
                chip: "main model",
                detail: "The model sees your recent events while building. Same thing again → **merges into the existing event**, no second file.\n\nA merge adds 1 to occurrence count and attaches the new day's frames. **More days = slower decay**, so recurring things outlive one-offs. Title and summary stay as first written.",
                pos: CGPoint(x: 0.5, y: 0.341)
            ),
            Node(
                id: "impact",
                title: "Score impact",
                kind: .llm,
                chip: "main model",
                detail: "One impact score per event — **how much it mattered to you**.\n\nDecides what survives in memory, and node size in the Neural Graph.",
                pos: CGPoint(x: 0.5, y: 0.487)
            ),
            Node(
                id: "weight",
                title: "Weights + daily budget",
                kind: .deterministic,
                detail: "**No AI.** Two algorithms.\n\n• **Weights** — exponential half-life decay, recomputed across the whole tree.\n\n• **Daily budget** — a busy day can't flood memory. Over the cap → scaled down; quiet days untouched. Peaks above the protection threshold are never scaled.",
                pos: CGPoint(x: 0.5, y: 0.632)
            ),
            Node(
                id: "classify",
                title: "Group into folders",
                kind: .llm,
                chip: "light model",
                detail: "Files events into project folders at `~/.portrait/events/_folders/*.json`.\n\n**Light model** — the call is narrow: existing folder, or a new one.\n\n**Last step of the run.**",
                pos: CGPoint(x: 0.5, y: 0.778)
            ),
            Node(
                id: "distill",
                title: "Portraits Distiller",
                kind: .downstream,
                detail: "Events landed → distiller **marked pending**. It turns them into long-term portrait entries on its own schedule.",
                pos: CGPoint(x: 0.27, y: 0.93)
            ),
            Node(
                id: "personality",
                title: "Personality Refresher",
                kind: .downstream,
                detail: "Each processed day is also **marked pending** for the refresher. It re-derives personality tags from that day's events, the rest of the portrait, and OCR.",
                pos: CGPoint(x: 0.73, y: 0.93)
            ),
        ],
        edges: [
            Edge(from: "capture", to: "event",
                 label: "Wrap data up once the day is over · 12 AM UTC"),
            Edge(from: "event", to: "merge"),
            Edge(from: "merge", to: "impact"),
            Edge(from: "impact", to: "weight"),
            Edge(from: "weight", to: "classify"),
            Edge(from: "classify", to: "distill", kind: .trigger),
            Edge(from: "classify", to: "personality", kind: .trigger),
        ],
        height: 620
    )
}

// MARK: - Portraits Distiller

extension PipelineFlow {

    /// Portraits Distiller。**顺序对应 `PortraitDistiller.distillImpl`**
    /// (入口 refreshDistillCategories → 按 category 分组 → 逐 category LLM
    /// 往返 → 收尾 `Archiver.run`)。
    static let portraitsDistiller = PipelineFlow(
        nodes: [
            Node(
                id: "events",
                title: "Processed events",
                kind: .source,
                chip: "events/",
                detail: "**The whole tree, not one day.** Every event that isn't archived — which is why one portrait entry can be backed by things months apart.\n\nSource is the Events Processor. Days that failed there have their events removed, so only clean days arrive.",
                pos: CGPoint(x: 0.30, y: 0.09)
            ),
            Node(
                id: "group",
                title: "Sort into categories",
                kind: .deterministic,
                detail: "**No AI.** Two passes over disk.\n\n• Every event filed under the categories it belongs to — experiences, social, background, interests, skills.\n\n• Existing entries re-weighted first, so an untouched entry still decays instead of freezing.\n\nEmpty categories are skipped — **no tokens spent on nothing**.",
                pos: CGPoint(x: 0.30, y: 0.34)
            ),
            Node(
                id: "distill",
                title: "Distill each category",
                kind: .llm,
                chip: "main model",
                detail: "**One round trip per category** — listed on the right. The model sees that category's events plus the entries already written, and answers **create / update / no change** per entry.\n\nResults land as Markdown at `~/.portrait/portrait/<category>/`.\n\nPersonality and writing style are excluded on purpose — they have their own pipelines and would be overwritten here.",
                pos: CGPoint(x: 0.30, y: 0.60)
            ),
            // 五个类别 —— 挂在右侧的**注释列**(08-10 用户三稿):不是流程的
            // 步骤,是"distill 都分成哪些 portrait"的展开说明,所以 note 虚线
            // 从 distill 侧向引出、**不接回 archive**。主干整体左移让位。
            // (emotions 08-10 前端下线,不再展示;pipeline 的彻底移除挂账。)
            Node(
                id: "cat_experiences", title: "Experiences", kind: .llm,
                detail: "Chapters of your life as lived — projects, trips, milestones, hard weeks. Events that tell a story over time end up here.\n\nWritten to portrait/experiences/.",
                pos: CGPoint(x: 0.80, y: 0.28), narrow: true, icon: "map.fill"
            ),
            Node(
                id: "cat_social", title: "Social", kind: .llm,
                detail: "Who shows up in your life and how — collaborators, friends, communities, how you host and keep in touch.\n\nWritten to portrait/social/.",
                pos: CGPoint(x: 0.80, y: 0.42), narrow: true, icon: "person.3.fill"
            ),
            Node(
                id: "cat_background", title: "Background", kind: .llm,
                detail: "The slow-moving facts — where you work and study, where you're from, the long arcs everything else sits on.\n\nWritten to portrait/background/.",
                pos: CGPoint(x: 0.80, y: 0.56), narrow: true, icon: "books.vertical.fill"
            ),
            Node(
                id: "cat_interests", title: "Interests", kind: .llm,
                detail: "What you keep coming back to unprompted — topics, hobbies, rabbit holes. Recurrence is the signal here.\n\nWritten to portrait/interests/.",
                pos: CGPoint(x: 0.80, y: 0.70), narrow: true, icon: "sparkles"
            ),
            Node(
                id: "cat_skills", title: "Skills", kind: .llm,
                detail: "What you can actually do, with evidence — languages, tools, crafts, and how deep each one goes.\n\nWritten to portrait/skills/.",
                pos: CGPoint(x: 0.80, y: 0.84), narrow: true, icon: "wrench.adjustable.fill"
            ),
            Node(
                id: "archive",
                title: "Archive faded entries",
                kind: .deterministic,
                detail: "**No AI.** A sweep right after the update: weight below the archive threshold **and** untouched long enough → archived.\n\n**Nothing is deleted.** Archived entries stay on disk, just out of your portrait. Pinned entries are never archived. Both limits are in Settings → Memory.",
                pos: CGPoint(x: 0.30, y: 0.88)
            ),
        ],
        edges: [
            Edge(from: "events", to: "group",
                 label: "Marked pending whenever new events land"),
            Edge(from: "group", to: "distill"),
            Edge(from: "distill", to: "cat_experiences", kind: .note),
            Edge(from: "distill", to: "cat_social", kind: .note),
            Edge(from: "distill", to: "cat_background", kind: .note),
            Edge(from: "distill", to: "cat_interests", kind: .note),
            Edge(from: "distill", to: "cat_skills", kind: .note),
            Edge(from: "distill", to: "archive"),
        ],
        height: 520
    )
}

// MARK: - Personality Refresher

extension PipelineFlow {

    /// Personality Refresher。**顺序对应 `PersonalityRefresh.refreshImpl`**
    /// (snapshot → OCR 验证 → cluster → merge → apply)。跟 distiller 不同,
    /// 这条是**按天**跑的,一次最多 7 天。
    static let personalityRefresher = PipelineFlow(
        nodes: [
            Node(
                id: "day",
                title: "Timeline patterns & events",
                kind: .source,
                chip: "events/<day>",
                detail: "Rebuilt **day by day**, oldest pending first, up to 7 days per run.\n\nEach day is independent — one that fails is retried later without holding up the rest.",
                pos: CGPoint(x: 0.5, y: 0.055)
            ),
            Node(
                id: "snapshot",
                title: "Read the day for traits",
                kind: .llm,
                chip: "main model",
                detail: "**The heaviest step.** The model reads that day's important events and proposes personality tags.\n\nEach tag carries the events it came from **plus keywords that should be visible on screen if the trait is real** — that's what the next step checks.",
                pos: CGPoint(x: 0.5, y: 0.257)
            ),
            Node(
                id: "ocr",
                title: "Check it against your screen",
                kind: .deterministic,
                detail: "**No AI. The strictest gate in the system.** Every proposed trait is searched for in that day's screenshots. **Under 15 matching frames (~45s of screen time) → discarded.**\n\nA model asked \"what is this person like?\" will always find something to say. Requiring on-screen evidence is what keeps personality from turning into flattery.",
                pos: CGPoint(x: 0.5, y: 0.422)
            ),
            Node(
                id: "cluster",
                title: "Group similar traits",
                kind: .llm,
                chip: "light model",
                detail: "Survivors are grouped by meaning — \"careful about details\", \"double-checks work\", \"perfectionist\" become one instead of three.\n\n**Light model on purpose**: narrow call, and a smaller model is more decisive at it.",
                pos: CGPoint(x: 0.5, y: 0.587)
            ),
            Node(
                id: "merge",
                title: "Merge into what's known",
                kind: .llm,
                chip: "main model",
                detail: "Each group is compared against the concepts you already have — **reinforce / rewrite / create**.\n\nThis is why personality **accumulates** instead of being replaced every day.",
                pos: CGPoint(x: 0.5, y: 0.752)
            ),
            Node(
                id: "apply",
                title: "Write concepts",
                kind: .deterministic,
                detail: "**No AI.** Merge decisions applied to `~/.portrait/portrait/personality/` — new concepts created, existing ones get the day's evidence appended. Day marked done.",
                pos: CGPoint(x: 0.5, y: 0.917)
            ),
        ],
        edges: [
            Edge(from: "day", to: "snapshot",
                 label: "Only events that actually mattered · weight > 3"),
            Edge(from: "snapshot", to: "ocr"),
            Edge(from: "ocr", to: "cluster"),
            Edge(from: "cluster", to: "merge"),
            Edge(from: "merge", to: "apply"),
        ],
        height: 545
    )
}

// MARK: - Writing Style Distiller

extension PipelineFlow {

    /// Writing Style Distiller。**顺序对应 `WritingStyleDistiller.runCoreImpl`**
    /// (weights → dependency gate → 取一批 records → LLM → applyDrafts)。
    ///
    /// 这条不走 events —— 上游是 typing capture 的 `writing_records`。
    ///
    /// `@MainActor`:批量上限直接引 `WritingStyleDistiller.defaultBatchCap`
    /// (它在 @MainActor 类上),省得在文案里再抄一遍数字抄到走样。
    @MainActor
    static let writingStyleDistiller = PipelineFlow(
        nodes: [
            Node(
                id: "records",
                title: "Writing events",
                kind: .source,
                chip: "writing_records",
                detail: "**Not events, and not everything you typed.** The pieces Typing Capture reconstructed and kept: the message, the email, the commit note, plus what you were doing at the time.\n\nEach piece is consumed **exactly once**. If you didn't type it, it isn't here.",
                pos: CGPoint(x: 0.5, y: 0.083)
            ),
            Node(
                id: "batch",
                title: "Take a batch",
                kind: .deterministic,
                chip: "up to \(WritingStyleDistiller.defaultBatchCap) per run",
                detail: "**No AI.** Pulls the oldest unprocessed pieces up to the batch cap, and loads your existing style entries so the model updates them instead of writing near-duplicates.\n\nEntries are re-weighted in the same pass — **styles you stopped using fade even on runs that change nothing**.",
                pos: CGPoint(x: 0.5, y: 0.389)
            ),
            Node(
                id: "llm",
                title: "Distill style facets",
                kind: .llm,
                chip: "light model",
                detail: "The model reads the batch next to your existing entries and returns drafts — **a new facet, or an update to one**. Facets: tone, sentence rhythm, how you open and close a message, how you edit yourself.\n\n**Light model** — short input, narrow call.",
                pos: CGPoint(x: 0.5, y: 0.639)
            ),
            Node(
                id: "apply",
                title: "Save + mark processed",
                kind: .deterministic,
                detail: "**No AI.** Drafts written to `~/.portrait/portrait/writing_style/`, weights refreshed across the tree, whole batch marked processed — **including pieces the model didn't use**, so they don't come back next run.\n\nAutomatic runs save straight away. A manual run **stages** the drafts and waits for your approval; nothing else starts while one is waiting.",
                pos: CGPoint(x: 0.5, y: 0.889)
            ),
        ],
        edges: [
            Edge(from: "records", to: "batch",
                 label: "Only runs when there's new writing to read"),
            Edge(from: "batch", to: "llm"),
            Edge(from: "llm", to: "apply"),
        ],
        height: 360
    )
}
