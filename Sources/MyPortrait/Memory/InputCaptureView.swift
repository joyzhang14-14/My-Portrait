import SwiftUI

/// Memory 区 "Input" scope 的渲染路径。
///
/// 跟 `MemoriesView` 不同 —— 数据来自 SQLite `typing_events` 表（typing capture
/// 模块采集），不是 `PortraitFile`，所以走独立 view。
///
/// v13 schema 是「一个 app 一条主记录」：左列每行一个 app，右侧展示该 app 累积
/// 的最终输入文本 + commit/delete 流水（edit_log）。
///
///   [app 列表]  [累积文本 + 元数据 + edit_log 时间线]
@MainActor
struct InputCaptureView: View {
    @Environment(\.services) private var services

    @State private var apps: [TypingEvent] = []
    @State private var selected: String?          // bundle_id
    @State private var loading: Bool = false
    @State private var loadFailed: Bool = false
    @State private var confirmingDelete: Bool = false

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
                Text("\(apps.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await reload() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bouncyIcon)
                .help("Reload typing capture")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.06))

            if apps.isEmpty && !loading {
                emptyHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(apps, id: \.bundleId) { app in
                            AppRow(app: app, selected: selected == app.bundleId)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = app.bundleId }
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
        if let id = selected, let app = apps.first(where: { $0.bundleId == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(Self.appLabel(app.bundleId))
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Button {
                            confirmingDelete = true
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.bouncyIcon)
                        .help("Delete this app's captured typing")
                    }
                    .padding(.top, 44)

                    metadataBlock(app)
                    Divider().background(Color.white.opacity(0.06))

                    Text(app.text.isEmpty ? "—" : app.text)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    let groups = Self.groupedLog(TypingRecordWriter.decodeLog(app.editLog))
                    if !groups.isEmpty {
                        Divider().background(Color.white.opacity(0.06))
                        Text("Edit log · \(groups.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            editGroupRow(group)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog(
                "Delete captured typing for “\(Self.appLabel(app.bundleId))”?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await deleteApp(app) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes this app's typing_events row from the database.")
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select an app")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func metadataBlock(_ app: TypingEvent) -> some View {
        let rows: [(String, String)] = [
            ("bundle_id", app.bundleId),
            ("time_start", Self.timeString(app.timeStart)),
            ("last_updated", Self.timeString(app.lastUpdated)),
            ("total_chars", "\(app.totalChars)")
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

    /// 一组编辑（连续同类已合并）。commit=绿+ / delete=红− / submit=蓝纸飞机。
    @ViewBuilder
    private func editGroupRow(_ group: EditGroup) -> some View {
        let isSubmit = group.kind == "submit"
        let isDelete = group.kind == "delete"
        let color: Color = isSubmit ? Theme.accent
            : (isDelete ? Color.red.opacity(0.8) : Color.green.opacity(0.8))

        HStack(alignment: .top, spacing: 8) {
            Group {
                if isSubmit {
                    Image(systemName: "paperplane.fill")
                } else {
                    Text(isDelete ? "−" : "+")
                }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.timeRangeString(group.firstTs, group.lastTs))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if isSubmit {
                        Text("SENT")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(color)
                    } else if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(group.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Actions

    @MainActor
    private func reload() async {
        guard let store = services?.typingStore else {
            loadFailed = true
            apps = []
            return
        }
        loading = true
        do {
            apps = try store.recentApps(limit: 300)
            loadFailed = false
        } catch {
            apps = []
            loadFailed = true
        }
        if let id = selected, !apps.contains(where: { $0.bundleId == id }) {
            selected = nil
        }
        loading = false
    }

    /// 永久删除某 app 的整条 typing_events 主记录。
    @MainActor
    private func deleteApp(_ app: TypingEvent) async {
        guard let store = services?.typingStore else { return }
        do {
            try store.delete(bundleId: app.bundleId)
            apps.removeAll { $0.bundleId == app.bundleId }
            if selected == app.bundleId { selected = nil }
        } catch {
            // 删除失败 —— 静默；下次 reload 回到真实状态。
        }
    }

    // MARK: - Formatting

    /// bundle_id 末段当友好名（com.tinyspeck.slackmacgap → slackmacgap）。
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
        stampFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// 单时刻 → `HH:mm:ss`；跨时刻 → `起 – 止`。
    static func timeRangeString(_ first: Int64, _ last: Int64) -> String {
        first == last ? timeString(first)
                       : "\(timeString(first)) – \(timeString(last))"
    }

    /// 把 edit_log 的连续同类条目（commit / delete）合并成组 —— 提高可读性。
    /// submit 永远独立成组（它是发送边界）。
    static func groupedLog(_ entries: [EditEntry]) -> [EditGroup] {
        var groups: [EditGroup] = []
        for e in entries {
            if let last = groups.last, last.kind == e.kind, e.kind != "submit" {
                groups[groups.count - 1] = EditGroup(
                    kind: last.kind,
                    text: last.text + e.text,
                    firstTs: last.firstTs,
                    lastTs: e.ts,
                    count: last.count + 1
                )
            } else {
                groups.append(EditGroup(kind: e.kind, text: e.text,
                                        firstTs: e.ts, lastTs: e.ts, count: 1))
            }
        }
        return groups
    }
}

/// edit_log 里一段连续同类编辑合并成的一组（commit / delete / submit）。
struct EditGroup {
    let kind: String      // "commit" | "delete" | "submit"
    let text: String      // 合并后的文本
    let firstTs: Int64
    let lastTs: Int64
    let count: Int
}

private struct AppRow: View {
    let app: TypingEvent
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppColor.color(for: InputCaptureView.appLabel(app.bundleId)))
                    .frame(width: 3, height: 24)
                Spacer(minLength: 0)
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(InputCaptureView.appLabel(app.bundleId))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(InputCaptureView.timeString(app.lastUpdated))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(app.totalChars) chars")
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
