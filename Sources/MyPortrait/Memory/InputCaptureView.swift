import SwiftUI

/// Memory 区 "Input" scope 的渲染路径。
///
/// **现在只展示 LLM 整理过的 writing_records**(canvas-editor-capture-design-final.md
/// §7 前端策略)。原 typing_events / keystroke_log / OCR frames 是 raw,
/// 给 LLM worker 当输入,不直接给用户看。
///
/// 三级下钻:
///   [app 列表] → [该 (app, url) 分组的 records] → [record 详情:text + edit_log + context_summary]
///
/// 数据源:`WritingCaptureStore`(走 `WritingCaptureWorker.shared.store`)。
@MainActor
struct InputCaptureView: View {

    @State private var apps: [WritingCaptureAppSummary] = []
    @State private var selectedGroup: WritingCaptureAppSummary?
    @State private var records: [WritingRecordViewRow] = []
    @State private var selectedRecordId: Int64?
    @State private var loadFailed = false
    @State private var appSearchText = ""
    @State private var recordSearchText = ""
    @State private var confirmingDelete = false
    @State private var confirmingRecordDelete = false
    @Environment(\.colorScheme) private var colorScheme

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

    // MARK: - 左列:app 列表 / records 列表

    @ViewBuilder
    private var leftColumn: some View {
        if let group = selectedGroup {
            recordsListColumn(group: group)
        } else {
            appsListColumn
        }
    }

    private var visibleApps: [WritingCaptureAppSummary] {
        let q = appSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            Self.appLabel($0.app).localizedCaseInsensitiveContains(q)
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
                                .onTapGesture { Task { await openGroup(app) } }
                            Divider().background(Color.primary.opacity(0.08))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(colorScheme == .light ? 0.03 : 0.28))
    }

    /// 没 writing_records 时引导用户去 Settings 跑 worker。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(loadFailed ? "Load failed" : "No LLM-processed writing records yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Run from\nSettings → Memory → Scheduler\n→ Process writing capture")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    /// records 模糊搜:text + context_summary 都参与匹配。
    private var visibleRecords: [WritingRecordViewRow] {
        let q = recordSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || ($0.contextSummary?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func recordsListColumn(group: WritingCaptureAppSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedGroup = nil
                    records = []
                    selectedRecordId = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bouncyIcon)

                Text(Self.appLabel(group.app))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(visibleRecords.count)\(recordSearchText.isEmpty ? "" : " / \(records.count)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bouncyIcon)
                .help("Delete all records for this group")
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 4)

            if !group.url.isEmpty {
                Text(group.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            SearchBar(text: $recordSearchText, placeholder: "Search records")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color.primary.opacity(0.10))

            if records.isEmpty {
                Text("No records")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRecords, id: \.id) { rec in
                            RecordRow(record: rec, selected: selectedRecordId == rec.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecordId = rec.id }
                            Divider().background(Color.primary.opacity(0.08))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(colorScheme == .light ? 0.03 : 0.28))
        .confirmationDialog("Delete all writing records for this group?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteGroup(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes all writing_records for \(Self.appLabel(group.app))" +
                 (group.url.isEmpty ? "." : " · \(group.url)."))
        }
    }

    // MARK: - 右栏:详情

    @ViewBuilder
    private var detail: some View {
        if let id = selectedRecordId, let rec = records.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.appLabel(rec.app))
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Button { confirmingRecordDelete = true } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bouncyIcon)
                        .help("Delete this record")
                    }
                    .padding(.top, 44)
                    metadataBlock(rec)
                    Divider().background(Color.primary.opacity(0.10))

                    Text(rec.text.isEmpty ? "(empty content)" : rec.text)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    let entries = decodeEditLog(rec.editLog)
                    if !entries.isEmpty {
                        Divider().background(Color.primary.opacity(0.10))
                        Text("Edit log · \(entries.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                            editEntryRow(e)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Delete this writing record?",
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
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(selectedGroup == nil ? "Select an app" : "Select a record")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadataBlock(_ rec: WritingRecordViewRow) -> some View {
        let rows = metadataRows(rec)
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
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    private func metadataRows(_ rec: WritingRecordViewRow) -> [(String, String)] {
        var rows: [(String, String)] = [("app", rec.app)]
        if let u = rec.url, !u.isEmpty { rows.append(("url", u)) }
        if let loc = rec.location, !loc.isEmpty { rows.append(("location", loc)) }
        rows.append(("source", rec.source))
        rows.append(("confidence", String(format: "%.2f", rec.confidence)))
        rows.append(("start_ts", Self.timeString(rec.startTs)))
        rows.append(("end_ts", Self.timeString(rec.endTs)))
        rows.append(("chars", "\(rec.text.count)"))
        if let cs = rec.contextSummary, !cs.isEmpty { rows.append(("context", cs)) }
        return rows
    }

    /// 单条 edit_log 行:[kind tag] text … timestamp。
    private func editEntryRow(_ e: EditEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(e.kind)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(e.kind == "delete" ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                .cornerRadius(3)
            Text(e.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(Self.timeString(e.ts))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// edit_log 是 JSON 字符串 `[{kind, text, ts}, ...]`,解出来给 UI。
    private func decodeEditLog(_ json: String) -> [EditEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EditEntry].self, from: data)) ?? []
    }

    // MARK: - Actions

    private var store: WritingCaptureStore? { WritingCaptureWorker.shared?.store }

    @MainActor
    private func reloadApps() async {
        guard let store else {
            loadFailed = true
            apps = []
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            (try? store.writingRecordAppSummaries()) ?? []
        }.value
        apps = result
        loadFailed = false
        if let g = selectedGroup, !apps.contains(where: { $0.id == g.id }) {
            selectedGroup = nil
            records = []
            selectedRecordId = nil
        }
    }

    @MainActor
    private func openGroup(_ group: WritingCaptureAppSummary) async {
        guard let store else { return }
        selectedGroup = group
        selectedRecordId = nil
        let result = await Task.detached(priority: .userInitiated) {
            (try? store.writingRecordsForGroup(app: group.app, url: group.url)) ?? []
        }.value
        records = result
    }

    @MainActor
    private func deleteGroup(_ group: WritingCaptureAppSummary) async {
        guard let store else { return }
        await Task.detached(priority: .userInitiated) {
            try? store.deleteWritingRecordsForGroup(app: group.app, url: group.url)
        }.value
        selectedGroup = nil
        records = []
        selectedRecordId = nil
        await reloadApps()
    }

    @MainActor
    private func deleteRecord(_ id: Int64) async {
        guard let store else { return }
        await Task.detached(priority: .userInitiated) {
            try? store.deleteWritingRecord(id: id)
        }.value
        records.removeAll { $0.id == id }
        selectedRecordId = nil
        await reloadApps()
    }

    // MARK: - 静态助手

    /// bundle_id 末段当友好名(com.tencent.xinWeChat → xinWeChat)。
    static func appLabel(_ bundleId: String) -> String {
        // CLI 导入的两个源 —— 显示成可读名,标注 (Imported)。
        switch bundleId {
        case "claude-code": return "Claude Code CLI (Imported)"
        case "codex-cli":   return "Codex CLI (Imported)"
        default: break
        }
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
    let app: WritingCaptureAppSummary

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
    let record: WritingRecordViewRow
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.source)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
                Text(String(format: "conf %.2f", record.confidence))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(record.text.count) chars")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(InputCaptureView.timeString(record.startTs))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let cs = record.contextSummary, !cs.isEmpty {
                Text(cs)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
            }
            Text(record.text.isEmpty ? "(empty)" : String(record.text.prefix(80)))
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
