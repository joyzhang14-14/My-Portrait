import SwiftUI

/// Workflow 每一段的 How it works 图 —— 横向流程:一格一步、从左往右,点一格在
/// 下面出说明。一段可以有几行(lane),比如事件合并「每个区间」和「每次运行」、
/// 画像和性格各一行。
///
/// **数据描述 + 通用渲染器两层**:每一段写一份 `PipelineFlow` 常量,渲染共用
/// `PipelineFlowView`。步骤顺序必须跟代码一一对应(见各常量的注释),改调度器
/// 的步骤时这里也要跟着改。
struct PipelineFlow {

    /// 一步的性质 —— 决定配色和边框。一眼要能分出「这步烧不烧 token」。
    enum Kind {
        /// 采集来的数据 / 上一段的产物。
        case data
        /// 确定性算法,不打 LLM。虚线框。
        case algorithm
        /// 走 LLM 的步骤。
        case ai
        /// 流水线的下一段 —— 本图只标「交给它」,不展开。
        case next
    }

    struct Step: Identifiable {
        let id: String
        let title: String
        let kind: Kind
        /// 标题下的一行小字(模型档位 / 数据来源)。
        var sub: String? = nil
        /// 右上角的小标(per frame / per category):这一步会按某个单位重复。
        var loop: String? = nil
        /// 进入这一步的箭头下面的条件小字。nil = 普通箭头。
        var gate: String? = nil
        /// 点开看的说明,支持 **加粗**。
        let detail: String
    }

    struct Lane: Identifiable {
        /// 行标题(小号大写)。只有一行时传 nil。
        var title: String? = nil
        let steps: [Step]
        var id: String { title ?? steps.first?.id ?? "" }
    }

    let lanes: [Lane]
}

// MARK: - 渲染

struct PipelineFlowView: View {
    let flow: PipelineFlow

    @State private var selected: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            ForEach(flow.lanes) { lane in
                VStack(alignment: .leading, spacing: 6) {
                    if let t = lane.title {
                        Text(t.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.textPrimary.opacity(0.45))
                    }
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(Array(lane.steps.enumerated()), id: \.element.id) { i, step in
                            if i > 0 { arrow(step.gate) }
                            stepBox(step)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            detailPanel
        }
    }

    // MARK: 一格

    private func stepBox(_ s: PipelineFlow.Step) -> some View {
        let st = Self.style(for: s.kind)
        let on = selected == s.id
        return Button {
            selected = on ? nil : s.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(st.label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(st.tint)
                Text(s.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = s.sub {
                    Text(sub)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minWidth: 72, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(st.tint.opacity(s.kind == .ai ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(on ? Theme.textPrimary.opacity(0.85) : st.tint.opacity(0.6),
                                  style: StrokeStyle(lineWidth: on ? 1.6 : 1,
                                                     dash: st.dashed && !on ? [3.5, 3] : []))
            )
            .overlay(alignment: .topTrailing) {
                if let loop = s.loop {
                    Text(loop)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.textPrimary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.hover))
                        .offset(x: 4, y: -7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 箭头

    /// 横线 + 箭头尖;有条件小字时箭头加宽,字压在线下。
    private func arrow(_ gate: String?) -> some View {
        let color = Theme.textPrimary.opacity(0.28)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: 2, y: 0))
                p.addLine(to: CGPoint(x: 1000, y: 0))
            }
            .stroke(color, lineWidth: 1.2)
            .frame(height: 1)
            .clipped()
            .overlay(alignment: .trailing) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: -3.5))
                    p.addLine(to: CGPoint(x: 5, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: 3.5))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 5, height: 1)
                .padding(.trailing, 2)
            }
            if let gate {
                Text(gate)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .offset(y: 14)
            }
        }
        .frame(width: gate == nil ? 20 : 54)
    }

    // MARK: 说明 + 图例

