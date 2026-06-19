import SwiftUI
import AppKit

/// The app's left sidebar.
/// Top: "My Portrait" title + section nav.
/// Body: floating glass cards holding live context for the current section:
///   - Active Apps: every distinct app/window seen within ±45s
///   - Audio: transcript chunks within the recent window (favours -120s..+30s)
///
/// When the user is not on the Timeline section, body shows the relevant
/// list (Recents / Memories scope / Cron Jobs / Settings) or a friendly
/// placeholder.
struct TimelineSidebar: View {
    let state: TimelineState
    @Binding var selection: SidebarSection?
    let chat: ChatController
    @Binding var memoryScope: MemoryScope
    @Binding var cronJobSelection: UUID?
    @Binding var settingsSubsection: SettingsSubsection?

    @State private var cronJobStore = CronJobStore.shared
    @State private var editingCronJob: CronJob? = nil

    @Environment(ChatStore.self) private var chatStore
    @Environment(\.services) private var services
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeApps: [ActiveAppEntry] = []
    @State private var audioItems: [AudioTranscriptEntry] = []
    @State private var loading: Bool = false
    /// reload 代际号 —— 丢弃慢的旧结果,避免盖掉新的(防 stale clobber)。
    @State private var reloadToken = 0
    @State private var recentsSearch: String = ""
    @State private var recentsSearchOpen: Bool = false
    /// RECENTS 折叠态。默认展开(false)—— 它是侧栏主入口,不像 cron history 那样
    /// 默认收起。
    @State private var recentsCollapsed: Bool = false
    @State private var renamingConvId: UUID? = nil
    @State private var renameDraft: String = ""
    @State private var cronJobHistoryCollapsed: Bool = true
    @State private var cronHistorySearch: String = ""
    @State private var cronHistorySearchOpen: Bool = false
    @State private var confirmingClearCronHistory: Bool = false

    private var focusedFrame: TimelineFrame? {
        guard state.frames.indices.contains(state.focusIndex) else { return nil }
        return state.frames[state.focusIndex]
    }

    private var focusedTimestamp: Date? { focusedFrame?.timestamp }

