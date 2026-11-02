import GraphPhysics
import SwiftUI

/// Data 页(圆形版,11-01 update):不要侧栏,中间是图谱,四角放东西。
///   左上  Portrait / Events / Input 切换 + Settings(原地展开)
///   左下  最近更新的条目
///   右上  搜索框 + 阅读视图 / 时间线按钮,下面一张卡片:
///         Profile(没选东西)/ 组的全部条目(选了组球)/ 全文(选了小球)/ 搜索结果
///   右下  本周新增 + 近 14 天柱子 + 热门标签,最底下节点数
/// 阅读视图(原 Text 模式):右上卡片往左铺开盖住圆,三栏 = 组 | 条目 | 正文。
/// Input 没有图谱,中间换成打字活动图。
struct DataPage: View {
    @Binding var selection: SidebarSection?
    @Binding var scope: DataScope
    @Binding var inputJump: Int64?

    @Environment(\.colorScheme) private var scheme
    @State private var config = ConfigStore.shared

    @State private var graphSel: GraphSelection = .none
    @State private var focus: GraphFocusRequest? = nil
    @State private var timelineOn = false
    @State private var reloadToken = 0
    @State private var query = ""
    @State private var reader = false
    @State private var readerFolder: String? = nil
    @State private var settingsOpen = false
    @State private var profileEditing = false
    @State private var profileDraft = PersonalInfoConfig()
    @State private var newLanguage = ""
    /// 编辑 Profile 时内容的实际高度:卡片正好长到 Cancel / Save 那一行。
    @State private var editorH: CGFloat = 0
    @State private var scene: GraphScene = .empty
    @State private var digest = DataDigest.empty
    @State private var counts = DataCounts()
    /// 时间线停在的那天(nil = 今天):最近 / 本周都按它算。
    @State private var refDay: Date? = nil
    @State private var photo: NSImage? = nil

    private var pal: RingPalette { RingPalette(dark: scheme == .dark) }

    private enum Zone { case portrait, events, input }
    private var zone: Zone {
        switch scope {
        case .input:     return .input
        case .portrait:  return .portrait
        default:         return .events
        }
    }

