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

    @State private var activeApps: [ActiveAppEntry] = []
    @State private var audioItems: [AudioTranscriptEntry] = []
    @State private var loading: Bool = false
    @State private var recentsSearch: String = ""
    @State private var recentsSearchOpen: Bool = false
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

    /// Frosted glass vs solid dark backdrop, controlled by
    /// `config.display.translucentSidebar`. Either way the glass cards float
    /// over it.
    @ViewBuilder private var sidebarBackground: some View {
        if ConfigStore.shared.display.translucentSidebar {
            // `.ignoresSafeArea()` must be inside this branch — the bare
            // Rectangle would otherwise stop at the title-bar inset and leave
            // a black strip across the top of the sidebar.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                SidebarBackdrop().opacity(0.55)
            }
            .ignoresSafeArea()
        } else {
            SidebarBackdrop()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
            Text("My Portrait")
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

    /// Wraps a section's header + rows in a floating glass card.
    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
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
                    }
                }
            }
        }
    }

    // MARK: Recents (chat conversations)

    private var recentsSection: some View {
        sectionCard {
            HStack(spacing: Theme.Space.sm) {
                SectionHeader(title: "RECENTS", count: filteredConversations.count)
                SidebarIconButton(
                    systemName: recentsSearchOpen ? "xmark" : "magnifyingglass",
                    help: "Search chats"
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        recentsSearchOpen.toggle()
                        if !recentsSearchOpen { recentsSearch = "" }
                    }
                }
                SidebarIconButton(systemName: "plus", help: "New chat") {
                    chat.switchTo(nil)
                }
            }

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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
    private var cronJobHistoryConversations: [Conversation] {
        let q = cronHistorySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let base = chatStore.conversations.filter { cronJobConvIds.contains($0.id) }
        guard !q.isEmpty else { return base }
        return base.filter { $0.title.lowercased().contains(q) }
    }

    // MARK: Memories scope picker (shown when selection == .memories)

    private var memoryScopeSection: some View {
        sectionCard {
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
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            Button("Clear \(cronJobHistoryConversations.count) run(s)", role: .destructive) {
                let active = chat.currentConvId
                let ids = cronJobHistoryConversations.map { $0.id }
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
        loading = true
        Task {
            let apps = (try? await db.activeAppsAround(
                timestamp: moment, windowSeconds: 45
            )) ?? []
            let audio = (try? await db.audioTranscriptsAround(
                timestamp: moment, beforeSeconds: 120, afterSeconds: 30
            )) ?? []
            await MainActor.run {
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
        .help(section.label)
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
