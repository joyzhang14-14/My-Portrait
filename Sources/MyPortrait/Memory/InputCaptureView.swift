import SwiftUI

/// Memory 区 "Input" scope 的渲染路径。
///
/// 跟 `MemoriesView` 不同 —— 数据来自 SQLite `typing_events` 表（typing capture
/// 模块采集），不是 `PortraitFile`，所以走独立 view。按 thread 分组：一个打字
/// session 一条。
///
///   [thread 列表]  [合并文本 + 元数据 + 逐 event 列表]
@MainActor
struct InputCaptureView: View {
    @Environment(\.services) private var services

    @State private var threads: [TypingThreadSummary] = []
    @State private var selected: TypingThreadSummary.ID?
    @State private var events: [TypingEvent] = []
    @State private var loading: Bool = false
    @State private var loadFailed: Bool = false

    var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task { await reload() }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Input")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(threads.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await reload() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bouncyIcon)
                .help("Reload typing sessions")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.06))

            if threads.isEmpty && !loading {
                emptyHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(threads) { thread in
                            ThreadRow(thread: thread, selected: selected == thread.id)
                                .contentShape(Rectangle())
                                .onTapGesture { handleSelect(thread) }
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(loadFailed
                 ? "Typing capture is unavailable."
                 : "No typing captured yet — enable Typing capture in Recording settings.")
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let thread = threads.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.appLabel(thread))
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 44)

                    metadataBlock(thread)
                    Divider().background(Color.white.opacity(0.06))

                    Text(mergedText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !events.isEmpty {
                        Divider().background(Color.white.opacity(0.06))
                        Text("Events")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(events, id: \.id) { ev in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.timeString(ev.startedAtMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(ev.text)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a typing session")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func metadataBlock(_ t: TypingThreadSummary) -> some View {
        let windowTitle = events.compactMap { $0.windowTitle }.first
        let langHint = events.compactMap { $0.languageHint }.first
        let rows: [(String, String)] = [
            ("app", t.appName ?? t.bundleId),
            ("window_title", windowTitle ?? "—"),
            ("span", Self.spanString(t.startedAt, t.endedAt)),
            ("language_hint", langHint ?? "—"),
            ("events", "\(t.eventCount)"),
            ("chars", "\(t.charCount)")
        ]
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

    private var mergedText: String {
        // events 已按 started_at_ms ASC 排（eventsInThread 保证）。
        events.map(\.text).joined(separator: "\n\n")
    }

    // MARK: - Actions

    private func handleSelect(_ thread: TypingThreadSummary) {
        selected = thread.id
        events = []
        guard let store = services?.typingStore else { return }
        do {
            events = try store.eventsInThread(threadId: thread.threadId)
        } catch {
            events = []
        }
    }

    @MainActor
    private func reload() async {
        guard let store = services?.typingStore else {
            loadFailed = true
            threads = []
            return
        }
        loading = true
        do {
            threads = try store.recentThreads(limit: 300)
            loadFailed = false
        } catch {
            threads = []
            loadFailed = true
        }
        // 选中项可能已不在新列表里。
        if let id = selected, !threads.contains(where: { $0.id == id }) {
            selected = nil
            events = []
        }
        loading = false
    }

    // MARK: - Formatting

    static func appLabel(_ t: TypingThreadSummary) -> String {
        if let name = t.appName, !name.isEmpty { return name }
        return t.bundleId
    }

    nonisolated(unsafe) private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    nonisolated(unsafe) private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    static func timeString(_ ms: Int64) -> String {
        stampFmt.string(from: date(ms))
    }

    /// 同一天 → `HH:mm–HH:mm`；跨天 → `yyyy-MM-dd HH:mm → yyyy-MM-dd HH:mm`。
    static func spanString(_ startMs: Int64, _ endMs: Int64) -> String {
        let start = date(startMs)
        let end = date(endMs)
        if dayFmt.string(from: start) == dayFmt.string(from: end) {
            return "\(dayFmt.string(from: start)) \(timeFmt.string(from: start))–\(timeFmt.string(from: end))"
        }
        return "\(dayFmt.string(from: start)) \(timeFmt.string(from: start)) → " +
               "\(dayFmt.string(from: end)) \(timeFmt.string(from: end))"
    }
}

private struct ThreadRow: View {
    let thread: TypingThreadSummary
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppColor.color(for: InputCaptureView.appLabel(thread)))
                    .frame(width: 3, height: 24)
                Spacer(minLength: 0)
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(InputCaptureView.appLabel(thread))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(InputCaptureView.spanString(thread.startedAt, thread.endedAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(thread.eventCount) edits · \(thread.charCount) chars")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Theme.accent.opacity(0.18) : .clear)
    }
}
