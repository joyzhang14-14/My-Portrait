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

    @State private var rings = TodayRings()
    @State private var attention = 0
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

                statusColumn
                    .frame(width: sideW, alignment: .topLeading)
                    .offset(x: W - rightPad - sideW, y: statusTop)
            }
            .frame(width: W, height: H, alignment: .topLeading)
        }
        // 和 Timeline / Data 一样铺满整窗(含标题栏那一条),坐标从窗口左上角算
        .ignoresSafeArea()
        .task { await refresh() }
    }

    private func backdrop(W: CGFloat, H: CGFloat, cx: CGFloat) -> some View {
        ZStack {
            SidebarBackdrop()
            RadialGradient(colors: [pal.glow, .clear],
                           center: UnitPoint(x: cx / max(1, W), y: 0.4),
                           startRadius: 0, endRadius: 420)
                .allowsHitTesting(false)
        }
        .frame(width: W, height: H)
    }

    // MARK: - 左边导航

    /// 行高按窗口高度分:15 行 + 4 个组标题正好铺满左列,窗口矮了最少 30、高了最多 42。
    private func navList(H: CGFloat) -> some View {
        let avail = H - navTop - 22
        let rowH = max(30, min(42, (avail - 4 * 26 - 30) / 15))
        return SideScroll(height: avail, enabled: true, pal: pal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SettingsSubsection.Group.allCases, id: \.self) { grp in
                    sectionTitle(grp.rawValue)
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
                Text(s.label).font(.system(size: 15.5 * panelScale)).foregroundStyle(pal.fg)
                    .lineLimit(1).truncationMode(.tail)
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
        case .workflow(.eventsProcessor):       return c.scheduler.event.frequency == .off ? .off : .on
        case .workflow(.portraitsDistiller):    return c.scheduler.portrait.frequency == .off ? .off : .on
        case .workflow(.personalityRefresher):  return c.scheduler.personality.frequency == .off ? .off : .on
        case .workflow(.writingStyleDistiller): return c.scheduler.writingStyle.frequency == .off ? .off : .on
        case .workflow(.changelog): return attention > 0 ? .warn : nil
        case .data(.health):        return health.unhealthy ? .warn : .on
        default: return nil
        }
    }

    // MARK: - 右边状态列

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            box {
                sectionTitle("TODAY")
                todayRing
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
                sectionTitle("CAPTURE")
                let c = config.current.capture
                statusRow("Screen", c.screen.enabled ? .on : .off, c.screen.enabled ? "On" : "Off", .capture(.screen))
                statusRow("Audio", c.audio.enabled ? .on : .off, c.audio.enabled ? "On" : "Off", .capture(.audio))
                statusRow("Typing", c.typingCaptureEnabled ? .on : .off, c.typingCaptureEnabled ? "On" : "Off", .capture(.typing))
                sectionTitle("WORKFLOW").padding(.top, 8)
                statusRow("Needs attention", attention > 0 ? .warn : .on,
                          attention > 0 ? "\(attention)" : "None", .workflow(.changelog))
                statusRow("Events", config.current.scheduler.event.frequency == .off ? .off : .on,
                          eventsSchedule, .workflow(.eventsProcessor))
                sectionTitle("DATA").padding(.top, 8)
                statusRow("Storage", nil, usedBytes.map(Self.bytes) ?? "Measuring…", .data(.storage))
                statusRow("Free", nil, freeBytes.map(Self.bytes) ?? "—", .data(.storage))
                statusRow("Health", health.unhealthy ? .warn : .on,
                          health.unhealthy ? "\(health.faults.count) issue\(health.faults.count == 1 ? "" : "s")" : "OK",
                          .data(.health))
            }
        }
    }

    private var eventsSchedule: String {
        let e = config.current.scheduler.event
        return e.frequency == .off ? "Off" : "Daily \(e.timeOfDay)"
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
        Text(t).font(.system(size: 12 * panelScale, weight: .semibold, design: .monospaced)).kerning(0.9)
            .foregroundStyle(pal.faint)
            .padding(.horizontal, 4).padding(.bottom, 5)
    }

    /// 一行状态,点一下跳到对应设置页。
    private func statusRow(_ label: String, _ state: LampState?, _ value: String,
                           _ target: SettingsSubsection) -> some View {
        Button { subsection = target } label: {
            HStack(spacing: 8) {
                if let state { Lamp(state: state, pal: pal) } else { Color.clear.frame(width: 7, height: 7) }
                Text(label).font(.system(size: 15.5 * panelScale)).foregroundStyle(pal.fg).lineLimit(1)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 14 * panelScale, design: .monospaced)).foregroundStyle(pal.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t).font(.system(size: 13 * panelScale)).foregroundStyle(pal.muted)
        }
    }

    // MARK: 今天的三条细圈

    private func ringColor(_ i: Int) -> Color {
        switch i {
        case 0: return pal.accent
        case 1: return pal.audio
        default: return Color(red: 0.88, green: 0.57, blue: 0.18)
        }
    }

    private var todayRing: some View {
        let side = sideW - 28
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
                Text(rings.frames.formatted()).font(.system(size: fs(28), weight: .bold)).foregroundStyle(pal.fg)
                Text("frames captured").font(.system(size: fs(12.5))).foregroundStyle(pal.muted)
                if let span = rings.activeSpan {
                    Text(span).font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
                }
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: - 取数

    private func refresh() async {
        attention = MemoryScheduler.localAttention(MemoryScheduler.shared.attentionDays(),
                                                   scheduler: config.current.scheduler).count
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
            .shadow(color: state == .off ? .clear : c.opacity(0.8), radius: 3)
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