    // 版式:两侧列宽固定、字号整体缩一档;图谱铺满整窗、只在中间的圆里显示,
    // 四个角贴着窗口的四个角放,左右中段留空给圆
    private let sideW: CGFloat = 288
    private let leftX: CGFloat = 22
    private let rightPad: CGFloat = 22
    /// 左上导航的顶边(页面切换条下面)。
    private let topY: CGFloat = 54
    /// 右上搜索那一行的顶边(Reload 按钮下面)。
    private let rightTopY: CGFloat = 60
    /// 四角面板字号缩放(让出空间给中间的图谱)。
    private func fs(_ size: CGFloat) -> CGFloat { size * 0.86 }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let centerL = leftX + sideW + 8
            ZStack(alignment: .topLeading) {
                backdrop(W: W, H: H)

                // 中间:图谱(整窗,圆形遮罩)/ 打字活动
                if zone != .input {
                    GraphRootView(scope: $scope,
                                  timelineOn: $timelineOn,
                                  selection: $graphSel,
                                  focusRequest: $focus,
                                  searchQuery: query,
                                  reloadToken: reloadToken,
                                  onSceneChange: { s in scene = s; recomputeDigest() },
                                  onDayChange: { d in refDay = d; recomputeDigest() })
                        .frame(width: W, height: H)
                        .opacity(reader ? 0.07 : 1)
                        .allowsHitTesting(!reader)
                        .animation(.easeOut(duration: 0.3), value: reader)
                }

                if zone != .input {
                    reloadButton.offset(x: W - rightPad - 40, y: 12)
                }

                // 左上:切换 + Settings
                navPanel
                    .frame(width: sideW, alignment: .topLeading)
                    .offset(x: leftX, y: topY)
                    .zIndex(2)

                if zone == .input {
                    DataInputPage(size: CGSize(width: W, height: H), sideW: sideW, leftX: leftX,
                                  rightPad: rightPad, listTop: recentTop(H), rightTopY: rightTopY,
                                  pal: pal, fs: fs)
                } else {
                    // 左下:最近
                    recentPanel
                        .frame(width: sideW, height: max(160, H - 24 - recentTop(H)))
                        .offset(x: leftX, y: recentTop(H))

                    // 右下:本周(贴底)
                    weekPanel
                        .frame(width: sideW, height: weekH)
                        .offset(x: W - rightPad - sideW, y: H - 22 - weekH)
                        .opacity(reader ? 0 : 1)

                    // 右上:搜索 + 卡片(阅读视图时往左铺开)
                    let rx = reader ? centerL + 6 : W - rightPad - sideW
                    rightTop(H: H)
                        .frame(width: W - rightPad - rx, height: rightTopH(H))
                        .offset(x: rx, y: rightTopY)
                        .animation(.spring(duration: 0.42, bounce: 0.1), value: reader)
                        .animation(.spring(duration: 0.32, bounce: 0.1), value: profileEditing)
                }
            }
            .frame(width: W, height: H, alignment: .topLeading)
        }
        // 和 Timeline 一样铺满整窗(含标题栏那一条),坐标从窗口左上角算
        .ignoresSafeArea()
        .task { loadPhoto() }
        .onReceive(NotificationCenter.default.publisher(for: .mainBallPhotoChanged)) { _ in loadPhoto() }
        .onAppear {
            // 侧栏时代存下的 scope 可能是 Personal Info / 设置页 → 回到 Events
            switch scope {
            case .events, .portrait, .input: break
            default: scope = .events
            }
            reloadCounts()
        }
        .onChange(of: graphSel) { _, s in
            if s != .none { profileEditing = false }
            if case .hub(let i) = s, i < scene.nodes.count, case .folder(let slug) = scene.nodes[i].kind {
                readerFolder = slug
            }
        }
        .onChange(of: zone) { _, _ in
            graphSel = .none; query = ""; reader = false; readerFolder = nil; timelineOn = false
        }
    }

    // MARK: - 版式辅助

    /// 左下「最近」的顶边:贴下半边;左上展开设置时再往下让。
    private func recentTop(_ H: CGFloat) -> CGFloat {
        settingsOpen ? max(H * 0.56, topY + 430) : H * 0.56
    }
    /// 右上卡片的底边。
    private func cardBottom(_ H: CGFloat) -> CGFloat { H * 0.5 }
    /// 右上(搜索行 + 卡片)的高度:阅读视图拉满;编辑 Profile 时长到装下内容为止,
    /// 最多到「本周」上沿。
    private func rightTopH(_ H: CGFloat) -> CGFloat {
        if reader { return H - rightTopY - 22 }
        let normal = cardBottom(H) - rightTopY
        guard profileEditing, editorH > 0 else { return normal }
        let maxH = H - 22 - weekH - 12 - rightTopY
        return min(maxH, max(normal, editorH + 44))
    }
    /// 右下「本周」的高度(贴窗口底边)。
    private let weekH: CGFloat = 250

    private func backdrop(W: CGFloat, H: CGFloat) -> some View {
        ZStack {
            SidebarBackdrop()
            RadialGradient(colors: [pal.glow, .clear],
                           center: UnitPoint(x: 0.5, y: 0.5),
                           startRadius: 0, endRadius: 434)
                .allowsHitTesting(false)
        }
        .frame(width: W, height: H)
    }

    private var reloadButton: some View {
        roundButton("arrow.clockwise", on: false, size: 40, help: "Reload from disk") {
            reloadToken += 1
            reloadCounts()
        }
    }

    private func roundButton(_ symbol: String, on: Bool, size: CGFloat = 34, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(on ? pal.accent : pal.muted)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? pal.accentbg : pal.pill))
                .overlay(Circle().stroke(on ? pal.accentb : pal.pillb, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func sectionTitle(_ t: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(t).font(.system(size: fs(12), weight: .semibold)).kerning(0.96)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.system(size: fs(12), design: .monospaced)) }
        }
        .foregroundStyle(pal.faint)
        .padding(.horizontal, 4)
        .padding(.bottom, 7)
    }

    // MARK: - 左上:切换 + Settings

    private var navPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("DATA")
            navRow(.portrait, "Portrait", "person", "\(counts.portraitNotes) notes · \(counts.portraitCategories) categories",
                   on: zone == .portrait) { switchTo(.portrait) }
            navRow(.events, "Events", "point.3.connected.trianglepath.dotted",
                   "\(counts.events.formatted()) events · \(counts.folders) groups",
                   on: zone == .events) { switchTo(.events) }
            navRow(.input, "Input", "keyboard", "Typing activity by day", on: zone == .input) { switchTo(.input) }
            Rectangle().fill(pal.rowb).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 6)
            navRow(nil, "Settings", "slider.horizontal.3", "Graph animation and links",
                   on: false, open: settingsOpen) {
                withAnimation(.spring(duration: 0.32, bounce: 0.1)) { settingsOpen.toggle() }
            }
            if settingsOpen { settingsBox.transition(.opacity) }
        }
    }

    private func switchTo(_ z: Zone) {
        switch z {
        case .events:   scope = .events
        case .input:    scope = .input
        case .portrait:
            if case .portrait = scope { return }
            scope = .portrait(category: PortraitPaths.seedCategories[0])
        }
    }

    private func navRow(_ z: Zone?, _ name: String, _ symbol: String, _ sub: String,
                        on: Bool, open: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: fs(15), weight: .medium))
                    .foregroundStyle(on ? Color.white : pal.muted)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(on ? pal.accent : pal.pill))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: fs(15.5), weight: .semibold)).foregroundStyle(pal.fg)
                    Text(sub).font(.system(size: fs(12), design: .monospaced)).foregroundStyle(pal.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: fs(11), weight: .semibold))
                    .foregroundStyle(pal.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16).fill(on ? pal.accentbg : .clear))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? pal.accentb : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// 原 Neural Graph 设置(主球照片在 Profile,排序在阅读视图列表头)。
    private var settingsBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GRAPH").font(.system(size: fs(10.5), weight: .semibold)).kerning(0.7)
                .foregroundStyle(pal.faint).padding(.top, 6).padding(.bottom, 2)
            settingRow("Animation") {
                Picker("", selection: config.binding(\.display.graphAnimationSpeed)) {
                    ForEach(SpeedLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            settingRow("Pulse") {
                Picker("", selection: config.binding(\.display.graphPulseSpeed)) {
                    ForEach(SpeedLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            settingRow("Show links") {
                Toggle("", isOn: Binding(
                    get: { !config.current.display.graphHideLinks },
                    set: { v in config.mutate { $0.display.graphHideLinks = !v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(.leading, 52).padding(.trailing, 10)
    }

    private func settingRow<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: fs(13.5))).foregroundStyle(pal.fg)
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(pal.rowb).frame(height: 1) }
    }

    // MARK: - 左下:最近

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(zone == .events ? "RECENT" : "RECENTLY UPDATED",
                         trailing: refDay.map { "until \(DataDigest.md($0))" })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(digest.recent) { it in
                        Button { focus = GraphFocusRequest(target: .node(it.id)) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 7) {
                                    Text(DataDigest.md(it.date))
                                        .font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
                                    Circle().fill(it.color).frame(width: 8, height: 8)
                                    Text(it.hub).font(.system(size: fs(12.5), weight: .semibold))
                                        .foregroundStyle(pal.muted).lineLimit(1)
                                }
                                Text(it.title).font(.system(size: fs(14))).foregroundStyle(pal.fg)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 14)
                                .fill(isSelected(it.id) ? pal.accentbg : pal.row))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected(it.id) ? pal.accentb : .clear, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.86),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }

    private func isSelected(_ id: Int) -> Bool {
        if case .leaf(let i) = graphSel { return i == id }
        return false
    }

    // MARK: - 右下:本周

    private var weekPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(refDay.map { "WEEK OF \(DataDigest.md($0).uppercased())" } ?? "THIS WEEK")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("+\(digest.week)").font(.system(size: fs(30), weight: .bold))
                    .foregroundStyle(pal.fg)
                let d = digest.week - digest.prevWeek
                Text("new \(zone == .events ? "events" : "notes") · \(d >= 0 ? "▲" : "▼") \(abs(d)) vs last week")
                    .font(.system(size: fs(13))).foregroundStyle(pal.muted)
            }
            .padding(.horizontal, 4)
            spark.padding(.horizontal, 4).padding(.top, 8)
            if !digest.tags.isEmpty {
                Text("TOP TAGS").font(.system(size: fs(11), weight: .semibold)).kerning(0.77)
                    .foregroundStyle(pal.faint).padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 5)
                FlowChips(items: digest.tags.map { "\($0.0)  \($0.1)" }, pal: pal)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Text("\(scene.nodes.count.formatted()) nodes · \(scene.edges.count.formatted()) links")
                    .font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
            }
        }
    }

    private var spark: some View {
        let mx = max(1, digest.days.max() ?? 1)
        return VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(digest.days.enumerated()), id: \.offset) { i, n in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(pal.accent.opacity(i < 7 ? 0.25 : 0.85))
                        .frame(height: max(2, 46 * CGFloat(n) / CGFloat(mx)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 46, alignment: .bottom)
            HStack {
                let ref = refDay ?? Date()
                Text(DataDigest.md(ref.addingTimeInterval(-13 * 86400)))
                Spacer()
                Text(DataDigest.md(ref))
            }
            .font(.system(size: fs(11), design: .monospaced)).foregroundStyle(pal.faint)
        }
    }

    // MARK: - 右上:搜索 + 卡片

    private func rightTop(H: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: fs(13))).foregroundStyle(pal.faint)
                    TextField(zone == .events ? "Search events" : "Search portrait", text: $query)
                        .textFieldStyle(.plain).font(.system(size: fs(14)))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(pal.faint)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(Capsule().fill(pal.pill))
                .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
                roundButton("list.bullet", on: reader, help: "Reader — read and edit as a list") {
                    reader.toggle()
                    if reader { profileEditing = false }
                }
                if zone == .events {
                    roundButton("clock.arrow.circlepath", on: timelineOn,
                                help: "Timeline — watch the graph change day by day") {
                        timelineOn.toggle()
                    }
                }
            }
            Group {
                if reader { readerCard } else { detailCard }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(reader ? pal.seg.opacity(scheme == .dark ? 0.35 : 0.9) : pal.row))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(pal.rowb, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var detailCard: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            searchCard(q)
        } else {
            switch graphSel {
            case .leaf(let i) where i < scene.nodes.count:
                GraphFloatWindow(node: scene.nodes[i], loadWhenVisible: true,
                                 onClose: { focus = GraphFocusRequest(target: .overview) },
                                 onJumpToEvent: { rel in focus = GraphFocusRequest(target: .eventRel(rel)) })
                    .id(i)
            case .hub(let i) where i < scene.nodes.count:
                hubCard(i)
            default:
                if profileEditing { profileEditor } else { profileCard }
            }
        }
    }

    private func cardHeader(_ crumb: String) -> some View {
        Text(crumb).font(.system(size: fs(11), weight: .semibold, design: .monospaced))
            .foregroundStyle(pal.faint)
    }

    private func searchCard(_ q: String) -> some View {
        let hits = scene.nodes.filter { !$0.kind.isHub && $0.title.localizedCaseInsensitiveContains(q) }
        return VStack(alignment: .leading, spacing: 4) {
            cardHeader("SEARCH")
            Text("\(hits.count) result\(hits.count == 1 ? "" : "s")")
                .font(.system(size: fs(18), weight: .semibold)).foregroundStyle(pal.fg)
            Text("matching balls stay lit in the graph")
                .font(.system(size: fs(12), design: .monospaced)).foregroundStyle(pal.muted)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits.prefix(200)) { n in
                        listRow(id: n.id, title: n.title, color: hubColor(n), trailing: dateText(n),
                                clearsSearch: true)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
    }

    private func hubCard(_ i: Int) -> some View {
        let hub = scene.nodes[i]
        let leaves = scene.nodes.filter { $0.hubIndex == i && !$0.kind.isHub }
            .sorted { $0.radius > $1.radius }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                cardHeader(zone == .events ? "GROUP" : "CATEGORY")
                Spacer()
                Button { reader = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: fs(12)))
                }
                .buttonStyle(.bouncyIcon).help("Open in reader")
            }
            HStack(spacing: 9) {
                Circle().fill(hub.color).frame(width: 12, height: 12)
                Text(hub.title).font(.system(size: fs(18), weight: .semibold)).foregroundStyle(pal.fg)
            }
            Text("\(leaves.count) \(zone == .events ? "events" : "notes")")
                .font(.system(size: fs(12.5), design: .monospaced)).foregroundStyle(pal.muted)
                .padding(.bottom, 6)
            Text("BY WEIGHT").font(.system(size: fs(11), weight: .semibold)).kerning(0.77)
                .foregroundStyle(pal.faint)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(leaves) { n in
                        listRow(id: n.id, title: n.title, color: hub.color, trailing: dateText(n))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
    }

    private func listRow(id: Int, title: String, color: Color, trailing: String,
                         clearsSearch: Bool = false) -> some View {
        Button {
            // 点搜索结果:收起搜索,卡片直接显示这一条
            if clearsSearch { query = "" }
            focus = GraphFocusRequest(target: .node(id))
        } label: {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: fs(14))).foregroundStyle(pal.fg).lineLimit(1)
                Spacer(minLength: 6)
                Text(trailing).font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hubColor(_ n: GraphNode) -> Color {
        n.hubIndex >= 0 && n.hubIndex < scene.nodes.count ? scene.nodes[n.hubIndex].color : n.color
    }

    private func dateText(_ n: GraphNode) -> String {
        if case .eventLeaf(let rel) = n.kind, let d = DataDigest.date(fromRel: rel) { return DataDigest.md(d) }
        return ""
    }

    // MARK: Profile

    private var info: PersonalInfoConfig { config.current.personalInfo }

    private var profileCard: some View {
        let name = [info.firstName, info.middleName, info.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        let sub = [info.alias.isEmpty ? nil : "Also goes by \(info.alias)",
                   info.gender == .unset ? nil : info.gender.displayName].compactMap { $0 }.joined(separator: " · ")
        let rows: [(String, String)] = [("Nationality", info.nationality), ("Ethnicity", info.ethnicity),
                                        ("Date of birth", info.birthDate)].filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                cardHeader("PROFILE")
                Spacer()
                Button {
                    profileDraft = info
                    withAnimation { profileEditing = true }
                } label: { Image(systemName: "pencil").font(.system(size: fs(13))) }
                    .buttonStyle(.bouncyIcon).help("Edit profile")
            }
            HStack(spacing: 12) {
                avatar(name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "You" : name).font(.system(size: fs(18), weight: .semibold)).foregroundStyle(pal.fg)
                    if !sub.isEmpty { Text(sub).font(.system(size: fs(13))).foregroundStyle(pal.muted) }
                }
            }
            .padding(.top, 6)
            Text("\(counts.events.formatted()) events   \(counts.portraitNotes) portrait notes")
                .font(.system(size: fs(12.5), design: .monospaced)).foregroundStyle(pal.muted)
                .padding(.vertical, 10)
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).foregroundStyle(pal.muted)
                    Spacer()
                    Text(r.1).foregroundStyle(pal.fg)
                }
                .font(.system(size: fs(14))).padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(pal.rowb).frame(height: 1) }
            }
            if !info.languages.isEmpty {
                Text("LANGUAGES").font(.system(size: fs(11), weight: .semibold)).kerning(0.77)
                    .foregroundStyle(pal.faint).padding(.top, 14).padding(.bottom, 5)
                FlowChips(items: info.languages, pal: pal)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private func avatar(_ name: String) -> some View {
        if let photo {
            Image(nsImage: photo).resizable().scaledToFill()
                .frame(width: 54, height: 54).clipShape(Circle())
        } else {
            initialsAvatar(name)
        }
    }

    /// 主球照片(和图谱中间那颗球同一张)。
    private func loadPhoto() {
        guard MainBallPhoto.exists else { photo = nil; return }
        let p = MainBallPhoto.url.path
        Task {
            photo = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: p) }.value
        }
    }

    private func initialsAvatar(_ name: String) -> some View {
        Text(String(name.first ?? "Y"))
            .font(.system(size: fs(22), weight: .semibold)).foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Circle().fill(RadialGradient(colors: [Color(red: 0.56, green: 0.71, blue: 1), Theme.accent],
                                                     center: UnitPoint(x: 0.35, y: 0.3),
                                                     startRadius: 0, endRadius: 40)))
    }

    private var profileEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                cardHeader("EDIT PROFILE")
                MainBallPhotoSlot().padding(.vertical, 2)
                editField("First name", \.firstName, "First name")
                editField("Middle name", \.middleName, "Optional")
                editField("Last name", \.lastName, "Last name")
                editField("Also goes by", \.alias, "Nickname")
                HStack {
                    Text("Pronouns").font(.system(size: fs(13.5))).foregroundStyle(pal.muted).frame(width: 104, alignment: .leading)
                    Picker("", selection: $profileDraft.gender) {
                        ForEach(PersonalInfoGender.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                editField("Nationality", \.nationality, "e.g. Chinese")
                editField("Ethnicity", \.ethnicity, "Optional")
                editField("Date of birth", \.birthDate, "YYYY-MM-DD")
                Text("LANGUAGES").font(.system(size: fs(11), weight: .semibold)).kerning(0.77)
                    .foregroundStyle(pal.faint).padding(.top, 8)
                HStack(spacing: 6) {
                    ForEach(Array(profileDraft.languages.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 4) {
                            Text(l)
                            Button { profileDraft.languages.remove(at: i) } label: {
                                Image(systemName: "xmark").font(.system(size: fs(9), weight: .bold))
                            }.buttonStyle(.plain)
                        }
                        .font(.system(size: fs(12.5))).foregroundStyle(pal.muted)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(pal.pill))
                    }
                }
                TextField("Add a language and press Return", text: $newLanguage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let l = newLanguage.trimmingCharacters(in: .whitespaces)
                        if !l.isEmpty, !profileDraft.languages.contains(l) { profileDraft.languages.append(l) }
                        newLanguage = ""
                    }
                HStack {
                    Spacer()
                    Button("Cancel") { withAnimation { profileEditing = false } }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let d = profileDraft
                        config.mutate { $0.personalInfo = d }
                        withAnimation { profileEditing = false }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 10)
            }
            .padding(16)
            .background(GeometryReader { g in
                Color.clear.preference(key: EditorHeightKey.self, value: g.size.height)
            })
        }
        .scrollIndicators(.never)
        .onPreferenceChange(EditorHeightKey.self) { editorH = $0 }
    }

    private func editField(_ label: String, _ kp: WritableKeyPath<PersonalInfoConfig, String>,
                           _ placeholder: String) -> some View {
        HStack {
            Text(label).font(.system(size: fs(13.5))).foregroundStyle(pal.muted).frame(width: 104, alignment: .leading)
            TextField(placeholder, text: Binding(get: { profileDraft[keyPath: kp] },
                                                 set: { profileDraft[keyPath: kp] = $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    // MARK: - 阅读视图:组 | 条目 | 正文

    private var readerCard: some View {
        HStack(spacing: 0) {
            groupColumn
                .frame(width: 210)
            Rectangle().fill(pal.rowb).frame(width: 1)
            DataView(scope: $scope,
                     externalInputJump: $inputJump,
                     folderFilter: zone == .events ? readerFolder : nil,
                     searchOverride: query,
                     topInset: 14)
            .overlay(alignment: .topTrailing) {
                Button { reader = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: fs(12)))
                }
                .buttonStyle(.bouncyIcon).help("Back to graph").padding(10)
            }
        }
    }

    private var groupColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(zone == .events ? "GROUPS" : "CATEGORIES")
                .font(.system(size: fs(11), weight: .semibold)).kerning(0.77).foregroundStyle(pal.faint)
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if zone == .events {
                        groupRow("All events", color: pal.faint, count: digest.leafCount,
                                 on: readerFolder == nil) { readerFolder = nil }
                        ForEach(digest.hubs, id: \.key) { h in
                            groupRow(h.title, color: h.color, count: h.count, on: readerFolder == h.key) {
                                readerFolder = h.key
                            }
                        }
                    } else {
                        ForEach(digest.hubs, id: \.key) { h in
                            let on: Bool = { if case .portrait(let c) = scope { return c == h.key }; return false }()
                            groupRow(h.title, color: h.color, count: h.count, on: on) {
                                scope = .portrait(category: h.key)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
        }
    }

    private func groupRow(_ title: String, color: Color, count: Int, on: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).font(.system(size: fs(14))).foregroundStyle(pal.fg).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? pal.accentbg : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? pal.accentb : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private func recomputeDigest() {
        let input = DataDigest.Input(scene: scene, refDay: refDay)
        Task {
            let d = await Task.detached(priority: .userInitiated) { DataDigest.build(input) }.value
            digest = d
        }
    }

    private func reloadCounts() {
        Task {
            counts = await Task.detached(priority: .utility) { DataCounts.scan() }.value
        }
    }
}

// MARK: - 角落里的数据

/// 场景派生出来的角落数据:最近、本周柱子、热门标签、组列表。后台线程算。
struct DataDigest: Sendable {
    struct Item: Identifiable, Sendable {
        let id: Int
        let title: String
        let date: Date
        let hub: String
        let rgb: SIMD3<Double>
        var color: Color { Color(red: rgb.x, green: rgb.y, blue: rgb.z) }
    }
    struct Hub: Sendable {
        let key: String
        let title: String
        let rgb: SIMD3<Double>
        let count: Int
        var color: Color { Color(red: rgb.x, green: rgb.y, blue: rgb.z) }
    }
    var recent: [Item] = []
    var days: [Int] = Array(repeating: 0, count: 14)
    var week = 0
    var prevWeek = 0
    var tags: [(String, Int)] = []
    var hubs: [Hub] = []
    var leafCount = 0

    static let empty = DataDigest()

    struct Input: Sendable {
        let nodes: [GraphNode]
        let refDay: Date?
        init(scene: GraphScene, refDay: Date?) { nodes = scene.nodes; self.refDay = refDay }
    }

    static func build(_ input: Input) -> DataDigest {
        let nodes = input.nodes
        var d = DataDigest()
        let cal = Calendar.current
        let today = cal.startOfDay(for: input.refDay ?? Date())
        var items: [(Item, URL?)] = []
        var hubCount: [Int: Int] = [:]
        for n in nodes where !n.kind.isHub {
            hubCount[n.hubIndex, default: 0] += 1
            let hub = n.hubIndex >= 0 && n.hubIndex < nodes.count ? nodes[n.hubIndex] : nil
            var date: Date? = nil
            if case .eventLeaf(let rel) = n.kind { date = Self.date(fromRel: rel) }
            else if let u = n.fileURL {
                // portrait 笔记按 frontmatter 的 last_modified(没有再 created)算;
                // 文件修改时间会被批量迁移刷成同一天,不能用
                date = Self.noteDate(of: u)
            }
            guard let date else { continue }
            items.append((Item(id: n.id, title: n.title, date: date, hub: hub?.title ?? "",
                               rgb: hub?.colorRGB ?? n.colorRGB), n.fileURL))
        }
        d.leafCount = items.count
        items.sort { $0.0.date > $1.0.date }
        d.recent = items.prefix(40).map { $0.0 }
        var tagCount: [String: Int] = [:]
        for (it, url) in items {
            let ago = cal.dateComponents([.day], from: cal.startOfDay(for: it.date), to: today).day ?? 999
            if ago >= 0 && ago < 14 { d.days[13 - ago] += 1 }
            if ago >= 0 && ago < 7 {
                d.week += 1
                if let url { for t in Self.tags(of: url) { tagCount[t, default: 0] += 1 } }
            } else if ago >= 7 && ago < 14 { d.prevWeek += 1 }
        }
        d.tags = tagCount.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
        for (i, n) in nodes.enumerated() {
            switch n.kind {
            case .folder(let slug):
                d.hubs.append(Hub(key: slug, title: n.title, rgb: n.colorRGB, count: hubCount[i] ?? 0))
            case .category(let name):
                d.hubs.append(Hub(key: name, title: n.title, rgb: n.colorRGB, count: hubCount[i] ?? 0))
            default: break
            }
        }
        d.hubs.sort { $0.count > $1.count }
        return d
    }

    /// "yyyy-MM-dd/xxx.md" → 那天。
    static func date(fromRel rel: String) -> Date? {
        dayFmt.date(from: String(rel.prefix(10)))
    }

    /// 文件头(frontmatter 在最前面,不读整篇)。
    private static func head(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 8192) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// portrait 笔记的更新日:frontmatter `last_modified`,没有就 `created`。
    static func noteDate(of url: URL) -> Date? {
        guard let s = head(url) else { return nil }
        var created: Date? = nil
        for line in s.split(separator: "\n") {
            if line.hasPrefix("last_modified:"), let d = dayFmt.date(from: String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces).prefix(10).description) { return d }
            if line.hasPrefix("created:") { created = dayFmt.date(from: String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces).prefix(10).description) }
        }
        return created
    }

    /// frontmatter 里的 `tags: [a, b]`(只读文件头,不解析整篇)。
    static func tags(of url: URL) -> [String] {
        guard let s = head(url) else { return [] }
        for line in s.split(separator: "\n") where line.hasPrefix("tags:") {
            let body = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            return body.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                .filter { !$0.isEmpty && $0 != "portrait" }
        }
        return []
    }

    static func md(_ d: Date) -> String { mdFmt.string(from: d) }

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    nonisolated(unsafe) private static let mdFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}

/// 左上导航的计数:读目录数文件,不解析内容。
struct DataCounts: Sendable {
    var events = 0
    var folders = 0
    var portraitNotes = 0
    var portraitCategories = 0

    static func scan() -> DataCounts {
        var c = DataCounts()
        let fm = FileManager.default
        if let e = fm.enumerator(at: Storage.uiEventsDir, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "md" { c.events += 1 }
        }
        let folderDir = Storage.uiEventsDir.appendingPathComponent("_folders")
        c.folders = ((try? fm.contentsOfDirectory(atPath: folderDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }.count
        for cat in PortraitPaths.seedCategories {
            let dir = Storage.uiPortraitDir.appendingPathComponent(cat)
            let n = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.count
            if n > 0 { c.portraitCategories += 1; c.portraitNotes += n }
        }
        return c
    }
}

/// 会换行的小胶囊(标签、语言)。
private struct FlowChips: View {
    let items: [String]
    let pal: RingPalette

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.system(size: 11)).foregroundStyle(pal.muted)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(pal.pill))
            }
        }
    }
}

private struct EditorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
