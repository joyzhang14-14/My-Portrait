import SwiftUI
import AppKit
import Observation

// =============================================================================
// MARK: - TimelineState (reference type — needed so NSEvent closures can mutate)
// =============================================================================

@Observable
final class TimelineState {
    var selectedDay: Date = Date()
    var frames: [ScreenpipeFrame] = []
    var loading: Bool = false
    var focusIndex: Int = 0
}

struct TimelineView: View {
    /// Hoisted to ContentView so the sidebar can share the same focus/frames.
    let state: TimelineState
    private let db = ScreenpipeDB()

    private var currentFrame: ScreenpipeFrame? {
        guard state.frames.indices.contains(state.focusIndex) else { return nil }
        return state.frames[state.focusIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineControlsBar(
                currentDate: Binding(
                    get: { state.selectedDay },
                    set: { state.selectedDay = $0 }
                ),
                onRefresh: { reload() }
            )
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Browser URL bar — fixed-height slot so the screenshot below NEVER
            // moves vertically when switching between frames with / without URLs.
            let hasURL = !(currentFrame?.browserUrl?.isEmpty ?? true)
            BrowserURLBar(url: currentFrame?.browserUrl ?? "")
                .opacity(hasURL ? 1 : 0)
                .frame(height: 34)              // locked height — no layout shift
                .padding(.horizontal, 80)
                .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.06))

            ZStack {
                if state.frames.isEmpty {
                    EmptyState(loading: state.loading, hasDB: db.exists)
                } else {
                    FramePreview(frame: state.frames[min(state.focusIndex, state.frames.count - 1)])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !state.frames.isEmpty {
                TimelineSlider(state: state)
                    .frame(height: 220)
                    .clipped()           // prevent bars from bleeding past pane edge
            }
        }
        .background(Color.black)
        .clipped()                       // belt + suspenders — pane never overflows
        // Listen for app-wide arrow-key notifications (posted by AppKeyboard).
        .onReceive(NotificationCenter.default.publisher(for: .leftArrowPressed)) { note in
            guard !state.frames.isEmpty else { return }
            let isAlt = (note.object as? Bool) ?? false
            state.focusIndex = isAlt
                ? Self.previousAppBoundary(in: state.frames, from: state.focusIndex)
                : max(0, state.focusIndex - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rightArrowPressed)) { note in
            guard !state.frames.isEmpty else { return }
            let isAlt = (note.object as? Bool) ?? false
            state.focusIndex = isAlt
                ? Self.nextAppBoundary(in: state.frames, from: state.focusIndex)
                : min(state.frames.count - 1, state.focusIndex + 1)
        }
        .task(id: state.selectedDay) { reload() }
    }

    static func previousAppBoundary(in frames: [ScreenpipeFrame], from idx: Int) -> Int {
        guard frames.indices.contains(idx), idx > 0 else { return idx }
        let current = frames[idx].appName
        var i = idx - 1
        while i >= 0, frames[i].appName == current { i -= 1 }
        return max(0, i)
    }

    static func nextAppBoundary(in frames: [ScreenpipeFrame], from idx: Int) -> Int {
        guard frames.indices.contains(idx), idx < frames.count - 1 else { return idx }
        let current = frames[idx].appName
        var i = idx + 1
        while i < frames.count, frames[i].appName == current { i += 1 }
        return min(frames.count - 1, i)
    }

    private func reload() {
        state.loading = true
        let day = state.selectedDay
        let dbRef = db
        Task { @MainActor in
            let fetched = await Task.detached(priority: .userInitiated) {
                dbRef.frames(on: day, limit: 2000)
            }.value
            state.frames = fetched
            state.focusIndex = max(fetched.count - 1, 0)
            state.loading = false
        }
    }
}

// =============================================================================
// MARK: - TimelineControls (date nav + calendar popover)
// =============================================================================

private struct TimelineControlsBar: View {
    @Binding var currentDate: Date
    let onRefresh: () -> Void
    @State private var calendarOpen = false

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 0) {
                ControlIconButton(systemName: "chevron.left") {
                    if let d = Calendar.current.date(byAdding: .day, value: -1, to: currentDate) {
                        currentDate = d
                    }
                }

                Button { calendarOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 12))
                        Text(dateFmt.string(from: currentDate))
                            .font(.system(size: 15, design: .monospaced))
                    }
                    .frame(minWidth: 140, minHeight: 32)
                    .foregroundStyle(.white.opacity(0.92))
                }
                .buttonStyle(InvertOnHoverButtonStyle())
                .popover(isPresented: $calendarOpen, arrowEdge: .bottom) {
                    CalendarPopover(selected: $currentDate, isPresented: $calendarOpen)
                }

                ControlIconButton(systemName: "chevron.right") {
                    if let d = Calendar.current.date(byAdding: .day, value: 1, to: currentDate),
                       d <= Date() { currentDate = d }
                }

                ControlIconButton(systemName: "arrow.clockwise") {
                    currentDate = Date()
                    onRefresh()
                }
            }
            .background(Color.black)
            .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            Spacer()
        }
    }

    private var dateFmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }
}

