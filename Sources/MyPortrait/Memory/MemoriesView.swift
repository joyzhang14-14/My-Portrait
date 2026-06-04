import SwiftUI

/// Three-column view of the memory system:
///   [scope picker]  [file list]  [detail]
///
///   scope picker → portrait categories + "Events"
///   file list    → portrait files in selected category (or events stream)
///   detail       → selected file's YAML metadata + body
///
/// Toolbar at the top of the middle column has a single action: reload from
/// disk. The pipeline triggers (Backfill / Rescore / Distill) live in
/// Settings → Memory → Scheduler.
struct MemoriesView: View {
    @Binding var scope: MemoryScope
    /// AI 编辑触发器。ContentView 注入:点击后把 chat 切到 edit 模式并
    /// 跳转到 Home。nil = 编辑按钮隐藏(测试 / 旧调用方兼容)。
    var onEditEntity: ((URL) -> Void)? = nil

    @State private var entries: [Entry] = []
    @State private var loading: Bool = false
    @State private var actionStatus: String = ""
    @State private var selected: Entry.ID?
    @State private var confirmingDelete: Bool = false
    /// 标题模糊搜(case-insensitive)。空 = 不过滤。切 scope 时清空。
    @State private var searchText: String = ""
    @Environment(\.colorScheme) private var colorScheme

    struct Entry: Identifiable {
        let id: URL
        let title: String
        let category: String
        let scope: MemoryScope
        let file: PortraitFile
        let modified: Date
        /// EMA lazy-decayed weight at scan time. List 排序 / 渲染都用这个，
        /// 不是 file.weight。同一 reload 内不重算。
        let currentWeight: Double
    }

