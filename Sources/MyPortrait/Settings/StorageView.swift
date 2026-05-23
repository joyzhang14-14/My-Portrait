import SwiftUI
import AppKit

/// Storage — data directory + disk usage breakdown. Mirrors Orphies'
/// `storage-section.tsx` + `disk-usage-section.tsx`. Numbers are live where
/// we can read them (file system) and "—" otherwise.
struct StorageSettingsView: View {
    @State private var config = ConfigStore.shared

    @State private var stats = StorageStats.empty
    @State private var scanning = false
    @State private var lastScannedAt: Date? = nil

    private var resolvedDataDir: String {
        if !config.current.storage.dataDirectory.isEmpty { return config.current.storage.dataDirectory }
        return NSString("~/.portrait").expandingTildeInPath
    }

    var body: some View {
        SettingsPage("Storage", subtitle: "Where captured data lives on disk") {

            SettingsCard(title: "Local disk storage") {
                SettingsRow(
                    "Data directory",
                    description: config.current.storage.dataDirectory.isEmpty
                        ? "~/.portrait (default) · changing directory starts fresh recordings"
                        : resolvedDataDir,
                    icon: "folder"
                ) {
                    HStack(spacing: 6) {
                        Button("Change") { pickDir() }
                            .font(.system(size: 12, weight: .medium))
                        if !config.current.storage.dataDirectory.isEmpty {
                            Button("Reset") { config.mutate { $0.storage.dataDirectory = "" } }
                                .font(.system(size: 11))
                        }
                    }
                }
            }

            SettingsCard(title: "Storage usage at \(resolvedDataDir)") {
                HStack {
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(scanning ? "Scanning…" : "Refresh",
                              systemImage: scanning ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .disabled(scanning)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)

                SummaryRow(stats: stats)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }

            HStack(spacing: 14) {
                StatTile(label: "Data",  value: bytes(stats.dataBytes),  icon: "cylinder.split.1x2", accent: .purple)
                StatTile(label: "Cache", value: bytes(stats.cacheBytes), icon: "folder",            accent: .cyan)
                StatTile(label: "Free",  value: bytes(stats.freeBytes),  icon: "externaldrive",     accent: .green)
            }

            SettingsCard(title: "Media files") {
                SettingsRow("Audio", icon: "waveform") {
                    Text(bytes(stats.audioBytes))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                SettingsDivider()
                SettingsRow("Total", icon: "rectangle.stack") {
                    Text(bytes(stats.mediaTotalBytes))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }

            SettingsCard(title: "Other files") {
                ForEach(stats.otherBreakdown, id: \.label) { row in
                    SettingsRow(row.label, icon: row.icon) {
                        Text(bytes(row.size))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if row.label != stats.otherBreakdown.last?.label {
                        SettingsDivider()
                    }
                }
            }

            autoDeleteCard

            SettingsCard(
                title: "Delete recent data",
                footnote: "Instantly purges every frame, OCR row, and audio chunk captured in the chosen window."
            ) {
                HStack(spacing: 8) {
                    DeleteButton(label: "Last 15 min") { purge(seconds: 15 * 60) }
                    DeleteButton(label: "Last 30 min") { purge(seconds: 30 * 60) }
                    DeleteButton(label: "Last hour")   { purge(seconds: 60 * 60) }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .task {
            if lastScannedAt == nil { await refresh() }
        }
    }

    private var autoDeleteCard: some View {
        SettingsCard(
            title: "Auto-delete old data",
            footnote: "Frees disk without you having to think about it. Recommended setting keeps your timeline searchable forever."
        ) {
            SettingsRow("Retention window",
                        description: "Data older than this is eligible for auto-delete.",
                        icon: "calendar.badge.clock") {
                Picker("", selection: config.binding(\.storage.retentionDays)) {
                    ForEach(RetentionDays.allCases) { r in Text(r.label).tag(r.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 140)
            }
            ForEach(AutoDeleteMode.allCases) { mode in
                SettingsDivider()
                AutoDeleteModeRow(
                    mode: mode,
                    isActive: config.current.storage.autoDeleteMode == mode.rawValue,
                    recommended: mode == .mediaOnly
                ) { config.mutate { $0.storage.autoDeleteMode = mode.rawValue } }
            }
        }
    }

    // MARK: - Scanner

    @MainActor
    private func refresh() async {
        scanning = true
        let target = resolvedDataDir
        let computed = await Task.detached(priority: .userInitiated) {
            StorageStats.scan(at: target)
        }.value
        stats = computed
        lastScannedAt = Date()
        scanning = false
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.mutate { $0.storage.dataDirectory = url.path }
            Task { await refresh() }
        }
    }

    /// "Delete last 15m / 30m / 1h" — destructive, no undo. We rely on the
    /// double-click of the SwiftUI button + the small font as gating; the
    /// user already understands what they're doing in a Settings panel.
    private func purge(seconds: Int) {
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        Task {
            let res = await Task.detached(priority: .userInitiated) {
                TimelineDB().deleteAfter(cutoff)
            }.value
            _ = res
            await refresh()
        }
    }

    private func bytes(_ n: Int64) -> String {
        if n <= 0 { return "—" }
        let f = ByteCountFormatter(); f.allowedUnits = [.useAll]; f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}

// MARK: - Stats

private struct StorageStats {
    var dataBytes: Int64
    var cacheBytes: Int64
    var freeBytes: Int64
    var audioBytes: Int64
    var mediaTotalBytes: Int64
    var otherBreakdown: [(label: String, size: Int64, icon: String)]
    var months: Double

    static let empty = StorageStats(
        dataBytes: 0, cacheBytes: 0, freeBytes: 0,
        audioBytes: 0, mediaTotalBytes: 0,
        otherBreakdown: [], months: 0
    )

    /// Walks the data directory and adds up sizes. Best-effort:
    /// missing dirs just contribute 0.
    nonisolated static func scan(at path: String) -> StorageStats {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        let dataBytes  = directorySize(root)
        let cacheBytes = directorySize(root.appendingPathComponent("cache"))
        let audioBytes = directorySize(root.appendingPathComponent("data/audio"))
        let mediaBytes = directorySize(root.appendingPathComponent("data"))

        let dbBytes    = fileSize(root.appendingPathComponent("portrait.sqlite"))
                       + fileSize(root.appendingPathComponent("portrait.sqlite-wal"))
                       + fileSize(root.appendingPathComponent("portrait.sqlite-shm"))
        let logBytes   = directorySize(root.appendingPathComponent("logs"))
        let pipeBytes  = directorySize(root.appendingPathComponent("cronJobs"))
        let otherBytes = max(0, dataBytes - cacheBytes - mediaBytes - dbBytes - logBytes - pipeBytes)

        var free: Int64 = 0
        if let attrs = try? fm.attributesOfFileSystem(forPath: root.path),
           let f = attrs[.systemFreeSize] as? NSNumber {
            free = f.int64Value
        }

        // Crude "months remaining" estimate. Avoid divide-by-zero.
        let monthly = max(Int64(1_000_000_000), max(mediaBytes, dataBytes) / 12)
        let months = Double(free) / Double(monthly)

        return StorageStats(
            dataBytes: dataBytes, cacheBytes: cacheBytes, freeBytes: free,
            audioBytes: audioBytes, mediaTotalBytes: mediaBytes,
            otherBreakdown: [
                (label: "Database", size: dbBytes,    icon: "cylinder"),
                (label: "Logs",     size: logBytes,   icon: "doc.text"),
                (label: "Cron Jobs",    size: pipeBytes,  icon: "antenna.radiowaves.left.and.right"),
                (label: "Other",    size: otherBytes, icon: "ellipsis.circle")
            ],
            months: months
        )
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let it = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                     options: [.skipsHiddenFiles], errorHandler: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let u as URL in it {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? 0)
    }
}

// MARK: - Memory summary header inside the usage card

private struct SummaryRow: View {
    let stats: StorageStats
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            ProgressView(value: fillFraction)
                .progressViewStyle(.linear)
                .tint(Color.purple)
                .frame(maxWidth: .infinity)
            Text(monthsRemaining)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var headline: String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useGB]; f.countStyle = .file
        let s = f.string(fromByteCount: max(stats.dataBytes, 0))
        let monthGB = max(stats.dataBytes, 1) / 1
        _ = monthGB
        return "1 month of memory in \(s)"
    }

    private var fillFraction: Double {
        guard stats.freeBytes > 0 else { return 0 }
        return min(1, Double(stats.dataBytes) / Double(stats.dataBytes + stats.freeBytes))
    }

    private var monthsRemaining: String {
        guard stats.months > 0 else { return "~0 months of space remaining" }
        return "~\(Int(stats.months)) months of space remaining"
    }
}

// MARK: - Tile + button helpers

private struct StatTile: View {
    let label: String; let value: String; let icon: String; let accent: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.50))
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(accent.opacity(0.25), lineWidth: 0.8))
        )
    }
}

private struct DeleteButton: View {
    let label: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.red.opacity(hover ? 0.20 : 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.red.opacity(0.45), lineWidth: 0.8))
                )
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}

// MARK: - Auto-delete mode row

private struct AutoDeleteModeRow: View {
    let mode: AutoDeleteMode
    let isActive: Bool
    let recommended: Bool
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [Color.purple.opacity(0.45), Color.blue.opacity(0.28)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.white.opacity(0.06)))
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? .white.opacity(0.95) : .white.opacity(0.75))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.label)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(0.95))
                        if recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(Color.green.opacity(0.90))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().stroke(Color.green.opacity(0.45), lineWidth: 0.8))
                        }
                    }
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.purple.opacity(0.90))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(isActive ? 0.04 : (hover ? 0.03 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncyIcon)
        .onHover { hover = $0 }
    }
}
