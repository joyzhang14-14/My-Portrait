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
    @State private var sampler = ResourceSampler.shared
    @State private var usageRange: UsageRange = .fiveMinutes
    @State private var detailsOpen = false

    var body: some View {
        SettingsPage("Health", onResetCurrentPage: nil) {

            statusCard
            usageCard
            recentCard
            detailsCard
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
        SettingsCard(title: "Bug report") {
            SettingsRow("Report on GitHub",
                        info: "Best if you can describe the bug clearly and know how to trigger it. Opens GitHub so you can file a public issue yourself.",
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
                        info: "Not sure what caused the bug, or don't feel like writing it up? This packs detailed logs and helps you email them to the developer.",
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
        if let issue = sampler.issue {
            let since = sampler.issueSince.map { "since \(Self.shortTime($0))" } ?? ""
            return SettingsCard(title: "Status") {
                SettingsRow(issue == "CPU high" ? "CPU has been high" : "Memory is high",
                            icon: "exclamationmark.triangle.fill") {
                    Text(since)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                }
            }
        }
        // 灰字说明这一页全收进 ⓘ,但这一行的副文是**当前状态本身**,不是解释 ——
        // 塞进 ⓘ 等于把唯一有用的信息藏起来。改放右侧值位(跟下面各卡的
        // 数值行同一个位置),灰字没了,信息还在。
        return SettingsCard(title: "Status") {
            SettingsRow(
                active ? "Stall(s) recently active" : "Healthy",
                icon: active ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
            ) {
                Text(active
                     ? "\(recent.last?.kind.rawValue ?? "?") at \(Self.shortTime(recent.last!.detectedAt))"
                     : "None in the last 5 min")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
        }
    }

    /// CPU / 内存两张趋势图,共用一个时间范围。
    private var usageCard: some View {
        SettingsCard(title: "Usage", info: "My Portrait's own CPU and memory. Green is normal; the part above the dashed line turns orange, and red past the limit. Gaps are times the app wasn't running.") {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Picker("", selection: $usageRange) {
                        ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .padding(.horizontal, 14).padding(.top, 10)
                ResourceChart(kind: .cpu, range: usageRange, sampler: sampler)
                SettingsDivider()
                ResourceChart(kind: .memory, range: usageRange, sampler: sampler)
            }
        }
    }

    /// 原来的 Vision / Audio / 暂停原因三张卡,默认收起。
    private var detailsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)) { detailsOpen.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(detailsOpen ? 90 : 0))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Details").font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if detailsOpen {
                    detailsGroup("Vision") { visionRows }
                    detailsGroup("Audio") { audioRows }
                    detailsGroup("Why capture is paused") { pauseRows }
                }
            }
        }
    }

    private func detailsGroup<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.55))
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
            rows()
        }
    }

    @ViewBuilder private var visionRows: some View {
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

    @ViewBuilder private var audioRows: some View {
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

    /// 任何一项开着,采集就是有意暂停,不算问题。
    @ViewBuilder private var pauseRows: some View {
        kv("DRM active",                pauseState.drmActive ? "On" : "Off")
        SettingsDivider()
        kv("Screen asleep",             pauseState.screenAsleep ? "On" : "Off")
        SettingsDivider()
        kv("Capture disabled",          pauseState.captureDisabled ? "On" : "Off")
        SettingsDivider()
        kv("Audio transcribe (battery)", pauseState.audioTranscriptionPaused ? "On" : "Off")
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
                // 同 statusCard:时间是数据,放右侧值位;cause 是"为什么"的解释,
                // 进 ⓘ(没 cause 时 info 为 nil,ⓘ 自动不出现)。
                ForEach(Array(recent.reversed().prefix(10))) { v in
                    SettingsRow(
                        v.kind.rawValue,
                        info: v.cause,
                        icon: "exclamationmark.triangle"
                    ) {
                        Text(Self.shortTime(v.detectedAt))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    }
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
                       intentionalSkips: 0, inFlight: 0,
                       lastAttemptMs: 0, lastDbWriteMs: 0, startedAtMs: 0)
    }
}

extension AudioMetricsSnapshot {
    static var zero: AudioMetricsSnapshot {
        AudioMetricsSnapshot(chunksProduced: 0, chunksTranscribed: 0, startedAtMs: 0)
    }
}

// MARK: - 趋势图

enum UsageRange: String, CaseIterable, Identifiable {
    case fiveMinutes, hour, day
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fiveMinutes: return "Last 5 minutes"
        case .hour:        return "Last hour"
        case .day:         return "Last 24 hours"
        }
    }
    var span: TimeInterval { switch self { case .fiveMinutes: 300; case .hour: 3600; case .day: 86_400 } }
    var ticks: [String] {
        switch self {
        case .fiveMinutes: return ["5m ago", "4m", "3m", "2m", "1m", "Now"]
        case .hour:        return ["1h ago", "45m", "30m", "15m", "Now"]
        case .day:         return ["24h ago", "18h", "12h", "6h", "Now"]
        }
    }
}

