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

    private let db = ScreenpipeDB()

    @State private var activeApps: [ActiveAppEntry] = []
    @State private var audioItems: [AudioTranscriptEntry] = []
    @State private var loading: Bool = false

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