private struct ControlIconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .frame(width: 32, height: 32)
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(InvertOnHoverButtonStyle())
    }
}

private struct InvertOnHoverButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hover ? Color.white : Color.clear)
            .colorInvert(if: hover)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private extension View {
    @ViewBuilder func colorInvert(if condition: Bool) -> some View {
        if condition { self.colorInvert() } else { self }
    }
}

// =============================================================================
// MARK: - Calendar Popover — native SwiftUI DatePicker(.graphical)
// =============================================================================
//
// Apple's stock graphical DatePicker, same one used in Date & Time settings,
// Reminders, Calendar.app's quick picker. Drops ~150 lines of custom grid
// code we no longer maintain — month nav, weekday header, day cells, future
// disable, accent color, light/dark all handled by the system.

private struct CalendarPopover: View {
    @Binding var selected: Date
    @Binding var isPresented: Bool

    var body: some View {
        DatePicker(
            "",
            selection: $selected,
            in: ...Date(),                  // future dates disabled
            displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .padding(12)
        .frame(width: 260)
        .onChange(of: Calendar.current.startOfDay(for: selected)) { _, _ in
            // Close the popover when user picks a different day.
            isPresented = false
        }
    }
}

// =============================================================================
// MARK: - FramePreview
// =============================================================================

private struct FramePreview: View {
    let frame: ScreenpipeFrame
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let path = frame.snapshotPath {
                    AsyncDiskThumbnail(path: path, targetPixelSize: 1800)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
                } else {
                    Rectangle().fill(Color.white.opacity(0.05))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 60)        // reduced — preview is smaller
            .padding(.top, 6)

            // ── Frame info row — 1.5× original size ──
            HStack(spacing: 10) {
                RealAppIcon(appName: frame.appName, size: 21)
                Text(frame.appName.isEmpty ? "(unknown app)" : frame.appName)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Text("·").font(.system(size: 17)).foregroundStyle(.white.opacity(0.3))
                Text(frame.windowName)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                Text(timeFmt.string(from: frame.timestamp))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 18).padding(.bottom, 8)
        }
    }
    private var timeFmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }
}

struct RealAppIcon: View {
    let appName: String
    let size: CGFloat
    @State private var realIcon: NSImage? = nil

    var body: some View {
        ZStack {
            if let img = realIcon {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Circle().fill(ScreenpipeColor.barColor(for: appName))
                Text(String(appName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .task(id: appName) { await load() }
    }

    private func load() async {
        if let cached = AppNameIconCache.shared.get(appName) { self.realIcon = cached; return }
        if AppNameIconCache.shared.isKnownMiss(appName) { return }
        let name = appName
        let img = await Task.detached(priority: .userInitiated) {
            AppIconLoader.icon(forAppName: name)
        }.value
        AppNameIconCache.shared.store(img, for: appName)
        if let img { self.realIcon = img }
    }
}

// =============================================================================
// MARK: - TimelineSlider — direct port of screenpipe's TimelineSlider
// =============================================================================
//
// Source: My-Orphies/apps/screenpipe-app-tauri/components/rewind/timeline/timeline.tsx
//
// Original React structure (the canonical version we're replicating exactly):
//
//   <div className="overflow-x-auto overflow-y-visible"
//        style={{ paddingTop: 60, paddingBottom: 24 }}>
//     <div className="flex flex-nowrap w-max justify-center px-[50vw] h-24">
//       {frames.map(f => (
//         <div style={{
//           width: '6px', marginLeft: '2px', marginRight: '2px',
//           backgroundColor: appNameToBarColor(f.appName),
//           height: isCurrent ? "80%" : "45%",
//           borderRadius: '4px 4px 0 0',
//           transform: isCurrent ? 'scale(1.15)' : '',
//         }} />
//       ))}
//     </div>
//   </div>
//
// SwiftUI translation:
//   - overflow-x-auto → ScrollView(.horizontal)
//   - overflow-y-visible → .scrollClipDisabled() (macOS 14+) — needed so the
//     scale(1.15) on current bar isn't clipped at the top
//   - flex flex-nowrap → HStack(alignment: .bottom, spacing: 0) [NOT LazyHStack
//     — the React version renders every frame eagerly, and Lazy was the cause
//     of "only one bar visible" reports]
//   - h-24 → .frame(height: 96, alignment: .bottom)
//   - px-[50vw] → .padding(.horizontal, 600)  // hardcoded buffer; GeometryReader
//     created a layout cycle that hid content
//   - width: 6px + 2px margin × 2 → bar width 6, HStack spacing 4
//   - height: 45% / 80% → 96 * 0.45 = 43 / 96 * 0.80 = 77 (absolute pixels)

private struct TimelineSlider: View {
    @Bindable var state: TimelineState

    var body: some View {
        VStack(spacing: 0) {
            // Bigger bars + bigger icons — matches original screenpipe scale.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(state.frames.indices, id: \.self) { idx in
                            FrameColumn(
                                frame: state.frames[idx],
                                isCurrent: idx == state.focusIndex,
                                isAppStart: idx == 0 || state.frames[idx].appName != state.frames[idx - 1].appName
                            )
                            .id(state.frames[idx].id)
                            .onTapGesture { state.focusIndex = idx }
                        }
                    }
                    .padding(.horizontal, 400)
                    .frame(height: 140, alignment: .bottom)
                }
                .frame(height: 155)
                .background(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), Color.clear],
                        startPoint: .bottom, endPoint: .top
                    )
                )
                .onAppear {
                    guard state.frames.indices.contains(state.focusIndex) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        proxy.scrollTo(state.frames[state.focusIndex].id, anchor: .center)
                    }
                }
                .onChange(of: state.focusIndex) {
                    guard state.frames.indices.contains(state.focusIndex) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(state.frames[state.focusIndex].id, anchor: .center)
                    }
                }
                .onChange(of: state.frames.count) {
                    guard state.frames.indices.contains(state.focusIndex) else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(state.frames[state.focusIndex].id, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 0)   // empty space below — clears the macOS dock
        }
    }
}

