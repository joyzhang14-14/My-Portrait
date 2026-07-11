import AppKit
import SwiftUI

/// Settings → Capture → Health。
///
/// 显示三件事:
///   - Vision metrics(累计 attempts/persisted/dedup/silent_loss + 最后时戳)
///   - Audio metrics(produced/transcribed + pending 队列实时)
///   - 当前 IntentionalPauseState(DRM / sleep / captureDisabled 哪条亮)
///   - 最近 10 条 StallVerdict
///
/// 数据是周期 pull,1 Hz 刷一次,Driver tick 之外的额外 actor 调用而已 ——
/// 关掉这页就停。
struct CaptureHealthView: View {
    @Environment(\.services) private var services
    @State private var vision: VisionSnapshot = .zero
    @State private var audio: AudioMetricsSnapshot = .zero
    @State private var pendingAudioCount: Int = 0
    @State private var pendingAudioOldestAgeSec: Int64 = 0
    @State private var pauseState = IntentionalPauseState.shared
    @State private var recent: [StallVerdict] = []
    @State private var refreshTask: Task<Void, Never>?

    @State private var diagBundleBusy = false
    @State private var diagBundleStatus: String = ""
    @State private var exportedBundleURL: URL?
    @State private var exportedBundleMode: DiagnosticBundleMode = .publicReport
    @State private var showUploadGuide = false

    var body: some View {
        SettingsPage("Health",
                     subtitle: "Live metrics for the capture engine. Auto-refreshes while this page is open.",
                     onResetCurrentPage: nil) {

            statusCard
            visionCard
            audioCard
            pauseCard
            recentCard
            diagnosticCard
        }
        .onAppear { startRefresh() }
        .onDisappear { stopRefresh() }
        .sheet(isPresented: $showUploadGuide) {
            if let url = exportedBundleURL { uploadGuideSheet(url: url) }
        }
    }