    @ViewBuilder
    private var detailPanel: some View {
        let step = flow.lanes.flatMap(\.steps).first { $0.id == selected }
        Group {
            if let step {
                Text(Markdown.inline("**\(step.title)** — \(step.detail)"))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            } else {
                Text("Click a step to see what it does.")
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
            }
        }
        .font(.system(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
    }

    /// 只列这张图里真出现过的性质,顺序固定。
    private var legend: some View {
        let order: [PipelineFlow.Kind] = [.data, .algorithm, .ai, .next]
        let present = order.filter { k in flow.lanes.contains { $0.steps.contains { $0.kind == k } } }
        return HStack(spacing: 14) {
            ForEach(present, id: \.self) { k in
                let st = Self.style(for: k)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(st.tint, style: StrokeStyle(lineWidth: 1.2, dash: st.dashed ? [2.5, 2] : []))
                        .frame(width: 10, height: 10)
                    Text(st.name).font(.system(size: 10))
                        .foregroundStyle(Theme.textPrimary.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
    }

    struct KindStyle {
        let tint: Color
        let dashed: Bool
        /// 格子里那行小字。
        let label: String
        /// 图例里的名字。
        let name: String
    }

    static func style(for kind: PipelineFlow.Kind) -> KindStyle {
        switch kind {
        case .data:
            return KindStyle(tint: Color(red: 0.35, green: 0.66, blue: 0.90), dashed: false,
                             label: "DATA", name: "Data")
        case .algorithm:
            return KindStyle(tint: Color.secondary, dashed: true,
                             label: "ALGORITHM", name: "Algorithm")
        case .ai:
            return KindStyle(tint: Theme.accent, dashed: false,
                             label: "AI", name: "AI step")
        case .next:
            return KindStyle(tint: Color.secondary, dashed: true,
                             label: "NEXT", name: "Next step")
        }
    }
}

// MARK: - Event Session

extension PipelineFlow {

    /// Event Session(还没上线,EventSession 开关灰着)。按设计:按焦点切会话 →
    /// 挑关键帧 → 逐帧看图(只给上一帧的笔记)→ 整个会话总结。
    static let eventSession = PipelineFlow(lanes: [
        Lane(steps: [
            Step(id: "input", title: "Screen + input", kind: .data, sub: "screen · input",
                 detail: "Screenshots with their OCR word boxes, which app and window had focus, keystrokes, clicks and scrolls. **The only input** — and the most private data My Portrait keeps."),
            Step(id: "cut", title: "Cut into sessions", kind: .algorithm, sub: "by focus change",
                 detail: "A new session starts every time focus moves to another app or window. **Pass-through sessions** — under 3 seconds, no keys, clicks or scrolls, at most 2 frames — are dropped."),
            Step(id: "pick", title: "Pick key frames", kind: .algorithm,
                 detail: "Keeps the frames that carry the story — the first one, the ones where you pressed Return, the ones where the screen clearly changed — so a long session doesn't cost a model call per second."),
            Step(id: "observe", title: "Read each frame", kind: .ai, sub: "vision model", loop: "per frame",
                 detail: "One call per picked frame. It notes **what you're doing, who's involved and what's in the background**, and sees only the previous frame's notes — not its image — so it can tell what changed."),
            Step(id: "summarize", title: "Summarize the session", kind: .ai,
                 detail: "The frame notes and your keystrokes become **one summary per session**: what you did, with whom, and the anchors that back it up — text you typed, titles you saw."),
            Step(id: "next", title: "Event Merge", kind: .next,
                 detail: "Session summaries go to **Event Merge**, which groups them into events."),
        ]),
    ])
}

// MARK: - Event Merge

extension PipelineFlow {

    /// Event Merge。**顺序与 `MemoryScheduler.runEventJob` 一一对应**:每个区间
    /// event → impact;整轮一次 weightPass → Archiver.runEvents → classify。
    static let eventMerge = PipelineFlow(lanes: [
        Lane(title: "For each interval", steps: [
            Step(id: "interval", title: "One interval", kind: .data, sub: "screen · audio · input",
                 detail: "The stretch between two breaks of **2 hours or more**: screenshots and their OCR text, audio transcripts, your typing. Closed intervals wait for the scheduled time; Run now closes one on the spot."),
            Step(id: "build", title: "Build events", kind: .ai, sub: "main model", gate: "closes at a\n2 h break",
                 detail: "Clusters the interval into events, **one Markdown file per event** under `events/<day>/`. The model sees your recent events while building."),
            Step(id: "repeat", title: "Merge repeats", kind: .ai, sub: "main model",
                 detail: "Same thing again → **merged into the existing event**, no second file. A merge adds an occurrence and the new day's frames, so recurring things fade slower than one-offs."),
            Step(id: "impact", title: "Score impact", kind: .ai, sub: "main model",
                 detail: "One impact score per new or merged event — **how much it mattered to you**. Decides what survives in memory and how big it is in the graph."),
        ]),
        Lane(title: "Once per run", steps: [
            Step(id: "weight", title: "Weights + daily budget", kind: .algorithm,
                 detail: "**Weights** decay by half-life across all events, and a **daily budget** scales busy days down so one day can't flood memory. Settled at the end time of the data processed, not today."),
            Step(id: "archive", title: "Archive cold events", kind: .algorithm, sub: "90 days · low weight",
                 detail: "An event that hasn't come up for **90 days** and whose weight has faded moves to the archive. Its history before archiving stays on the timeline. **Nothing is deleted.**"),
            Step(id: "folders", title: "Group into folders", kind: .ai, sub: "light model",
                 detail: "Files events into project folders. **Light model** — a narrow call: an existing folder, or a new one. Last step of the run."),
            Step(id: "next", title: "Portrait Distillation", kind: .next, gate: "new events\nlanded",
                 detail: "**Portrait Distillation** is marked pending and picks the new events up on its own schedule."),
        ]),
    ])
}

// MARK: - Portrait Distillation

extension PipelineFlow {

    /// Portrait Distillation。画像一行对应 `PortraitDistiller.distillImpl`
    /// (按 category 分组 → 逐 category LLM → `Archiver.run`);性格一行对应
    /// `PersonalityRefresh.refreshImpl`(snapshot → OCR 验证 → cluster → merge → apply),
    /// 按本地日跑。
    static let portraitDistillation = PipelineFlow(lanes: [
        Lane(title: "Portrait", steps: [
            Step(id: "events", title: "New events", kind: .data,
                 detail: "Events from Event Merge. The portrait is marked pending whenever new events land."),
            Step(id: "sort", title: "Sort into categories", kind: .algorithm, sub: "5 categories",
                 detail: "Every event is filed under the categories it belongs to — **experiences, social, background, interests, skills**. Existing entries are re-weighted first, and empty categories are skipped, so no tokens are spent on nothing."),
            Step(id: "distill", title: "Distill each category", kind: .ai, sub: "main model", loop: "per category",
                 detail: "**One round trip per category.** The model sees that category's events plus the entries already written, and answers **create / update / no change** for each entry."),
            Step(id: "archive", title: "Archive faded entries", kind: .algorithm,
                 detail: "Entries whose weight fell below the limit and that haven't been touched for long enough are archived. **Nothing is deleted**, and pinned entries are never archived."),
        ]),
        Lane(title: "Personality · one day at a time", steps: [
            Step(id: "day", title: "A finished day", kind: .data, sub: "events · screen",
                 detail: "One local day, once every interval touching it is processed. Only the events that mattered (**weight above 3**), plus that day's screen."),
            Step(id: "traits", title: "Read the day for traits", kind: .ai, sub: "main model",
                 detail: "**The heaviest step.** The model reads the day's important events and proposes personality traits, each with keywords that should show up on screen if the trait is real."),
            Step(id: "check", title: "Check against your screen", kind: .algorithm, sub: "≥ 15 frames",
                 detail: "The strictest gate. Each proposed trait is searched for in that day's screenshots. **Under 15 matching frames (about 45 s on screen) → discarded.** This is what keeps personality from turning into flattery."),
            Step(id: "group", title: "Group similar traits", kind: .ai, sub: "light model",
                 detail: "Survivors are grouped by meaning — \"careful about details\", \"double-checks work\" and \"perfectionist\" become one. **Light model on purpose**: it's a narrow call."),
            Step(id: "merge", title: "Merge into what's known", kind: .ai, sub: "main model",
                 detail: "Each group is compared with the traits you already have — **reinforce, rewrite or create** — so personality accumulates instead of being replaced every day."),
            Step(id: "write", title: "Write traits", kind: .algorithm,
                 detail: "Decisions are written to `portrait/personality/`: new traits are created, existing ones get the day's evidence. The day is marked done."),
        ]),
    ])
}