/// One frame's full column: app icon on top (only at app-block boundary),
/// colored bar on the bottom. Column locks to 130pt tall so all bars share
/// a baseline and all icons share a top line.
private struct FrameColumn: View {
    let frame: ScreenpipeFrame
    let isCurrent: Bool
    let isAppStart: Bool

    var body: some View {
        // Bigger column matching original screenpipe scale:
        //   - bar width: 12pt
        //   - icon size: 32pt (overflows 12pt column ±10pt on each side)
        //   - bar heights: 100 / 56
        let barH: CGFloat = isCurrent ? 100 : 56
        VStack(spacing: 2) {
            // ── icon area (32pt) ──
            if isAppStart {
                RealAppIcon(appName: frame.appName, size: 32)
                    .frame(width: 32, height: 32)
            } else {
                Color.clear.frame(width: 12, height: 32)
            }

            Spacer(minLength: 0)

            // ── bar ──
            UnevenRoundedRectangle(
                topLeadingRadius: 5, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 5
            )
            .fill(ScreenpipeColor.barColor(for: frame.appName))
            .frame(width: 12, height: barH)
            .scaleEffect(isCurrent ? 1.12 : 1.0, anchor: .bottom)
            .shadow(color: isCurrent ? .white.opacity(0.6) : .clear, radius: 5)
            .animation(.easeOut(duration: 0.15), value: isCurrent)
        }
        .frame(width: 12, height: 140)   // a bit taller to fit 32pt icon
    }
}

// =============================================================================
// MARK: - Color helper (port of screenpipe's appNameToBarColor)
// =============================================================================

enum ScreenpipeColor {
    /// Brighter than the React original's `hsl(hue, 35%, 65%)` because
    /// SwiftUI uses HSB (not HSL) — at the same numeric values the colors
    /// come out much darker and basically invisible on a black background.
    /// Tuned by eye for dark-mode visibility.
    static func barColor(for appName: String) -> Color {
        if appName.isEmpty { return Color(hue: 0, saturation: 0, brightness: 0.6) }
        var hash: UInt64 = 5381
        for ch in appName.unicodeScalars { hash = (hash &* 33) &+ UInt64(ch.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.88)
    }
}

// =============================================================================
// MARK: - Browser URL bar — Safari-style address bar above the screenshot
// =============================================================================
//
// Visual contract (mirrors screenpipe's URL bar):
//   ┌──────────────────────────────────────────────────────────┐
//   │  🔒  developer.apple.com/design/…/designing-for-macos  ↗  │
//   └──────────────────────────────────────────────────────────┘
//   - dark rounded background, subtle white-opacity border
//   - lock glyph on the left (green tint when https)
//   - URL truncated middle, monospaced, selectable
//   - external link icon on the right opens in default browser

private struct BrowserURLBar: View {
    let url: String

    private var isSecure: Bool { url.hasPrefix("https://") }

    private var displayURL: String {
        // Strip scheme for a cleaner address-bar look
        if let r = url.range(of: "://") {
            return String(url[r.upperBound...])
        }
        return url
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSecure ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 11))
                .foregroundStyle(isSecure ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))

            Text(displayURL)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 6)

            Button {
                if let target = URL(string: url) {
                    NSWorkspace.shared.open(target)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("Open in browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

// =============================================================================
// MARK: - Empty state
// =============================================================================

private struct EmptyState: View {
    let loading: Bool
    let hasDB: Bool
    var body: some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
                Text("Loading frames…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            } else if !hasDB {
                Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.3))
                Text("No ~/.screenpipe/db.sqlite found")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            } else {
                Image(systemName: "moon.zzz").font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.3))
                Text("No frames on this day").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
