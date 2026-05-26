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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Found screenpipe data")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Re-scan") { Task { await rescan() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            statRow("Path",       s.sourceDir.path,                        mono: true)
            statRow("OCR frames", "\(s.frameCount.formatted()) importable",mono: false)
            if let mn = s.earliestMs, let mx = s.latestMs {
                statRow("Range",
                        "\(Self.shortDate(mn))  →  \(Self.shortDate(mx))",
                        mono: false)
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
                .disabled(running || s.frameCount == 0)
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
        // 后台跑 scan,SQLite query 是同步 IO。
        let result = await Task.detached(priority: .userInitiated) {
            // 用户选过自定义路径就只扫那条;否则走 candidateDirs 全扫。
            if let dir = await MainActor.run(body: { self.overrideDir }) {
                return Self.scanSingleDir(dir)
            }
            return ScreenpipeImporter.scan()
        }.value
        scan = result
    }

    /// 单目录扫盘(用户 picker 选的)。内部复用 ScreenpipeImporter.scan 的
    /// candidate 路径检测逻辑,但只测一条路径。nonisolated 让 Task.detached
    /// 能直接调,不被 MainActor 隔离阻塞。
    nonisolated private static func scanSingleDir(_ dir: URL) -> ScreenpipeImporter.ScanResult {
        let db = dir.appendingPathComponent("db.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else {
            return ScreenpipeImporter.ScanResult(
                sourceDir: dir, dbPath: db, exists: false,
                frameCount: 0, earliestMs: nil, latestMs: nil
            )
        }
        // 把 dir 临时塞 candidateDirs 头部 —— 简单粗暴:直接复用全 scan,它会
        // 优先返回找到的第一个。但 candidate 是固定的,这里不能直接覆盖。
        // 改:复刻一份 scan 逻辑只跑这条路径。
        do {
            var c = Configuration()
            c.readonly = true
            let q = try DatabaseQueue(path: db.path, configuration: c)
            let (cnt, minMs, maxMs): (Int, Int64?, Int64?) = try q.read { d in
                let cnt = (try? Int.fetchOne(
                    d,
                    sql: """
                        SELECT COUNT(*) FROM frames f
                        INNER JOIN ocr_text o ON o.frame_id = f.id
                        WHERE o.text IS NOT NULL AND o.text != ''
                        """
                )) ?? 0
                let minTs: String? = (try? String.fetchOne(d, sql: "SELECT MIN(timestamp) FROM frames")) ?? nil
                let maxTs: String? = (try? String.fetchOne(d, sql: "SELECT MAX(timestamp) FROM frames")) ?? nil
                return (cnt, minTs.flatMap(isoToMs), maxTs.flatMap(isoToMs))
            }
            return ScreenpipeImporter.ScanResult(
                sourceDir: dir, dbPath: db, exists: true,
                frameCount: cnt, earliestMs: minMs, latestMs: maxMs
            )
        } catch {
            return ScreenpipeImporter.ScanResult(
                sourceDir: dir, dbPath: db, exists: false,
                frameCount: 0, earliestMs: nil, latestMs: nil
            )
        }
    }

    /// 复用 ScreenpipeImporter 私有的 ISO→ms 转换(public-internal 接口)。
    /// scanSingleDir 里要用,通过这个 trampoline 转发。
    nonisolated private static func isoToMs(_ s: String) -> Int64? {
        // 跟 ScreenpipeImporter.isoToMs 同实现 —— private 不能跨 struct
        // 调,这里复刻一份(就 10 行,不抽 protocol)。
        guard !s.isEmpty else { return nil }
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso1.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = df.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        if let d = df.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        return nil
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
