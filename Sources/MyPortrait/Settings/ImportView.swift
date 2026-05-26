import SwiftUI
import AppKit
import GRDB

/// Settings → Data → Import:启动时自动扫盘 ~/.screenpipe / Library / Documents,
/// 找到 screenpipe DB → 显示 frame 数 + 日期范围 + Import 按钮。
/// 找不到 → 提示"未找到" + Pick folder 兜底。
///
/// 只导比 My-Portrait 最早数据老的部分,从不动当前数据。
struct ImportSettingsView: View {

    @Environment(\.services) private var services

    @State private var scan: ScreenpipeImporter.ScanResult? = nil
    @State private var scanning: Bool = true
    @State private var running: Bool = false
    @State private var statusLines: [String] = []
    @State private var lastReport: ScreenpipeImporter.Report? = nil
    @State private var errorMessage: String? = nil
    /// 用户用 folder picker 选了自定义 path → 覆盖自动扫盘。
    @State private var overrideDir: URL? = nil

    var body: some View {
        SettingsPage(
            "Import",
            subtitle: "Bring historical data from other capture tools into My Portrait."
        ) {
            SettingsCard(
                title: "Import from screenpipe",
                footnote: "Copies frames (OCR text + app + URL) and audio transcripts that are OLDER than the earliest data My Portrait already has. Existing My Portrait data is never touched. Media files (MP4 / WAV / JPG) are NOT imported — only the searchable metadata. After import you can run Settings → Memory → Scheduler → Process events to distill the new data into events."
            ) {
                if scanning {
                    scanningRow
                } else if let s = scan, s.exists {
                    foundBlock(s)
                } else {
                    notFoundBlock
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
        }
        .task { await rescan() }
    }

    // MARK: scan UI

    private var scanningRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning ~/.screenpipe / Library / Documents …")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
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
                    .foregroundStyle(.white.opacity(0.55))
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
                .foregroundStyle(.white.opacity(0.55))
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
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(statusLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
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
                .foregroundStyle(.white.opacity(0.45))
            statRow("Frames",            "\(r.framesImported) imported · \(r.skippedFramesNoOCR) skipped (no OCR)", mono: false)
            statRow("Audio chunks",      "\(r.audioChunksImported) imported", mono: false)
            statRow("Audio transcripts", "\(r.audioTranscriptsImported) imported", mono: false)
            statRow("Cutoff",            Self.cutoffDescription(r.cutoffMs), mono: false)
            Text("Next: Settings → Memory → Scheduler → Process events to distill the new data into events.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
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
                .foregroundStyle(.white.opacity(0.50))
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.92))
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
        let dbImpl = services?.db as? PortraitDBImpl
        let dbPool = dbImpl?.dbPool
        let override = overrideDir
        let result = await Task.detached(priority: .userInitiated) { () -> ScreenpipeImporter.ScanResult in
            let cutoff: Int64? = {
                guard let pool = dbPool else { return nil }
                return (try? pool.read { db in
                    try Int64.fetchOne(db, sql: "SELECT MIN(timestamp_ms) FROM frames")
                }) ?? nil
            }()
            if let dir = override {
                return (try? ScreenpipeImporter.scanSingle(dir: dir, cutoffMs: cutoff))
                    ?? ScreenpipeImporter.ScanResult(
                        sourceDir: dir,
                        dbPath: dir.appendingPathComponent("db.sqlite"),
                        exists: false, cutoffMs: cutoff,
                        frameCount: 0, audioChunkCount: 0, audioTranscriptCount: 0,
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
        defer { running = false }

        guard let dbImpl = services?.db as? PortraitDBImpl else {
            errorMessage = "Portrait DB not available (Services not initialized)."
            return
        }
        let dbPool = dbImpl.dbPool
        do {
            let importer = ScreenpipeImporter(sourceDir: source)
            let r = try await importer.run(into: dbPool)
            statusLines.append("Done.")
            lastReport = r
        } catch {
            errorMessage = error.localizedDescription
            statusLines.append("Failed.")
        }
    }
}