    /// Solid dark backdrop. 原来还有个 translucent(毛玻璃)分支由
    /// `translucentSidebar` toggle 切换,该开关已下线 —— 固定实色。
    @ViewBuilder private var sidebarBackground: some View {
        SidebarBackdrop()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if selection == .timeline {
                        if focusedTimestamp != nil {
                            activeAppsSection
                            audioSection
                        } else {
                            placeholderCard(
                                symbol: "clock",
                                text: "Pick a moment in the timeline\nto see context.")
                        }
                    } else if selection == .home || selection == .cronJobs {
                        cronJobsSection
                        cronJobHistorySection
                        recentsSection
                    } else if selection == .memories {
                        memoryScopeSection
                    } else if selection == .settings {
                        settingsListSection
                    } else {
                        placeholderCard(
                            symbol: (selection ?? .timeline).symbol,
                            text: "Switch to Timeline\nfor live context.")
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xl)
            }
            // 高亮转录行换了(切帧导致最近行变 / 列表更新)→ 滚到视口中心,
            // 长列表时不再沉到看不见的底端 / 顶端。entry id 已稳定,内容/高亮
            // 没变时这个值不变,不触发无谓滚动。
            .onChange(of: activeAudioId) { scrollActiveAudioToCenter(proxy) }
            }
        }
        .background(sidebarBackground.ignoresSafeArea())
        .navigationTitle("")
        .onAppear { reload() }
        .onChange(of: state.focusIndex) { reload() }
        .onChange(of: state.frames.count) { reload() }
        .onChange(of: selection) { reload() }
    }

    // MARK: header (title + nav rail)

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // App customize:跟 mainWindow.title 走同一份 config.display.appName,
            // 空串 → fallback "My Portrait"。改名 + 重启后这里跟着变。
            Text(Self.effectiveAppName())
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Space.xs) {
                ForEach([SidebarSection.timeline, .home, .memories, .settings], id: \.self) { item in
                    NavIconButton(section: item, isSelected: selection == item) {
                        selection = item
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.md)
    }

    // MARK: section card wrapper

    /// Wraps a section's header + rows in a solid 深色卡片。原来还有个
    /// Liquid Glass 分支由 "Translucent sidebar" toggle 切换,该开关已下线 ——
    /// 固定实色(可读性优先)。
    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let card = VStack(alignment: .leading, spacing: Theme.Space.sm) {
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)

        // **fill / stroke 必须跟着 colorScheme 切** —— 之前钉死 white-on-X
        // 在 Light 主题侧栏(奶白 + 浅薰衣草)上完全融成一片,看不见卡片
        // 边界。Dark 仍是白底浮起,Light 改成 black 低透明做"压下去"的卡边。
        let fill   = colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.05)
        let stroke = colorScheme == .light ? Color.black.opacity(0.10) : Color.white.opacity(0.08)
        card.background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(stroke, lineWidth: 0.8)
                )
        )
    }

    private func placeholderCard(symbol: String, text: String) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .glassCard()
    }

    // MARK: Active Apps

    private var activeAppsSection: some View {
        sectionCard {
            SectionHeader(title: "ACTIVE APPS", count: activeApps.count)
            if activeApps.isEmpty && !loading {
                EmptyRow(text: "No apps captured at this moment.")
            } else {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(activeApps) { entry in
                        ActiveAppRow(entry: entry)
                    }
                }
            }
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        sectionCard {
            SectionHeader(title: "AUDIO", count: audioItems.count)
            if audioItems.isEmpty && !loading {
                EmptyRow(text: "No audio in the surrounding window.")
            } else {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(audioItems) { entry in
                        AudioRow(entry: entry, focusTime: focusedTimestamp ?? Date())
                            .id(entry.id)
                    }
                }
            }
        }
    }

    /// 当前焦点时刻附近(<8s,跟 AudioRow 高亮阈值一致)最接近的转录行 ——
    /// 切帧后把它滚到视口中心。焦点离所有转录都远(没高亮行)→ nil,不滚。
    private func activeAudioEntry() -> AudioTranscriptEntry? {
        guard let ft = focusedTimestamp else { return nil }
        return audioItems
            .filter { abs($0.timestamp.timeIntervalSince(ft)) < 8 }
            .min { abs($0.timestamp.timeIntervalSince(ft)) < abs($1.timestamp.timeIntervalSince(ft)) }
    }

    /// 滚动触发用:高亮行的稳定 id。**只在它变化时**滚动(onChange 比这个) ——
    /// 现在 entry id 稳定了,窗口内容没变 / 高亮行没换时不触发滚动,免无谓动效。
    private var activeAudioId: AudioTranscriptEntry.ID? { activeAudioEntry()?.id }

    /// 把高亮转录行滚到视口中心。下一拍执行 —— 等新 audioItems 的行布局好,
    /// scrollTo 才能命中 id。
    private func scrollActiveAudioToCenter(_ proxy: ScrollViewProxy) {
        guard selection == .timeline, let active = activeAudioEntry() else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(active.id, anchor: .center)
            }
        }
    }

    // MARK: Recents (chat conversations)

    private var recentsSection: some View {
        sectionCard {
            HStack(spacing: Theme.Space.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        recentsCollapsed.toggle()
                        if recentsCollapsed {
                            recentsSearchOpen = false
                            recentsSearch = ""
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: recentsCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 10)
                        SectionHeader(title: "RECENTS", count: filteredConversations.count)
                    }
                    // 整行可点折叠 + y 轴命中区靠 minHeight 撑(同 CRON JOB HISTORY)。
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 搜索只在展开时显示(折叠态搜索无意义)。
                if !recentsCollapsed {
                    SidebarIconButton(
                        systemName: recentsSearchOpen ? "xmark" : "magnifyingglass",
                        help: "Search chats"
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            recentsSearchOpen.toggle()
                            if !recentsSearchOpen { recentsSearch = "" }
                        }
                    }
                }
                // 新建 ➕ 常驻 —— 折叠态也能直接开新对话,不跟着折叠隐藏。
                SidebarIconButton(systemName: "plus", help: "New chat") {
                    chat.switchTo(nil)
                }
            }
            .frame(minHeight: 24)

            if !recentsCollapsed {
              if recentsSearchOpen {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("filter chats…", text: $recentsSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.7))
                )
                .transition(.opacity)
              }

              if filteredConversations.isEmpty {
                EmptyRow(text: recentsSearch.isEmpty
                         ? "No chats yet — start typing below."
                         : "No chats match \"\(recentsSearch)\".")
              } else {
                VStack(spacing: 2) {
                    ForEach(filteredConversations) { conv in
                        RecentRow(
                            conv: conv,
                            isActive: chat.currentConvId == conv.id,
                            isRenaming: renamingConvId == conv.id,
                            renameDraft: $renameDraft,
                            onTap: {
                                if renamingConvId == nil {
                                    chat.switchTo(conv.id)
                                    // 若主面板正停在 CronJobsView,切回 Home 让聊天显示出来。
                                    if selection == .cronJobs { selection = .home }
                                }
                            },
                            onStartRename: {
                                renameDraft = conv.title
                                renamingConvId = conv.id
                            },
                            onCommitRename: {
                                if !renameDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                                    chatStore.renameConversation(conv.id, to: renameDraft.trimmingCharacters(in: .whitespaces))
                                }
                                renamingConvId = nil
                            },
                            onCancelRename: { renamingConvId = nil },
                            onTogglePin: { chatStore.togglePinned(conv.id) },
                            onDelete: {
                                let wasActive = chat.currentConvId == conv.id
                                chatStore.deleteConversation(conv.id)
                                if wasActive { chat.switchTo(nil) }
                            }
                        )
                    }
                }
              }
            }   // if !recentsCollapsed
        }
    }

    /// 所有 cron job 跑过的 conv id 集合 —— 用来从 RECENTS 里过滤掉、单独
    /// 归到 CRON JOB HISTORY 分区。
    private var cronJobConvIds: Set<UUID> {
        Set(cronJobStore.cronJobs.flatMap { $0.runs.map { $0.convId } })
    }

    /// RECENTS:只留普通聊天,把 cron job 跑出来的 conv 排除掉。
    private var filteredConversations: [Conversation] {
        let q = recentsSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let base = chatStore.conversations.filter { !cronJobConvIds.contains($0.id) }
        guard !q.isEmpty else { return base }
        return base.filter { $0.title.lowercased().contains(q) }
    }

    /// CRON JOB HISTORY:仅 cron job 跑出来的 conv,按 ChatStore 的时间序。
    /// cronHistorySearch 非空时按标题模糊过滤(case-insensitive)。
    /// 受 Settings → General → CronJob history limit 截断,0 = 不截。
    private var cronJobHistoryConversations: [Conversation] {
        let q = cronHistorySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let base = chatStore.conversations.filter { cronJobConvIds.contains($0.id) }
        let filtered: [Conversation]
        if q.isEmpty {
            filtered = base
        } else {
            filtered = base.filter { $0.title.lowercased().contains(q) }
        }
        let cap = ConfigStore.shared.current.general.cronJobHistoryLimit
        if cap > 0, filtered.count > cap {
            return Array(filtered.prefix(cap))
        }
        return filtered
    }

    // MARK: Memories scope picker (shown when selection == .memories)

    private var memoryScopeSection: some View {
        sectionCard {
            scopeHeader("PROFILE")
            VStack(spacing: 2) {
                scopeRow(.personalInfo)
            }
            Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
            scopeHeader("PORTRAIT")
            VStack(spacing: 2) {
                ForEach(PortraitPaths.seedCategories, id: \.self) { cat in
                    scopeRow(.portrait(category: cat))
                }
            }
            Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
            scopeHeader("DATA")
            VStack(spacing: 2) {
                scopeRow(.events)
                scopeRow(.input)
            }
        }
    }

    private func scopeHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 2)
    }

    private func scopeRow(_ s: MemoryScope) -> some View {
        let isOn = memoryScope == s
        return Button {
            memoryScope = s
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: s.systemImage)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                Text(s.displayName)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isOn ? Theme.accent.opacity(0.16) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
            )
            // 整行(含 Spacer 空白区)都可点击,而不只是 icon + text 像素。
            // Button 默认 hit-test 只在 label 内容上,不加这条只能点 icon
            // 或文字才选中。跟 RecentRow / CronJobSidebarRow / SettingsSidebarRow
            // 同款修法。(#7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncyIcon)
    }

    // MARK: Cron Job History (折叠分区,跟 RECENTS 同样的标题行样式)

    private var cronJobHistorySection: some View {
        sectionCard {
            // 标题 + 折叠箭头 + 搜索 + 一键清除(展开时才显示后两个,
            // 避免折叠态噪声)
            HStack(spacing: Theme.Space.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        cronJobHistoryCollapsed.toggle()
                        // 折叠时顺手关搜索 + 清空 query
                        if cronJobHistoryCollapsed {
                            cronHistorySearchOpen = false
                            cronHistorySearch = ""
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: cronJobHistoryCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 10)
                        SectionHeader(title: "CRON JOB HISTORY", count: cronJobHistoryConversations.count)
                    }
                    // 整个标题行(含右侧空白)都可点折叠 —— Button 默认 hit-test
                    // 只在 chevron+文字像素上,点标题右边的空白没反应,显得"不灵敏"。
                    // 撑满 + contentShape 让整条都是命中区。y 轴命中区靠下面
                    // header HStack 的 minHeight(24)撑出来,**不再用 padding 撑高
                    // 卡片本身** —— padding 会把卡片实际变高(用户反馈)。
                    // 命中形状用 minHeight 高度的 Rectangle,撑满整个 header 行。
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 折叠 Button 已 maxWidth:.infinity 撑满左侧,这里不再加贪婪
                // Spacer —— 两个都贪婪会平分宽度,把 button 命中区压到半行。
                if !cronJobHistoryCollapsed {
                    SidebarIconButton(
                        systemName: cronHistorySearchOpen ? "xmark" : "magnifyingglass",
                        help: "Search history"
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            cronHistorySearchOpen.toggle()
                            if !cronHistorySearchOpen { cronHistorySearch = "" }
                        }
                    }
                    SidebarIconButton(systemName: "trash", help: "Clear all history") {
                        confirmingClearCronHistory = true
                    }
                }
            }
            // header 行锁定最小高 24(= SidebarIconButton 高)。展开时搜索/垃圾桶
            // 图标(24pt)才出现,不锁高度的话 header 会从"一行小字"撑到 24pt,
            // 把下面内容往下顶 —— 就是用户说的"展开往下蹭一点"。
            .frame(minHeight: 24)

            if !cronJobHistoryCollapsed {
                if cronHistorySearchOpen {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                        TextField("filter history…", text: $cronHistorySearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 0.7))
                    )
                    // 纯淡入,不要 .move(edge:.top) —— 位移会让展开瞬间整块往下
                    // "蹭"一下再回弹。opacity 只渐显不移位。
                    .transition(.opacity)
                }

                if cronJobHistoryConversations.isEmpty {
                    EmptyRow(text: cronHistorySearch.isEmpty
                             ? "No runs yet."
                             : "No history matches \"\(cronHistorySearch)\".")
                } else {
                    VStack(spacing: 2) {
                        ForEach(cronJobHistoryConversations) { conv in
                            RecentRow(
                                conv: conv,
                                isActive: chat.currentConvId == conv.id,
                                isRenaming: renamingConvId == conv.id,
                                renameDraft: $renameDraft,
                                onTap: {
                                    if renamingConvId == nil {
                                        chat.switchTo(conv.id)
                                        if selection == .cronJobs { selection = .home }
                                    }
                                },
                                onStartRename: {
                                    renameDraft = conv.title
                                    renamingConvId = conv.id
                                },
                                onCommitRename: {
                                    let v = renameDraft.trimmingCharacters(in: .whitespaces)
                                    if !v.isEmpty {
                                        chatStore.renameConversation(conv.id, to: v)
                                    }
                                    renamingConvId = nil
                                },
                                onCancelRename: { renamingConvId = nil },
                                onTogglePin: { chatStore.togglePinned(conv.id) },
                                onDelete: {
                                    let wasActive = chat.currentConvId == conv.id
                                    chatStore.deleteConversation(conv.id)
                                    if wasActive { chat.switchTo(nil) }
                                }
                            )
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear all cron job history?",
            isPresented: $confirmingClearCronHistory,
            titleVisibility: .visible
        ) {
            Button("Clear \(Set(chatStore.conversations.map(\.id)).intersection(cronJobConvIds).count) run(s)", role: .destructive) {
                // 删**全部** cron-run 对话(uncapped/unfiltered),不只是分页/搜索后那
                // 一截 —— 否则超 cronJobHistoryLimit 的那些删不掉、UI 看不到却仍占库,
                // 跟对话框承诺的「删除全部」相悖。
                let active = chat.currentConvId
                let ids = Set(chatStore.conversations.map(\.id)).intersection(cronJobConvIds)
                for id in ids { chatStore.deleteConversation(id) }
                if let a = active, ids.contains(a) { chat.switchTo(nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every cron job run conversation. The cron jobs themselves stay.")
        }
    }

    // MARK: Cron Jobs (background AI workers)

    private var cronJobsSection: some View {
        sectionCard {
            HStack(spacing: Theme.Space.sm) {
                SectionHeader(title: "CRON JOBS", count: cronJobStore.cronJobs.count)
                SidebarIconButton(systemName: "plus", help: "New cron job") {
                    editingCronJob = CronJobsView.blankCronJob()
                }
            }

            if cronJobStore.cronJobs.isEmpty {
                EmptyRow(text: "No cron jobs yet — click + to create one.")
            } else {
                VStack(spacing: 2) {
                    ForEach(cronJobStore.cronJobs) { p in
                        CronJobSidebarRow(
                            cronJob: p,
                            isActive: cronJobSelection == p.id,
                            onTap: {
                                cronJobSelection = p.id
                                selection = .cronJobs
                            },
                            onToggle: { cronJobStore.toggleEnabled(p.id) }
                        )
                    }
                }
            }
        }
        .sheet(item: $editingCronJob) { cronJob in
            // Inline edit sheet so user can create a cronJob directly from the
            // sidebar — same content the main pane uses.
            CronJobQuickEditor(initial: cronJob) { saved in
                if cronJobStore.cronJobs.contains(where: { $0.id == saved.id }) {
                    cronJobStore.update(saved)
                } else {
                    cronJobStore.add(saved)
                }
                editingCronJob = nil
                cronJobSelection = saved.id
            } onCancel: { editingCronJob = nil }
        }
    }

    // MARK: Settings (subsections grouped in the rail)

    private var settingsListSection: some View {
        sectionCard {
            ForEach([SettingsSubsection.Group.app, .capture, .memory, .dataPrivacy], id: \.self) { grp in
                Text(grp.rawValue)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, grp == .app ? 0 : Theme.Space.sm)
                    .padding(.bottom, 2)
                VStack(spacing: 2) {
                    ForEach(SettingsSubsection.allCases.filter { $0.group == grp }) { s in
                        SettingsSidebarRow(
                            subsection: s,
                            isActive: settingsSubsection == s,
                            onTap: { settingsSubsection = s }
                        )
                    }
                }
            }
        }
    }

    // MARK: customize helper

    /// 读 config.display.appName,空串 fallback "My Portrait"。
    /// static —— header 是 computed var,每次 SwiftUI 重渲都重读。
    private static func effectiveAppName() -> String {
        let n = ConfigStore.shared.current.display.appName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "My Portrait" : n
    }

    // MARK: reload

    private func reload() {
        guard selection == .timeline, let moment = focusedTimestamp else {
            activeApps = []
            audioItems = []
            return
        }
        guard let db = services?.db else {
            activeApps = []
            audioItems = []
            return
        }
        reloadToken &+= 1
        let token = reloadToken
        loading = true
        Task {
            let apps = (try? await db.activeAppsAround(
                timestamp: moment, windowSeconds: 45
            )) ?? []
            let audio = (try? await db.audioTranscriptsAround(
                timestamp: moment, beforeSeconds: 120, afterSeconds: 30
            )) ?? []
            await MainActor.run {
                guard token == reloadToken else { return }   // 已有更新的 reload,丢弃这次旧结果
                self.activeApps = apps
                self.audioItems = audio
                self.loading = false
            }
        }
    }
}

// MARK: - Section pieces

private struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent.opacity(0.16)))
            }
            Spacer()
        }
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.vertical, Theme.Space.xs)
    }
}


