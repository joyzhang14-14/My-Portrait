import SwiftUI
import AppKit
import GRDB

/// Settings → Data → Import:从 ~/.screenpipe(或用户指定路径)把 frames +
/// audio transcripts 搬到 My-Portrait,只导比当前最早数据老的部分。
struct ImportSettingsView: View {

    @Environment(\.services) private var services

    /// 用户选的源路径,默认 ~/.screenpipe。
    @State private var sourcePath: String = ScreenpipeImporter.defaultSourceDir.path
    @State private var running: Bool = false
    @State private var statusLines: [String] = []
    @State private var lastReport: ScreenpipeImporter.Report? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        SettingsPage(
            "Import",
            subtitle: "Bring historical data from other capture tools into My Portrait."
        ) {
            SettingsCard(
                title: "Import from screenpipe",
                footnote: "Reads ~/.screenpipe/db.sqlite and copies frames (OCR text + app + URL) and audio transcripts that are OLDER than the earliest data My Portrait already has. Existing My Portrait data is never touched. Media files (MP4 / WAV / JPG) are NOT imported — only the searchable metadata. After import you can run Settings → Memory → Scheduler → Process events to distill the new data into events."
            ) {
                pathRow
                SettingsDivider()
                runRow
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
    }

    // MARK: rows

    private var pathRow: some View {
        SettingsRow(
            "Source folder",
            description: "Path to a screenpipe data directory. Defaults to ~/.screenpipe.",
            icon: "folder"
        ) {
            HStack(spacing: 8) {
                TextField("/Users/you/.screenpipe", text: $sourcePath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 220)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                    )
                Button {
                    pickFolder()
                } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Pick a folder…")
            }
        }
    }

    private var runRow: some View {
        SettingsRow(
            "Run import",
            description: "Only data older than My Portrait's earliest record will be imported. Existing data is preserved.",
            icon: "tray.and.arrow.down"
        ) {
            Button(running ? "Importing…" : "Import") {
                Task { await runImport() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(running || sourcePath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

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
            statLine("Frames",         "\(r.framesImported) imported · \(r.skippedFramesNoOCR) skipped (no OCR)")
            statLine("Audio chunks",   "\(r.audioChunksImported) imported")
            statLine("Audio transcripts", "\(r.audioTranscriptsImported) imported")
            statLine("Cutoff", Self.cutoffDescription(r.cutoffMs))
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

    private static func cutoffDescription(_ ms: Int64?) -> String {
        guard let ms = ms else {
            return "no cutoff (My Portrait was empty, imported all)"
        }
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return "imported only data BEFORE \(fmt.string(from: d))"
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a screenpipe data folder (the one containing db.sqlite)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
    }

    private func runImport() async {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        running = true
        statusLines = ["Scanning \(trimmed)…"]
        lastReport = nil
        errorMessage = nil
        defer { running = false }

        // 通过 SwiftUI \.services 环境注入拿 DB(PortraitDB 是 protocol,
        // 实际是 PortraitDBImpl,有 dbPool let)。
        guard let dbImpl = services?.db as? PortraitDBImpl else {
            errorMessage = "Portrait DB not available (Services not initialized)."
            return
        }
        let dbPool = dbImpl.dbPool
        do {
            let importer = ScreenpipeImporter(sourceDir: URL(fileURLWithPath: trimmed))
            statusLines.append("Running import…")
            let r = try await importer.run(into: dbPool)
            statusLines.append("Done.")
            lastReport = r
        } catch {
            errorMessage = error.localizedDescription
            statusLines.append("Failed.")
        }
    }
}
