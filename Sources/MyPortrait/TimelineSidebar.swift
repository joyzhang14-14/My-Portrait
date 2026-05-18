import SwiftUI
import AppKit

/// The app's left sidebar — replaces the original navigation-only sidebar.
/// Top: "My Portrait" title + compact section nav icons.
/// Body: live context for the currently focused timeline frame:
///   - Active Apps: every distinct app/window seen within ±45s
///   - Audio: transcript chunks within the recent window (favours -120s..+30s)
///
/// When the user is not on the Timeline section, body shows a friendly
/// placeholder (AI / Connections / etc. don't have per-moment context).
struct TimelineSidebar: View {
    let state: TimelineState
    @Binding var selection: SidebarSection?
    let chat: ChatController
    @Binding var memoryScope: MemoryScope

    @Environment(ChatStore.self) private var chatStore

    private let db = ScreenpipeDB()

    @State private var activeApps: [ActiveAppEntry] = []
    @State private var audioItems: [AudioTranscriptEntry] = []
    @State private var loading: Bool = false
    @State private var recentsSearch: String = ""
    @State private var recentsSearchOpen: Bool = false
    @State private var renamingConvId: UUID? = nil
    @State private var renameDraft: String = ""

    private var focusedFrame: ScreenpipeFrame? {
        guard state.frames.indices.contains(state.focusIndex) else { return nil }
        return state.frames[state.focusIndex]
    }

    private var focusedTimestamp: Date? { focusedFrame?.timestamp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.horizontal, 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selection == .timeline {
                        if let _ = focusedTimestamp {
                            activeAppsSection
                            audioSection
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(.tertiary)
                                Text("Pick a moment in the timeline\nto see context.")
                                    .font(.system(size: 11))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                        }
                    } else if selection == .home {
                        recentsSection
                    } else if selection == .memories {
                        memoryScopeSection
                    } else {
                        otherSectionPlaceholder
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
        .navigationTitle("")
        .onAppear { reload() }
        .onChange(of: state.focusIndex) { reload() }
        .onChange(of: state.frames.count) { reload() }
        .onChange(of: selection) { reload() }
    }

    // MARK: header (title + compact nav icons)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("My Portrait")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            HStack(spacing: 4) {
                ForEach([SidebarSection.timeline, .home, .connections, .memories, .pipes], id: \.self) { item in
                    NavIconButton(
                        section: item,
                        isSelected: selection == item
                    ) {
                        selection = item
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: Active Apps

    private var activeAppsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "ACTIVE APPS", count: activeApps.count)

            if activeApps.isEmpty && !loading {
                EmptyRow(text: "No apps captured at this moment.")
            } else {
                VStack(spacing: 4) {
                    ForEach(activeApps) { entry in
                        ActiveAppRow(entry: entry)
                    }
                }
            }
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "AUDIO", count: audioItems.count)

            if audioItems.isEmpty && !loading {
                EmptyRow(text: "No audio in the surrounding window.")
            } else {
                VStack(spacing: 6) {
                    ForEach(audioItems) { entry in
                        AudioRow(entry: entry, focusTime: focusedTimestamp ?? Date())
                    }
                }
            }
        }
    }

    // MARK: Recents (chat conversations)

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionHeader(title: "RECENTS", count: filteredConversations.count)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        recentsSearchOpen.toggle()
                        if !recentsSearchOpen { recentsSearch = "" }
                    }
                } label: {
                    Image(systemName: recentsSearchOpen ? "xmark" : "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(recentsSearchOpen ? 0.12 : 0.06))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("Search chats")

                Button {
                    chat.switchTo(nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("New chat")
            }

            if recentsSearchOpen {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    TextField("filter chats…", text: $recentsSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 0.7))
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
                                if renamingConvId == nil { chat.switchTo(conv.id) }
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

    private var filteredConversations: [Conversation] {
        let q = recentsSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return chatStore.conversations }
        return chatStore.conversations.filter { $0.title.lowercased().contains(q) }
    }

    // MARK: Memories scope picker (shown when selection == .memories)

    private var memoryScopeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeHeader("PORTRAIT")
            ForEach(PortraitPaths.seedCategories, id: \.self) { cat in
                scopeRow(.portrait(category: cat))
            }
            Divider().padding(.vertical, 8)
            scopeHeader("EVENTS")
            scopeRow(.events)
        }
        .padding(.bottom, 8)
    }

    private func scopeHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
    }

    private func scopeRow(_ s: MemoryScope) -> some View {
        Button {
            memoryScope = s
        } label: {
            HStack(spacing: 8) {
                Image(systemName: s.systemImage)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(memoryScope == s ? .white : .secondary)
                Text(s.displayName)
                    .font(.system(size: 12, weight: memoryScope == s ? .semibold : .regular))
                    .foregroundStyle(memoryScope == s ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(memoryScope == s ? Color.accentColor.opacity(0.65) : .clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
    }

    // MARK: placeholder for non-Timeline sections

    private var otherSectionPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: (selection ?? .timeline).symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Switch to Timeline\nfor live context.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    // MARK: reload

    private func reload() {
        guard selection == .timeline, let moment = focusedTimestamp else {
            activeApps = []
            audioItems = []
            return
        }
        loading = true
        let dbRef = db
        Task {
            let apps = await Task.detached(priority: .userInitiated) {
                dbRef.activeApps(around: moment)
            }.value
            let audio = await Task.detached(priority: .userInitiated) {
                dbRef.audioTranscripts(around: moment)
            }.value
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
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
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
                .frame(width: 26, height: 26)
                .foregroundStyle(isSelected ? Color.white : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor :
                              hover ? Color.secondary.opacity(0.15) : .clear)
                )
        }
        .buttonStyle(.plain)
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
        HStack(alignment: .top, spacing: 8) {
            RealAppIcon(appName: entry.appName, size: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !entry.windowName.isEmpty {
                    Text(entry.windowName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let url = entry.browserUrl, !url.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(displayURL(url))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
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
                    .foregroundStyle(.tertiary)
                Text(displaySpeaker)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: entry.isInput ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundStyle(isNearFocus ? .primary : .secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isNearFocus
                      ? Color.accentColor.opacity(0.14)
                      : Color.secondary.opacity(0.05))
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
        HStack(spacing: 8) {
            if conv.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .focused($renameFocused)
                    .onSubmit { onCommitRename() }
                    .onExitCommand { onCancelRename() }
                    .onAppear { renameFocused = true }
            } else {
                Text(conv.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if hover, !isRenaming {
                Button(action: onTogglePin) {
                    Image(systemName: conv.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(conv.pinned ? "Unpin" : "Pin")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.white.opacity(0.10)
                      : hover ? Color.white.opacity(0.05)
                      : Color.clear)
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
