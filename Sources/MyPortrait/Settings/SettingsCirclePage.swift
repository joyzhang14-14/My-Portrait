import SwiftUI

/// Settings 页(和 Timeline / Data 同一套整窗版式):
///   左边  四组 15 页的导航,有运行状态的页带一个小灯
///   中间  设置页本身(各页面内容不变)
///   右边  状态列:今天 0–24 点屏幕 / 音频 / 打字各自录到的时段 + 采集、workflow、存储、健康
/// 页面切换条在左上、Settings 齿轮在右上,都由 ContentView 叠上来。
struct SettingsCirclePage: View {
    @Binding var subsection: SettingsSubsection?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelScale) private var panelScale
    @Environment(\.services) private var services
    @State private var config = ConfigStore.shared
    @ObservedObject private var health = HealthMonitor.shared

    /// Audio Capture 那行的小红点:还有没命名的声音簇。
    @State private var speakerBadge = UnidentifiedSpeakerBadge.shared
    /// 导航内容实际高度:放得下就不滚动。
    @State private var navContentH: CGFloat = 0

    @State private var rings = TodayRings()
    @State private var attention = 0
    /// 最近一次 pipeline 运行(Changelog 同一张表)。
    @State private var lastRun: ProcessingLogStore.PipelineRunRecord?
    @State private var sampler = ResourceSampler.shared
    @State private var usedBytes: Int64?
    @State private var freeBytes: Int64?

    private var pal: RingPalette { RingPalette(dark: scheme == .dark) }
    private var sideW: CGFloat { 280 * panelScale }
    private let leftX: CGFloat = 22
    private let rightPad: CGFloat = 22
    /// 左边导航顶边(页面切换条下面)。
    private let navTop: CGFloat = 54
    /// 右边状态列顶边(右上角齿轮下面)。
    private let statusTop: CGFloat = 60
    /// 中间设置页的顶边:切换条下沿,上面 14pt 渐隐,滚上去的内容不压切换条。
    private let contentTop: CGFloat = 46
    /// 两侧的字和中间设置页(行字 14pt)对齐到同一档,只随窗口缩放。
    private func fs(_ s: CGFloat) -> CGFloat { s * panelScale }

    private var current: SettingsSubsection { subsection ?? .app(.general) }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let contentX = leftX + sideW + 12
            let contentW = max(320, W - contentX - (sideW + rightPad + 12))
            ZStack(alignment: .topLeading) {
                backdrop(W: W, H: H, cx: contentX + contentW / 2)

                navList(H: H)
                    .frame(width: sideW)
                    .offset(x: leftX, y: navTop)

                SettingsPane(subsection: $subsection)
                    .frame(width: contentW, height: H - contentTop)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                 .init(color: .black, location: 14 / max(1, H - contentTop))],
                                         startPoint: .top, endPoint: .bottom))
                    .offset(x: contentX, y: contentTop)

                statusColumn(H: H)
                    .frame(width: sideW, alignment: .topLeading)
                    .offset(x: W - rightPad - sideW, y: statusTop)
            }
            .frame(width: W, height: H, alignment: .topLeading)
        }
        // 和 Timeline / Data 一样铺满整窗(含标题栏那一条),坐标从窗口左上角算
        .ignoresSafeArea()
        .task {
            speakerBadge.refresh()
            await refresh()
        }
    }

    private func backdrop(W: CGFloat, H: CGFloat, cx: CGFloat) -> some View {
        ZStack {
            SidebarBackdrop()
        }
        .frame(width: W, height: H)
    }

    // MARK: - 左边导航

    /// 行高按窗口高度分:15 行 + 4 个组标题正好铺满左列,窗口矮了最少 30、高了最多 42。
    private func navList(H: CGFloat) -> some View {
        let avail = H - navTop - 22
        let rowH = (max(32, min(40, (avail - 4 * 26 - 30) / 15)) / 4).rounded(.down) * 4
        return SideScroll(height: avail, enabled: navContentH > avail + 1, pal: pal,
                          contentHeight: $navContentH) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SettingsSubsection.Group.allCases, id: \.self) { grp in
                    sectionTitle(grp.rawValue.capitalized)
                        .padding(.top, grp == .app ? 0 : 10)
                    ForEach(SettingsSubsection.allCases.filter { $0.group == grp }) { s in
                        navRow(s, height: rowH)
                    }
                }
            }
        }
    }

    private func navRow(_ s: SettingsSubsection, height: CGFloat) -> some View {
        let on = s == current
        return Button { subsection = s } label: {
            HStack(spacing: 9) {
                Image(systemName: s.icon)
                    .font(.system(size: 15 * panelScale))
                    .foregroundStyle(on ? pal.accent : pal.muted)
                    .frame(width: 20)
                Text(s.label).font(.system(size: 16.5 * panelScale)).foregroundStyle(pal.fg)
                    .lineLimit(1).truncationMode(.tail)
                    // 红点贴在文字右上角,不占布局
                    .overlay(alignment: .topTrailing) {
                        if s == .capture(.audio) && speakerBadge.count > 0 {
                            Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: 8, y: -1)
                        }
                    }
                Spacer(minLength: 4)
                if let lamp = lamp(for: s) { Lamp(state: lamp, pal: pal) }
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? pal.accentbg : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? pal.accentb : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 导航行后面的小灯:采集 = 开关;workflow = 自动运行开没开;Changelog = 有待处理;Health = 有故障。
    private func lamp(for s: SettingsSubsection) -> LampState? {
        let c = config.current
        switch s {
        case .capture(.screen): return c.capture.screen.enabled ? .on : .off
        case .capture(.audio):  return c.capture.audio.enabled ? .on : .off
        case .capture(.typing): return c.capture.typingCaptureEnabled ? .on : .off
        case .workflow(.eventSession):         return c.premium.eventSession ? .on : .off
        case .workflow(.eventMerge):           return c.scheduler.event.frequency == .off ? .off : .on
        case .workflow(.portraitDistillation): return c.scheduler.portrait.frequency == .off ? .off : .on
        case .workflow(.changelog): return attention > 0 ? .warn : nil
        case .data(.health):        return healthIssue == nil ? .on : .warn
        default: return nil
        }
    }

    // MARK: - 右边状态列

    /// 状态列:行和字比左边导航再大一档;圆的大小按窗口高度收,保证整列放得下。
    private func statusColumn(H: CGFloat) -> some View {
        let ring = max(120, min(sideW - 28, H - statusTop - 22 - 12 - 390 - 70))
        return VStack(alignment: .leading, spacing: 12) {
            box {
                sectionTitle("Today")
                todayRing(side: ring)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    legend("Screen", ringColor(0))
                    legend("Audio", ringColor(1))
                    legend("Typing", ringColor(2))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            box {
                sectionTitle("Capture")
                let c = config.current.capture
                statusRow("Screen", c.screen.enabled ? .on : .off, c.screen.enabled ? "On" : "Off", .capture(.screen))
                statusRow("Audio", c.audio.enabled ? .on : .off, c.audio.enabled ? "On" : "Off", .capture(.audio))
                statusRow("Typing", c.typingCaptureEnabled ? .on : .off, c.typingCaptureEnabled ? "On" : "Off", .capture(.typing))
                sectionTitle("Workflow").padding(.top, 8)
                statusRow("Last run", lastRunLamp, lastRunText, .workflow(.changelog))
                statusRow("Next run", nil, nextRunText, .workflow(.eventMerge))
                sectionTitle("Data").padding(.top, 8)
                statusRow("Storage", nil, usedBytes.map(Self.bytes) ?? "Measuring…", .data(.storage))
                statusRow("Free", nil, freeBytes.map(Self.bytes) ?? "—", .data(.storage))
                statusRow("Health", healthIssue == nil ? .on : .warn, healthIssue ?? "OK", .data(.health))
            }
        }
    }

    /// 健康状态:采集故障优先,其次 CPU / 内存超线。
    private var healthIssue: String? {
        if health.unhealthy { return "\(health.faults.count) issue\(health.faults.count == 1 ? "" : "s")" }
        return sampler.issue
    }

    /// 上次运行:成功 / 没活可干 = 绿;失败、自动重试中,或有待处理的天 = 橙。
    private var lastRunLamp: LampState {
        guard let r = lastRun else { return .off }
        return r.outcome == "failure" || r.outcome == "auto-recovering" || attention > 0 ? .warn : .on
    }

    private var lastRunText: String {
        guard let r = lastRun else { return "Never" }
        let d = Date(timeIntervalSince1970: Double(r.timestampMs) / 1000)
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if r.outcome == "failure" {
            f.dateFormat = cal.isDateInToday(d) ? "HH:mm" : "MMM d"
            return "Failed \(f.string(from: d))"
        }
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return "Today \(f.string(from: d))" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    /// 下次运行:所有开着自动运行的流水线里最早的那次。
    private var nextRunText: String {
        let s = config.current.scheduler
        let now = Date()
        guard let next = [s.event, s.portrait, s.personality, s.writingStyle]
            .compactMap({ Self.nextRun($0, after: now) }).min() else { return "Off" }
        // 24 小时内只写钟点(列窄,"Tomorrow 03:00" 放不下),再远带星期
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = next.timeIntervalSince(now) < 86_400 ? "HH:mm" : "EEE HH:mm"
        return f.string(from: next)
    }

    /// 按 SchedulerConfig 算下一次触发时刻(daily / weekly 0=周日 / monthly 超出当月落到月底)。
    private static func nextRun(_ c: SchedulerConfig, after now: Date) -> Date? {
        guard c.frequency != .off else { return nil }
        let hm = c.timeOfDay.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        let cal = Calendar.current
        for d in 0..<62 {
            guard let day = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now)),
                  let t = cal.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day), t > now else { continue }
            switch c.frequency {
            case .daily: return t
            case .weekly: if cal.component(.weekday, from: t) - 1 == c.dayOfWeek { return t }
            case .monthly:
                let last = cal.range(of: .day, in: .month, for: t)?.count ?? 31
                if cal.component(.day, from: t) == min(c.dayOfMonth, last) { return t }
            case .off: return nil
            }
        }
        return nil
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(pal.row))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(pal.rowb, lineWidth: 1))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13 * panelScale, weight: .semibold))
            .foregroundStyle(pal.faint)
            .padding(.horizontal, 4).padding(.bottom, 5)
    }

    /// 一行状态,点一下跳到对应设置页。
    private func statusRow(_ label: String, _ state: LampState?, _ value: String,
                           _ target: SettingsSubsection) -> some View {
        Button { subsection = target } label: {
            HStack(spacing: 8) {
                if let state { Lamp(state: state, pal: pal) } else { Color.clear.frame(width: 7, height: 7) }
                Text(label).font(.system(size: 17.5 * panelScale)).foregroundStyle(pal.fg).lineLimit(1)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 16 * panelScale, design: .monospaced)).foregroundStyle(pal.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t).font(.system(size: 14.5 * panelScale)).foregroundStyle(pal.muted)
        }
    }

    // MARK: 今天的三条细圈

    private func ringColor(_ i: Int) -> Color {
        // 屏幕是底色(中性灰),音频 / 打字各一个色;琥珀强调色留给打字
        switch i {
        case 0: return pal.muted
        case 1: return pal.audio
        default: return pal.accent
        }
    }

    private func todayRing(side: CGFloat) -> some View {
        let rings = self.rings
        return ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let lw: CGFloat = 5
                for (i, spans) in [rings.screen, rings.audio, rings.typing].enumerated() {
                    let r = size.width / 2 - lw / 2 - CGFloat(i) * (lw + 5)
                    ctx.stroke(Path { p in p.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                               with: .color(pal.track), lineWidth: lw)
                    for (m0, m1) in spans {
                        let p = Path { p in
                            p.addArc(center: c, radius: r, startAngle: .degrees(m0 / 4 - 90),
                                     endAngle: .degrees(max(m1, m0 + 2) / 4 - 90), clockwise: false)
                        }
                        ctx.stroke(p, with: .color(ringColor(i)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    }
                }
            }
            VStack(spacing: 2) {
                Text(rings.frames.formatted()).font(.system(size: fs(36), weight: .medium).monospacedDigit()).foregroundStyle(pal.fg)
                Text("frames captured").font(.system(size: fs(15))).foregroundStyle(pal.muted)
                if let span = rings.activeSpan {
                    Text(span).font(.system(size: fs(13.5), design: .monospaced)).foregroundStyle(pal.faint)
                }
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: - 取数

    private func refresh() async {
        attention = MemoryScheduler.localAttention(MemoryScheduler.shared.attentionDays(),
                                                   scheduler: config.current.scheduler).count
        lastRun = await Task.detached(priority: .utility) {
            ProcessingLogStore().recentPipelineRuns(limit: 1).first
        }.value
        let day = Calendar.current.startOfDay(for: Date())
        if let db = services?.db {
            async let frames = TimelineFeed.framesForDay(day, db: db)
            async let audio = TimelineFeed.audioMomentsForDay(day, db: db)
            let startMs = Int64(day.timeIntervalSince1970 * 1000)
            async let keys = WritingCaptureBrowse.keystrokes(startMs: startMs, endMs: startMs + 86_400_000,
                                                             excludeBundleIds: [])
            let (f, a, k) = await (frames, audio, keys)
            rings = TodayRings(day: day, frames: f.map(\.timestamp), audio: a,
                               typing: k.map { Date(timeIntervalSince1970: Double($0.tsMs) / 1000) })
        }
        let dir = config.current.storage.dataDirectory.isEmpty
            ? NSString("~/.portrait").expandingTildeInPath : config.current.storage.dataDirectory
        let (used, free) = await Task.detached(priority: .utility) { () -> (Int64, Int64?) in
            let url = URL(fileURLWithPath: dir)
            let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            return (dataDirectorySize(url), free)
        }.value
        usedBytes = used
        freeBytes = free
    }
}

/// 导航行 / 状态行的小灯。
enum LampState { case on, off, warn }

private struct Lamp: View {
    let state: LampState
    let pal: RingPalette
    var body: some View {
        let c: Color = switch state {
        case .on:   Color(red: 0.24, green: 0.81, blue: 0.53)
        case .warn: Color(red: 0.94, green: 0.65, blue: 0.28)
        case .off:  pal.faint
        }
        Circle().fill(c).frame(width: 7, height: 7)
    }
}

/// 今天 0–24 点三条细圈的数据:屏幕帧 / 音频 / 击键,相邻不到 5 分钟的连成一段,单位分钟。
struct TodayRings {
    var screen: [(Double, Double)] = []
    var audio: [(Double, Double)] = []
    var typing: [(Double, Double)] = []
    var frames = 0
    var activeSpan: String?

    init() {}

    init(day: Date, frames: [Date], audio: [Date], typing: [Date]) {
        self.frames = frames.count
        screen = Self.spans(frames, day)
        self.audio = Self.spans(audio, day)
        self.typing = Self.spans(typing, day)
        if let a = frames.min(), let b = frames.max() {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            activeSpan = "\(f.string(from: a)) – \(f.string(from: b))"
        }
    }

    private static func spans(_ ts: [Date], _ day: Date) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for t in ts.sorted() {
            let m = t.timeIntervalSince(day) / 60
            guard m >= 0, m < 1440 else { continue }
            if let last = out.last, m - last.1 < 5 { out[out.count - 1].1 = m } else { out.append((m, m)) }
        }
        return out
    }
}
