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
    /// writing-style chip → Input 跳转目标 record id;writing record 文本预览缓存。
    @State private var pendingInputRecordId: Int64? = nil
    @State private var wrPreviews: [Int64: String] = [:]
    /// AI 编辑触发器。ContentView 注入:点击后把 chat 切到 edit 模式并
    /// 跳转到 Home。nil = 编辑按钮隐藏(测试 / 旧调用方兼容)。
    var onEditEntity: ((URL) -> Void)? = nil
    /// 图谱浮窗 wr chip 跳转注入(ContentView 传):非 nil → Input 定位该 record。
    /// nil = 无外部跳转,走内部 pendingInputRecordId(writing-style chip 路径)。
    var externalInputJump: Binding<Int64?>? = nil

    /// Display 的 Memory sort order 改动要即时反映到列表 —— 持有 store 让
    /// @Observable 依赖追踪生效(body 里读 memorySortOrder 建立观察)。
    @State private var config = ConfigStore.shared

    @State private var entries: [Entry] = []
    /// events 视图的 folder 分组缓存 —— 原来 foldersGroupedList 在 body 里
    /// 每次重算都同步 EventFolderStore.loadAll()(枚举目录+逐 JSON 解码)
    /// 在主线程。现在只在 reload()(folder 写操作成功后都会走 reload)和
    /// deleteEntry 后后台重算,body 只读缓存。
    @State private var folderGroups: [FolderGroup] = []
    @State private var ungroupedEntries: [Entry] = []
    @State private var loading: Bool = false
    /// 代际 token —— reload / resort / refreshFolderSplit 都是「同步前缀 → await
    /// detached → 写回 @State」两段式,完成顺序不确定。入口 bump+捕获,await 后
    /// 写回前 guard,过期续体丢弃,避免后完成的盖掉新结果(stale 快照 / 旧排序)。
    @State private var refreshGen: Int = 0
    @State private var actionStatus: String = ""
    @State private var selected: Entry.ID?
    /// 选中 portrait 条目「Derived from events」块解析出的可点击引用
    /// （异步读盘填充；选中变更即清空，避免残留上一条目的 chip）。
    @State private var derivedRefs: [DerivedRef] = []
    /// 点 Derived chip 要跳转到的 event 相对路径（"yyyy-MM-dd/foo.md"）。切 scope
    /// 到 .events 会清 selected，所以先存这，reload 后按 eventRelPath 匹配回 selected。
    /// 存相对路径而非 URL：直接拿 entries 里真实的 Entry.id 比，绕开 URL 等值表示差异。
    @State private var pendingEventRel: String? = nil
    @State private var confirmingDelete: Bool = false
    /// 标题模糊搜(case-insensitive)。空 = 不过滤。切 scope 时清空。
    @State private var searchText: String = ""
    /// event 右键 "Move to new folder…" 弹窗状态。
    @State private var movingEntry: Entry? = nil
    @State private var newFolderDraft: String = ""
    /// event 右键 "Delete" 确认。
    @State private var deletingEntry: Entry? = nil
    /// 顶部 Create folder 按钮的 sheet 状态(跟上面 newFolderDraft 那条 event
    /// 右键 New folder 路径分开 —— 这条是「空 folder 立刻可用」)。
    @State private var creatingFolderSheet: Bool = false
    @State private var creatingFolderName: String = ""
    @State private var creatingFolderHex: String? = nil
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

    /// 一条「Derived from events」引用的解析结果 —— 渲染成可点击蓝色 chip。
    struct DerivedRef: Identifiable {
        let id: String     // 原始 [[id]] 相对路径（含 .md），导航 + 去重键
        let date: String   // id 第一段 "yyyy-MM-dd"（非法则空）
        let title: String  // event 人读标题（失效时空）
        let exists: Bool   // 能读到真实 event .md → 可点击
    }

    @ViewBuilder
    var body: some View {
        // .input scope 的数据源是 SQLite typing_events，不是 PortraitFile，
        // 走独立渲染路径（InputCaptureView）；其它 scope 走文件目录扫描。
        if scope == .personalInfo {
            PersonalInfoView()
        } else if scope == .input {
            InputCaptureView(jumpToRecordId: externalInputJump ?? $pendingInputRecordId)
        } else {
            HSplitView {
                listColumn
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(SidebarBackdrop().ignoresSafeArea())
            .task(id: scope) {
                searchText = ""
                selected = nil
                await reload()
                // Derived chip 导航：reload 后 events 已加载，按相对路径匹配到真实
                // Entry.id（绕开 URL 等值表示差异），detail 即显示该 event。
                if let rel = pendingEventRel {
                    pendingEventRel = nil
                    selected = entries.first(where: { Self.eventRelPath(of: $0.id) == rel })?.id
                }
            }
            // 选中条目变化 → 重新解析它的 Derived 引用为可点击 chip。
            .task(id: selected) {
                await loadDerivedRefs()
            }
            // 改 Display 的 Memory sort order → 就地重排已加载的列表(纯内存,
            // 不重新读盘),主列表与 folder 分组同时刷新。
            .onChange(of: config.current.display.memorySortOrder) {
                Task { await resort() }
            }
        }
    }

    /// 从 Display 设置读当前排序规则(非法值兜底 weight)。MainActor 上下文。
    @MainActor
    private var currentSortOrder: MemorySortOrder {
        MemorySortOrder(rawValue: config.current.display.memorySortOrder) ?? .weight
    }

    /// 对已加载的 entries / folder 分组就地重排,跟随当前排序设置。entries 已在
    /// 内存里,只是换比较器 —— folder split 仍要读 _folders/(loadAll 读盘),
    /// 跟 reload 一样丢后台,主列表先排好。
    @MainActor
    private func resort() async {
        refreshGen += 1
        let gen = refreshGen
        let order = currentSortOrder
        entries = Self.sortedByConfig(entries, order: order)
        guard scope == .events else { return }
        let snapshot = entries
        let split = await Task.detached(priority: .userInitiated) {
            Self.makeFolderSplit(entries: snapshot, order: order)
        }.value
        guard gen == refreshGen else { return }   // 期间有更新的刷新 → 丢弃本次
        folderGroups = split.folders
        ungroupedEntries = split.ungrouped
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
                // Create folder 只在 events scope 有意义 —— 其他 scope
                // (portrait / personalInfo / input) 没 folder 概念。
                if case .events = scope {
                    IconHoverButton(systemImage: "folder.badge.plus",
                                    tooltip: "Create folder",
                                    systemHelp: "Create a new empty folder") {
                        creatingFolderName = ""
                        creatingFolderHex = nil
                        creatingFolderSheet = true
                    }
                }
                IconHoverButton(systemImage: "arrow.clockwise",
                                  tooltip: "Refresh",
                                  systemHelp: "Reload from disk") {
                    Task { await reload() }
                }
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
                            let isEvents = { if case .events = scope { return true } else { return false } }()
                            ForEach(visibleEntries) { entry in
                                EntryRow(entry: entry, selected: selected == entry.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { handleSelect(entry: entry) }
                                    .contextHighlight { if isEvents { eventContextMenu(entry) } }
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
        // event 右键 "New folder…" → 输入新 folder 名。
        .alert("New folder", isPresented: Binding(
            get: { movingEntry != nil },
            set: { if !$0 { movingEntry = nil } }
        )) {
            TextField("Folder name", text: $newFolderDraft)
            Button("Create & move") {
                let n = newFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let e = movingEntry, !n.isEmpty {
                    Task { await assignEventToNewFolder(e, name: n) }
                }
                movingEntry = nil
            }
            Button("Cancel", role: .cancel) { movingEntry = nil }
        }
        // event 右键 "Delete event" → 确认后删 .md + 摘掉 folder 引用。
        .confirmationDialog(
            "Delete this event?",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete event", role: .destructive) {
                if let e = deletingEntry { Task { await deleteEntry(e) } }
                deletingEntry = nil
            }
            Button("Cancel", role: .cancel) { deletingEntry = nil }
        } message: {
            Text(deletingEntry.map { "“\($0.title)” will be permanently deleted from disk." } ?? "")
        }
        // 顶部 Create folder 按钮唤起的 sheet。Name + 颜色选择。空 folder
        // 立刻可见,后续可右键 Move events into / 重命名 / 改色 / 删。
        .sheet(isPresented: $creatingFolderSheet) {
            NewFolderSheet(
                name: $creatingFolderName,
                hex: $creatingFolderHex,
                onCancel: { creatingFolderSheet = false },
                onCreate: {
                    Task { await createEmptyFolder() }
                }
            )
        }
    }

    // MARK: - Folders-grouped events list

    /// events 视图的 folder 分组渲染。读 _folders/*.json:
    ///   - 有 folder → 渲染成可展开 DisclosureRow,按内部事件数倒序
    ///   - 没归任何 folder 的 → 平铺到 folder 区之后(用户原话:"ungrouped 不
    ///     需要打包,直接展示就好了")
    @ViewBuilder
    private var foldersGroupedList: some View {
        // 读缓存(reload / deleteEntry 后台重算),不在 body 里读盘重算。
        // 分组视图只在搜索为空时渲染(visibleEntries == entries),所以
        // 缓存按全量 entries 算就是对的。
        let split = (folders: folderGroups, ungrouped: ungroupedEntries)
        // folders 先
        ForEach(Array(split.folders.enumerated()), id: \.element.id) { idx, g in
            FolderDisclosureRow(
                title: g.title,
                count: g.entries.count,
                colorHex: g.colorHex,
                entries: g.entries,
                selected: selected,
                onSelect: handleSelect,
                onDelete: { Task { await deleteFolder(slug: g.slug, name: g.title) } },
                onRename: { newName in Task { await renameFolder(slug: g.slug, to: newName) } },
                onSetColor: { hex in Task { await setFolderColor(slug: g.slug, hex: hex) } },
                eventMenu: { entry in AnyView(eventContextMenu(entry)) }
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
                .contextHighlight { eventContextMenu(entry) }
            Divider().background(Color.primary.opacity(0.08))
        }
    }

    /// 按指定规则排序。weight 倒序 / created 新→旧 / 最新 occurrence 新→旧。
    /// 主列表与 folder 内 event 共用,口径一致。order 由 MainActor 调用方读
    /// config 传入(nonisolated 不能直接碰 ConfigStore.shared)。
    ///
    /// ⚠️ created / lastOccurred 的主键是**天级**(event 的 created / occurrence
    /// 都截断到 UTC 当天),同一天会有大量并列。次级键用 member frame id(采集帧
    /// 自增主键,递增≈真实时间)细分当天内时序:created 用最早一帧(起始时刻)、
    /// lastOccurred 用最后一帧(最后活动)。无 frame(distill 出的 portrait)退
    /// weight,再退文件名 —— 保证严格弱序 + 刷新不抖。
    nonisolated private static func sortedByConfig(_ entries: [Entry], order: MemorySortOrder) -> [Entry] {
        switch order {
        case .weight:
            return entries.sorted {
                if $0.currentWeight != $1.currentWeight { return $0.currentWeight > $1.currentWeight }
                return $0.id.path > $1.id.path   // 全序兜底,同 weight 刷新不抖
            }
        case .created:
            return entries.sorted { a, b in
                if a.file.created != b.file.created { return a.file.created > b.file.created }
                return intraDayBefore(a, b, useEnd: false)
            }
        case .lastOccurred:
            return entries.sorted { a, b in
                // lastOccurrence 可能 nil → 退回 created 当锚点。
                let la = a.file.lastOccurrence ?? a.file.created
                let lb = b.file.lastOccurrence ?? b.file.created
                if la != lb { return la > lb }
                return intraDayBefore(a, b, useEnd: true)
            }
        }
    }

    /// 同一天(主键并列)内的细分:event 当天真实时刻(member frame id 递增≈时间)
    /// 降序 —— useEnd=false 用最早帧(起始),true 用最后帧(最后活动)。无 frame
    /// 退 weight,再退文件名,保证严格弱序 + 刷新确定。
    nonisolated private static func intraDayBefore(_ a: Entry, _ b: Entry, useEnd: Bool) -> Bool {
        let ta = useEnd ? a.file.memberFrameIds.max() : a.file.memberFrameIds.min()
        let tb = useEnd ? b.file.memberFrameIds.max() : b.file.memberFrameIds.min()
        if let ta, let tb, ta != tb { return ta > tb }
        if a.currentWeight != b.currentWeight { return a.currentWeight > b.currentWeight }
        return a.id.path > b.id.path
    }

    /// 把 entries 拆成 (folders, ungrouped)。Entry.id 是 URL,得换算
    /// 成 "yyyy-MM-dd/foo.md" 相对路径跟 folder.events 对齐。
    /// static + nonisolated:EventFolderStore.loadAll() 读盘,在 reload 的
    /// 后台任务里跑,不进 body。
    nonisolated private static func makeFolderSplit(entries: [Entry], order: MemorySortOrder) -> (folders: [FolderGroup], ungrouped: [Entry]) {
        let prefix = Storage.eventsDir.path + "/"
        func relPath(of url: URL) -> String {
            url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
        }
        let byPath: [String: Entry] = Dictionary(uniqueKeysWithValues:
            entries.map { (relPath(of: $0.id), $0) }
        )

        let allFolders = EventFolderStore.loadAll()
        let folderGroups: [FolderGroup] = allFolders
            .map { f -> FolderGroup in
                // 内部事件跟随 Display 的 Memory sort order(weight / created /
                // last occurrence),与主列表口径一致。folder.events 的原序
                // (LLM 输出顺序)信息量低,按设置排更符合直觉。
                let entries = Self.sortedByConfig(f.events.compactMap { byPath[$0] }, order: order)
                return FolderGroup(id: "folder:" + f.slug, slug: f.slug, title: f.name,
                                   colorHex: f.colorHex, entries: entries)
            }
            .filter { !$0.entries.isEmpty }
            .sorted { $0.entries.count > $1.entries.count }

        let classifiedPaths = Set(allFolders.flatMap { $0.events })
        let ungrouped = entries.filter { !classifiedPaths.contains(relPath(of: $0.id)) }
        return (folderGroups, ungrouped)
    }

    private struct FolderGroup {
        let id: String
        let slug: String
        let title: String
        let colorHex: String?
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
                    bodyWithDerived(entry)
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

    // MARK: - Derived events → clickable chips

    /// 详情 body：prose 走原 markdownBody，末尾 `Derived from events` 块换成
    /// 一排可点击蓝色 event chip。没有该块的老条目 → 整体照旧渲染。
    @ViewBuilder
    private func bodyWithDerived(_ entry: Entry) -> some View {
        // writing-style:末尾 `**Derived from writing records:**` + [[wr:NNN]] →
        // 蓝色 chip,点击跳到 Input 对应记录。其它 scope 走下面 event/personality 路径。
        let wr = Self.splitWritingRecords(entry.file.body)
        if !wr.wrIds.isEmpty {
            markdownBody(wr.before)
            Divider().background(Color.primary.opacity(0.10))
            derivedWritingRecordsBlock(wr.wrIds)
        } else {
        let parsed = Self.splitDerivedSections(entry.file.body)
        markdownBody(parsed.before)
        if !parsed.eventRels.isEmpty {
            Divider().background(Color.primary.opacity(0.10))
            derivedEventsBlock()
        }
        // personality 概念：events 之后的 `## portraits` / `## ocr` 等小节保持
        // 原样渲染（非 event，不做成 chip）。普通 portrait 这里恒为空。
        if !parsed.after.isEmpty {
            Divider().background(Color.primary.opacity(0.10))
            markdownBody(parsed.after)
        }
        }
    }

    /// `Derived from events` 区：标题 + 流式排布的 chip。chip 内容来自异步解析的
    /// derivedRefs（读盘期间可能短暂只有标题，毫秒级填充）。
    @ViewBuilder
    private func derivedEventsBlock() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DERIVED FROM EVENTS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(derivedRefs) { ref in
                    if ref.exists {
                        Button { navigateToEvent(ref.id) } label: {
                            derivedChip(ref)
                        }
                        .buttonStyle(.plain)
                        .help(ref.id)
                    } else {
                        // 失效引用（已删 / 非 event 的 wr: 引用）：灰色纯文本，不可点。
                        Text(ref.date.isEmpty ? ref.id : "\(ref.date)  \(ref.id)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个蓝色 event chip 的外观：日期 + 标题。
    private func derivedChip(_ ref: DerivedRef) -> some View {
        HStack(spacing: 5) {
            if !ref.date.isEmpty {
                Text(ref.date)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent.opacity(0.75))
            }
            Text(ref.title.isEmpty ? ref.id : ref.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.accent.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.8)
                )
        )
    }

    /// 点 chip → 跳到对应 event。rel = "yyyy-MM-dd/foo.md"。切 scope 到 .events，
    /// reload 后 `.task(id: scope)` 按 rel 匹配落到 selected，右侧 detail 显示该 event。
    private func navigateToEvent(_ rel: String) {
        if scope == .events {
            // 防御：portrait detail 不会走这条；同 scope 时直接在已加载 entries 里选。
            selected = entries.first(where: { Self.eventRelPath(of: $0.id) == rel })?.id
        } else {
            pendingEventRel = rel
            scope = .events
        }
    }

    /// writing-style:`**Derived from writing records:**` 区 → 蓝色 chip 一排,
    /// label 显示记录文本预览(无则 #id),点击跳到 Input 对应记录。
    @ViewBuilder
    private func derivedWritingRecordsBlock(_ ids: [Int64]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DERIVED FROM WRITING RECORDS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6).foregroundStyle(.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(ids, id: \.self) { id in
                    Button { pendingInputRecordId = id; scope = .input } label: {
                        let p = wrPreviews[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let label = p.isEmpty ? "#\(id)" : String(p.prefix(40))
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                    .fill(Theme.accent.opacity(0.16))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                        .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain).help("wr:\(id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: selected) { await loadWritingRecordPreviews(ids) }
    }

    /// 批量取 writing record 文本预览填 wrPreviews(后台 DB 查)。
    @MainActor
    private func loadWritingRecordPreviews(_ ids: [Int64]) async {
        guard let store = WritingCaptureWorker.shared?.store else { return }
        let sel = selected
        let m = await Task.detached(priority: .userInitiated) { store.writingRecordPreviews(ids: ids) }.value
        guard selected == sel else { return }
        wrPreviews = m
    }

    /// 拆 writing-style body：`**Derived from writing records:**` 之前是 prose,
    /// 之后(含同行)的 `[[wr:NNN]]` 全抽成 id。无该块 → (body, [])。
    /// internal:图谱浮窗(GraphFloatWindow)复用同一解析,与 text 模式行为一致。
    nonisolated static func splitWritingRecords(_ body: String) -> (before: String, wrIds: [Int64]) {
        guard let r = body.range(of: "**Derived from writing records:**") else { return (body, []) }
        let before = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(body[r.lowerBound...])
        var ids: [Int64] = []; var seen = Set<Int64>()
        guard let re = try? NSRegularExpression(pattern: #"\[\[wr:(\d+)\]\]"#) else { return (before, []) }
        let ns = tail as NSString
        for m in re.matches(in: tail, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 2 {
            if let id = Int64(ns.substring(with: m.range(at: 1))), seen.insert(id).inserted { ids.append(id) }
        }
        return (before, ids)
    }

    /// 解析当前选中条目 body 的 Derived 引用 → derivedRefs（读盘在后台）。
    /// 先清空避免残留上一条目；写回前 guard selected 未变，丢弃过期结果。
    @MainActor
    private func loadDerivedRefs() async {
        derivedRefs = []
        guard let id = selected,
              let entry = entries.first(where: { $0.id == id }) else { return }
        let ids = Self.splitDerivedSections(entry.file.body).eventRels
        guard !ids.isEmpty else { return }
        let resolved = await Task.detached(priority: .userInitiated) {
            ids.map { Self.resolveDerivedRef($0) }
        }.value
        guard selected == id else { return }   // 期间换了选中 → 丢弃
        derivedRefs = resolved
    }

    /// 把 body 拆成 (before, eventRels, after)。eventRels 统一是 event 相对路径
    /// "yyyy-MM-dd/foo.md"，无论来自哪种格式。两种格式：
    ///   1. 普通 portrait：末尾 `**Derived from events:**` + `- [[relpath]]` 行。
    ///      after 恒空（该块在 body 最后）。
    ///   2. personality 概念：`## events` 小节 + 裸 slug 行（slug 以 yyyy-MM-dd 开头），
    ///      转成 "<date>/<slug>.md"；events 之后的 `## portraits` / `## ocr` 落进
    ///      after，保持原样渲染（非 event）。
    /// 都不匹配 → (body, [], "")，整体照旧渲染。不动 `# Title`（prose 不变）。
    /// internal:图谱浮窗(GraphFloatWindow)复用同一解析,与 text 模式行为一致。
    nonisolated static func splitDerivedSections(_ body: String)
        -> (before: String, eventRels: [String], after: String) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Case 1：普通 portrait —— `**Derived from events:**` 块。
        if let marker = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("**Derived from events:**")
        }) {
            let before = lines[..<marker].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var rels: [String] = []
            var seen = Set<String>()
            for raw in lines[(marker + 1)...] {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("- [[") && line.hasSuffix("]]") else { continue }
                let inner = String(line.dropFirst(4).dropLast(2))
                // 去重：同一引用两次会让 ForEach 撞 id（DerivedRef.id = 这个串）。
                if !inner.isEmpty, seen.insert(inner).inserted { rels.append(inner) }
            }
            return (before, rels, "")
        }

        // Case 2：personality 概念 —— `## events` 小节（裸 slug）。
        if let evHeader = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("## events")
        }) {
            let before = lines[..<evHeader].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var rels: [String] = []
            var seen = Set<String>()
            var afterStart = lines.count
            var i = evHeader + 1
            while i < lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { afterStart = i; break }   // 下个 heading → events 段结束
                if line.hasPrefix("- ") {
                    let slug = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if slug != "(none)", let rel = eventRelFromSlug(slug),
                       seen.insert(rel).inserted { rels.append(rel) }
                }
                i += 1
            }
            let after = afterStart < lines.count
                ? lines[afterStart...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return (before, rels, after)
        }

        return (body, [], "")
    }

    /// personality `## events` 裸 slug → event 相对路径 "<date>/<slug>.md"。
    /// event 文件名以日期开头、所在文件夹即该日期，所以 slug 前 10 位 = 文件夹。
    /// slug 不以 yyyy-MM-dd 开头 → 返回 nil（不当 event，不进 chip）。
    nonisolated private static func eventRelFromSlug(_ slug: String) -> String? {
        guard slug.count >= 10 else { return nil }
        let date = Array(slug.prefix(10))
        guard date[4] == "-", date[7] == "-" else { return nil }
        return "\(String(date))/\(slug).md"
    }

    /// 单条 `[[id]]` → DerivedRef。能读到 event 文件即可点击；否则失效（灰文本）。
    /// internal:图谱浮窗(GraphFloatWindow)复用。
    nonisolated static func resolveDerivedRef(_ rawId: String) -> DerivedRef {
        let url = URL(fileURLWithPath: Storage.eventsDir.path + "/" + rawId)
        let date: String = {
            let seg = rawId.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return seg.count == 10 ? seg : ""
        }()
        if let file = try? PortraitFileIO.read(from: url) {
            let title = file.eventTitle.isEmpty
                ? (extractTitle(from: file.body) ?? url.deletingPathExtension().lastPathComponent)
                : file.eventTitle
            return DerivedRef(id: rawId, date: date, title: title, exists: true)
        }
        return DerivedRef(id: rawId, date: date, title: "", exists: false)
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
            // 顺手从所属 folder 摘掉引用,避免 folder 指向死路径 + count 虚高。
            // events scope 才有 folder 概念;其它 scope rel 不匹配,no-op。
            try? EventFolderStore.removeEventEverywhere(Self.eventRelPath(of: entry.id))
            entries.removeAll { $0.id == entry.id }
            refreshFolderSplit()
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

    /// 改名:只改 name,slug 不动(cron job/AI 仍用老 slug 引用,不分裂)。
    @MainActor
    private func renameFolder(slug: String, to newName: String) async {
        do {
            try EventFolderStore.rename(slug: slug, to: newName)
            await reload()
            actionStatus = "Renamed folder → \(newName)"
        } catch {
            actionStatus = "Rename failed: \(error.localizedDescription)"
        }
    }

    /// 改颜色:写 colorHex(nil = 恢复默认 hash 色)。
    @MainActor
    private func setFolderColor(slug: String, hex: String?) async {
        do {
            try EventFolderStore.setColor(slug: slug, hex: hex)
            await reload()
            actionStatus = hex == nil ? "Folder color reset" : "Folder color updated"
        } catch {
            actionStatus = "Color change failed: \(error.localizedDescription)"
        }
    }

    /// event 分到某 folder:assignEvent 内部先从别的 folder 移除再加入。
    @MainActor
    private func assignEventToFolder(_ entry: Entry, slug: String) async {
        let rel = Self.eventRelPath(of: entry.id)
        do {
            try EventFolderStore.assignEvent(rel, toSlug: slug)
            await reload()
            actionStatus = "Moved to folder"
        } catch {
            actionStatus = "Move failed: \(error.localizedDescription)"
        }
    }

    /// 顶部 Create folder 按钮:建一个**空** folder(无 event),立刻可见。
    /// 跟 `assignEventToNewFolder` 共享 slug 冲突解决 + reload + status 逻辑,
    /// 只是不预塞 event。
    @MainActor
    private func createEmptyFolder() async {
        let name = creatingFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var slug = EventFolderStore.makeSlug(from: name)
        if EventFolderStore.load(slug: slug) != nil {
            var n = 2
            while EventFolderStore.load(slug: "\(slug)-\(n)") != nil { n += 1 }
            slug = "\(slug)-\(n)"
        }
        do {
            // 没手选色 → 创建时随机固化一色(07-10:随机色生成后永不变;
            // 不再留 nil 走"每次启动漂移"的默认色)。
            let used = Set(EventFolderStore.loadAll().compactMap(\.colorHex))
            let f = EventFolder(slug: slug, name: name, description: "",
                                events: [], createdAtMs: now, updatedAtMs: now,
                                colorHex: creatingFolderHex
                                    ?? FolderPalette.assignHex(used: used))
            try EventFolderStore.save(f)
            await reload()
            actionStatus = "Created folder: \(name)"
        } catch {
            actionStatus = "Create folder failed: \(error.localizedDescription)"
        }
        creatingFolderSheet = false
        creatingFolderName = ""
        creatingFolderHex = nil
    }

    /// event 分到一个**新建** folder(名字 = 用户输入)。
    @MainActor
    private func assignEventToNewFolder(_ entry: Entry, name: String) async {
        let rel = Self.eventRelPath(of: entry.id)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var slug = EventFolderStore.makeSlug(from: name)
        // slug 冲突 → 加 -2/-3 后缀。
        if EventFolderStore.load(slug: slug) != nil {
            var n = 2
            while EventFolderStore.load(slug: "\(slug)-\(n)") != nil { n += 1 }
            slug = "\(slug)-\(n)"
        }
        do {
            // 先从旧 folder 摘掉,再建新 folder 放进去。
            try EventFolderStore.removeEventEverywhere(rel)
            // 创建时随机固化一色(07-10,同 createEmptyFolder)。
            let used = Set(EventFolderStore.loadAll().compactMap(\.colorHex))
            let f = EventFolder(slug: slug, name: name, description: "",
                                events: [rel], createdAtMs: now, updatedAtMs: now,
                                colorHex: FolderPalette.assignHex(used: used))
            try EventFolderStore.save(f)
            await reload()
            actionStatus = "Moved to new folder: \(name)"
        } catch {
            actionStatus = "Create folder failed: \(error.localizedDescription)"
        }
    }

    /// Entry.id(绝对 URL)→ "yyyy-MM-dd/foo.md" 相对路径,跟 folder.events 对齐。
    static func eventRelPath(of url: URL) -> String {
        let prefix = Storage.eventsDir.path + "/"
        return url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// event 行的右键菜单:分到 folder(列出现有 folder + 新建)/ 删除。
    /// 只在 events scope 有意义 —— 其它 scope 的行不挂这个。
    @ViewBuilder
    private func eventContextMenu(_ entry: Entry) -> some View {
        Menu("Move to folder") {
            // 当前所有 folder(读盘,轻量;folder 数量很小)。
            let folders = EventFolderStore.loadAll()
            if folders.isEmpty {
                Text("No folders yet")
            } else {
                ForEach(folders) { f in
                    Button(f.name) {
                        Task { await assignEventToFolder(entry, slug: f.slug) }
                    }
                }
            }
            Divider()
            Button("New folder…") {
                newFolderDraft = ""
                movingEntry = entry
            }
        }
        Divider()
        Button("Delete event", role: .destructive) { deletingEntry = entry }
    }

    @MainActor
    private func reload() async {
        refreshGen += 1
        let gen = refreshGen
        loading = true
        let currentScope = scope
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let order = currentSortOrder
        // folder split(loadAll 读盘 + 分组排序)跟 scan 一起在后台算好,
        // body 只消费缓存。非 events scope 用不上分组,不白读 _folders/。
        let (loaded, split) = await Task.detached(priority: .userInitiated) {
            () -> ([Entry], (folders: [FolderGroup], ungrouped: [Entry])) in
            let loaded = Self.scan(scope: currentScope, halfLifeDays: halfLife, order: order)
            guard currentScope == .events else { return (loaded, ([], [])) }
            return (loaded, Self.makeFolderSplit(entries: loaded, order: order))
        }.value
        guard gen == refreshGen else { return }   // 期间有更新的刷新 → 丢弃本次
        entries = loaded
        folderGroups = split.folders
        ungroupedEntries = split.ungrouped
        loading = false
    }

    /// 只重算 folder 分组缓存,不重扫 entries。deleteEntry 这种「直接改
    /// entries、不走 reload」的路径用 —— folder 引用也变了(removeEventEverywhere),
    /// 得重读 _folders/。
    private func refreshFolderSplit() {
        guard scope == .events else { return }
        refreshGen += 1
        let gen = refreshGen
        let snapshot = entries
        let order = currentSortOrder
        Task.detached(priority: .userInitiated) {
            let split = Self.makeFolderSplit(entries: snapshot, order: order)
            await MainActor.run {
                guard gen == refreshGen else { return }   // 期间有更新的刷新 → 丢弃
                folderGroups = split.folders
                ungroupedEntries = split.ungrouped
            }
        }
    }

    // MARK: - Disk scan

    /// Walks the appropriate root (events/ or portrait/<cat>/) for the
    /// current scope. Off the main actor.
    nonisolated private static func scan(scope: MemoryScope, halfLifeDays: Double, order: MemorySortOrder) -> [Entry] {
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
        return Self.sortedByConfig(out, order: order)
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
/// folder 颜色:预设色板 + hex 解析 + 默认 hash 色。UI 改色存 hex 到
/// EventFolder.colorHex;没设过按 name hash 出默认色("第一次随机")。
enum FolderPalette {
    struct Swatch { let name: String; let hex: String }

    /// 随机分配/默认色的预设池(07-10 起 UI 不再展示——选色一律走光谱;
    /// 仅供 assignHex 随机固化与 defaultHex 兜底取色)。
    static let swatches: [Swatch] = [
        Swatch(name: "Blue",    hex: "#5C8DE8"),
        Swatch(name: "Green",   hex: "#76BD80"),
        Swatch(name: "Orange",  hex: "#E6944D"),
        Swatch(name: "Purple",  hex: "#B87BDC"),
        Swatch(name: "Pink",    hex: "#EB7390"),
        Swatch(name: "Teal",    hex: "#57B5C7"),
        Swatch(name: "Gold",    hex: "#DBBC5C"),
        Swatch(name: "Red",     hex: "#E0605F"),
        Swatch(name: "Gray",    hex: "#9AA0A6"),
    ]

    /// 默认色兜底(只给还没固化颜色的瞬间用,创建/迁移都会写死 colorHex):
    /// djb2 稳定 hash 取预设色。⚠️ 不能用 Swift hashValue —— 每次启动随机化
    /// 种子,"同名每次同色"只在同一次启动内成立,跨启动漂移(07-10 修:
    /// 没设色的 folder 每次启动换色的历史遗留根因)。
    static func defaultTint(for title: String) -> Color {
        color(fromHex: defaultHex(for: title)) ?? .blue
    }

    /// djb2 稳定默认色 hex(text 与 canvas 两侧共用同一算法,观感一致)。
    static func defaultHex(for title: String) -> String {
        var h: UInt32 = 5381
        for b in title.utf8 { h = (h &* 33) &+ UInt32(b) }
        return swatches[Int(h % UInt32(swatches.count))].hex
    }

    /// 创建时随机分配(07-10 用户定稿"随机色生成之后就不会变"):从预设池
    /// 随机取一个,结果由调用方写进 colorHex 落盘、此后永不变。
    /// - 池子排除 Gray(灰 = 未分组/Unclassified 的观感,避免新 folder 与
    ///   之撞脸;用户手选 Gray 不受限)。
    /// - 优先选当前没被任何 folder 占用的色(治"颜色冲突"),全被占则纯随机。
    static func assignHex(used: Set<String>) -> String {
        let pool = swatches.filter { $0.name != "Gray" }.map(\.hex)
        let free = pool.filter { !used.contains($0) }
        return (free.isEmpty ? pool : free).randomElement() ?? swatches[0].hex
    }

    /// "#RRGGBB" → Color。失败返回 nil。
    static func color(fromHex hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue:  Double(v & 0xFF) / 255
        )
    }

    static func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green:   CGFloat((v >> 8) & 0xFF) / 255,
            blue:    CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    /// NSColor → "#RRGGBB"(sRGB;光谱取色回读用)。转不了 sRGB 返回 nil。
    static func hex(from color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

/// 系统取色板(NSColorPanel:光谱/色轮/滑杆,即"炫彩调色盘")桥接:
/// 右键 Custom… 打开,持续回传 hex(07-10 用户"9 个预设不够,要 spectrum")。
/// 单例复用共享面板;换 folder 重开时旧回调被顶掉(target/action 覆盖)。
/// @MainActor:NSColorPanel 主线程隔离,action 回调也由 AppKit 在主线程发。
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onPick: ((String) -> Void)?

    func present(initialHex: String?, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let hex = initialHex, let c = FolderPalette.nsColor(fromHex: hex) {
            panel.color = c
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        if let hex = FolderPalette.hex(from: sender.color) { onPick?(hex) }
    }
}

private struct FolderDisclosureRow: View {
    let title: String
    let count: Int
    let colorHex: String?
    let entries: [MemoriesView.Entry]
    let selected: URL?
    let onSelect: (MemoriesView.Entry) -> Void
    /// 点删除按钮 + 确认后调。只取消分组(删 _folders json),不删事件。
    let onDelete: () -> Void
    /// 右键 Rename → 拿到新名字回调。
    let onRename: (String) -> Void
    /// 右键 Change color → 选了预设色(hex)回调;nil = 恢复默认色。
    let onSetColor: (String?) -> Void
    /// 展开后每个 event 行的右键菜单(分 folder / 删除)。由 MemoriesView 构造。
    @ViewBuilder let eventMenu: (MemoriesView.Entry) -> AnyView

    @State private var expanded: Bool = false
    /// 只跟踪指针是否在删除按钮本身上(不是整行)。
    @State private var trashHover: Bool = false
    @State private var confirmingDelete: Bool = false
    @State private var renaming: Bool = false
    @State private var renameDraft: String = ""
    /// 光谱取色的防抖提交(NSColorPanel 拖动持续回调,0.25s 静默才落盘)。
    @State private var colorCommitTask: Task<Void, Never>? = nil

    private var tint: Color {
        // 用户设过颜色 → 用它;否则按 name hash 出默认色("第一次随机")。
        if let hex = colorHex, let c = FolderPalette.color(fromHex: hex) { return c }
        return FolderPalette.defaultTint(for: title)
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
            // 右键菜单:改名 / 改颜色(预设色板)/ 删除。右键时蓝框框住标题行。
            .contextHighlight(cornerRadius: 8) {
                Button("Rename…") { renameDraft = title; renaming = true }
                Menu("Change color") {
                    // 光谱取色(07-10 用户定稿"不要 9 色,直接 spectrum"):系统
                    // NSColorPanel。持续回调防抖 0.25s 再落盘 —— onSetColor
                    // 会整列表 reload,拖光谱逐 tick 提交会打爆。
                    Button("Spectrum…") {
                        ColorPanelBridge.shared.present(initialHex: colorHex) { hex in
                            colorCommitTask?.cancel()
                            colorCommitTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                if !Task.isCancelled { onSetColor(hex) }
                            }
                        }
                    }
                    Divider()
                    Button("Default") { onSetColor(nil) }
                }
                Divider()
                Button("Delete folder", role: .destructive) { confirmingDelete = true }
            }
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
            .alert("Rename folder", isPresented: $renaming) {
                TextField("Folder name", text: $renameDraft)
                Button("Save") {
                    let n = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !n.isEmpty, n != title { onRename(n) }
                }
                Button("Cancel", role: .cancel) {}
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
                            .contextHighlight(cornerRadius: 6) { eventMenu(entry) }
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
            return "No portrait entries in this category yet."
        }
    }
}

/// Refresh / icon-only Button + 即时 hover label。系统 .help() 要停留 ~2 秒,
/// 跟 sidebar NavIconButton 同款做法:hover 时立刻在 button 下方浮一个小气泡 label,
/// .help 留作 VoiceOver / 系统层 fallback。本地 struct 持有自己的 hover state
/// 避免触发外层 MemoriesView body 重新 render。
private struct IconHoverButton: View {
    let systemImage: String
    let tooltip: String
    let systemHelp: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bouncyIcon)
        .help(systemHelp)
        .onHover { hover = $0 }
        .overlay(alignment: .bottom) {
            if hover {
                Text(tooltip)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6))
                    )
                    .fixedSize()
                    .offset(y: 22)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(999)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// 顶部 Create folder 按钮唤起的 sheet。Name + 9 个预设色 + Default(随机 hash)。
/// 颜色选项跟 FolderPalette.swatches 同源 —— 改色板这里自动跟随。
private struct NewFolderSheet: View {
    @Binding var name: String
    @Binding var hex: String?
    let onCancel: () -> Void
    let onCreate: () -> Void

    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New folder")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. My-Portrait", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                    .focused($nameFocused)
                    .onSubmit { if !trimmed.isEmpty { onCreate() } }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                // 内嵌光谱(07-10 用户定稿"不要 9 色,直接 spectrum 嵌入"):
                // 点/拖即选;不选 = 创建时随机固化一色。
                SpectrumPicker(hex: $hex)
                HStack(spacing: 8) {
                    Text(hex == nil
                         ? "No color picked — a random palette color is assigned and kept."
                         : "Selected \(hex ?? "")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if hex != nil {
                        Button("Clear") { hex = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }
}

/// 内嵌光谱取色(07-10 用户定稿"不要 9 色,直接 spectrum 嵌入"):x=色相,
/// y=上半掺白(亮)→中线纯色→下半掺黑(暗),同 NSColorPanel Spectrum 页
/// 观感。点/拖即选,写 "#RRGGBB" 进 binding。
private struct SpectrumPicker: View {
    @Binding var hex: String?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: (0...12).map {
                    Color(hue: Double($0) / 12, saturation: 1, brightness: 1)
                }, startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white.opacity(0), location: 0.5),
                    .init(color: .black.opacity(0), location: 0.5),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                if let pos = indicator(in: size) {
                    ZStack {
                        Circle().stroke(.black.opacity(0.6), lineWidth: 3)
                        Circle().stroke(.white, lineWidth: 1.5)
                    }
                    .frame(width: 14, height: 14)
                    .position(pos)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    pick(at: v.location, in: size)
                }
            )
        }
        .frame(height: 110)
    }

    private func pick(at p: CGPoint, in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let fx = min(max(p.x / size.width, 0), 1)
        let fy = min(max(p.y / size.height, 0), 1)
        let sat = fy <= 0.5 ? fy * 2 : 1
        let bri = fy <= 0.5 ? 1 : 1 - (fy - 0.5) * 2
        let c = NSColor(hue: fx, saturation: sat, brightness: bri, alpha: 1)
        hex = FolderPalette.hex(from: c)
    }

    /// 当前 hex 在光谱上的指示点(反解 HSB;光谱表不了的组合取最近似位置)。
    private func indicator(in size: CGSize) -> CGPoint? {
        guard let hx = hex, let ns = FolderPalette.nsColor(fromHex: hx),
              let c = ns.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let fy = b > 0.99 ? s / 2 : 0.5 + (1 - b) / 2
        return CGPoint(x: h * size.width, y: fy * size.height)
    }
}
