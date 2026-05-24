import SwiftUI

/// Memory 区 "Input" scope 的渲染路径。
///
/// 数据来自 SQLite `typing_events` 表（v14 event-log schema）—— append-only，
/// 一条 record = 一个 (app, element) 的一段输入 session。三级下钻:
///
///   [app 列表]  →  [该 app 的 records]  →  [record 详情: text + edit_log]
@MainActor
struct InputCaptureView: View {
    @Environment(\.services) private var services

    @State private var apps: [TypingAppSummary] = []
    @State private var selectedGroup: TypingAppSummary?   // (app, URL) 分组
    @State private var records: [TypingEvent] = []
    @State private var selectedRecordId: Int64?
    @State private var loadFailed = false
    @State private var confirmingDelete = false        // app 级
    @State private var confirmingRecordDelete = false   // 单条 session
    /// app 列表的标题搜(app label).
    @State private var appSearchText: String = ""
    /// records 列表的标题搜(URL / element label).
    @State private var recordSearchText: String = ""

    // 写作采集 LLM 输出 —— approved 天的 writing_records 跟选中的 typing_event
    // 时间窗重叠时,detail 顶部展示。
    @State private var matchedWritingRecords: [WritingRecordViewRow] = []
    @State private var writingCaptureDayStatus: WritingCaptureRunStatus? = nil

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task { await reloadApps() }
        .onChange(of: selectedRecordId) { _, _ in
            loadMatchedWritingRecords()
        }
    }

    /// 选了某条 typing_event → 查写作采集状态 + 重叠的 writing_records。
    private func loadMatchedWritingRecords() {
        guard let id = selectedRecordId,
              let rec = records.first(where: { $0.id == id }),
              let worker = WritingCaptureWorker.shared else {
            matchedWritingRecords = []
            writingCaptureDayStatus = nil
            return
        }
        let store = worker.store
        let startTs = rec.startedAt
        let endTs = rec.endedAt
        let app = rec.bundleId
        Task.detached(priority: .userInitiated) {
            let status = (try? store.dayStatus(forTsMs: startTs)) ?? nil
            let matched: [WritingRecordViewRow]
            if status == .approved {
                matched = (try? store.writingRecordsOverlapping(
                    startTs: startTs, endTs: endTs, app: app)) ?? []
            } else {
                matched = []
            }
            await MainActor.run {
                self.writingCaptureDayStatus = status
                self.matchedWritingRecords = matched
            }
        }
    }

    // MARK: - 左列：app 列表 / records 列表

    @ViewBuilder
    private var leftColumn: some View {
        if let group = selectedGroup {
            recordsListColumn(group: group)
        } else {
            appsListColumn
        }
    }

    /// app 标题(label)模糊搜。
    private var visibleApps: [TypingAppSummary] {
        let q = appSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            Self.appLabel($0.bundleId).localizedCaseInsensitiveContains(q)
        }
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

            Divider().background(Color.white.opacity(0.06))

            if apps.isEmpty {
                emptyHint
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
                                .onTapGesture { Task { await openGroup(app) } }
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
    }

    /// records 标题模糊搜:URL + element label 都参与匹配(两者构成 record
    /// 在列表里可见的"标题"语义)。
    private var visibleRecords: [TypingEvent] {
        let q = recordSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter { rec in
            let label = Self.elementLabel(rec.elementHash, in: records)
            return rec.url.localizedCaseInsensitiveContains(q)
                || label.localizedCaseInsensitiveContains(q)
        }
    }

    private func recordsListColumn(group: TypingAppSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedGroup = nil
                    selectedRecordId = nil
                    records = []
                    recordSearchText = ""
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bouncyIcon)
                .help("Back to apps")
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.appLabel(group.bundleId))
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if !group.url.isEmpty {
                        Text(group.url)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Text("\(visibleRecords.count)\(recordSearchText.isEmpty ? "" : " / \(records.count)")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.bouncyIcon)
                    .help("Delete all captured typing for this group")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)

            SearchBar(text: $recordSearchText, placeholder: "Search URL or element")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.06))

            if visibleRecords.isEmpty && !recordSearchText.isEmpty {
                Text("No records match “\(recordSearchText)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRecords, id: \.id) { rec in
                            RecordRow(record: rec,
                                      elementLabel: Self.elementLabel(rec.elementHash, in: records),
                                      selected: selectedRecordId == rec.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecordId = rec.id }
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
        .confirmationDialog(
            "Delete all captured typing for “\(Self.appLabel(group.bundleId))”?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteGroup(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all \(records.count) typing records here.")
        }
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

    // MARK: - 右侧：record 详情

    @ViewBuilder
    private var detail: some View {
        if let id = selectedRecordId, let rec = records.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.appLabel(rec.bundleId))
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Button { confirmingRecordDelete = true } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bouncyIcon)
                        .help("Delete this session")
                    }
                    .padding(.top, 44)
                    metadataBlock(rec)

                    writingCaptureBlock(rec: rec)

                    // Approved 天 → 只展示 LLM 输出(writingCaptureBlock 上面已展示)。
                    // 不再显示原 typing_events 的 text + edit_log。
                    //
                    // 未跑 / Pending review / Reject / Failed → 显示 raw(原行为)。
                    if writingCaptureDayStatus != .approved {
                        Divider().background(Color.white.opacity(0.06))

                        Text(rec.text.isEmpty ? "（无新增文本，仅编辑/删除）" : rec.text)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        let groups = Self.groupedLog(TypingRecordWriter.decodeLog(rec.editLog))
                        if !groups.isEmpty {
                            Divider().background(Color.white.opacity(0.06))
                            Text("Edit log · \(groups.count)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                                editGroupRow(g)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Delete this typing session?",
                                isPresented: $confirmingRecordDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await deleteRecord(id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes this one record.")
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(selectedGroup == nil ? "Select an app" : "Select a record")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 写作采集 LLM 输出 block —— 该天 approved 且有对应 writing_records 时才展示。
    /// 显示 LLM 整理后的最终文本 + context_summary,而不是原始 typing_event 文本。
    @ViewBuilder
    private func writingCaptureBlock(rec: TypingEvent) -> some View {
        if !matchedWritingRecords.isEmpty {
            Divider().background(Color.white.opacity(0.06))
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Writing capture · \(writingCaptureDayStatus?.rawValue ?? "?") · \(matchedWritingRecords.count) record(s)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ForEach(matchedWritingRecords, id: \.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.source)
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                        Text(String(format: "conf %.2f", row.confidence))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        if let cs = row.contextSummary, !cs.isEmpty {
                            Text(cs).font(.system(size: 10))
                                .foregroundStyle(.secondary).italic()
                                .lineLimit(2)
                        }
                    }
                    Text(row.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(6)
            }
        } else if writingCaptureDayStatus == .approved {
            // 该天 approved 但这条 typing_event 没匹配到 writing_record —— LLM 把
            // 整段判定为 throwaway(搜索 / 短应答 / 命令行 等)。raw 不再展示。
            HStack(spacing: 6) {
                Image(systemName: "trash.slash")
                    .foregroundStyle(.secondary)
                Text("Filtered as throwaway by Pass 2 LLM (search / short response / command / etc.)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
            }
            .padding(.vertical, 8)
        } else if let status = writingCaptureDayStatus, status != .approved {
            // 该天跑过但没 approved(pending_review / rejected_for_rerun / failed)
            // —— 提示状态,raw 在下面继续显示
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("This day's writing-capture status: \(status.rawValue) — showing raw typing event below.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func metadataBlock(_ rec: TypingEvent) -> some View {
        let rows: [(String, String)] =
            [("bundle_id", rec.bundleId),
             ("element", Self.elementLabel(rec.elementHash, in: records))]
            + (rec.url.isEmpty ? [] : [("url", rec.url)])
            + [("started_at", Self.timeString(rec.startedAt)),
               ("ended_at", Self.timeString(rec.endedAt)),
               ("total_chars", "\(rec.totalChars)")]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 110, alignment: .leading)
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
                if isSubmit { Image(systemName: "paperplane.fill") }
                else { Text(isDelete ? "−" : "+") }
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
    private func reloadApps() async {
        guard let store = services?.typingStore else {
            loadFailed = true; apps = []; return
        }
        do {
            apps = try store.appSummaries()
            loadFailed = false
        } catch {
            apps = []; loadFailed = true
        }
        if let g = selectedGroup, !apps.contains(where: { $0.id == g.id }) {
            selectedGroup = nil; records = []; selectedRecordId = nil
        }
    }

    @MainActor
    private func openGroup(_ group: TypingAppSummary) async {
        guard let store = services?.typingStore else { return }
        selectedGroup = group
        selectedRecordId = nil
        records = (try? store.records(bundleId: group.bundleId, url: group.url)) ?? []
    }

    /// 永久删除某 (app, URL) 分组的全部 typing records。
    @MainActor
    private func deleteGroup(_ group: TypingAppSummary) async {
        guard let store = services?.typingStore else { return }
        try? store.delete(bundleId: group.bundleId, url: group.url)
        selectedGroup = nil
        records = []
        selectedRecordId = nil
        await reloadApps()
    }

    /// 永久删除单条 session record。
    @MainActor
    private func deleteRecord(_ id: Int64) async {
        guard let store = services?.typingStore else { return }
        try? store.delete(id: id)
        records.removeAll { $0.id == id }
        selectedRecordId = nil
        await reloadApps()
    }

    // MARK: - 编辑日志分组（连续同类合并）

    /// 把 edit_log 连续同类条目（commit / delete）合并成组。submit 永远独立。
    static func groupedLog(_ entries: [EditEntry]) -> [EditGroup] {
        var groups: [EditGroup] = []
        for e in entries {
            if let last = groups.last, last.kind == e.kind, e.kind != "submit" {
                groups[groups.count - 1] = EditGroup(
                    kind: last.kind, text: last.text + e.text,
                    firstTs: last.firstTs, lastTs: e.ts, count: last.count + 1)
            } else {
                groups.append(EditGroup(kind: e.kind, text: e.text,
                                        firstTs: e.ts, lastTs: e.ts, count: 1))
            }
        }
        return groups
    }

    // MARK: - Formatting

    /// bundle_id 末段当友好名（com.tencent.xinWeChat → xinWeChat）。
    static func appLabel(_ bundleId: String) -> String {
        let last = bundleId.split(separator: ".").last.map(String.init)
        return (last?.isEmpty == false ? last : nil) ?? bundleId
    }

    /// element_hash 不暴露原始值 —— 在该 app 的 records 里按出现顺序编号。
    static func elementLabel(_ hash: Int, in records: [TypingEvent]) -> String {
        var seen: [Int] = []
        for r in records.sorted(by: { $0.startedAt < $1.startedAt }) where !seen.contains(r.elementHash) {
            seen.append(r.elementHash)
        }
        let idx = (seen.firstIndex(of: hash) ?? 0) + 1
        return "element \(idx)"
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

    static func timeRangeString(_ first: Int64, _ last: Int64) -> String {
        first == last ? timeString(first)
                       : "\(timeString(first)) – \(timeString(last))"
    }
}

/// edit_log 里一段连续同类编辑合并成的一组。
struct EditGroup {
    let kind: String      // "commit" | "delete" | "submit"
    let text: String
    let firstTs: Int64
    let lastTs: Int64
    let count: Int
}

// MARK: - 行视图

private struct AppRow: View {
    let app: TypingAppSummary

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
                    .lineLimit(1)
                if !app.url.isEmpty {
                    Text(app.url)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(InputCaptureView.timeString(app.lastEndedAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(app.recordCount) records")
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

private struct RecordRow: View {
    let record: TypingEvent
    let elementLabel: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(elementLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(record.totalChars) chars")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(InputCaptureView.timeString(record.startedAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(record.text.isEmpty ? "（仅编辑/删除）" : String(record.text.prefix(50)))
                .font(.system(size: 12))
                .foregroundStyle(record.text.isEmpty ? .tertiary : .primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.18) : .clear)
    }
}
