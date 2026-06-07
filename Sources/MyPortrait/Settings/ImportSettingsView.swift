import SwiftUI
import AppKit
import GRDB

/// Settings → Data → Import:启动时自动扫盘 ~/.screenpipe / Library / Documents,
/// 找到 screenpipe DB → 显示 frame 数 + 日期范围 + Import 按钮。
/// 找不到 → 提示"未找到" + Pick folder 兜底。
///
/// 只导比 My-Portrait 最早数据老的部分,从不动当前数据。
/// CLI 导入进度 —— 读日志阶段 indeterminate,写库阶段 current/total。
struct CLIImportProgress {
    var label: String
    var current: Int
    var total: Int
    var indeterminate: Bool
}

struct ImportSettingsView: View {

    @Environment(\.services) private var services

    @State private var scan: ScreenpipeImporter.ScanResult? = nil
    /// 初始值绑开关:自动模式 → true(直接进扫描态);手动模式 → false(初始「未扫描」,
    /// 不闪一下 Scanning…)。
    @State private var scanning: Bool = ConfigStore.shared.general.autoScanImports
    @State private var running: Bool = false
    @State private var statusLines: [String] = []
    @State private var lastReport: ScreenpipeImporter.Report? = nil
    @State private var errorMessage: String? = nil
    /// 用户用 folder picker 选了自定义 path → 覆盖自动扫盘。
    @State private var overrideDir: URL? = nil
    /// 当前进度(running 时实时更新)。
    @State private var progress: ScreenpipeImporter.Progress? = nil

    // CLI 导入状态 —— Claude Code 与 Codex 各自独立(分开扫描,互不触发)。
    @State private var ccCount: Int? = nil
    @State private var ccSessions: Int? = nil
    @State private var ccScanning: Bool = false
    @State private var codexCount: Int? = nil
    @State private var codexSessions: Int? = nil
    @State private var codexScanning: Bool = false
    @State private var ccRunning: Bool = false
    @State private var ccStatus: String? = nil
    @State private var codexRunning: Bool = false
    @State private var codexStatus: String? = nil
    // 上次导入时刻(= 该源已导记录的 MAX(start_ts)),卡片底部加粗显示。
    @State private var ccLastTs: Int64? = nil
    @State private var codexLastTs: Int64? = nil
    // 导入进度(running 时实时更新);indeterminate=读日志阶段。
    @State private var ccProgress: CLIImportProgress? = nil
    @State private var codexProgress: CLIImportProgress? = nil

    var body: some View {
        SettingsPage(
            "Import",
            subtitle: "Bring historical data from other capture tools into My Portrait."
        ) {
            SettingsCard(
                title: "Import from screenpipe",
                footnote: "Brings in your older screenpipe history — screen text and audio — from before My Portrait started recording. Your current data isn't touched, and the original video and audio files stay where they are. Afterward, run Process events in Memory settings to turn it into memories."
            ) {
                if scanning {
                    scanningRow
                } else if scan == nil {
                    notScannedBlock          // 手动模式:还没扫过
                } else if let s = scan, s.exists {
                    foundBlock(s)
                } else {
                    notFoundBlock
                }
                if let p = progress, running {
                    SettingsDivider()
                    progressBlock(p)
                }
                if !statusLines.isEmpty {
                    SettingsDivider()
                    statusBlock
                }
                if let r = lastReport {
                    SettingsDivider()
                    summaryBlock(r)
                }
                if let err = errorMessage {
                    SettingsDivider()
                    errorBlock(err)
                }
            }

            SettingsCard(
                title: "Import from Claude Code",
                footnote: "Brings in the prompts you typed into Claude Code and counts them toward your writing. Only your own messages are imported, and importing again won't create duplicates."
            ) {
                cliSourceBlock(
                    icon: "terminal.fill",
                    title: "Claude Code",
                    sessions: ccSessions,
                    count: ccCount,
                    lastTs: ccLastTs,
                    running: ccRunning,
                    progress: ccProgress,
                    status: ccStatus,
                    scanning: ccScanning,
                    rescanAction: { await rescanClaudeCode() },
                    importAction: { await runImport(app: "claude-code") }
                )
            }

            SettingsCard(
                title: "Import from Codex CLI",
                footnote: "Brings in the prompts you typed into Codex CLI and counts them toward your writing. Importing again won't create duplicates."
            ) {
                cliSourceBlock(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Codex CLI",
                    sessions: codexSessions,
                    count: codexCount,
                    lastTs: codexLastTs,
                    running: codexRunning,
                    progress: codexProgress,
                    status: codexStatus,
                    scanning: codexScanning,
                    rescanAction: { await rescanCodex() },
                    importAction: { await runImport(app: "codex-cli") }
                )
            }
        }
        .task {
            // 手动模式(General → Imports → Auto-scan off):不自动扫,每个来源显示
            // 「未扫描」+ Scan 按钮,用户点了才扫。
            guard ConfigStore.shared.general.autoScanImports else {
                scanning = false
                return
            }
            // 三个来源同时扫,互不等待。
            async let sp: Void = rescan()
            async let cc: Void = rescanClaudeCode()
            async let cx: Void = rescanCodex()
            _ = await (sp, cc, cx)
        }
    }

