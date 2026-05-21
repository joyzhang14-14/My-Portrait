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
    @State private var selectedApp: String?              // bundle_id
    @State private var records: [TypingEvent] = []
    @State private var selectedRecordId: Int64?
    @State private var loadFailed = false
    @State private var confirmingDelete = false

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task { await reloadApps() }
    }

    // MARK: - 左列：app 列表 / records 列表

    @ViewBuilder
    private var leftColumn: some View {
        if let bundleId = selectedApp {
            recordsListColumn(bundleId: bundleId)
        } else {
            appsListColumn
        }
    }

    private var appsListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Input")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(apps.count)")
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
            Divider().background(Color.white.opacity(0.06))

            if apps.isEmpty {
                emptyHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(apps) { app in
                            AppRow(app: app)
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await openApp(app.bundleId) } }
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
    }

    private func recordsListColumn(bundleId: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedApp = nil
                    selectedRecordId = nil
                    records = []
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bouncyIcon)
                .help("Back to apps")
                Text(Self.appLabel(bundleId))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text("\(records.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.bouncyIcon)
                    .help("Delete all captured typing for this app")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 8)
            Divider().background(Color.white.opacity(0.06))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records, id: \.id) { rec in
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
        .confirmationDialog(
            "Delete all captured typing for “\(Self.appLabel(bundleId))”?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteApp(bundleId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all \(records.count) typing records for this app.")
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
                    Text(Self.appLabel(rec.bundleId))
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 44)
                    metadataBlock(rec)
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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(selectedApp == nil ? "Select an app" : "Select a record")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func metadataBlock(_ rec: TypingEvent) -> some View {
        let rows: [(String, String)] = [
            ("bundle_id", rec.bundleId),
            ("element", Self.elementLabel(rec.elementHash, in: records)),
            ("started_at", Self.timeString(rec.startedAt)),
            ("ended_at", Self.timeString(rec.endedAt)),
            ("total_chars", "\(rec.totalChars)")
        ]
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
        if let id = selectedApp, !apps.contains(where: { $0.bundleId == id }) {
            selectedApp = nil; records = []; selectedRecordId = nil
        }
    }

    @MainActor
    private func openApp(_ bundleId: String) async {
        guard let store = services?.typingStore else { return }
        selectedApp = bundleId
        selectedRecordId = nil
        records = (try? store.records(bundleId: bundleId)) ?? []
    }

    /// 永久删除某 app 的全部 typing records。
    @MainActor
    private func deleteApp(_ bundleId: String) async {
        guard let store = services?.typingStore else { return }
        try? store.delete(bundleId: bundleId)
        selectedApp = nil
        records = []
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
