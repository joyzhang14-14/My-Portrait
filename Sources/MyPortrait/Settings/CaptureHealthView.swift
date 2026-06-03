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
    }

    /// 一键导出诊断 zip。无 PII,纯结构 + 日志 + 状态。
    private var diagnosticCard: some View {
        SettingsCard(title: "Diagnostic export",
                     footnote: "Saves a diagnostics file to your Desktop to help with bug reports. It contains only technical status and logs — none of your captured content (screen text, audio, or typing).") {
            SettingsRow("Export diagnostic bundle",
                        description: "Use this when reporting a bug. Open the zip to review before sharing.",
                        icon: "ladybug") {
                Button(diagBundleBusy ? "Working…" : "Export") {
                    runDiagnosticExport()
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

    private func runDiagnosticExport() {
        diagBundleBusy = true
        diagBundleStatus = "Collecting…"
        Task { @MainActor in
            do {
                let url = try await DiagnosticBundle.build()
                diagBundleStatus = "Saved: \(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                diagBundleStatus = "Export failed: \(error.localizedDescription)"
            }
            diagBundleBusy = false
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
        SettingsCard(title: "Recent stalls",
                     footnote: "Up to 50 most recent verdicts kept in memory; cleared on app restart.") {
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
                       lastAttemptMs: 0, lastDbWriteMs: 0, startedAtMs: 0)
    }
}

extension AudioMetricsSnapshot {
    static var zero: AudioMetricsSnapshot {
        AudioMetricsSnapshot(chunksProduced: 0, chunksTranscribed: 0, startedAtMs: 0)
    }
}