    // MARK: CLI 导入 UI(Claude Code / Codex 各一张卡片,共用此 block)

    @ViewBuilder
    private func cliSourceBlock(
        icon: String,
        title: String,
        sessions: Int?,
        count: Int?,
        lastTs: Int64?,
        running: Bool,
        progress: CLIImportProgress?,
        status: String?,
        scanning: Bool,
        rescanAction: @escaping () async -> Void,
        importAction: @escaping () async -> Void
    ) -> some View {
        // 未扫描(手动模式还没点 Scan):卡片缩到只剩 header + 提示,
        // 不显示 Import 按钮和 Last imported 时间。
        let notScanned = sessions == nil && count == nil && !running && !scanning
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.green)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(count == nil ? "Scan" : "Re-scan") { Task { await rescanAction() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(running || scanning)
            }
            if running, let p = progress {
                cliProgressBlock(p)              // 导入中:进度条优先
            } else if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning session logs …")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if sessions == nil && count == nil {
                // 手动模式:还没扫过这个来源。
                Text("Not scanned — press Scan above.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                if let s = sessions {
                    statRow("Sessions", "\(s.formatted())", mono: false)
                }
                if let c = count {
                    statRow("Typed prompts", "\(c.formatted()) to import", mono: false)
                }
            }
            if let st = status {
                Text(st)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notScanned {
                HStack(spacing: 8) {
                    Spacer()
                    Button(running ? "Importing…" : "Import") {
                        Task { await importAction() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(running || (count ?? 0) == 0)
                }
                .padding(.top, 4)
                Text(lastTs.map { "Last imported: \(Self.dateTimeString($0))" } ?? "Last imported: never")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func cliProgressBlock(_ p: CLIImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(p.label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !p.indeterminate, p.total > 0 {
                    Text("\(p.current.formatted()) / \(p.total.formatted())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !p.indeterminate, p.total > 0 {
                ProgressView(value: Double(p.current), total: Double(p.total))
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            }
        }
    }

    private static func dateTimeString(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: d)
    }

    private func rescanClaudeCode(quiet: Bool = false) async {
        if !quiet { ccScanning = true }
        let dbPool = (services?.db as? PortraitDBImpl)?.dbPool
        let (count, sessions, since) = await Task.detached(priority: .userInitiated) {
            var since: Int64? = nil
            if let dbPool {
                since = try? WritingCaptureStore(dbPool: dbPool).cliImportLastTs(app: "claude-code")
            }
            let r = CLIInputImporter.scanClaudeCode(since: since)
            return (r.count, r.sessions, since)
        }.value
        ccCount = count
        ccSessions = sessions
        ccLastTs = since
        ccScanning = false
    }

    private func rescanCodex(quiet: Bool = false) async {
        if !quiet { codexScanning = true }
        let dbPool = (services?.db as? PortraitDBImpl)?.dbPool
        let (count, sessions, since) = await Task.detached(priority: .userInitiated) {
            var since: Int64? = nil
            if let dbPool {
                since = try? WritingCaptureStore(dbPool: dbPool).cliImportLastTs(app: "codex-cli")
            }
            let r = CLIInputImporter.scanCodex(since: since)
            return (r.count, r.sessions, since)
        }.value
        codexCount = count
        codexSessions = sessions
        codexLastTs = since
        codexScanning = false
    }

    /// 单源导入 —— app 取 "claude-code" 或 "codex-cli"。
    private func runImport(app: String) async {
        let isCC = app == "claude-code"
        func setStatus(_ s: String?) { if isCC { ccStatus = s } else { codexStatus = s } }
        func setProgress(_ p: CLIImportProgress?) { if isCC { ccProgress = p } else { codexProgress = p } }

        if isCC { ccRunning = true } else { codexRunning = true }
        setStatus(nil)
        setProgress(CLIImportProgress(label: "Reading session logs…", current: 0, total: 0, indeterminate: true))
        defer {
            if isCC { ccRunning = false } else { codexRunning = false }
            setProgress(nil)
        }

        guard let dbImpl = services?.db as? PortraitDBImpl else {
            setStatus("Portrait DB not available.")
            return
        }
        let dbPool = dbImpl.dbPool
        let result: (inserted: Int, skipped: Int)
        do {
            result = try await Task.detached(priority: .userInitiated) {
                let store = WritingCaptureStore(dbPool: dbPool)
                let since = try? store.cliImportLastTs(app: app)
                let rows = isCC
                    ? CLIInputImporter.collectClaudeCode(since: since)
                    : CLIInputImporter.collectCodex(since: since)
                // 写库阶段:确定性进度条。回调跳回 MainActor 更新 @State。
                return try store.insertCLIImported(rows) { current, total in
                    Task { @MainActor in
                        let p = CLIImportProgress(
                            label: "Importing…", current: current, total: total, indeterminate: false)
                        if isCC { self.ccProgress = p } else { self.codexProgress = p }
                    }
                }
            }.value
        } catch {
            setStatus("Failed: \(error.localizedDescription)")
            return
        }
        setStatus("Done. \(result.inserted) imported, \(result.skipped) already present.")
        // 静默刷新该源的游标/计数,不再闪 scan spinner。只刷新刚导入的那个源。
        if isCC { await rescanClaudeCode(quiet: true) } else { await rescanCodex(quiet: true) }
    }

    // MARK: scan UI

    private var scanningRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning ~/.screenpipe / Library / Documents …")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 手动模式(Auto-scan off)下还没扫过 —— 提示 + Scan 按钮。
    private var notScannedBlock: some View {
        // 跟 Claude Code / Codex 的未扫描卡片一致:绿色 source 图标 + 名 + 灰 Scan 按钮 + 简短提示。
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.green)
                Text("screenpipe")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Scan") { Task { await rescan() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Not scanned — press Scan above.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func foundBlock(_ s: ScreenpipeImporter.ScanResult) -> some View {
        let nothingNew = !s.hasAnythingToImport
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: nothingNew
                      ? "checkmark.seal.fill"
                      : "checkmark.circle.fill")
                    .foregroundStyle(nothingNew ? .blue : .green)
                Text(nothingNew
                     ? "Already up to date"
                     : "Found screenpipe data")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Re-scan") { Task { await rescan() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            statRow("Path",         s.sourceDir.path, mono: true)
            statRow("OCR frames",   "\(s.frameCount.formatted()) to import", mono: false)
            statRow("Video chunks", "\(s.videoChunkCount.formatted()) MP4(s) · ~\(Self.bytesHuman(s.videoBytesEst)) to copy", mono: false)
            statRow("Audio chunks", "\(s.audioChunkCount.formatted()) to import", mono: false)
            statRow("Audio transcripts", "\(s.audioTranscriptCount.formatted()) to import", mono: false)
            if let cutoff = s.cutoffMs {
                statRow("Cutoff",
                        "only data BEFORE \(Self.shortDate(cutoff)) is imported (your earliest data)",
                        mono: false)
            }
            if let mn = s.earliestMs, let mx = s.latestMs {
                statRow("Source range",
                        "\(Self.shortDate(mn))  →  \(Self.shortDate(mx))",
                        mono: false)
            }
            if nothingNew {
                Text("Everything older than your cutoff has already been imported. Nothing left to copy.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    pickFolder()
                } label: {
                    Label("Pick a different folder", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(running ? "Importing…" : "Import") {
                    Task { await runImport(source: s.sourceDir) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(running || nothingNew)
                .help(nothingNew
                      ? "Nothing new to import."
                      : "Copy frames + transcripts older than your cutoff into My Portrait.")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var notFoundBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("No screenpipe data found")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Re-scan") { Task { await rescan() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Searched ~/.screenpipe, ~/Library/Application Support/screenpipe, and ~/Documents/screenpipe. If your data is somewhere else, pick the folder manually.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button {
                    pickFolder()
                } label: {
                    Label("Pick folder…", systemImage: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: status / summary

    @ViewBuilder
    private func progressBlock(_ p: ScreenpipeImporter.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(Self.stageTitle(p.stage))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if p.total > 0 {
                    Text("\(p.current.formatted()) / \(p.total.formatted())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if p.total > 0 {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            }
            if p.stage == .copyingVideo, p.bytesTotal > 0 {
                Text("\(Self.bytesHuman(p.bytesDone))  /  \(Self.bytesHuman(p.bytesTotal))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static func stageTitle(_ s: ScreenpipeImporter.Progress.Stage) -> String {
        switch s {
        case .scanning:        return "Preparing…"
        case .copyingVideo:    return "Copying video chunks"
        case .importingFrames: return "Importing frames (OCR text)"
        case .importingAudio:  return "Importing audio transcripts"
        case .done:            return "Done"
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(statusLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func summaryBlock(_ r: ScreenpipeImporter.Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST IMPORT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            statRow("Screen text",       "\(r.framesImported + r.framesBackfilled) added · \(r.skippedFramesNoOCR) skipped (no text found)", mono: false)
            statRow("Video chunks",      "\(r.videoChunksImported) MP4(s) copied · \(Self.bytesHuman(r.videoBytesCopied))", mono: false)
            statRow("Audio chunks",      "\(r.audioChunksImported) imported", mono: false)
            statRow("Audio transcripts", "\(r.audioTranscriptsImported) imported", mono: false)
            statRow("Cutoff",            Self.cutoffDescription(r.cutoffMs), mono: false)
            Text("Next: run Process events in Memory settings to turn this into memories.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func errorBlock(_ err: String) -> some View {
        Text("Error: \(err)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func statRow(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: actions

    private static func shortDate(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: d)
    }

    /// "1.2 GB" / "812 MB" / "34 KB" ——给 UI 显示磁盘占用估算。
    private static func bytesHuman(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private static func cutoffDescription(_ ms: Int64?) -> String {
        guard let ms = ms else {
            return "no cutoff (My Portrait was empty, imported all)"
        }
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return "imported only data BEFORE \(fmt.string(from: d))"
    }

    private func rescan() async {
        scanning = true
        defer { scanning = false }
        // 先从 My-Portrait DB 拿 cutoff,再扫盘按 cutoff 过滤源端 count。
        // cutoff = 最早**带媒体**的 frame ts,允许 backfill 老 NULL-media
        // imported frames(B 方案场景)。
        let dbImpl = services?.db as? PortraitDBImpl
        let dbPool = dbImpl?.dbPool
        let override = overrideDir
        let result = await Task.detached(priority: .userInitiated) { () -> ScreenpipeImporter.ScanResult in
            let cutoff: Int64? = {
                guard let pool = dbPool else { return nil }
                return (try? pool.read { db in
                    try Int64.fetchOne(db, sql: """
                        SELECT MIN(timestamp_ms) FROM frames
                        WHERE snapshot_path IS NOT NULL OR video_chunk_id IS NOT NULL
                        """)
                }) ?? nil
            }()
            if let dir = override {
                return (try? ScreenpipeImporter.scanSingle(dir: dir, cutoffMs: cutoff))
                    ?? ScreenpipeImporter.ScanResult(
                        sourceDir: dir,
                        dbPath: dir.appendingPathComponent("db.sqlite"),
                        exists: false, cutoffMs: cutoff,
                        frameCount: 0,
                        videoChunkCount: 0, videoBytesEst: 0,
                        audioChunkCount: 0, audioTranscriptCount: 0,
                        earliestMs: nil, latestMs: nil
                    )
            }
            return ScreenpipeImporter.scan(cutoffMs: cutoff)
        }.value
        scan = result
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a screenpipe data folder (the one containing db.sqlite)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        overrideDir = url
        Task { await rescan() }
    }

    private func runImport(source: URL) async {
        running = true
        statusLines = ["Importing from \(source.path)…"]
        lastReport = nil
        errorMessage = nil
        progress = nil
        defer {
            running = false
            progress = nil
        }

        guard let dbImpl = services?.db as? PortraitDBImpl else {
            errorMessage = "Portrait DB not available (Services not initialized)."
            return
        }
        let dbPool = dbImpl.dbPool
        do {
            let importer = ScreenpipeImporter(sourceDir: source)
            // progress callback 跑在 detached task 上,跳回 MainActor 更新 @State。
            let r = try await importer.run(into: dbPool) { p in
                Task { @MainActor in self.progress = p }
            }
            statusLines.append("Done.")
            lastReport = r
        } catch {
            errorMessage = error.localizedDescription
            statusLines.append("Failed.")
        }
    }
}
