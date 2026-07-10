import GraphPhysics
import SwiftUI

extension Notification.Name {
    /// 图谱浮窗的 wr chip → 切回 text 模式的 Input 并定位该 record。
    /// object = Int64(writing record id)。ContentView 监听。
    static let memoryJumpToInputRecord = Notification.Name("MyPortrait.MemoryJumpToInputRecord")
}

/// 末端球(event / portrait 小球)点击后的浮动详情卡(需求 §5.1):
/// 完整内容,markdown 正文可滚动;来源 chips 可点跳转。
/// 关闭:右上 × / 鼠标移出浮窗 1s 后自动关(移回取消计时)。
struct GraphFloatWindow: View {
    let node: GraphNode
    /// "移出 1s 自动关"开关:窗口自己在动(球没停/相机在动)时由调用方置
    /// false —— 窗口从静止光标底下滑走同样触发 onHover exit,不代表用户
    /// 想关(07-10 跳转落地期浮窗被误杀)。移入取消计时不受此开关影响。
    let autoCloseEnabled: Bool
    let onClose: () -> Void
    /// portrait 浮窗的 event chip → 跳 Event 图谱并打开该 event 的浮窗。
    let onJumpToEvent: (String) -> Void

    @State private var file: PortraitFile? = nil
    @State private var currentWeight: Double = 0
    /// markdown 段落在 load() 里解析一次存好 —— 浮窗跟球走时 body 每帧
    /// 重算,绝不能在 body 里逐帧重新解析 AttributedString。
    @State private var proseBlocks: [AttributedString] = []
    /// personality 概念 `## events` 之后的小节(照旧渲染,非 chip)。
    @State private var afterBlocks: [AttributedString] = []
    @State private var derivedRefs: [MemoriesView.DerivedRef] = []
    @State private var wrIds: [Int64] = []
    @State private var closeTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(node.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if let file {
                metaRows(file)
                Divider().background(Color.primary.opacity(0.1))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        blocks(proseBlocks)
                        if !derivedRefs.isEmpty {
                            Divider().background(Color.primary.opacity(0.1))
                            derivedChips
                        }
                        if !wrIds.isEmpty {
                            Divider().background(Color.primary.opacity(0.1))
                            wrChips
                        }
                        if !afterBlocks.isEmpty {
                            Divider().background(Color.primary.opacity(0.1))
                            blocks(afterBlocks)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding(14)
        .frame(width: 380)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .glassCard()
        // 移出 1s 自动关;移回取消(需求 §5.1)。窗口在动时 exit 不武装
        //(见 autoCloseEnabled 注释)。
        .onHover { inside in
            if inside {
                closeTask?.cancel()
                closeTask = nil
            } else if autoCloseEnabled {
                closeTask = Task {
                    try? await Task.sleep(
                        for: .seconds(GraphConstants.floatWindowAutoCloseDelay))
                    if !Task.isCancelled { onClose() }
                }
            }
        }
        .task(id: node.id) { await load() }
    }

    // MARK: - 元数据行(英文文案)

    private func metaRows(_ f: PortraitFile) -> some View {
        let rows: [(String, String)] = [
            ("type", f.eventType.isEmpty ? "experience" : f.eventType),
            ("weight", String(format: "%.3g", currentWeight)),
            ("last occurred", (f.lastOccurrence ?? f.created).formatted(.iso8601.year().month().day())),
            ("occurrences", "\(f.occurrences.count)"),
            ("tags", f.tags.isEmpty ? "—" : f.tags.joined(separator: ", ")),
        ]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 88, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - markdown(load() 时解析好的段落,body 只渲染)

    @ViewBuilder
    private func blocks(_ parsed: [AttributedString]) -> some View {
        ForEach(Array(parsed.enumerated()), id: \.offset) { _, attr in
            Text(attr)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 逐段解析(同 text 模式口径:按空行分段,inline-only)。后台执行。
    nonisolated private static func parseBlocks(_ raw: String) -> [AttributedString] {
        raw.split(separator: "\n\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { para in
                (try? AttributedString(
                    markdown: para,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(para)
            }
    }

    // MARK: - 来源 chips

    private var derivedChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DERIVED FROM EVENTS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 5) {
                ForEach(derivedRefs) { ref in
                    if ref.exists {
                        Button { onJumpToEvent(ref.id) } label: {
                            chipLabel(date: ref.date,
                                      text: ref.title.isEmpty ? ref.id : ref.title)
                        }
                        .buttonStyle(.plain)
                        .help(ref.id)
                    } else {
                        Text(ref.date.isEmpty ? ref.id : "\(ref.date)  \(ref.id)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var wrChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DERIVED FROM WRITING RECORDS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 5) {
                ForEach(wrIds, id: \.self) { id in
                    Button {
                        NotificationCenter.default.post(name: .memoryJumpToInputRecord,
                                                        object: id)
                    } label: {
                        chipLabel(date: "", text: "#\(id)")
                    }
                    .buttonStyle(.plain)
                    .help("wr:\(id)")
                }
            }
        }
    }

    private func chipLabel(date: String, text: String) -> some View {
        HStack(spacing: 4) {
            if !date.isEmpty {
                Text(date)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent.opacity(0.75))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.8))
        )
    }

    // MARK: - 加载

    @MainActor
    private func load() async {
        guard let url = node.fileURL else { return }
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let loaded = await Task.detached(priority: .userInitiated) {
            () -> (PortraitFile, Double, [AttributedString], [AttributedString],
                   [MemoriesView.DerivedRef], [Int64])? in
            guard let f = try? PortraitFileIO.read(from: url) else { return nil }
            let w = WeightEMA(halfLifeDays: halfLife)
                .currentWeight(stored: f.weight, daysSinceModified: f.daysSinceModified())
            // writing_style 记录来源 → wr chips;其它 → event chips(同 text 模式)。
            let wr = MemoriesView.splitWritingRecords(f.body)
            if !wr.wrIds.isEmpty {
                return (f, w, Self.parseBlocks(wr.before), [], [], wr.wrIds)
            }
            let parsed = MemoriesView.splitDerivedSections(f.body)
            let refs = parsed.eventRels.map { MemoriesView.resolveDerivedRef($0) }
            return (f, w, Self.parseBlocks(parsed.before),
                    Self.parseBlocks(parsed.after), refs, [])
        }.value
        guard let loaded, node.fileURL == url else { return }
        (file, currentWeight, proseBlocks, afterBlocks, derivedRefs, wrIds) =
            (loaded.0, loaded.1, loaded.2, loaded.3, loaded.4, loaded.5)
    }
}
