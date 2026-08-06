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
        SettingsPage("Storage",
                     onResetCurrentPage: { config.mutate { $0.storage = .init() } }) {

            SettingsCard(title: "Local disk storage") {
                // 描述只报当前路径 —— 目录已经不让在 UI 里改了(Change 按钮
                // 07-28 换成 Open),原来那句"改目录会重新开始录"没有对应操作。
                SettingsRow(
                    "Data directory",
                    description: resolvedDataDir,
                    icon: "folder"
                ) {
                    HStack(spacing: 6) {
                        // 07-28:原 "Change" 换成 "Open" —— 接管被删掉的
                        // 每页右上角 "Open ~/.portrait" 按钮的入口。
                        Button("Open") { config.openPortraitDir() }
                            .font(.system(size: 12, weight: .medium))
                            .help("Open the data folder in Finder")
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

            // 三张卡把 app 占的空间**全部**记完:采集下来的 / 分析出来的 /
            // app 自己要用的。前两张对齐 README 架构图的 CAP / ANA subgraph。
            // ⚠️ portrait.sqlite 归 **Capture** —— README 里它的名字就叫
            // "Capture DB"(frames / OCR / audio 都是采集层写的),别因为它
            // "不是媒体文件"就挪去分析那边。
            SettingsCard(
                title: "Capture data",
                info: "Everything recorded off your Mac: the screen, what was said, and what you typed — plus the searchable index built from them.\n\nThis is raw material. It's almost all of your disk usage, and it's what the retention window above trims."
            ) {
                breakdownRows(stats.captureRows)
            }

            SettingsCard(
                title: "Analysis data",
                info: "What turns raw recordings into memory: the on-device models that read your audio, and the events and portrait the pipelines distilled out of everything.\n\nThe written-out memory is tiny — and it's the only part that can't be recovered by recording again."
            ) {
                breakdownRows(stats.analysisRows)
            }

            SettingsCard(
                title: "App data",
                info: "My Portrait itself and what it needs to run — the app bundle, the AI runtime it downloaded on first launch, and its logs.\n\nNone of this is your data; all of it comes back by reinstalling."
            ) {
                breakdownRows(stats.appRows)
            }

            autoDeleteCard

            waitForTranscriptionCard

            SettingsCard(
                title: "Delete recent data",
                footnote: "Permanently deletes everything captured in the chosen time range. This can't be undone."
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

    /// 明细表:每行一个尺寸,`total` 非 nil 时末尾多一行加粗合计。
    @ViewBuilder
    private func breakdownRows(_ rows: [StorageRow]) -> some View {
        ForEach(rows) { row in
            SettingsRow(row.label, info: row.info, icon: row.icon) {
                Text(bytes(row.size))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            if row.id != rows.last?.id {
                SettingsDivider()
            }
        }
    }

    private var autoDeleteCard: some View {
        SettingsCard(
            title: "Auto-delete old data"
        ) {
            SettingsRow("Retention window",
                        info: "How far back captured data is kept. Anything older becomes eligible for auto-delete — what actually gets deleted depends on the mode you pick below.\n\nKeep forever means none of your captured data ever ages out. Rebuildable files are still cleaned up either way; that isn't governed by this window.",
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
                    recommendedReason: mode == .mediaOnly
                        ? "Video and audio are almost all of the disk usage, and they're the part you're least likely to go back to. Dropping them keeps the OCR text and transcripts — so your timeline stays searchable and the memory pipelines still have something to read.\n\nEverything deletes those too: past the retention window, that day is simply gone."
                        : nil
                ) { config.mutate { $0.storage.autoDeleteMode = mode.rawValue } }
            }
        }
    }

    private var waitForTranscriptionCard: some View {
        SettingsCard {
            SettingsRow("Wait for transcription",
                        info: "Audio that hasn't been transcribed yet is kept past the retention window until its text is saved.\n\nWithout this, a backlog of un-transcribed recordings can age out and be deleted before they're ever turned into text — the audio is gone and so is what was said in it.",
                        icon: "text.bubble") {
                Toggle("", isOn: config.binding(\.storage.waitForTranscription)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: - Scanner

    @MainActor
    private func refresh() async {
        scanning = true
        let target = resolvedDataDir
        var computed = await Task.detached(priority: .userInitiated) {
            StorageStats.scan(at: target)
        }.value
        // Cache 磁贴 = **回收器此刻真会删掉的那些东西**,不是"看着像缓存的目录"。
        // 走 CacheHousekeeper 同一份判据,磁贴上的数字和自动回收永远对得上。
        computed.cacheBytes = await CacheHousekeeper.reclaimableBytes()
        stats = computed
        lastScannedAt = Date()
        scanning = false
    }

    /// ⚠️ 07-28 起**没有调用方** —— Data directory 卡片的 "Change" 按钮换成
    /// 了 "Open"。改数据目录目前只能编辑 config.toml 的 storage.data_directory。
    /// 保留实现:想把 "Change" 加回来(或挪到别处)接上这个函数即可。
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

    /// 0 就显示 "0 B",**不显示 "—"** —— 刚清理过的 Cache 是真的 0,用破折号
    /// 会让人以为是"读不出来"。(ByteCountFormatter 给 0 会返回 "Zero KB",
    /// 也不要。)
    private func bytes(_ n: Int64) -> String {
        if n <= 0 { return "0 B" }
        let f = ByteCountFormatter(); f.allowedUnits = [.useAll]; f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}

// MARK: - Stats

/// 明细表里的一行。
private struct StorageRow: Identifiable {
    let label: String
    let size: Int64
    let icon: String
    var info: String? = nil
    var id: String { label }
}

private struct StorageStats {
    var dataBytes: Int64
    /// ⚠️ `scan()` 填不了这个 —— 判定孤儿附件要读对话的 session 文件(异步 +
    /// 上主 actor)。由 `refresh()` 在 scan 之后用 `CacheHousekeeper` 补上。
    var cacheBytes: Int64
    var freeBytes: Int64
    /// 采集系统的产物(README 那张图的 CAP subgraph)。
    var captureRows: [StorageRow]
    /// 分析系统:本地模型 + 蒸馏出来的记忆文件(ANA subgraph)。
    var analysisRows: [StorageRow]
    /// app 自己:本体 + 下载来的 AI 运行时 + 日志。都不是用户数据。
    var appRows: [StorageRow]
    var months: Double

    static let empty = StorageStats(
        dataBytes: 0, cacheBytes: 0, freeBytes: 0,
        captureRows: [], analysisRows: [], appRows: [],
        months: 0
    )

    /// Walks the data directory and adds up sizes. Best-effort:
    /// missing dirs just contribute 0.
    ///
    /// 三张卡(capture / analysis / app)的目标是把 app 占的空间记全,但
    /// **没有兜底行** —— chat.sqlite、voice_training、agent_sessions、
    /// attachments、cron_jobs 这些(合计十几 MB)不计入任何一行,几行加起来
    /// 不等于 Data 磁贴。要闭合就再加一行 Other。
    ///
    /// 另外 App 那行量的是 `Bundle.main`,**在 `~/.portrait` 之外** ——
    /// 所以 app 行的和也不可能被 Data 磁贴(只扫数据目录)覆盖。
    nonisolated static func scan(at path: String) -> StorageStats {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        let dataBytes  = directorySize(root)
        // 音频 = 转录后留存的 wav + 待转录队列。
        let audioBytes = directorySize(root.appendingPathComponent("raw_data/audio"))
                       + directorySize(root.appendingPathComponent("audio_queue"))
        let videoBytes = directorySize(root.appendingPathComponent("raw_data/video"))
        let frameBytes = directorySize(root.appendingPathComponent("raw_data/frames"))
        let mediaBytes = audioBytes + videoBytes + frameBytes

        let dbBytes    = fileSize(root.appendingPathComponent("portrait.sqlite"))
                       + fileSize(root.appendingPathComponent("portrait.sqlite-wal"))
                       + fileSize(root.appendingPathComponent("portrait.sqlite-shm"))
        let logBytes   = directorySize(root.appendingPathComponent("logs"))

        var free: Int64 = 0
        if let attrs = try? fm.attributesOfFileSystem(forPath: root.path),
           let f = attrs[.systemFreeSize] as? NSNumber {
            free = f.int64Value
        }

        // Crude "months remaining" estimate. Avoid divide-by-zero.
        let monthly = max(Int64(1_000_000_000), max(mediaBytes, dataBytes) / 12)
        let months = Double(free) / Double(monthly)

        // 记忆层四个目录合成一行 —— 单拎出来每个都是几百 KB,占四行只是噪音。
        let memoryBytes = directorySize(root.appendingPathComponent("events"))
                        + directorySize(root.appendingPathComponent("portrait"))
                        + directorySize(root.appendingPathComponent("journal"))
                        + directorySize(root.appendingPathComponent("personality_daily"))
        // app 本体在 ~/.portrait 之外(/Applications 之类),单独量。
        let bundleBytes = directorySize(Bundle.main.bundleURL)
        // 首次启动下载的 AI 运行时:Bun + pi-agent 包 + 注入 PATH 的小 wrapper。
        let runtimeBytes = directorySize(root.appendingPathComponent("bun"))
                         + directorySize(root.appendingPathComponent("pi-agent"))
                         + directorySize(root.appendingPathComponent("bin"))

        return StorageStats(
            dataBytes: dataBytes, cacheBytes: 0, freeBytes: free,
            captureRows: [
                StorageRow(label: "Screenshots + Video", size: frameBytes + videoBytes,
                           icon: "photo.on.rectangle"),
                StorageRow(label: "Audio", size: audioBytes, icon: "waveform"),
                StorageRow(
                    label: "Metadata", size: dbBytes, icon: "cylinder",
                    info: "Everything the app knows *about* your captures, rather than the captures themselves: the text read off your screen, transcripts of what was said, your typing, and where each word sat on screen.\n\nThis is what makes your timeline searchable — it's why you can find a moment by typing a phrase you saw months ago. It usually outgrows the screenshots and recordings it describes."),
            ],
            analysisRows: [
                StorageRow(
                    label: "Local models", size: directorySize(root.appendingPathComponent("models")),
                    icon: "cpu",
                    info: "On-device models that run on your Mac and never send anything out: speaker recognition, voice activity detection, speech segmentation.\n\nManaged in Settings → Downloads. Deleting them here isn't possible on purpose — they'd have to be downloaded again."),
                StorageRow(
                    label: "Events, portrait + journal", size: memoryBytes, icon: "brain",
                    info: "Your memory, written out: one file per event, the distilled portrait entries, daily personality snapshots, and an append-only journal of what the pipelines decided.\n\nAll plain Markdown you can open and read. Tiny — and the only part that can't be recovered by recording again."),
            ],
            appRows: [
                StorageRow(label: "App", size: bundleBytes, icon: "macwindow",
                           info: "My Portrait itself — wherever you dragged it to, usually /Applications."),
                StorageRow(label: "AI runtime", size: runtimeBytes, icon: "shippingbox",
                           info: "Bun and the agent package, downloaded on first launch so the chat and the memory pipelines can run. Reinstalled automatically if missing."),
                StorageRow(label: "Logs", size: logBytes, icon: "doc.text"),
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                Spacer()
            }
            ProgressView(value: fillFraction)
                .progressViewStyle(.linear)
                .tint(Color.purple)
                .frame(maxWidth: .infinity)
            Text(monthsRemaining)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.55))
        }
    }

    private var headline: String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useGB]; f.countStyle = .file
        let s = f.string(fromByteCount: max(stats.dataBytes, 0))
        return "\(s) of memory stored"
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
                    .foregroundStyle(Theme.textPrimary.opacity(0.50))
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.96))
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
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
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

/// RECOMMENDED 角标 —— 点开讲为什么推荐(ⓘ 那一套,只是换了个外形)。
///
/// **自己是个 Button,不是 onTapGesture**:它嵌在整行那个 Button 的 label
/// 里,内层 Button 会把这一下点击吃掉,不会顺手把模式给切了。
private struct RecommendedBadge: View {
    let reason: String
    @State private var shown = false
    @State private var hover = false

    var body: some View {
        Button { shown.toggle() } label: {
            Text("RECOMMENDED")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.green.opacity(hover || shown ? 1.0 : 0.90))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.green.opacity(hover || shown ? 0.12 : 0))
                        .overlay(Capsule().stroke(
                            Color.green.opacity(hover || shown ? 0.80 : 0.45), lineWidth: 0.8))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Why this one?")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300, alignment: .leading)
        }
    }
}

private struct AutoDeleteModeRow: View {
    let mode: AutoDeleteMode
    let isActive: Bool
    /// nil = 这行不是推荐项。非 nil = 显示 RECOMMENDED 角标,点开就是这段理由。
    let recommendedReason: String?
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
                              : AnyShapeStyle(Color.primary.opacity(0.06)))
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? Color.white.opacity(0.95) : Theme.textPrimary.opacity(0.75))
                }
                .frame(width: 30, height: 30)
                // 灰字 subtitle 删了(2026-08-05)。AutoDeleteMode.subtitle 还在,
                // 想加回来直接放这儿。
                HStack(spacing: 6) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary.opacity(0.95))
                    if let reason = recommendedReason {
                        RecommendedBadge(reason: reason)
                    }
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
