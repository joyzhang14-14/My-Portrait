import AppKit
import SwiftUI

/// Data 页阅读视图(11-01 update):右上卡片铺开后的三栏 = 组 | 条目 | 正文。
/// events 的组 = `_folders/` 里的 folder + Unclassified;portrait 的组 = 分类。
/// 读盘、排序都走 DataView 的 scan / sortedByConfig,口径与图谱浮窗一致。
/// 写盘后只调 onChanged(DataPage bump reloadToken),列表跟着 reloadToken 重读。
struct DataReaderView: View {
    typealias Entry = DataView.Entry

    let isEvents: Bool
    @Binding var scope: DataScope
    /// 选中的组:events = folder slug(含 unclassifiedSlug),portrait = 分类名;nil = All。
    @Binding var group: String?
    /// 外面要选中的条目(图谱 / 左下最近 / 跨区跳转),选中后清空。
    @Binding var focus: URL?
    @Binding var inputJump: Int64?
    let query: String
    let reloadToken: Int
    /// 图谱 hub 的颜色 / 名字(key 同 group),跟圆里的球对得上。
    let hubColors: [String: Color]
    let hubTitles: [String: String]
    let onClose: () -> Void
    let onChanged: () -> Void
    let onJump: (DataScope, URL) -> Void

    struct ReaderGroup: Identifiable, Sendable {
        let key: String
        let title: String
        let colorHex: String?
        let desc: String
        let isFolder: Bool
        var id: String { key }
    }

    @Environment(\.colorScheme) private var scheme
    @State private var config = ConfigStore.shared
    @State private var entries: [Entry] = []
    @State private var groupOf: [URL: String] = [:]
    @State private var groups: [ReaderGroup] = []
    @State private var loading = true
    @State private var gen = 0
    @State private var selected: URL?
    @State private var derived: [DataView.DerivedRef] = []
    @State private var showDetails = false
    @State private var showHistory = false
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftTags: [TagCapsuleEditor.Item] = []
    @State private var draftImpact: Double = 0
    @State private var editError: String?
    @State private var confirmDelete = false
    @State private var newGroupSheet = false
    @State private var newGroupName = ""
    @State private var newGroupHex: String? = nil
    /// 非 nil = 新组建好后把这条 event 移进去。
    @State private var newGroupFor: URL? = nil
    @State private var renaming: ReaderGroup? = nil
    @State private var renameDraft = ""
    @State private var deletingGroup: ReaderGroup? = nil
    @State private var colorTask: Task<Void, Never>? = nil
    @State private var errorText: String? = nil

    private var pal: RingPalette { RingPalette(dark: scheme == .dark) }
    private var unit: String { isEvents ? "events" : "notes" }
    private var q: String { query.trimmingCharacters(in: .whitespaces) }
    private var order: MemorySortOrder {
        MemorySortOrder(rawValue: config.current.display.memorySortOrder) ?? .weight
    }

    private func matches(_ e: Entry) -> Bool { q.isEmpty || e.title.localizedCaseInsensitiveContains(q) }
    private var visible: [Entry] {
        entries.filter { matches($0) && (group == nil || groupOf[$0.id] == group) }
    }
    private func info(_ key: String?) -> ReaderGroup? { groups.first { $0.key == key } }
    private func color(_ key: String?) -> Color {
        guard let key else { return pal.faint }
        if let c = hubColors[key] { return c }
        let g = info(key)
        return g?.colorHex.flatMap { FolderPalette.color(fromHex: $0) }
            ?? FolderPalette.defaultTint(for: g?.title ?? key)
    }
    private var current: Entry? { selected.flatMap { s in entries.first { $0.id == s } } }

