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
                        drawEdge(ctx: ctx, size: size, from: a, to: b,
                                 kind: e.kind, label: e.label)
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
                          kind: PipelineFlow.EdgeKind, label: String?) {
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
    /// 排版:竖排主干,最后一行分叉到被触发的另外两条 pipeline。
    ///
    /// "等这一天过完" 是**闸门条件**不是步骤,所以做成第一条连线上的一行小字,
    /// 不占节点 —— 节点只留真正会产出东西的步骤。
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
                id: "event",
                title: "Build events",
                kind: .llm,
                chip: "main model",
                detail: "Reads the whole day's timeline and clusters it into discrete events — one file per event under events/<day>/. This is where a scroll of raw activity turns into \"what actually happened\".\n\nA day is only picked up once it's actually over — UTC midnight plus a 10-minute grace period, so transcripts and OCR that are still finishing up land in time. Days that aren't ready are skipped and retried on the next tick (every 15 minutes).",
                pos: CGPoint(x: 0.5, y: 0.27)
            ),
            Node(
                id: "impact",
                title: "Score impact",
                kind: .llm,
                chip: "main model",
                detail: "Every event gets an impact score — how much this mattered to you. That score is what later decides which events survive in your memory and how big they show up in the Neural Graph.",
                pos: CGPoint(x: 0.5, y: 0.45)
            ),
            Node(
                id: "weight",
                title: "Weights + daily budget",
                kind: .deterministic,
                detail: "Two pure algorithms, no AI:\n\n• Weights — every event decays over time (exponential half-life), recomputed across the whole tree.\n\n• Daily budget — a busy day can't flood your memory. If a day's total impact exceeds the cap it's scaled back down; quiet days are left alone. Peak events above the protection threshold are never scaled.",
                pos: CGPoint(x: 0.5, y: 0.63)
            ),
            Node(
                id: "classify",
                title: "Group into folders",
                kind: .llm,
                chip: "light model",
                detail: "Sorts events into project folders (events/_folders/*.json) — \"My Portrait\", \"UCI application\", and so on. Uses the light model because the decision is narrow: does this event belong in an existing folder, or does it need a new one?\n\nThis is the last step of the run.",
                pos: CGPoint(x: 0.5, y: 0.81)
            ),
            Node(
                id: "distill",
                title: "Portraits Distiller",
                kind: .downstream,
                detail: "Once events land, the portrait distiller is marked pending — it turns events into long-term portrait entries (experiences, social, and so on) on its own schedule.",
                pos: CGPoint(x: 0.27, y: 0.95)
            ),
            Node(
                id: "personality",
                title: "Personality Refresher",
                kind: .downstream,
                detail: "Each processed day is also marked pending for the personality refresher, which re-derives your personality tags from that day's events, the rest of the portrait, and OCR.",
                pos: CGPoint(x: 0.73, y: 0.95)
            ),
        ],
        edges: [
            Edge(from: "capture", to: "event",
                 label: "Wrap data up once the day is over · 12 AM UTC"),
            Edge(from: "event", to: "impact"),
            Edge(from: "impact", to: "weight"),
            Edge(from: "weight", to: "classify"),
            Edge(from: "classify", to: "distill", kind: .trigger),
            Edge(from: "classify", to: "personality", kind: .trigger),
        ],
        height: 500
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
                title: "Every event you have",
                kind: .source,
                chip: "events/",
                detail: "Not one day — the whole tree. The distiller reads every event that isn't archived yet, which is why a portrait entry can be backed by things that happened months apart.\n\nEvents come from the Events Processor; days that failed there have their events removed, so only clean days ever reach here.",
                pos: CGPoint(x: 0.5, y: 0.083)
            ),
            Node(
                id: "group",
                title: "Sort into categories",
                kind: .deterministic,
                detail: "No AI. Two passes over the disk:\n\n• Every event is filed under the portrait categories it belongs to — social, background, experiences, interests, skills, emotions.\n\n• Existing portrait entries are re-weighted first, so an entry that nothing touched this round still decays with time instead of sitting frozen.\n\nCategories with no events and no existing entries are skipped entirely — no tokens spent on nothing.",
                pos: CGPoint(x: 0.5, y: 0.389)
            ),
            Node(
                id: "distill",
                title: "Distill each category",
                kind: .llm,
                chip: "main model",
                detail: "One round trip per category. The model sees that category's events plus the entries already written, and answers with create / update / no change for each one.\n\nThis is the step that turns \"here are 40 things that happened\" into \"this is a person who…\". Results land as Markdown under portrait/<category>/.\n\nPersonality and writing style are deliberately left out — they have their own pipelines and would be overwritten here.",
                pos: CGPoint(x: 0.5, y: 0.639)
            ),
            Node(
                id: "archive",
                title: "Archive faded entries",
                kind: .deterministic,
                detail: "No AI. A sweep over the portrait tree right after it was updated: any entry whose weight has dropped below the archive threshold and that hasn't been touched for long enough is moved to the archive.\n\nNothing is deleted — archived entries stay on disk and stop showing up in your portrait. Pinned entries are never archived. Both limits live in Settings → Memory.",
                pos: CGPoint(x: 0.5, y: 0.889)
            ),
        ],
        edges: [
            Edge(from: "events", to: "group",
                 label: "Marked pending whenever new events land"),
            Edge(from: "group", to: "distill"),
            Edge(from: "distill", to: "archive"),
        ],
        height: 360
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
                title: "One processed day",
                kind: .source,
                chip: "events/<day>",
                detail: "Personality is rebuilt day by day, oldest pending day first, up to 7 days per run. Each day is handled independently — a day that fails is retried later without holding up the rest.",
                pos: CGPoint(x: 0.5, y: 0.055)
            ),
            Node(
                id: "snapshot",
                title: "Read the day for traits",
                kind: .llm,
                chip: "main model",
                detail: "The heaviest step. The model reads that day's important events and proposes personality tags — each one carrying the events it came from, plus a handful of keywords that should be visible on your screen if the trait is real.\n\nThose keywords are what the next step checks against.",
                pos: CGPoint(x: 0.5, y: 0.257)
            ),
            Node(
                id: "ocr",
                title: "Check it against your screen",
                kind: .deterministic,
                detail: "No AI, and the strictest gate in the whole system. For every proposed trait, the day's screenshots are searched for its keywords. Fewer than 15 matching frames — roughly 45 seconds of screen time — and the trait is thrown away.\n\nThis exists because a language model asked \"what is this person like?\" will always find something to say. Requiring the evidence to be visible on screen is what keeps personality from drifting into flattering fiction.",
                pos: CGPoint(x: 0.5, y: 0.422)
            ),
            Node(
                id: "cluster",
                title: "Group similar traits",
                kind: .llm,
                chip: "light model",
                detail: "Survivors get grouped by meaning, so \"careful about details\", \"double-checks work\" and \"perfectionist\" become one thing instead of three.\n\nUses the light model on purpose — the decision is narrow and a smaller model is more decisive at it.",
                pos: CGPoint(x: 0.5, y: 0.587)
            ),
            Node(
                id: "merge",
                title: "Merge into what's known",
                kind: .llm,
                chip: "main model",
                detail: "Each group is compared against the personality concepts you already have: is this the same trait showing up again (reinforce it), a sharper version of it (rewrite), or genuinely new (create)?\n\nThis is why personality accumulates instead of being replaced every day.",
                pos: CGPoint(x: 0.5, y: 0.752)
            ),
            Node(
                id: "apply",
                title: "Write concepts",
                kind: .deterministic,
                detail: "No AI. The merge decisions are applied to portrait/personality/ — new concepts created, existing ones updated with the day's evidence appended, and the day is marked done.",
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
                title: "Things you actually wrote",
                kind: .source,
                chip: "writing_records",
                detail: "Not events, and not everything you typed — the pieces of writing that Typing Capture reconstructed and kept: the message, the email, the commit note, along with what you were doing at the time.\n\nEach piece is consumed exactly once. Nothing here is invented; if you didn't type it, it isn't in this pipeline.",
                pos: CGPoint(x: 0.5, y: 0.083)
            ),
            Node(
                id: "batch",
                title: "Take a batch",
                kind: .deterministic,
                chip: "up to \(WritingStyleDistiller.defaultBatchCap) per run",
                detail: "No AI. Pulls the oldest unprocessed pieces, up to the batch cap, and reads the style entries you already have so the model can update them instead of writing near-duplicates.\n\nExisting entries are re-weighted at the same time, so styles you've stopped using fade even on runs that change nothing.",
                pos: CGPoint(x: 0.5, y: 0.389)
            ),
            Node(
                id: "llm",
                title: "Distill style facets",
                kind: .llm,
                chip: "light model",
                detail: "The model reads the batch next to your existing entries and answers with drafts — a new facet, or an update to one that exists. Facets are things like tone, sentence rhythm, how you open and close a message, how you edit yourself.\n\nRuns on the light model: the input is short text and the judgement is narrow.",
                pos: CGPoint(x: 0.5, y: 0.639)
            ),
            Node(
                id: "apply",
                title: "Save + mark processed",
                kind: .deterministic,
                detail: "No AI. Drafts are written under portrait/writing_style/, weights are refreshed across the tree, and the whole batch is marked processed — including pieces the model chose not to use, so they don't come back next run.\n\nAutomatic runs save straight away. A manual run stages the drafts instead and waits for you to approve them; while a run is waiting, nothing else starts.",
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