    /// 私下 bug 上报的操作指引:三步——文件已在 Finder 点亮 → 打开邮件 → 拖进附件发送。
    private func uploadGuideSheet(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                Text("Diagnostic file ready")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("Saved to your Downloads folder:\n\(url.lastPathComponent)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            disclaimer

            Divider()

            Text("Almost done — just three steps:")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                uploadStep(1, "The file is highlighted in Finder (a window just opened). Keep it visible.")
                uploadStep(2, "Click “Open email” below — a message to the developer opens, already addressed.")
                uploadStep(3, "Drag the highlighted file into that email, then hit Send. Done!")
            }

            Divider()

            HStack(spacing: 10) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button("Open email") {
                    openBugReportEmail(attaching: url)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Spacer()
                Button("Done") { showUploadGuide = false }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func uploadStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 免责说明:告诉用户这个文件里有什么、绝不包含什么,发之前可自查。
    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's in this file")
                .font(.system(size: 12, weight: .semibold))
            Text("It holds technical diagnostics only: app / system info, capture health, queue and table counts, recent errors, crash and hang reports, and the last 24 h of app logs.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It never includes your screenshots, audio, typing, transcripts, chats, memory files, API keys, or personal profile. Paths, emails, IPs and IDs are automatically masked. You can open the zip and check every file before sending.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 两条上报路径:自己去 GitHub 提 issue(纯跳转),或私下打包发邮件给开发者。
    private var diagnosticCard: some View {
        SettingsCard(title: "Bug report",
                     footnote: "The private option excludes captured images, audio, typing, transcriptions, chats, memory files, and secrets. You can inspect the zip before sharing.") {
            SettingsRow("Report on GitHub",
                        description: "Best if you can describe the bug clearly and know how to trigger it. Opens GitHub so you can file a public issue yourself — nothing is sent automatically.",
                        icon: "ladybug") {
                Button("Open") {
                    if let issue = URL(string: "https://github.com/joyzhang14-14/My-Portrait/issues/new?template=bug_report.yml") {
                        NSWorkspace.shared.open(issue)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            SettingsDivider()
            SettingsRow("Send data to developer privately",
                        description: "Not sure what caused the bug, or don't feel like writing it up? This packs detailed logs and helps you email them to the developer.",
                        icon: "lock.shield") {
                Button(diagBundleBusy ? "Working…" : "Send") {
                    runDiagnosticExport(mode: .privateSupport)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(diagBundleBusy)
            }
            if !diagBundleStatus.isEmpty {
                Text(diagBundleStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.65))
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func runDiagnosticExport(mode: DiagnosticBundleMode) {
        diagBundleBusy = true
        diagBundleStatus = "Collecting…"
        Task { @MainActor in
            do {
                let url = try await DiagnosticBundle.build(mode: mode)
                diagBundleStatus = "Saved: \(url.path)"
                exportedBundleURL = url
                exportedBundleMode = mode
                // zip 先在 Finder 里点亮,方便待会拖进邮件;再弹步骤指引窗口。
                NSWorkspace.shared.activateFileViewerSelecting([url])
                showUploadGuide = true
            } catch {
                diagBundleStatus = "Export failed: \(error.localizedDescription)"
            }
            diagBundleBusy = false
        }
    }

    /// 打开系统默认邮件客户端的写信窗口,To 预填开发者邮箱、主题 / 正文预填好。
    /// mailto 规范不支持附件,所以正文里附上文件路径 + 提示拖拽(zip 已在 Finder 点亮)。
    private func openBugReportEmail(attaching url: URL) {
        let body = """
        Hi, I ran into a bug in My Portrait.

        (Feel free to add anything you remember here — or just leave it blank.)

        A diagnostic file has been created at:
        \(url.path)

        Please drag that file into this email as an attachment before sending. Thanks!
        """
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = "joyzhang144@gmail.com"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "My Portrait bug report"),
            URLQueryItem(name: "body", value: body),
        ]
        if let mailURL = comps.url {
            NSWorkspace.shared.open(mailURL)
        }
    }

    // MARK: - Cards

    private var statusCard: some View {
        let active = !recent.isEmpty && Self.activeWithinSec(recent.last!, sec: 300)
        return SettingsCard(title: "Status") {
            SettingsRow(
                active ? "Stall(s) recently active" : "Healthy",
                description: active
                    ? "Last verdict: \(recent.last?.kind.rawValue ?? "?") at \(Self.shortTime(recent.last!.detectedAt))"
                    : "No stalls in the last 5 minutes.",
                icon: active ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
            ) {
                EmptyView()
            }
        }
    }

    private var visionCard: some View {
        SettingsCard(title: "Vision", footnote: "If \"Silent loss\" keeps rising, some screenshots aren't being saved.") {
            kv("Uptime",         Self.uptimeStr(vision.uptimeSec))
            SettingsDivider()
            kv("Capture attempts", "\(vision.captureAttempts)")
            SettingsDivider()
            kv("Frames persisted", "\(vision.framesPersisted)")
            SettingsDivider()
            kv("Dedup skips",      "\(vision.dedupSkips)")
            SettingsDivider()
            kv("Silent loss",      "\(vision.silentLoss)")
            SettingsDivider()
            kv("Last attempt",     Self.tsAgo(vision.lastAttemptMs))
            SettingsDivider()
            kv("Last DB write",    Self.tsAgo(vision.lastDbWriteMs))
        }
    }

    private var audioCard: some View {
        SettingsCard(title: "Audio") {
            kv("Uptime",            Self.uptimeStr(audio.uptimeSec))
            SettingsDivider()
            kv("Chunks produced",   "\(audio.chunksProduced)")
            SettingsDivider()
            kv("Chunks transcribed","\(audio.chunksTranscribed)")
            SettingsDivider()
            kv("Pending queue",     "\(pendingAudioCount)")
            SettingsDivider()
            kv("Oldest pending",    pendingAudioCount > 0 ? "\(pendingAudioOldestAgeSec)s" : "—")
        }
    }

    private var pauseCard: some View {
        SettingsCard(title: "Why capture is paused",
                     footnote: "When any of these is on, capture pauses on purpose — this isn't a problem.") {
            kv("DRM active",                pauseState.drmActive ? "ON" : "off")
            SettingsDivider()
            kv("Screen asleep",             pauseState.screenAsleep ? "ON" : "off")
            SettingsDivider()
            kv("Capture disabled",          pauseState.captureDisabled ? "ON" : "off")
            SettingsDivider()
            kv("Audio transcribe (battery)", pauseState.audioTranscriptionPaused ? "ON" : "off")
        }
    }

    private var recentCard: some View {
        SettingsCard(title: "Recent stalls") {
            if recent.isEmpty {
                Text("No stalls recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(recent.reversed().prefix(10))) { v in
                    SettingsRow(
                        v.kind.rawValue,
                        description: [Self.shortTime(v.detectedAt), v.cause]
                            .compactMap { $0 }
                            .joined(separator: " — "),
                        icon: "exclamationmark.triangle"
                    ) { EmptyView() }
                    if v.id != recent.reversed().prefix(10).last?.id {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func kv(_ label: String, _ value: String) -> some View {
        SettingsRow(label) {
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
        }
    }

    private func startRefresh() {
        refresh()
        let ns: UInt64 = 1_000_000_000
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                await refreshAsync()
            }
        }
    }

    private func stopRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() {
        Task { @MainActor in await refreshAsync() }
    }

    private func refreshAsync() async {
        vision = await VisionMetrics.shared.snapshot()
        audio = await AudioMetrics.shared.snapshot()
        recent = StallDetector.shared.recent
        guard let db = services?.db else { return }
        do {
            let stats = try await db.audioBacklogStats()
            pendingAudioCount = stats.pendingCount
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            pendingAudioOldestAgeSec = stats.oldestRecordedAtMs.map { (nowMs - $0) / 1000 } ?? 0
        } catch {
            // 失败不显示就好,不在 UI 抛错。
        }
    }

    // MARK: - Static formatters

    private static func uptimeStr(_ sec: Double) -> String {
        guard sec > 0 else { return "—" }
        let s = Int(sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \(s/60%60)m"
    }

    private static func tsAgo(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        let agoSec = Int((Date().timeIntervalSince1970 * 1000 - Double(ms)) / 1000)
        if agoSec < 60 { return "\(agoSec)s ago" }
        if agoSec < 3600 { return "\(agoSec/60)m \(agoSec%60)s ago" }
        return "\(agoSec/3600)h ago"
    }

    private static func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private static func activeWithinSec(_ v: StallVerdict, sec: Int) -> Bool {
        Date().timeIntervalSince(v.detectedAt) < Double(sec)
    }
}

// MARK: - Default snapshots

extension VisionSnapshot {
    static var zero: VisionSnapshot {
        VisionSnapshot(captureAttempts: 0, framesPersisted: 0, dedupSkips: 0,
                       intentionalSkips: 0,
                       lastAttemptMs: 0, lastDbWriteMs: 0, startedAtMs: 0)
    }
}

extension AudioMetricsSnapshot {
    static var zero: AudioMetricsSnapshot {
        AudioMetricsSnapshot(chunksProduced: 0, chunksTranscribed: 0, startedAtMs: 0)
    }
}