/// Compact glass icon button used for the +/search affordances inside cards.
private struct SidebarIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(hover ? Theme.active : Theme.hover)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.8))
                )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct NavIconButton: View {
    let section: SidebarSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: section.symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30, height: 30)
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.16)
                              : hover ? Theme.hover : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .strokeBorder(isSelected ? Theme.accent.opacity(0.40) : .clear,
                                              lineWidth: 1))
                )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
        // 系统 .help() tooltip 要停留 ~2 秒才弹,太慢。hover 时直接在 icon
        // 下方浮一个小气泡 label,即时反馈分区名。
        .overlay(alignment: .bottom) {
            if hover {
                Text(section.label)
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
                    .offset(y: 26)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(999)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - Active app row

private struct ActiveAppRow: View {
    let entry: ActiveAppEntry

    private func displayURL(_ url: String) -> String {
        if let r = url.range(of: "://") {
            return String(url[r.upperBound...])
        }
        return url
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            RealAppIcon(appName: entry.appName, size: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !entry.windowName.isEmpty {
                    Text(entry.windowName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let url = entry.browserUrl, !url.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.textTertiary)
                        Text(displayURL(url))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - Audio row

private struct AudioRow: View {
    let entry: AudioTranscriptEntry
    let focusTime: Date

    private var displaySpeaker: String {
        if let n = entry.speakerName, !n.isEmpty { return n }
        if let id = entry.speakerId { return "Speaker \(id)" }
        return entry.device.isEmpty ? "Audio" : entry.device
    }

    private var isNearFocus: Bool {
        abs(entry.timestamp.timeIntervalSince(focusTime)) < 8
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.timeFmt.string(from: entry.timestamp))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Text(displaySpeaker)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: entry.isInput ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundStyle(isNearFocus ? Theme.textPrimary : Theme.textSecondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isNearFocus
                      ? Theme.accent.opacity(0.16)
                      : Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(isNearFocus ? Theme.accent.opacity(0.30) : .clear, lineWidth: 1))
        )
    }
}

// MARK: - Recents row

/// One conversation row. Click the row body to switch; double-click the
/// title (or right-click → Rename) to rename in place; hover surfaces
/// pin + delete; pin button toggles pinned state.
private struct RecentRow: View {
    let conv: Conversation
    let isActive: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onTap: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var hover = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if conv.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
            }
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($renameFocused)
                    .onSubmit { onCommitRename() }
                    .onExitCommand { onCancelRename() }
                    .onAppear { renameFocused = true }
            } else {
                Text(conv.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if hover, !isRenaming {
                Button(action: onTogglePin) {
                    Image(systemName: conv.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.bouncyIcon)
                .help(conv.pinned ? "Unpin" : "Pin")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.bouncyIcon)
                .help("Delete")
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isActive ? Theme.accent.opacity(0.16)
                      : hover ? Theme.hover
                      : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(isActive ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isRenaming { onStartRename() }
        }
        .onTapGesture(count: 1) {
            if !isRenaming { onTap() }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename", action: onStartRename)
            Button(conv.pinned ? "Unpin" : "Pin", action: onTogglePin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