/// 一张趋势图:正常绿、过警戒线(虚线)橙、过上限红;前后两笔隔太久(app 没在跑)就断开。
private struct ResourceChart: View {
    enum Kind { case cpu, memory }
    let kind: Kind
    let range: UsageRange
    let sampler: ResourceSampler
    @Environment(\.colorScheme) private var scheme
    @State private var hoverX: CGFloat?

    private var dark: Bool { scheme == .dark }
    private var okC: Color { dark ? Color(red: 0.30, green: 0.76, blue: 0.54) : Color(red: 0.09, green: 0.64, blue: 0.29) }
    private var warnC: Color { dark ? Color(red: 0.94, green: 0.65, blue: 0.28) : Color(red: 0.85, green: 0.53, blue: 0.10) }
    private var badC: Color { dark ? Color(red: 0.90, green: 0.28, blue: 0.30) : Color(red: 0.86, green: 0.15, blue: 0.15) }

    private var warn: Double { kind == .cpu ? ResourceSampler.cpuWarn : ResourceSampler.memWarn }
    private var bad: Double { kind == .cpu ? ResourceSampler.cpuBad : ResourceSampler.memBad }
    private func value(_ s: ResourceSampler.Sample) -> Double { kind == .cpu ? s.cpu : s.memMB }
    private func fmt(_ v: Double) -> String {
        if kind == .cpu { return v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%" }
        return v >= 1024 ? String(format: "%.1f GB", v / 1024) : "\(Int(v.rounded())) MB"
    }
    private func color(_ v: Double) -> Color { v >= bad ? badC : v >= warn ? warnC : okC }

    /// 这个时间范围里的点,和"隔多久算断开"。1 小时 / 24 小时 = 每分钟一笔 + 最近几分钟的细采样;
    /// 断开门槛放到 400 秒,容得下 health.log 补进来的每 5 分钟一笔。CPU 不知道的点(-1)不画。
    private var points: (data: [ResourceSampler.Sample], gap: TimeInterval) {
        let cut = Date().addingTimeInterval(-range.span)
        var data: [ResourceSampler.Sample]
        let gap: TimeInterval
        if range == .fiveMinutes, !sampler.fine.isEmpty {
            data = sampler.fine.filter { $0.t >= cut }
            gap = ResourceSampler.fineInterval * 3
        } else {
            let lastCoarse = sampler.coarse.last?.t ?? .distantPast
            data = sampler.coarse.filter { $0.t >= cut } + sampler.fine.filter { $0.t > lastCoarse }
            gap = 400
        }
        if kind == .cpu { data = data.filter { $0.cpu >= 0 } }
        return (data, gap)
    }

    var body: some View {
        let (data, gap) = points
        let vals = data.map(value)
        let worst = vals.max() ?? 0
        let state: (Color, String) = worst >= bad ? (badC, "High")
            : worst >= warn ? (warnC, "Above usual") : (okC, data.isEmpty ? "Collecting…" : "Normal")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(kind == .cpu ? "CPU" : "Memory").font(.system(size: 13, weight: .medium))
                Text(vals.last.map(fmt) ?? "—").font(.system(size: 20, weight: .medium).monospacedDigit())
                HStack(spacing: 6) {
                    Circle().fill(state.0).frame(width: 7, height: 7)
                    Text(state.1).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            chart(data: data, gap: gap)
                .frame(height: 132)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func chart(data: [ResourceSampler.Sample], gap: TimeInterval) -> some View {
        let now = Date(), start = now.addingTimeInterval(-range.span)
        let top = max(warn * 1.15, data.map(value).max() ?? 0) * 1.05
        let left: CGFloat = 48, bottom: CGFloat = 20
        let grid = Theme.textPrimary.opacity(0.07), label = Theme.textPrimary.opacity(0.4)
        return Canvas { ctx, size in
            let w = size.width - left, h = size.height - bottom
            func x(_ t: Date) -> CGFloat { left + CGFloat(t.timeIntervalSince(start) / range.span) * w }
            func y(_ v: Double) -> CGFloat { 4 + (1 - CGFloat(v / top)) * (h - 4) }
            for f in [0.0, 0.5, 1.0] {
                let yy = y(top * f)
                ctx.stroke(Path { $0.move(to: CGPoint(x: left, y: yy)); $0.addLine(to: CGPoint(x: size.width, y: yy)) },
                           with: .color(grid), lineWidth: 1)
                ctx.draw(Text(fmt(top * f)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(label),
                         at: CGPoint(x: left - 6, y: yy), anchor: .trailing)
            }
            let wy = y(warn)
            ctx.stroke(Path { $0.move(to: CGPoint(x: left, y: wy)); $0.addLine(to: CGPoint(x: size.width, y: wy)) },
                       with: .color(warnC.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            for i in data.indices.dropLast() {
                let a = data[i], b = data[i + 1]
                guard b.t.timeIntervalSince(a.t) <= gap else { continue }
                let c = color(max(value(a), value(b)))
                let pa = CGPoint(x: x(a.t), y: y(value(a))), pb = CGPoint(x: x(b.t), y: y(value(b)))
                ctx.fill(Path { p in
                    p.move(to: pa); p.addLine(to: pb)
                    p.addLine(to: CGPoint(x: pb.x, y: y(0))); p.addLine(to: CGPoint(x: pa.x, y: y(0))); p.closeSubpath()
                }, with: .color(c.opacity(0.12)))
                ctx.stroke(Path { $0.move(to: pa); $0.addLine(to: pb) }, with: .color(c),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            let ticks = range.ticks
            for (k, t) in ticks.enumerated() {
                let f = CGFloat(k) / CGFloat(ticks.count - 1)
                let anchor: UnitPoint = k == 0 ? .bottomLeading : k == ticks.count - 1 ? .bottomTrailing : .bottom
                ctx.draw(Text(t).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(label),
                         at: CGPoint(x: left + f * w, y: size.height), anchor: anchor)
            }
            if let hx = hoverX, hx >= left {
                ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: 4)); $0.addLine(to: CGPoint(x: hx, y: h)) },
                           with: .color(label), lineWidth: 1)
            }
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { g in
                if let hx = hoverX, hx >= left, let s = nearest(data, at: hx, width: g.size.width - left, left: left, start: start) {
                    let ago = Int(now.timeIntervalSince(s.t))
                    Text("\(fmt(value(s))) · \(ago < 60 ? "\(ago)s" : ago < 3600 ? "\(ago / 60)m" : "\(ago / 3600)h") ago")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                        .fixedSize()
                        .offset(x: min(hx + 10, g.size.width - 130), y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func nearest(_ data: [ResourceSampler.Sample], at hx: CGFloat, width: CGFloat, left: CGFloat,
                         start: Date) -> ResourceSampler.Sample? {
        let t = start.addingTimeInterval(Double((hx - left) / max(1, width)) * range.span)
        guard let s = data.min(by: { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }),
              abs(s.t.timeIntervalSince(t)) < range.span / 30 else { return nil }
        return s
    }
}