    var body: some View {
        HStack(spacing: 0) {
            groupsColumn.frame(width: 210)
            divider
            itemsColumn.frame(minWidth: 250, idealWidth: 340, maxWidth: 340)
            divider
            articleColumn.frame(minWidth: 320, maxWidth: .infinity)
        }
        .task(id: isEvents) {
            selected = nil; editing = false
            await reload()
        }
        .onChange(of: reloadToken) { Task { await reload() } }
        .onChange(of: focus) { applyFocus(final: false) }
        .onChange(of: config.current.display.memorySortOrder) {
            entries = DataView.sortedByConfig(entries, order: order)
        }
        .onChange(of: group) {
            if let s = selected, !visible.contains(where: { $0.id == s }) { selected = nil }
        }
        .onChange(of: selected) {
            editing = false
            derived = []
        }
        .task(id: selected) { await loadDerived() }
        .sheet(isPresented: $newGroupSheet) {
            NewFolderSheet(name: $newGroupName, hex: $newGroupHex,
                           onCancel: { newGroupSheet = false; newGroupFor = nil },
                           onCreate: { createGroup() })
        }
        .alert("Rename group", isPresented: Binding(get: { renaming != nil },
                                                    set: { if !$0 { renaming = nil } })) {
            TextField("Group name", text: $renameDraft)
            Button("Save") {
                let n = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let g = renaming, !n.isEmpty, n != g.title {
                    run { try EventFolderStore.rename(slug: g.key, to: n) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete group “\(deletingGroup?.title ?? "")”?",
                            isPresented: Binding(get: { deletingGroup != nil },
                                                 set: { if !$0 { deletingGroup = nil } }),
                            titleVisibility: .visible) {
            Button("Delete group", role: .destructive) {
                if let g = deletingGroup {
                    if group == g.key { group = nil }
                    run { try EventFolderStore.delete(slug: g.key) }
                }
                deletingGroup = nil
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            Text("Removes the grouping only. The events inside are kept and move to Unclassified.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil },
                                                            set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var divider: some View { Rectangle().fill(pal.rowb).frame(width: 1) }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).kerning(0.77).foregroundStyle(pal.faint)
    }

    private func dot(_ c: Color, _ d: CGFloat) -> some View { Circle().fill(c).frame(width: d, height: d) }

    private func rowBG(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(on ? pal.accentbg : .clear)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? pal.accentb : .clear, lineWidth: 1))
    }

    private func toolButton(_ symbol: String, _ help: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint ?? pal.muted)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.bouncyIcon).help(help)
    }

    // MARK: - 组

    private var groupsColumn: some View {
        let counts = Dictionary(grouping: entries.filter(matches), by: { groupOf[$0.id] ?? "" })
            .mapValues(\.count)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel(isEvents ? "GROUPS" : "CATEGORIES")
                Spacer()
                if isEvents {
                    toolButton("plus", "New group") { newGroupFor = nil; newGroupSheet = true }
                }
            }
            .frame(height: 26)
            .padding(.leading, 14).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    groupRow(nil, "All \(unit)", count: counts.values.reduce(0, +))
                    ForEach(groups) { g in
                        if g.isFolder {
                            groupRow(g.key, g.title, count: counts[g.key] ?? 0)
                                .contextMenu { folderMenu(g) }
                        } else {
                            groupRow(g.key, g.title, count: counts[g.key] ?? 0)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
    }

    private func groupRow(_ key: String?, _ title: String, count: Int) -> some View {
        Button { selectGroup(key) } label: {
            HStack(spacing: 8) {
                dot(color(key), 9)
                Text(title).font(.system(size: 14)).foregroundStyle(pal.fg)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.faint)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(rowBG(group == key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func folderMenu(_ g: ReaderGroup) -> some View {
        Button("Rename…") { renameDraft = g.title; renaming = g }
        // NSColorPanel 拖动时连续回调,防抖 0.25s 再落盘
        Button("Change color…") { pickColor(g) }
        Divider()
        Button("Delete group", role: .destructive) { deletingGroup = g }
    }

    private func pickColor(_ g: ReaderGroup) {
        ColorPanelBridge.shared.present(initialHex: g.colorHex) { hex in
            colorTask?.cancel()
            colorTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { run { try EventFolderStore.setColor(slug: g.key, hex: hex) } }
            }
        }
    }

    private func selectGroup(_ key: String?) {
        group = key
        if !isEvents, let key { scope = .portrait(category: key) }
    }

    // MARK: - 条目

    private var itemsColumn: some View {
        let list = visible
        let g = info(group)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let g { dot(color(g.key), 11) }
                    Text(g?.title ?? (q.isEmpty ? "All \(unit)" : "Search"))
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(pal.fg).lineLimit(1)
                    Text("\(list.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.faint)
                }
                sortControl
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if loading && entries.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                Spacer()
            } else if list.isEmpty {
                Text(entries.isEmpty ? "No \(unit) yet."
                     : !q.isEmpty ? "No titles match." : "This group is empty.")
                    .font(.system(size: 13)).foregroundStyle(pal.faint)
                    .frame(maxWidth: .infinity).padding(.top, 30)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(list) { e in itemRow(e).id(e.id) }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 14)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selected) { _, s in
                        if let s { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(s) } }
                    }
                }
            }
        }
    }

    private var sortControl: some View {
        let sel = config.binding(\.display.memorySortOrder)
        let opts: [(MemorySortOrder, String)] = [(.weight, "Weight"), (.created, "Created"), (.lastOccurred, "Last seen")]
        return HStack(spacing: 0) {
            ForEach(opts, id: \.0) { o, label in
                let on = order == o
                Button { sel.wrappedValue = o.rawValue } label: {
                    Text(label).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? pal.fg : pal.muted)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .background(Capsule().fill(on ? pal.seg : .clear)
                            .shadow(color: .black.opacity(on ? 0.15 : 0), radius: 1, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(pal.pill))
        .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
    }

    private func itemRow(_ e: Entry) -> some View {
        Button { selected = e.id } label: {
            HStack(spacing: 10) {
                if group == nil { dot(color(groupOf[e.id]), 7) }
                Text(e.title).font(.system(size: 14)).foregroundStyle(pal.fg)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(trailing(e)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.faint)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(rowBG(selected == e.id))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func trailing(_ e: Entry) -> String {
        switch order {
        case .weight:       return String(format: "%.2f", e.currentWeight)
        case .created:      return Self.short.string(from: e.file.created)
        case .lastOccurred: return Self.short.string(from: e.file.lastOccurrence ?? e.file.created)
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private var articleColumn: some View {
        if let e = current {
            if editing { editPane(e) } else { article(e) }
        } else if let g = info(group) {
            groupOverview(g)
        } else {
            VStack(spacing: 0) {
                HStack { Spacer(); backButton }.padding(.top, 10).padding(.trailing, 12)
                Spacer()
                placeholder
                Spacer()
            }
        }
    }

    private var backButton: some View {
        toolButton("arrow.down.right.and.arrow.up.left", "Back to graph", action: onClose)
    }

    private var placeholder: some View {
        Text("Pick an item on the left to read it.")
            .font(.system(size: 13)).foregroundStyle(pal.faint).frame(maxWidth: .infinity)
    }

    private func crumb(_ key: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if key != nil { dot(color(key), 8) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(pal.faint).lineLimit(1)
        }
    }

    private func groupOverview(_ g: ReaderGroup) -> some View {
        let n = entries.filter { groupOf[$0.id] == g.key }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack { crumb(nil, isEvents ? "GROUP" : "CATEGORY"); Spacer(); backButton }
                HStack(spacing: 10) {
                    dot(color(g.key), 14)
                    Text(g.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(pal.fg)
                }
                Text("\(n) \(unit)").font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.muted)
                if !g.desc.isEmpty {
                    Text(g.desc).font(.system(size: 15)).foregroundStyle(pal.fg.opacity(0.92))
                        .lineSpacing(4).textSelection(.enabled).frame(maxWidth: 760, alignment: .leading)
                }
                if g.isFolder {
                    HStack(spacing: 6) {
                        chip("Rename…", link: true) { renameDraft = g.title; renaming = g }
                        chip("Change color…", link: true) { pickColor(g) }
                        chip("Delete group…", link: true, danger: true) { deletingGroup = g }
                    }
                    .padding(.top, 6)
                }
                placeholder.padding(.top, 40)
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func article(_ e: Entry) -> some View {
        let f = e.file
        let gk = groupOf[e.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 2) {
                    crumb(gk, info(gk)?.title ?? "")
                    Spacer(minLength: 8)
                    toolButton("square.and.pencil", "Edit") { beginEdit(e) }
                    if isEvents { moveMenu(e) }
                    toolButton("folder", "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([e.id])
                    }
                    if isEvents { toolButton("trash", "Delete", tint: .red.opacity(0.8)) { confirmDelete = true } }
                    Spacer().frame(width: 8)
                    backButton
                }
                Text(e.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(pal.fg)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
                metaRow(e)
                bodyBlock(f).padding(.top, 4)
                if !f.tags.isEmpty {
                    labeled("Tags") { ForEach(f.tags, id: \.self) { chip($0) } }
                }
                if !derived.isEmpty {
                    labeled("Derived from events") {
                        ForEach(derived) { r in
                            chip(r.title.isEmpty ? r.id : r.title, sub: r.date, link: r.exists) {
                                if r.exists {
                                    onJump(.events, URL(fileURLWithPath: Storage.uiEventsDir.path + "/" + r.id))
                                }
                            }
                        }
                    }
                }
                let wr = DataView.splitWritingRecords(f.body).wrIds
                if !wr.isEmpty {
                    labeled("Derived from writing records") {
                        ForEach(wr, id: \.self) { id in
                            chip("Record #\(id)", link: true) { inputJump = id; scope = .input }
                        }
                    }
                }
                fold("Details", on: $showDetails)
                if showDetails { details(e) }
                if let notes = f.editNotes, !notes.isEmpty, !isEvents {
                    fold("Edit history", count: notes.count, on: $showHistory)
                    if showHistory { history(notes) }
                }
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .confirmationDialog("Delete “\(e.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(e) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the event file from disk.")
        }
    }

    private func moveMenu(_ e: Entry) -> some View {
        let here = groupOf[e.id]
        return Menu {
            ForEach(groups.filter { $0.isFolder && $0.key != here }) { g in
                Button(g.title) {
                    let rel = Self.rel(e.id)
                    run { try EventFolderStore.assignEvent(rel, toSlug: g.key) }
                }
            }
            Divider()
            Button("New group…") { newGroupFor = e.id; newGroupSheet = true }
        } label: {
            Image(systemName: "folder.badge.plus").font(.system(size: 12)).foregroundStyle(pal.muted)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 26, height: 26).help("Move to group")
    }

    private func metaRow(_ e: Entry) -> some View {
        let f = e.file
        var parts: [(String, String)] = [("", Self.long.string(from: f.created))]
        if isEvents { parts.append(("impact", String(format: "%.1f", f.impact ?? 0))) }
        parts.append(("weight", String(format: "%.2f", e.currentWeight)))
        parts.append(("seen", "\(f.occurrences.count)×"))
        return HStack(spacing: 14) {
            ForEach(parts, id: \.0) { k, v in
                HStack(spacing: 4) {
                    if !k.isEmpty { Text(k).foregroundStyle(pal.faint) }
                    Text(v).foregroundStyle(pal.muted)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    @ViewBuilder
    private func bodyBlock(_ f: PortraitFile) -> some View {
        let wr = DataView.splitWritingRecords(f.body)
        if !wr.wrIds.isEmpty {
            markdown(wr.before)
        } else {
            let p = DataView.splitDerivedSections(f.body)
            markdown(p.before)
            if !p.after.isEmpty { markdown(p.after) }
        }
    }

    /// 逐段走 AttributedString(只解析行内标记);标题行已在上面单独显示,这里去掉。
    private func markdown(_ raw: String) -> some View {
        let text = PortraitFile.splitHeading(raw).rest
        let paras = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paras.enumerated()), id: \.offset) { _, para in
                Text((try? AttributedString(markdown: para,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(para))
                    .font(.system(size: 15)).lineSpacing(4)
                    .foregroundStyle(pal.fg.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.77)
                .foregroundStyle(pal.faint)
            FlowLayout(spacing: 6) { content() }
        }
        .padding(.top, 6)
    }

    private func chip(_ text: String, sub: String? = nil, link: Bool = false, danger: Bool = false,
                      action: (() -> Void)? = nil) -> some View {
        let fg: Color = danger ? .red : link ? pal.accent : pal.muted
        let bg: Color = danger ? Color.red.opacity(0.12) : link ? pal.accentbg : pal.pill
        let label = HStack(spacing: 5) {
            Text(text).lineLimit(1).truncationMode(.tail)
            if let sub, !sub.isEmpty {
                Text(sub).font(.system(size: 10.5, design: .monospaced)).opacity(0.7)
            }
        }
        .font(.system(size: 12)).foregroundStyle(fg)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(bg))
        .frame(maxWidth: 320, alignment: .leading)
        return Group {
            if let action {
                Button(action: action) { label }.buttonStyle(.plain).disabled(!link && !danger)
            } else {
                label
            }
        }
    }

    private func fold(_ title: String, count: Int? = nil, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: on.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.77)
                if let count { Text("\(count)").font(.system(size: 11, design: .monospaced)) }
            }
            .foregroundStyle(pal.faint).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.top, 10)
    }

    private func details(_ e: Entry) -> some View {
        let f = e.file
        var rows: [(String, String)] = [("type", f.eventType.isEmpty ? "experience" : f.eventType)]
        if !isEvents {
            rows.append(("portrait_facets", f.portraitFacets.isEmpty ? "—"
                         : f.portraitFacets.map { "\($0.facet):\($0.value)" }.joined(separator: ", ")))
            rows.append(("category", e.category.isEmpty ? "—" : e.category))
        }
        rows.append(("weight", String(format: "%.4g", e.currentWeight)))
        if isEvents {
            rows.append(("impact", String(format: "%.4g", f.impact ?? 0)))
            rows.append(("impact_source", f.impactSource ?? "—"))
        }
        rows += [("created", Self.day.string(from: f.created)),
                 ("last_occurred", f.lastOccurrence.map { Self.day.string(from: $0) } ?? "—"),
                 ("occurrences (days)", "\(f.occurrences.count)"),
                 ("member frames", "\(f.memberFrameIds.count)"),
                 ("tags", f.tags.isEmpty ? "—" : f.tags.joined(separator: ", "))]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { k, v in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(k).foregroundStyle(pal.faint).frame(width: 150, alignment: .leading)
                    Text(v).foregroundStyle(pal.muted).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func history(_ notes: [PortraitFile.EditNote]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notes.reversed().enumerated()), id: \.offset) { _, n in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.short.string(from: n.date)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(pal.muted)
                        Text(n.summary).font(.system(size: 13)).foregroundStyle(pal.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !n.request.isEmpty {
                        Text("Request: \(n.request)").font(.system(size: 12)).foregroundStyle(pal.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: 760, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(pal.rowb).frame(height: 1) }
            }
        }
    }

    // MARK: - 编辑

    private func editPane(_ e: Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    crumb(nil, "EDITING")
                    Spacer()
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Save") { save(e) }.keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                TextField("Title", text: $draftTitle, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(pal.pill))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.pillb, lineWidth: 1))
                editField("Tags") { TagCapsuleEditor(items: $draftTags) }
                if isEvents, e.file.impact != nil {
                    editField("Impact") {
                        HStack(spacing: 10) {
                            Slider(value: $draftImpact, in: PortraitFile.impactRange, step: 0.1)
                            Text(String(format: "%.1f", draftImpact))
                                .font(.system(size: 12, design: .monospaced)).frame(width: 30, alignment: .trailing)
                        }
                    }
                }
                TextEditor(text: $draftBody)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(pal.pill))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.pillb, lineWidth: 1))
                    .frame(minHeight: 320)
                if let editError {
                    Text(editError).font(.system(size: 12)).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 28)
        }
        .scrollIndicators(.never)
    }

    private func editField<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).font(.system(size: 12)).foregroundStyle(pal.faint).frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func beginEdit(_ e: Entry) {
        draftTitle = e.title
        draftBody = PortraitFile.splitHeading(e.file.body).rest
        draftTags = e.file.tags.map { TagCapsuleEditor.Item(text: $0) }
        draftImpact = e.file.impact ?? 0
        editError = nil
        editing = true
    }

    private func save(_ e: Entry) {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { editError = "Title can't be empty."; return }
        var seen = Set<String>()
        let tags = draftTags.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        do {
            // 重读盘上最新版再套用,别冲掉后台期间写进去的 weight / occurrences
            let cur = try PortraitFileIO.read(from: e.id)
            let updated = cur.applyingManualEdit(title: title, shownTitle: e.title, body: draftBody, tags: tags,
                                                 impact: e.file.impact == nil ? nil : draftImpact)
            try PortraitFileIO.write(updated, to: e.id)
            editing = false
            onChanged()
        } catch {
            editError = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - 动作

    /// 跑一个写盘动作,成功后通知外面重载;失败弹窗。
    private func run(_ op: () throws -> Void) {
        do { try op(); onChanged() } catch { errorText = error.localizedDescription }
    }

    private func delete(_ e: Entry) {
        let list = visible
        let next: URL? = list.firstIndex(where: { $0.id == e.id }).flatMap { i in
            i + 1 < list.count ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil)
        }
        run {
            try FileManager.default.removeItem(at: e.id)
            try? EventFolderStore.removeEventEverywhere(Self.rel(e.id))
            entries.removeAll { $0.id == e.id }
            selected = next
        }
    }

    /// 新建 folder(slug 冲突加 -2/-3);newGroupFor 非 nil 时顺手把那条 event 移进去。
    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let moving = newGroupFor
        newGroupSheet = false; newGroupName = ""; newGroupFor = nil
        let hex = newGroupHex; newGroupHex = nil
        guard !name.isEmpty else { return }
        var slug = EventFolderStore.makeSlug(from: name)
        if EventFolderStore.load(slug: slug) != nil {
            var n = 2
            while EventFolderStore.load(slug: "\(slug)-\(n)") != nil { n += 1 }
            slug = "\(slug)-\(n)"
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rels = moving.map { [Self.rel($0)] } ?? []
        run {
            for r in rels { try EventFolderStore.removeEventEverywhere(r) }
            let used = Set(EventFolderStore.loadAll().compactMap(\.colorHex))
            try EventFolderStore.save(EventFolder(slug: slug, name: name, description: "", events: rels,
                                                  createdAtMs: now, updatedAtMs: now,
                                                  colorHex: hex ?? FolderPalette.assignHex(used: used)))
        }
    }

    /// 跨区跳转时 focus 会先于新区的数据到达:没找到先留着,等这一区读完盘(final)再作废。
    private func applyFocus(final: Bool) {
        guard let f = focus, !loading else { return }
        let p = f.standardizedFileURL.path
        guard let e = entries.first(where: { $0.id.standardizedFileURL.path == p }) else {
            if final { focus = nil }
            return
        }
        focus = nil
        if let g = group, groupOf[e.id] != g { selectGroup(groupOf[e.id]) }
        selected = e.id
    }

    private func loadDerived() async {
        guard let e = current else { return }
        let ids = DataView.splitDerivedSections(e.file.body).eventRels
        guard !ids.isEmpty else { return }
        let id = e.id
        let refs = await Task.detached(priority: .userInitiated) {
            ids.map { DataView.resolveDerivedRef($0) }
        }.value
        guard selected == id else { return }
        derived = refs
    }

    // MARK: - 读盘

    private func reload() async {
        gen += 1
        let token = gen
        loading = true
        let events = isEvents
        let halfLife = Double(config.current.memory.weightHalfLifeDays)
        let ord = order
        let titles = hubTitles
        let r = await Task.detached(priority: .userInitiated) {
            Self.load(events: events, halfLife: halfLife, order: ord, titles: titles)
        }.value
        guard token == gen else { return }
        entries = r.entries
        groupOf = r.groupOf
        groups = r.groups
        loading = false
        if let g = group, !groups.contains(where: { $0.key == g }) { group = nil }
        if let s = selected, !entries.contains(where: { $0.id == s }) { selected = nil }
        applyFocus(final: true)
    }

    nonisolated private static func rel(_ url: URL) -> String {
        let prefix = Storage.uiEventsDir.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    nonisolated private static func load(events: Bool, halfLife: Double, order: MemorySortOrder,
                                         titles: [String: String])
        -> (entries: [Entry], groupOf: [URL: String], groups: [ReaderGroup]) {
        var groupOf: [URL: String] = [:]
        if events {
            let all = DataView.scan(scope: .events, halfLifeDays: halfLife, order: order)
            var slugOf: [String: String] = [:]
            let folders = EventFolderStore.loadAll()
            for f in folders { for r in f.events { slugOf[r] = f.slug } }
            let un = GraphSceneBuilder.unclassifiedSlug
            for e in all { groupOf[e.id] = slugOf[rel(e.id)] ?? un }
            var count: [String: Int] = [:]
            for g in groupOf.values { count[g, default: 0] += 1 }
            var groups = folders
                .map { ReaderGroup(key: $0.slug, title: $0.name, colorHex: $0.colorHex,
                                   desc: $0.description, isFolder: true) }
                .sorted { (count[$0.key] ?? 0, $1.title) > (count[$1.key] ?? 0, $0.title) }
            if count[un] != nil {
                groups.append(ReaderGroup(key: un, title: "Unclassified", colorHex: nil, desc: "", isFolder: false))
            }
            return (all, groupOf, groups)
        }
        // portrait:预置分类在前,盘上多出来的分类目录跟在后面
        var cats = PortraitPaths.seedCategories
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: Storage.uiPortraitDir.path)) ?? []
        for d in dirs.sorted() where !d.hasPrefix("_") && !d.hasPrefix(".") && !cats.contains(d) {
            var isDir: ObjCBool = false
            let p = Storage.uiPortraitDir.appendingPathComponent(d).path
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { cats.append(d) }
        }
        var all: [Entry] = []
        for c in cats {
            let es = DataView.scan(scope: .portrait(category: c), halfLifeDays: halfLife, order: order)
            for e in es { groupOf[e.id] = c }
            all += es
        }
        let groups = cats.map {
            ReaderGroup(key: $0, title: titles[$0] ?? $0.replacingOccurrences(of: "_", with: " ").capitalized,
                        colorHex: nil, desc: "", isFolder: false)
        }
        return (DataView.sortedByConfig(all, order: order), groupOf, groups)
    }

    private static let short: DateFormatter = fmt("MMM d")
    private static let long: DateFormatter = fmt("MMM d, yyyy")
    private static let day: DateFormatter = fmt("yyyy-MM-dd")
    nonisolated private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = f
        d.timeZone = TimeZone(identifier: "UTC")   // event 日期按 UTC 天截断
        return d
    }
}
