import SwiftUI
import AppKit

/// The app's left sidebar.
/// Top: "My Portrait" title + section nav.
/// Body: floating glass cards holding live context for the current section:
///   - Active Apps: every distinct app/window seen within ±45s
///   - Audio: transcript chunks within the recent window (favours -120s..+30s)
///
/// When the user is not on the Timeline section, body shows the relevant
/// list (Memories scope / Settings) or a friendly
/// placeholder.
struct TimelineSidebar: View {
    let state: TimelineState
    @Binding var selection: SidebarSection?
    @Binding var dataScope: DataScope
    @Binding var dataViewMode: DataViewMode
    @Binding var settingsSubsection: SettingsSubsection?

    @Environment(\.services) private var services
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeApps: [ActiveAppEntry] = []
    @State private var audioItems: [AudioTranscriptEntry] = []
    @State private var loading: Bool = false
    /// reload 代际号 —— 丢弃慢的旧结果,避免盖掉新的(防 stale clobber)。
    @State private var reloadToken = 0

    private var focusedFrame: TimelineFrame? {
        guard state.frames.indices.contains(state.focusIndex) else { return nil }
        return state.frames[state.focusIndex]
    }

    private var focusedTimestamp: Date? { focusedFrame?.timestamp }

    /// Solid dark backdrop —— 固定实色,不可切换。
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
                    } else if selection == .data {
                        // text/Neural Graph 模式切换钮:独立小卡,放 scope 卡上方。
                        // 卡比 sectionCard 更瘦(padding 6 vs 12,07-01 update),钮本身不变。
                        memoryViewModeCard
                        dataScopeSection
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
            // SignPainter(House Script Semibold)—— macOS 自带的手绘招牌体,
            // /System/Library/Fonts/Supplemental/SignPainter.ttc,每台 Mac 都有,
            // 不用打包字体。PostScript 名带 "-HouseScriptSemibold" 后缀,
            // **写 "SignPainter" 加载不到**,会静默回落成系统默认字体。
            //
            // ⚠️ 花体只有拉丁字形。用户把 appName 改成中文的话,系统会自动
            // 回落到默认字体 —— 不会缺字,只是花体白设。这是可接受的降级。
            //
            // 字号 34 比 SF 的 26 大不少:花体 x-height(小写字母主体高度)
            // 天生矮,同号数看着小一圈,不加上去撑不起标题。
            Text(Self.effectiveAppName())
                .font(.custom("SignPainter-HouseScriptSemibold", size: 34))
                .foregroundStyle(Theme.textPrimary)

        }
        .padding(.horizontal, Theme.Space.lg)
        // 页面切换条浮在窗口左上角(ContentView),标题让到它下面
        .padding(.top, Theme.Space.md + 26)
        .padding(.bottom, Theme.Space.md)
    }

    // MARK: section card wrapper

    /// Wraps a section's header + rows in a solid 深色卡片 —— 固定实色
    /// (可读性优先),不可切换。
    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let card = VStack(alignment: .leading, spacing: Theme.Space.sm) {
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)

        // **fill / stroke 必须跟着 colorScheme 切** —— 固定成同一组值会在
        // Light 主题侧栏(奶白 + 浅薰衣草)上跟背景融成一片,看不见卡片边界。
        // Dark 是白底浮起,Light 用 black 低透明做"压下去"的卡边。
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

    /// text/Neural Graph 切换钮的瘦身卡:同 sectionCard 的 fill/stroke,padding 减半
    ///(07-01 update:卡缩小,钮不变)。
    private var memoryViewModeCard: some View {
        let fill   = colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.05)
        let stroke = colorScheme == .light ? Color.black.opacity(0.10) : Color.white.opacity(0.08)
        return DataViewModeToggle(mode: $dataViewMode)
            .onChange(of: dataViewMode) {
                if dataViewMode == .text, dataScope == .neuralGraphSettings {
                    dataScope = .textSettings
                } else if dataViewMode == .neuralGraph, dataScope == .textSettings {
                    dataScope = .neuralGraphSettings
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .stroke(stroke, lineWidth: 0.8)
                    )
            )
    }

    // MARK: Memories scope picker (shown when selection == .data)

    private var dataScopeSection: some View {
        sectionCard {
            if dataViewMode == .neuralGraph {
                // Neural Graph 模式列:PROFILE 小分区(Personal Info,跟 text 模式对齐)
                // + GRAPH(Portrait 整图 / Events / Input 打字活动面积图)。
                scopeHeader("PROFILE")
                VStack(spacing: 2) {
                    scopeRow(.personalInfo)
                }
                Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
                scopeHeader("GRAPH")
                VStack(spacing: 2) {
                    scopeRowCustom(isOn: isPortraitScope,
                                   icon: "person.fill",
                                   title: "Portrait") {
                        if !isPortraitScope {
                            dataScope = .portrait(category: PortraitPaths.seedCategories[0])
                        }
                    }
                    scopeRow(.events)
                    scopeRow(.input)
                }
                // 无标题分区:Neural Graph 设置入口。
                Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
                VStack(spacing: 2) {
                    scopeRow(.neuralGraphSettings)
                }
            } else {
                scopeHeader("PROFILE")
                VStack(spacing: 2) {
                    scopeRow(.personalInfo)
                }
                Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
                scopeHeader("PORTRAIT")
                VStack(spacing: 2) {
                    // emotions 前端下线(08-10 update):入口不再显示。目录、
                    // pipeline(distillCategories)与 dev 种子数据都还在 ——
                    // 彻底移除是挂账的后续任务,别在这里顺手删数据。
                    ForEach(PortraitPaths.seedCategories.filter { $0 != "emotions" },
                            id: \.self) { cat in
                        scopeRow(.portrait(category: cat))
                    }
                }
                Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
                scopeHeader("DATA")
                VStack(spacing: 2) {
                    scopeRow(.events)
                    scopeRow(.input)
                }
                // 无标题分区:Text 设置入口。
                Divider().overlay(Theme.stroke).padding(.vertical, Theme.Space.xs)
                VStack(spacing: 2) {
                    scopeRow(.textSettings)
                }
            }
        }
    }

    private var isPortraitScope: Bool {
        if case .portrait = dataScope { return true }
        return false
    }

    private func scopeHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 2)
    }

    private func scopeRow(_ s: DataScope) -> some View {
        scopeRowCustom(isOn: dataScope == s, icon: s.systemImage, title: s.displayName) {
            dataScope = s
            // Neural Graph 模式下点 Personal Info **不**切回 text:
            // toggle 保持 Neural Graph,主面板由 ContentView 按「该 scope 无
            // 图谱形态」自动落到表单;再点 Portrait/Events 直接回图谱。
        }
    }

    /// scope 行的通用外观(Neural Graph 模式的聚合 "Portrait" 行复用)。
    private func scopeRowCustom(isOn: Bool, icon: String, title: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                Text(title)
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
            // 或文字才选中。跟 SettingsSidebarRow
            // 同款修法。(#7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncyIcon)
    }

    // MARK: Settings (subsections grouped in the rail)

    private var settingsListSection: some View {
        sectionCard {
            ForEach([SettingsSubsection.Group.app, .capture, .workflow, .dataPrivacy], id: \.self) { grp in
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
        // 侧栏一露面就算一次未命名簇数量,决定 Audio Capture 那行点不点红点。
        .task { UnidentifiedSpeakerBadge.shared.refresh() }
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
            let apps = await TimelineFeed.activeAppsAround(
                moment, windowSeconds: 45, db: db)
            let audio = await TimelineFeed.audioTranscriptsAround(
                moment, beforeSeconds: 120, afterSeconds: 30, db: db)
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