    @ViewBuilder
    var body: some View {
        // .input scope 的数据源是 SQLite typing_events，不是 PortraitFile，
        // 走独立渲染路径（InputCaptureView）；其它 scope 走文件目录扫描。
        if scope == .personalInfo {
            PersonalInfoView()
        } else if scope == .input {
            InputCaptureView()
        } else {
            HSplitView {
                listColumn
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(SidebarBackdrop().ignoresSafeArea())
            .task(id: scope) {
                selected = nil
                searchText = ""
                await reload()
            }
        }
    }

    // MARK: - List column (toolbar + list)

    /// 搜索过滤:空串走全量,否则按 title case-insensitive contains。
    private var visibleEntries: [Entry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(scope.displayName)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(visibleEntries.count)\(searchText.isEmpty ? "" : " / \(entries.count)")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await reload() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bouncyIcon)
                .help("Reload from disk")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            SearchBar(text: $searchText, placeholder: "Search titles")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if !actionStatus.isEmpty {
                Text(actionStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(Color.primary.opacity(0.10))

            if entries.isEmpty && !loading {
                EmptyHint(scope: scope)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEntries.isEmpty {
                Text("No titles match “\(searchText)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if case .events = scope,
                           searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            // events 视图 + 没搜索 → 按 folder 分组(可展开)。
                            // 搜索激活时仍走 flat 列表 —— 搜索本来就是要看跨 folder
                            // 匹配,折叠成 group 会反直觉。
                            foldersGroupedList
                        } else {
                            ForEach(visibleEntries) { entry in
                                EntryRow(entry: entry, selected: selected == entry.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { handleSelect(entry: entry) }
                                Divider().background(Color.primary.opacity(0.08))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 中间列原来钉死 black.opacity(0.28),light 模式下盖在 warm-white
        // 上变成大灰块,跟左右两列格格不入。light 下用极淡 black 透出底色,
        // dark 下保留原本的 0.28 暗化效果。
        .background(Color.black.opacity(colorScheme == .light ? 0.03 : 0.28))
    }

    // MARK: - Folders-grouped events list

    /// events 视图的 folder 分组渲染。读 _folders/*.json:
    ///   - 有 folder → 渲染成可展开 DisclosureRow,按内部事件数倒序
    ///   - 没归任何 folder 的 → 平铺到 folder 区之后(用户原话:"ungrouped 不
    ///     需要打包,直接展示就好了")
    @ViewBuilder
    private var foldersGroupedList: some View {
        let split = makeFolderSplit()
        // folders 先
        ForEach(Array(split.folders.enumerated()), id: \.element.id) { idx, g in
            FolderDisclosureRow(
                title: g.title,
                count: g.entries.count,
                entries: g.entries,
                selected: selected,
                onSelect: handleSelect,
                onDelete: { Task { await deleteFolder(slug: g.slug, name: g.title) } }
            )
            // 最后一个 folder 后面**不画**这条细 Divider —— 紧接着就是下面那条
            // 10px 粗线,两条线之间会被 VStack spacing 撑出间距让粗线偏下。
            if idx < split.folders.count - 1 || split.ungrouped.isEmpty {
                Divider().background(Color.primary.opacity(0.08))
            }
        }
        // folders 区 与 ungrouped 区之间的粗灰分隔线 —— 放在 folders ForEach
        // 之后,所有 folder(含展开后的 event)天然都在它上方,ungrouped 在下方。
        // 只在两边都非空时画,避免孤线。
        if !split.folders.isEmpty, !split.ungrouped.isEmpty {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 10)
                .frame(maxWidth: .infinity)
        }
        // ungrouped 平铺
        ForEach(split.ungrouped) { entry in
            EntryRow(entry: entry, selected: selected == entry.id)
                .contentShape(Rectangle())
                .onTapGesture { handleSelect(entry: entry) }
            Divider().background(Color.primary.opacity(0.08))
        }
    }

    /// 把 visibleEntries 拆成 (folders, ungrouped)。Entry.id 是 URL,得换算
    /// 成 "yyyy-MM-dd/foo.md" 相对路径跟 folder.events 对齐。
    private func makeFolderSplit() -> (folders: [FolderGroup], ungrouped: [Entry]) {
        let prefix = Storage.eventsDir.path + "/"
        func relPath(of url: URL) -> String {
            url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
        }
        let byPath: [String: Entry] = Dictionary(uniqueKeysWithValues:
            visibleEntries.map { (relPath(of: $0.id), $0) }
        )

        let allFolders = EventFolderStore.loadAll()
        let folderGroups: [FolderGroup] = allFolders
            .map { f -> FolderGroup in
                // 内部事件按 currentWeight 倒序 —— 用户原话:"folder 里的词条
                // 按 weight 从高到低排"。folder.events 的原序(LLM 输出顺序)
                // 信息量低,weight 排在前更符合"重要的事先看见"直觉。
                let entries = f.events.compactMap { byPath[$0] }
                    .sorted { $0.currentWeight > $1.currentWeight }
                return FolderGroup(id: "folder:" + f.slug, slug: f.slug, title: f.name, entries: entries)
            }
            .filter { !$0.entries.isEmpty }
            .sorted { $0.entries.count > $1.entries.count }

        let classifiedPaths = Set(allFolders.flatMap { $0.events })
        let ungrouped = visibleEntries.filter { !classifiedPaths.contains(relPath(of: $0.id)) }
        return (folderGroups, ungrouped)
    }

    private struct FolderGroup {
        let id: String
        let slug: String
        let title: String
        let entries: [Entry]
    }

    // MARK: - Detail (right)

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let entry = entries.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.title)
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        if let onEdit = onEditEntity {
                            Button {
                                onEdit(entry.id)
                            } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                            .buttonStyle(.bouncyIcon)
                            .help("Edit with AI chat")
                        }
                        Button {
                            confirmingDelete = true
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.bouncyIcon)
                        .help("Delete this event")
                    }
                    .padding(.top, 44)
                    metadataBlock(entry.file, category: entry.category, scope: entry.scope)
                    Divider().background(Color.primary.opacity(0.10))
                    // markdown 渲染:body 里 `**bold**` / `> quote` 这种标记
                    // 现在能正确显示。SwiftUI 原生 `Text(.init(...))` 走
                    // AttributedString 解析,够用且零依赖。
                    markdownBody(entry.file.body)
                    if let notes = entry.file.editNotes, !notes.isEmpty {
                        Divider().background(Color.primary.opacity(0.10))
                        editNotesBlock(notes)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog(
                "Delete “\(entry.title)”?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await deleteEntry(entry) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the event file from disk.")
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: scope.systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select an item")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 把 portrait body 渲染成 markdown(原生 AttributedString)。
    /// 只能逐段处理 —— SwiftUI Text(.init(...)) 解析单段,跨段会丢换行。
    @ViewBuilder
    private func markdownBody(_ raw: String) -> some View {
        let paragraphs = raw
            .split(separator: "\n\n", omittingEmptySubsequences: true)
            .map(String.init)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                let attr = (try? AttributedString(
                    markdown: para,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(para)
                Text(attr)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func metadataBlock(_ f: PortraitFile, category: String, scope: MemoryScope) -> some View {
        let facetStr = f.portraitFacets.isEmpty
            ? "—"
            : f.portraitFacets.map { "\($0.facet):\($0.value)" }.joined(separator: ", ")
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let curW = WeightEMA(halfLifeDays: halfLife)
            .currentWeight(stored: f.weight, daysSinceModified: f.daysSinceModified())
        // event 路径展示 impact / impact_source；portrait 路径整行不渲染
        // （portrait 不持有 impact，impact_source 残留也无意义）。
        let impactRows: [(String, String)] = scope == .events
            ? [("impact", String(format: "%.4g", f.impact ?? 0)),
               ("impact_source", f.impactSource ?? "—")]
            : []
        let rows: [(String, String)] =
            [("type", f.eventType.isEmpty ? "experience" : f.eventType),
             ("portrait_facets", facetStr),
             ("category (legacy)", category.isEmpty ? "—" : category),
             ("weight", String(format: "%.4g", curW))]
            + impactRows
            + [("last_occurred", f.lastOccurrence.map { Self.dayString($0) } ?? "—"),
               ("occurrences (days)", "\(f.occurrences.count)"),
               ("member frames", "\(f.memberFrameIds.count)"),
               ("tags", f.tags.joined(separator: ", "))]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 130, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// 详情页底部:AI 编辑历史。每条 EditNote 一行 `(date) summary`,
    /// 时间倒序(最新在上)。给用户 + 下游 distill/personality 的 LLM 看,
    /// 提醒别再犯同样的事实错误。
    private func editNotesBlock(_ notes: [PortraitFile.EditNote]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("EDIT HISTORY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text("(\(notes.count))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(notes.reversed().enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(Self.dayString(note.date))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(note.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !note.request.isEmpty {
                        Text("Request: \(note.request)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textPrimary.opacity(0.50))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 0.5))
                )
            }
        }
    }

    // MARK: - Actions

    /// Single user click on a list row — selection only. Opening a detail
    /// pane is housekeeping, not a real-world recurrence of the event, so it
    /// does NOT touch weight or any counter.
    private func handleSelect(entry: Entry) {
        selected = entry.id
    }

    /// Permanently delete one event's `.md` file from disk.
    @MainActor
    private func deleteEntry(_ entry: Entry) async {
        do {
            try FileManager.default.removeItem(at: entry.id)
            entries.removeAll { $0.id == entry.id }
            selected = nil
            actionStatus = "Deleted: \(entry.title)"
        } catch {
            actionStatus = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// 删一个 folder —— 只删 `_folders/<slug>.json`(取消分组),folder 里的
    /// 事件 .md **不动**,删完落回 ungrouped 平铺区。reload() 重扫触发
    /// makeFolderSplit 重读 _folders/,该 folder 自然消失。
    @MainActor
    private func deleteFolder(slug: String, name: String) async {
        do {
            try EventFolderStore.delete(slug: slug)
            await reload()
            actionStatus = "Removed folder: \(name)"
        } catch {
            actionStatus = "Remove folder failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func reload() async {
        loading = true
        let currentScope = scope
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.scan(scope: currentScope, halfLifeDays: halfLife)
        }.value
        entries = loaded
        loading = false
    }

    // MARK: - Disk scan

    /// Walks the appropriate root (events/ or portrait/<cat>/) for the
    /// current scope. Off the main actor.
    nonisolated private static func scan(scope: MemoryScope, halfLifeDays: Double) -> [Entry] {
        let fm = FileManager.default
        let root: URL
        switch scope {
        case .events:
            root = Storage.eventsDir
        case .input, .personalInfo:
            // .input 走 InputCaptureView,.personalInfo 走 PersonalInfoView —— 都没文件可扫。
            return []
        case .portrait(let cat):
            root = Storage.portraitDir.appendingPathComponent(cat, isDirectory: true)
        }
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var out: [Entry] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let file = try? PortraitFileIO.read(from: url) else { continue }
            let categoryPath = file.category
            let title = file.eventTitle.isEmpty
                ? (extractTitle(from: file.body) ?? url.deletingPathExtension().lastPathComponent)
                : file.eventTitle
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? file.created
            let cw = WeightEMA(halfLifeDays: halfLifeDays)
                .currentWeight(stored: file.weight,
                               daysSinceModified: file.daysSinceModified())
            out.append(Entry(
                id: url,
                title: title,
                category: categoryPath,
                scope: scope,
                file: file,
                modified: modified,
                currentWeight: cw
            ))
        }
        out.sort { $0.currentWeight > $1.currentWeight }
        return out
    }

    nonisolated private static func extractTitle(from body: String) -> String? {
        for line in body.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    nonisolated private static func dayString(_ d: Date) -> String { dayFmt.string(from: d) }
}

/// folder 行 = 可展开标题(folder 图标 + name + count 徽章),展开后是
/// 该 folder 内 entries 的 EntryRow 列表。
/// **只给真 folder 用**。Ungrouped events 现在直接平铺渲染 EntryRow
/// (用户原话:"ungrouped event 不需要打包,直接展示就好了")。
private struct FolderDisclosureRow: View {
    let title: String
    let count: Int
    let entries: [MemoriesView.Entry]
    let selected: URL?
    let onSelect: (MemoriesView.Entry) -> Void
    /// 点删除按钮 + 确认后调。只取消分组(删 _folders json),不删事件。
    let onDelete: () -> Void

    @State private var expanded: Bool = false
    /// 只跟踪指针是否在删除按钮本身上(不是整行)。
    @State private var trashHover: Bool = false
    @State private var confirmingDelete: Bool = false

    /// 给 folder 名稳定挑一个柔和的色相,跟 macOS Finder 自带 tag 颜色一脉。
    /// hash 取模 → 同名 folder 每次都同色,UI 视觉一致。
    private static let folderTints: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.91),   // 蓝
        Color(red: 0.46, green: 0.74, blue: 0.50),   // 绿
        Color(red: 0.90, green: 0.58, blue: 0.30),   // 橙
        Color(red: 0.72, green: 0.48, blue: 0.86),   // 紫
        Color(red: 0.92, green: 0.45, blue: 0.55),   // 玫红
        Color(red: 0.34, green: 0.71, blue: 0.78),   // 青
        Color(red: 0.86, green: 0.74, blue: 0.36),   // 金
    ]
    private var tint: Color {
        let h = abs(title.hashValue) % Self.folderTints.count
        return Self.folderTints[h]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部:点击切换展开。整行可点。
            // **不 withAnimation** —— 同时动画 N 个 EntryRow 的 opacity/transform
            // 在 N=40+ 时帧预算爆炸,scroll 完全卡死。瞬时切换无肉眼可见瑕疵。
            // 头部用 onTapGesture 切换展开(不再用 Button 包裹整行),好让
            // 末尾的删除按钮作为独立 Button 单独接 tap、不触发展开。
            HStack(spacing: 12) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                // folder 图标:用 .palette 模式让 fill 跟 stroke 分两色
                // (跟 Finder 文件夹观感一致)。
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tint.opacity(0.95), tint.opacity(0.35))
                    .font(.system(size: 17))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        Capsule().fill(tint.opacity(0.13))
                            .overlay(
                                Capsule().stroke(tint.opacity(0.25), lineWidth: 0.5)
                            )
                    )
                // 删除按钮 —— 放在数字右边。常驻但低调,**只有指针碰到按钮本身**
                // 才变亮(用独立 trashHover,不跟整行 hover 走)。只取消分组,不删事件。
                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(trashHover ? 0.9 : 0.4))
                }
                .buttonStyle(.plain)
                .onHover { trashHover = $0 }
                .help("Delete folder (ungroups its events; the events are kept)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .confirmationDialog(
                "Delete folder “\(title)”?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete folder", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the grouping only. The \(count) event(s) inside are kept and move back to ungrouped.")
            }

            // 展开后的事件列表 —— **嵌一层 LazyVStack** 让子项也按需渲染。
            // folder 大的能去到 40+ events,外层 LazyVStack 只 lazy 到
            // FolderDisclosureRow 这一层,内部 ForEach 默认 eager 全 materialize
            // 一上来 scroll 时 SwiftUI 算整个子树 layout → 100% 卡死。
            // 嵌套 LazyVStack 在 macOS 12+ 完全支持。
            if expanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        EntryRow(entry: entry, selected: selected == entry.id)
                            .padding(.leading, 22)   // 跟 chevron 缩对齐
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(entry) }
                        // 最后一个 event 不画尾部细线 —— 否则它会漏在外层
                        // folders↔ungrouped 的 10px 粗线上方,显得多一道线。
                        if idx < entries.count - 1 {
                            Divider().background(Color.primary.opacity(0.05))
                                .padding(.leading, 22)
                        }
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: MemoriesView.Entry
    let selected: Bool

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3, height: max(4, min(36, CGFloat(entry.currentWeight) * 6)))
                Spacer(minLength: 0)
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.category)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("w=\(String(format: "%.2f", entry.currentWeight))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if entry.scope == .events, let imp = entry.file.impact {
                        Text("i=\(String(format: "%.1f", imp))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text("×\(entry.file.occurrences.count)d")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    // 显示「最近一次出现」而不是「文件创建日」—— 后者只是
                    // 蒸馏跑那一天,信息量低且会让所有同批 portrait 看上去一样。
                    if let last = entry.file.lastOccurrence {
                        Text(Self.dayFmt.string(from: last))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Theme.accent.opacity(0.18) : .clear)
    }

    private var barColor: Color {
        let w = max(0, min(5, entry.currentWeight))
        let hue = (w / 5) * 0.35
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }
}

private struct EmptyHint: View {
    let scope: MemoryScope
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyText)
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
    private var emptyText: String {
        switch scope {
        case .events:
            return "No events yet.\nClick ↓ to backfill from the timeline."
        case .input:
            return "Input capture is not set up yet."
        case .personalInfo:
            // 不会走到 —— .personalInfo 路由直接进 PersonalInfoView,不走 list 列。
            return ""
        case .portrait:
            return "No portrait entries in this category yet.\nRun events backfill first."
        }
    }
}
