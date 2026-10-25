import SwiftUI

/// Memory 区 "Input" scope 的列表形态。
///
/// **只显示元输入**(10-25 update):`keystroke_log` 按 app 和停顿切成段、原样拼字
/// (`InputSegments`),不显示整理过的 writing_records。
///
/// 三级下钻:
///   [app 列表] → [该 app 的段,新的在前,往下翻页取更早的] → [段详情:全文 + 时间]
///
/// 数据源:`WritingCaptureBrowse`(dev mode 自动换成演示击键)。
@MainActor
struct InputCaptureView: View {

    /// writing-style chip 跳转目标 record id。非 nil → 跳到那条 record 当时那个 app 的元输入。
    var jumpToRecordId: Binding<Int64?>? = nil

    @State private var apps: [InputAppSummary] = []
    @State private var selectedApp: String?
    @State private var segments: [InputSegment] = []
    /// 非 nil = 更早还有,「Load earlier」从这里接着取。
    @State private var nextBefore: Int64?
    @State private var loadingMore = false
    @State private var selectedSegmentId: Int64?
    @State private var loadFailed = false
    @State private var appSearchText = ""
    @State private var segmentSearchText = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task { await reloadApps(); await handleJump() }
        .onChange(of: jumpToRecordId?.wrappedValue) { _, v in
            if v != nil { Task { await handleJump() } }
        }
    }

    /// writing-style chip 跳转:record 的 app + 开始时间 → 打开该 app,往前翻到那个时间,
    /// 选中包含它(或离它最近)的那段。
    @MainActor
    private func handleJump() async {
        guard let target = jumpToRecordId?.wrappedValue else { return }
        jumpToRecordId?.wrappedValue = nil
        guard let t = WritingCaptureBrowse.jumpTarget(forRecord: target) else { return }
        await openApp(t.app)
        var pages = 0
        while let before = nextBefore, before > t.startMs, pages < 50, selectedApp == t.app {
            await loadEarlier()
            pages += 1
        }
        guard selectedApp == t.app else { return }
        selectedSegmentId = segments.min {
            Self.distance($0, to: t.startMs) < Self.distance($1, to: t.startMs)
        }?.id
    }

    private static func distance(_ s: InputSegment, to ts: Int64) -> Int64 {
        ts < s.startMs ? s.startMs - ts : (ts > s.endMs ? ts - s.endMs : 0)
    }

    // MARK: - 左列:app 列表 / 段列表

    @ViewBuilder
    private var leftColumn: some View {
        if let app = selectedApp {
            segmentsListColumn(app: app)
        } else {
            appsListColumn
        }
    }

    private var visibleApps: [InputAppSummary] {
        let q = appSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { Self.appLabel($0.app).localizedCaseInsensitiveContains(q) }
    }

    private var appsListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Input")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(visibleApps.count)\(appSearchText.isEmpty ? "" : " / \(apps.count)")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await reloadApps() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bouncyIcon)
                .help("Reload")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            SearchBar(text: $appSearchText, placeholder: "Search apps")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color.primary.opacity(0.10))

            if apps.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleApps.isEmpty {
                Text("No apps match “\(appSearchText)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleApps) { app in
                            AppRow(app: app)
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await openApp(app.app) } }
                            Divider().background(Color.primary.opacity(0.08))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(colorScheme == .light ? 0.03 : 0.28))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(loadFailed ? "Load failed" : "No typing recorded yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Turn on\nSettings → Capture → Typing Capture")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    private var visibleSegments: [InputSegment] {
        let q = segmentSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return segments }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private func segmentsListColumn(app: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedApp = nil
                    segments = []
                    nextBefore = nil
                    selectedSegmentId = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bouncyIcon)

                Text(Self.appLabel(app))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(visibleSegments.count)\(segmentSearchText.isEmpty ? "" : " / \(segments.count)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            SearchBar(text: $segmentSearchText, placeholder: "Search loaded input")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color.primary.opacity(0.10))

            if segments.isEmpty && nextBefore == nil {
                Text("No input")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleSegments) { seg in
                            SegmentRow(segment: seg, selected: selectedSegmentId == seg.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedSegmentId = seg.id }
                            Divider().background(Color.primary.opacity(0.08))
                        }
                        if nextBefore != nil {
                            Button { Task { await loadEarlier() } } label: {
                                Text(loadingMore ? "Loading…" : "Load earlier")
                                    .font(.system(size: 11))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .disabled(loadingMore)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(colorScheme == .light ? 0.03 : 0.28))
    }

    // MARK: - 右栏:详情

    @ViewBuilder
    private var detail: some View {
        if let id = selectedSegmentId, let seg = segments.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.appLabel(seg.app))
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 44)
                    metadataBlock(seg)
                    Divider().background(Color.primary.opacity(0.10))
                    Text(seg.text)
                        .font(.system(size: 14, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(selectedApp == nil ? "Select an app" : "Select a segment")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadataBlock(_ seg: InputSegment) -> some View {
        let rows: [(String, String)] = [
            ("app", seg.app),
            ("start", Self.timeString(seg.startMs)),
            ("end", Self.timeString(seg.endMs)),
            ("keys", "\(seg.keys)"),
        ]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func reloadApps() async {
        guard WritingCaptureBrowse.isAvailable else {
            loadFailed = true
            apps = []
            return
        }
        apps = await WritingCaptureBrowse.apps()
        loadFailed = false
        if let a = selectedApp, !apps.contains(where: { $0.app == a }) {
            selectedApp = nil
            segments = []
            nextBefore = nil
            selectedSegmentId = nil
        }
    }

    @MainActor
    private func openApp(_ app: String) async {
        selectedApp = app
        selectedSegmentId = nil
        segments = []
        nextBefore = nil
        segmentSearchText = ""
        let page = await WritingCaptureBrowse.segments(app: app, beforeMs: .max)
        // 快速连点两个 app 时慢查询晚归会把前一个 app 的段盖在当前 app 名下,
        // 回来后确认选中的还是本次的 app 才落地。
        guard selectedApp == app else { return }
        segments = page.segments
        nextBefore = page.nextBefore
    }

    @MainActor
    private func loadEarlier() async {
        guard let app = selectedApp, let before = nextBefore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let page = await WritingCaptureBrowse.segments(app: app, beforeMs: before)
        guard selectedApp == app, nextBefore == before else { return }
        segments += page.segments
        nextBefore = page.nextBefore
    }

    // MARK: - 静态助手

    /// bundle_id 末段当友好名(com.tencent.xinWeChat → xinWeChat)。
    static func appLabel(_ bundleId: String) -> String {
        let last = bundleId.split(separator: ".").last.map(String.init)
        return (last?.isEmpty == false ? last : nil) ?? bundleId
    }

    nonisolated(unsafe) private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func timeString(_ ms: Int64) -> String {
        stampFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

// MARK: - 行视图

private struct AppRow: View {
    let app: InputAppSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppColor.color(for: InputCaptureView.appLabel(app.app)))
                    .frame(width: 3, height: 24)
                Spacer(minLength: 0)
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(InputCaptureView.appLabel(app.app))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(InputCaptureView.timeString(app.lastMs))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(app.keys) keys")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SegmentRow: View {
    let segment: InputSegment
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(InputCaptureView.timeString(segment.startMs))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(segment.keys) keys")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Text(segment.text)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.18) : .clear)
    }
}
