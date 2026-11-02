import SwiftUI
import AppKit
import Observation

// =============================================================================
// MARK: - TimelineState (reference type — needed so NSEvent closures can mutate)
// =============================================================================

@Observable
final class TimelineState {
    var selectedDay: Date = Date()
    var frames: [TimelineFrame] = []
    var loading: Bool = false
    var focusIndex: Int = 0
    /// Set by `seek(to:)` when the requested moment falls on a day whose
    /// frames haven't loaded yet. TimelineView's frame loader will pull
    /// `focusIndex` to the closest frame once they arrive.
    var pendingSeek: Date? = nil
    /// reload 代际计数(同 TimelineSidebar.reloadToken):快速切天时,帧多的
    /// 旧天慢查询可能晚于新天空查询返回,把 frames 盖成旧天的 —— 取数前 +1
    /// 记 token,回来对不上就丢弃。
    var reloadToken = 0

    /// Navigate the Timeline to the moment `t`. If we're already on the right
    /// day, snap focusIndex to the nearest frame; otherwise switch days and
    /// queue the snap via `pendingSeek`.
    func seek(to t: Date) {
        let cal = Calendar.current
        if cal.isDate(t, inSameDayAs: selectedDay) {
            if frames.isEmpty {
                // 同天但帧还没加载(如从未打开过 Timeline):snapFocus 的空帧
                // guard 会把目标直接丢掉 → 落到默认最后一帧。记到 pendingSeek,
                // 等 reload 完成(token 校验通过那次)统一消费吸附。
                pendingSeek = t
            } else {
                snapFocus(to: t)
            }
        } else {
            selectedDay = cal.startOfDay(for: t)
            pendingSeek = t
        }
    }

    /// Internal: pick the frame with timestamp nearest `t`.
    func snapFocus(to t: Date) {
        guard !frames.isEmpty else { return }
        var bestIdx = 0
        var bestDiff = abs(frames[0].timestamp.timeIntervalSince(t))
        for (i, f) in frames.enumerated() {
            let d = abs(f.timestamp.timeIntervalSince(t))
            if d < bestDiff { bestDiff = d; bestIdx = i }
        }
        focusIndex = bestIdx
    }
}

// =============================================================================
// MARK: - TimelineView — circular day view
// =============================================================================
//
// 外圈 = 选中那天 00:00–24:00(00 点在正上方,顺时针);圆里是日期、URL、截图、
// 信息行和沿下半圈排开的选帧竖线;圆四周四个角:Active Apps / Audio /
// Event Session / Today。设计稿在 1600×960 上按外圈半径 392 画,这里按窗口
// 可用空间求半径,圆相关的常数都乘 k = R / 392(见 RingGeo)。
// 点截图进聚焦视图:圆、下半圈选帧竖线和 Today 淡出,截图在左右两列之间放到
// 最大并上移,窗口底部长出横排条带;Active Apps / Audio / Event Session 挪进
// 按窗口比例钉死的区域照常用。再点截图或按 Esc 原路返回。两套布局都从窗口尺寸算(RingGeo.shot /
// midL / midR),同一个 spring 驱动,切换时不重新取数、不解码。

struct TimelineView: View {
    /// Hoisted to ContentView so the focus/frames survive page switches.
    let state: TimelineState
    @Binding var selection: SidebarSection?
    @Environment(\.services) private var services
    @Environment(\.colorScheme) private var colorScheme

    @State private var ui = TimelineUI()
    @State private var model = DayModel()
    @State private var audioMoments: [Date] = []
    @State private var activeApps: [ActiveAppEntry] = []
    @State private var transcripts: [AudioTranscriptEntry] = []
    @State private var hover: RingHover? = nil
    @State private var hotApp: String? = nil
    @State private var drag: RingDrag? = nil
    /// 选帧竖线换焦点时的过渡量(单位:帧):先挪回旧位置,再动画回到 0。
    @State private var tickShift: Double = 0
    /// 主图解码尺寸(pt):当前模式下截图的显示宽度,向上取到 320pt 一档 —— 拖窗口
    /// 时缓存 key 不跟着每个像素变;预取用同一档。
    @State private var shotPx: CGFloat = 960

    static let tickStep: Double = 2.4
    /// 聚焦条带一列宽(12pt 竖条 + 6pt 缝)。
    static let stripCol: CGFloat = 18
    static let focusAnim = Animation.spring(duration: 0.45, bounce: 0.12)

    private var pal: RingPalette { RingPalette(dark: colorScheme == .dark) }

    private var currentFrame: TimelineFrame? {
        guard state.frames.indices.contains(state.focusIndex) else { return nil }
        return state.frames[state.focusIndex]
    }

    private var day0: Date { Calendar.current.startOfDay(for: state.selectedDay) }
    private var dayLength: TimeInterval {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day0) ?? day0.addingTimeInterval(86400)
        return next.timeIntervalSince(day0)
    }
    private var isToday: Bool { Calendar.current.isDateInToday(state.selectedDay) }

    private func ang(_ d: Date) -> Double { d.timeIntervalSince(day0) / dayLength * 360 }
    private func time(at a: Double) -> Date { day0.addingTimeInterval(a / 360 * dayLength) }

    var body: some View {
        GeometryReader { proxy in
            let g = RingGeo(size: proxy.size)
            let fm = isFocused
            let sl = g.shot(focused: fm)
            // 圆淡出时跟着日期药丸一起往上走一半的位移
            let lift = fm ? (sl.pillY - g.shot(focused: false).pillY) / 2 : 0
            ZStack(alignment: .topLeading) {
                backdrop(g)
                ringCanvas(g)
                    .scaleEffect(fm ? 1.06 : 1)
                    .offset(y: lift)
                    .opacity(fm ? 0 : 1)
                ringHitArea(g).allowsHitTesting(!fm)
                if state.frames.isEmpty {
                    EmptyState(loading: state.loading, hasDB: services != nil)
                        .position(g.c)
                } else {
                    stripBackdrop(g).opacity(fm ? 1 : 0)
                    ticksLayer(g)
                        .compositingGroup()
                        .scaleEffect(fm ? 0.9 : 1, anchor: UnitPoint(x: g.c.x / max(1, g.size.width),
                                                                    y: g.c.y / max(1, g.size.height)))
                        .offset(y: lift)
                        .opacity(fm ? 0 : 1)
                        .allowsHitTesting(!fm)
                    stripLayer(g, fm: fm)
                    stripHitArea(g).allowsHitTesting(fm)
                    innerLayer(g, sl)
                    corners(g, hideToday: fm)
                }
                datePill(g, sl)
                tooltip(g)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { ui.size = proxy.size; updateShotPx() }
            .onChange(of: proxy.size) { ui.size = proxy.size; updateShotPx() }
        }
        .ignoresSafeArea()
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor(); ImageThumbnailCache.shared.removePreviews() }
        // 进出聚焦后换解码档:等 0.45s 的过渡走完再换,过渡中不解码。
        .onChange(of: ui.focused) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { updateShotPx() }
        }
        // Listen for app-wide arrow-key notifications (posted by AppKeyboard).
        .onReceive(NotificationCenter.default.publisher(for: .leftArrowPressed)) { arrow(-1, $0) }
        .onReceive(NotificationCenter.default.publisher(for: .rightArrowPressed)) { arrow(1, $0) }
        // focusIndex 一变:选帧竖线做一段转动过渡。
        .onChange(of: state.focusIndex) { old, new in
            animateTicks(new - old)
            warmPreviews()
        }
        // 换天时回到圆盘:专注视图只对当前这一天的帧有意义
        .task(id: state.selectedDay) { ui.calendarOpen = false; ui.focused = false; reload() }
        // 焦点停稳 180ms 才做旁路活:预取前后各 5 帧 + 四周列表取数。拨帧时每步
        // 都会取消上一个任务,连拨过程中这些都不跑;迟到的结果按取消丢弃。
        .task(id: currentFrame?.id) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            prefetchAround()
            await loadAround()
        }
        // Background workers (CompactionWorker, RetentionWorker, …) mutate
        // the frames table and delete JPGs they've embedded into MP4s.
        // If the change touches the day we're currently showing, refetch
        // so the in-memory `state.frames` doesn't keep pointing at dead
        // snapshot paths.
        .onReceive(NotificationCenter.default.publisher(for: .timelineFramesChanged)) { note in
            // 后台 compaction 触发 → preserveFocus,保住正看的帧,不甩到最新。
            guard let changedDay = note.object as? Date else { reload(preserveFocus: true); return }
            let cal = Calendar(identifier: .gregorian)
            if cal.isDate(changedDay, inSameDayAs: state.selectedDay) {
                reload(preserveFocus: true)
            }
        }
        .onChange(of: ui.calendarOpen) { ui.wheelBlocked = ui.calendarOpen }
    }

    // MARK: Focus

    /// 当天没帧时聚焦视图没东西可看,按圆形视图画。
    private var isFocused: Bool { ui.focused && !state.frames.isEmpty }

    private func toggleFocus() {
        hover = nil; hotApp = nil
        withAnimation(Self.focusAnim) { ui.focused.toggle() }
    }

    /// 方向键:按下走一帧;按住 0.3s 后按固定节奏连续播放,松手(keyUp)即停。
    /// 系统重复键不用 —— 速率随系统设置、间隔不均,播起来一顿一顿。
    private func arrow(_ dir: Int, _ note: Notification) {
        guard !state.frames.isEmpty, !Self.isRepeat(note) else { return }
        let alt = (note.object as? Bool) ?? false
        let state = self.state
        let step: @MainActor () -> Bool = {
            let old = state.focusIndex
            let new = dir < 0
                ? (alt ? Self.previousAppBoundary(in: state.frames, from: old) : max(0, old - 1))
                : (alt ? Self.nextAppBoundary(in: state.frames, from: old) : min(state.frames.count - 1, old + 1))
            state.focusIndex = new
            return new != old
        }
        _ = step()
        ui.play(key: dir < 0 ? 123 : 124, step: step)
    }

    private static func isRepeat(_ note: Notification) -> Bool {
        (note.userInfo?["isRepeat"] as? Bool) ?? false
    }

    private func setFocus(_ i: Int) {
        guard !state.frames.isEmpty else { return }
        state.focusIndex = max(0, min(state.frames.count - 1, i))
    }

    private func seek(_ t: Date) {
        guard !state.frames.isEmpty else { return }
        state.snapFocus(to: t)
    }

    private func animateTicks(_ delta: Int) {
        guard delta != 0, abs(delta) <= 16 else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { tickShift = -Double(delta) }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) { tickShift = 0 }
        }
    }

    static func previousAppBoundary(in frames: [TimelineFrame], from idx: Int) -> Int {
        guard frames.indices.contains(idx), idx > 0 else { return idx }
        let current = frames[idx].appName
        var i = idx - 1
        while i >= 0, frames[i].appName == current { i -= 1 }
        return max(0, i)
    }

    static func nextAppBoundary(in frames: [TimelineFrame], from idx: Int) -> Int {
        guard frames.indices.contains(idx), idx < frames.count - 1 else { return idx }
        let current = frames[idx].appName
        var i = idx + 1
        while i < frames.count, frames[i].appName == current { i += 1 }
        return min(frames.count - 1, i)
    }

    // MARK: Loading

    /// 预取当前 focusIndex 前后各 5 帧。targetPixelSize 跟主图一致(shotPx),
    /// 命中同一 cache key。
    private func updateShotPx() {
        let w = RingGeo(size: ui.size).shot(focused: isFocused).w
        let px = max(320, (w / 320).rounded(.up) * 320)
        if px != shotPx { shotPx = px }
    }

    /// 拨帧预览(长边 480px):焦点所在 MP4 chunk 里前后 40 帧整批顺序解;
    /// JPG 帧解前后 15 帧。已有 / 在解的跳过,所以每步调一次也便宜。
    private func warmPreviews() {
        let frames = state.frames
        let f = state.focusIndex
        guard frames.indices.contains(f) else { return }
        let chunk = frames[f].videoPath
        var pick: [TimelineFrame] = []
        for i in max(0, f - 40)...min(frames.count - 1, f + 40) {
            let fr = frames[i]
            if fr.snapshotPath != nil ? abs(i - f) <= 15 : (chunk != nil && fr.videoPath == chunk) {
                pick.append(fr)
            }
        }
        ImageThumbnailCache.shared.warmPreviews(pick)
    }

    private func prefetchAround() {
        let frames = state.frames
        guard !frames.isEmpty else { return }
        let radius = 5
        let lo = max(0, state.focusIndex - radius)
        let hi = min(frames.count - 1, state.focusIndex + radius)
        for i in lo...hi where i != state.focusIndex {
            ImageThumbnailCache.shared.prefetch(frames[i], targetPixelSize: shotPx)
        }
    }

    /// `preserveFocus`:后台 compaction 顺带触发的刷新传 true —— 保住正看的
    /// 那一帧(按时间戳吸附回最近帧),不甩到最新帧。主动切天传 false(默认),
    /// 落到当天最后一帧。
    private func reload(preserveFocus: Bool = false) {
        state.loading = true
        let day = state.selectedDay
        // 异步 fetch 前先记下当前帧时间戳(读的是旧 frames/focusIndex)。
        let keepTimestamp: Date? = preserveFocus ? currentFrame?.timestamp : nil
        guard let db = services?.db else {
            state.frames = []
            model = DayModel()
            state.loading = false
            return
        }
        state.reloadToken &+= 1
        let token = state.reloadToken
        Task { @MainActor in
            let fetched = await TimelineFeed.framesForDay(day, db: db)
            let moments = await TimelineFeed.audioMomentsForDay(day, db: db)
            // 已有更新的 reload(快速切天),丢弃这次旧天结果 —— 否则慢的旧天
            // 查询迟到会盖掉新天 frames,日期栏显示新天、画面却是旧天。
            guard token == state.reloadToken else { return }
            model = DayModel(frames: fetched, moments: moments)
            audioMoments = moments
            state.frames = fetched
            // 优先级:跨天 seek > 后台刷新保焦点 > 默认落最后一帧。
            if let target = state.pendingSeek {
                state.snapFocus(to: target)   // 最近帧;空帧内部 guard
                state.pendingSeek = nil        // 清掉,免得后续同天 reload 又吸到旧目标
            } else if let keep = keepTimestamp, !fetched.isEmpty {
                state.snapFocus(to: keep)      // 后台刷新:吸附回原来那一帧
            } else {
                state.focusIndex = max(fetched.count - 1, 0)
            }
            state.loading = false
        }
    }

    private func loadAround() async {
        guard let moment = currentFrame?.timestamp, let db = services?.db else {
            activeApps = []; transcripts = []; return
        }
        let apps = await TimelineFeed.activeAppsAround(moment, windowSeconds: 45, db: db)
        let audio = await TimelineFeed.audioTranscriptsAround(
            moment, beforeSeconds: 120, afterSeconds: 30, db: db)
        guard !Task.isCancelled else { return }
        activeApps = apps
        transcripts = audio
    }

    // MARK: Wheel / Esc

    /// 圆形视图里滚轮只在指针落在圆里(含外圈)时拨帧,圆外的列表照常滚;聚焦视图
    /// 里落在截图或底部条带上才拨。Esc 退出聚焦。
    private func installMonitor() {
        guard ui.monitor == nil else { return }
        let ui = self.ui, state = self.state
        ui.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .keyUp]) { e in
            if e.type == .keyUp {
                ui.stopPlay(key: e.keyCode)
                return e
            }
            if e.type == .keyDown {
                if e.keyCode == 53, ui.focused {
                    withAnimation(Self.focusAnim) { ui.focused = false }
                    return nil
                }
                return e
            }
            guard !ui.wheelBlocked, !state.frames.isEmpty,
                  let cv = e.window?.contentView else { return e }
            let p = CGPoint(x: e.locationInWindow.x, y: cv.bounds.height - e.locationInWindow.y)
            let g = RingGeo(size: ui.size)
            let inside = ui.focused
                ? (p.y >= g.size.height - RingGeo.stripH && abs(p.x - g.c.x) <= g.stripW / 2)
                    || g.shot(focused: true).rect(g).contains(p)
                : g.dist(p) <= g.r2 + 12 * g.k
            guard inside else { return e }
            var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            if !e.hasPreciseScrollingDeltas { dx *= TimelineUI.wheelStep; dy *= TimelineUI.wheelStep }
            ui.wheelAcc += abs(dx) > abs(dy) ? -dx : -dy
            guard abs(ui.wheelAcc) >= TimelineUI.wheelStep else { return nil }
            // 一次最多走一步,攒多的直接扔:快速甩动不会排出一串欠账,松手就停。
            let dir = ui.wheelAcc > 0 ? 1 : -1
            ui.wheelAcc = 0
            if ui.canStep() {
                state.focusIndex = max(0, min(state.frames.count - 1, state.focusIndex + dir))
            }
            return nil
        }
    }

    private func removeMonitor() {
        ui.stopPlay(key: nil)
        if let m = ui.monitor { NSEvent.removeMonitor(m) }
        ui.monitor = nil
    }

    // MARK: Backdrop + page switcher

    private func backdrop(_ g: RingGeo) -> some View {
        ZStack {
            SidebarBackdrop()
            RadialGradient(colors: [pal.glow, .clear], center: UnitPoint(x: g.c.x / max(1, g.size.width),
                                                                         y: g.c.y / max(1, g.size.height)),
                           startRadius: 0, endRadius: 434 * g.k)
                .allowsHitTesting(false)
        }
        .frame(width: g.size.width, height: g.size.height)
    }

    // MARK: Ring

    private func ringCanvas(_ g: RingGeo) -> some View {
        let model = self.model, pal = self.pal, hover = self.hover, hotApp = self.hotApp
        let focusTs = currentFrame?.timestamp
        let nowAng: Double? = isToday ? ang(Date()) : nil
        let ang = self.ang
        return Canvas { ctx, _ in
            let k = g.k
            ctx.stroke(RingPaths.arc(g, g.r, 0, 360), with: .color(pal.track), lineWidth: g.band)
            ctx.stroke(RingPaths.arc(g, g.ra, 0, 360), with: .color(pal.track), lineWidth: 5 * k)
            for h in 0..<24 {
                let a = Double(h) * 15, major = h % 3 == 0
                let p = g.pt(416 * k, a), rr = (major ? 2.6 : 1.6) * k
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)),
                         with: .color(pal.tick.opacity(major ? 1 : 0.6)))
                if major {
                    ctx.draw(Text(String(format: "%02d", h))
                                .font(.system(size: 14 * g.fk, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pal.muted),
                             at: g.pt(430 * k, a))
                }
            }
            for gp in model.gaps {
                ctx.stroke(RingPaths.arc(g, g.r, ang(gp.start), ang(gp.end)), with: .color(pal.faint),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0, 7]))
            }
            let gapDeg = 2.4 / Double(g.r) * 180 / .pi
            var hotBlock = -1
            if case .block(let i) = hover { hotBlock = i }
            let dimming = hotBlock >= 0 || hotApp != nil
            for (i, b) in model.blocks.enumerated() {
                let hot = i == hotBlock || b.app == hotApp
                let a0 = ang(b.start) + gapDeg / 2
                let a1 = max(a0 + 0.25, ang(b.end) - gapDeg / 2)
                let grow = hot ? 4 * k : 0
                let path = RingPaths.roundSeg(g, g.r1 - grow, g.r2 + grow, a0, a1, g.band / 2 + grow)
                ctx.fill(path, with: .color(TimelineBarColor.barColor(for: b.app)
                    .opacity(dimming && !hot ? 0.35 : 1)))
            }
            var hotAudio = -1
            if case .audio(let i) = hover { hotAudio = i }
            for (i, s) in model.audio.enumerated() {
                let a0 = ang(s.start) + 0.6
                ctx.stroke(RingPaths.arc(g, g.ra, a0, max(a0 + 0.1, ang(s.end) - 0.6)),
                           with: .color(pal.audio),
                           style: StrokeStyle(lineWidth: (i == hotAudio ? 8 : 5) * k, lineCap: .round))
            }
            if let an = nowAng {
                var line = Path()
                line.move(to: g.pt(g.r1 - 5 * k, an)); line.addLine(to: g.pt(g.r2 + 5 * k, an))
                ctx.stroke(line, with: .color(pal.fg), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                let inTicks = abs(an.truncatingRemainder(dividingBy: 360) - 180) < 80
                ctx.draw(Text("now").font(.system(size: 14 * g.fk, weight: .semibold, design: .monospaced))
                            .foregroundStyle(pal.fg),
                         at: g.pt(inTicks ? 470 * k : g.r1 - 26 * k, an))
            }
            if let ts = focusTs {
                let a = ang(ts)
                // 焦点帧:外圈上一个白点 + 圈内一个小三角
                func local(_ dx: CGFloat, _ rad: CGFloat) -> CGPoint {
                    let t = a * .pi / 180
                    return CGPoint(x: g.c.x + rad * CGFloat(sin(t)) + dx * CGFloat(cos(t)),
                                   y: g.c.y - rad * CGFloat(cos(t)) + dx * CGFloat(sin(t)))
                }
                var tri = Path()
                tri.move(to: local(-7 * k, g.r1 - 15 * k))
                tri.addLine(to: local(7 * k, g.r1 - 15 * k))
                tri.addLine(to: local(0, g.r1 - 6 * k))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(pal.fg))
                ctx.stroke(tri, with: .color(pal.fg), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                let p = g.pt(g.r, a), rr = 5.5 * k
                let dot = Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: pal.curglow, radius: 4))
                    l.fill(dot, with: .color(.white))
                }
                ctx.stroke(dot, with: .color(.black.opacity(0.35)), lineWidth: 1)
            }
        }
        .frame(width: g.size.width, height: g.size.height)
        .allowsHitTesting(false)
    }

    /// 外圈 + 声音细圈的命中区:hover 出 tooltip,点 / 拖跳到那个角度最近的帧。
    private func ringHitArea(_ g: RingGeo) -> some View {
        Color.clear
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Annulus(center: g.c, inner: g.r1 - 6 * g.k, outer: g.ra + 10 * g.k), eoFill: true)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    ui.hoverPoint = p
                    let h = drag == nil ? hitTest(p, g) : nil
                    if h != hover { hover = h }
                case .ended:
                    if hover != nil { hover = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard !state.frames.isEmpty else { return }
                        let a = g.angle(at: v.location)
                        if drag == nil { drag = RingDrag(a0: a, moved: false); hover = nil }
                        if var d = drag, !d.moved, abs(a - d.a0) > 1.5 { d.moved = true; drag = d }
                        if drag?.moved == true { seek(time(at: a)) }
                    }
                    .onEnded { v in
                        defer { drag = nil }
                        guard let d = drag, !d.moved else { return }
                        if case .audio(let i) = hitTest(v.location, g) {
                            seek(model.audio[i].start)
                        } else {
                            seek(time(at: d.a0))
                        }
                    }
            )
    }

    private func hitTest(_ p: CGPoint, _ g: RingGeo) -> RingHover? {
        let d = g.dist(p), ts = time(at: g.angle(at: p))
        if d > (g.r2 + g.ra) / 2 {
            if let i = model.audio.firstIndex(where: { $0.start.addingTimeInterval(-60) <= ts && ts <= $0.end.addingTimeInterval(60) }) {
                return .audio(i)
            }
            return nil
        }
        if let i = model.blocks.firstIndex(where: { $0.start <= ts && ts <= $0.end }) { return .block(i) }
        if let i = model.gaps.firstIndex(where: { $0.start <= ts && ts <= $0.end }) { return .gap(i) }
        return nil
    }

    @ViewBuilder
    private func tooltip(_ g: RingGeo) -> some View {
        if let h = hover, drag == nil {
            RingTooltip(ui: ui, size: g.size, pal: pal) { tipContent(h) }
        }
    }

    @ViewBuilder
    private func tipContent(_ h: RingHover) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch h {
            case .block(let i):
                let b = model.blocks[i]
                HStack(spacing: 8) {
                    RealAppIcon(appName: b.app, size: 20)
                    Text(b.app).font(.system(size: 15, weight: .semibold))
                }
                Text("\(Fmt.hm(b.start)) – \(Fmt.hm(b.end)) · \(Fmt.dur(b.end.timeIntervalSince(b.start)))")
                    .font(.system(size: 13, design: .monospaced))
                let sub = (b.url?.isEmpty == false ? b.url : nil) ?? b.title
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 14)).foregroundStyle(pal.muted).lineLimit(1).truncationMode(.tail)
                }
                Text("\(b.f1 - b.f0) frames · click to jump here").font(.system(size: 12.5)).foregroundStyle(pal.faint)
            case .gap(let i):
                let s = model.gaps[i]
                Text("No capture").font(.system(size: 15, weight: .semibold))
                Text("\(Fmt.hm(s.start)) – \(Fmt.hm(s.end)) · \(Fmt.dur(s.end.timeIntervalSince(s.start)))")
                    .font(.system(size: 13, design: .monospaced))
                Text("Lid closed, asleep, or paused").font(.system(size: 12.5)).foregroundStyle(pal.faint)
            case .audio(let i):
                let s = model.audio[i]
                Text("Audio").font(.system(size: 15, weight: .semibold))
                Text("\(Fmt.hm(s.start)) – \(Fmt.hm(s.end)) · \(Fmt.dur(s.end.timeIntervalSince(s.start)))")
                    .font(.system(size: 13, design: .monospaced))
                Text("\(s.count) transcripts · click to jump here").font(.system(size: 12.5)).foregroundStyle(pal.faint)
            }
        }
        .foregroundStyle(pal.fg)
    }

    // MARK: Frame ticks (bottom inner arc)

    /// 选帧竖线:沿圆的下半圈排开,当前帧在正下方,往右是更晚的帧。
    private func ticksLayer(_ g: RingGeo) -> some View {
        let frames = state.frames
        let f = min(max(0, state.focusIndex), frames.count - 1)
        let lo = max(0, f - 20), hi = min(frames.count - 1, f + 20)
        var icons = Set<Int>()
        var lastIcon = -99
        for i in lo...hi where (i == 0 || frames[i - 1].appName != frames[i].appName)
            && abs(i - f) <= 14 && i - lastIcon >= 3 {
            icons.insert(i); lastIcon = i
        }
        let k = g.k
        return ZStack(alignment: .topLeading) {
            ForEach(Array(lo...hi), id: \.self) { i in
                let d = abs(i - f), cur = i == f
                let a = 180 - Double(i - f) * Self.tickStep
                let len = (cur ? 64 : 36) * k
                let fade = max(0, 1 - Double(max(0, d - 14)) / 6)
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(TimelineBarColor.barColor(for: frames[i].appName))
                        .frame(width: 11 * k, height: len + 11 * k)
                        .shadow(color: cur ? pal.curglow : .clear, radius: cur ? 6 * k : 0)
                }
                .frame(width: 18 * k, height: 76 * k, alignment: .top)
                .contentShape(Rectangle())
                .rotationEffect(.degrees(a))
                .position(g.pt(330 * k, a))
                .opacity(fade)
                .onTapGesture { setFocus(i) }
                if icons.contains(i) {
                    RealAppIcon(appName: frames[i].appName, size: 26 * k)
                        .position(g.pt(276 * k, a))
                        .opacity(fade)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .rotationEffect(.degrees(tickShift * Self.tickStep),
                        anchor: UnitPoint(x: g.c.x / max(1, g.size.width), y: g.c.y / max(1, g.size.height)))
    }

    // MARK: Focus strip (bottom edge)

    /// 聚焦视图底部的横排条带,在面板下面铺满窗口宽:竖条从窗口底边长出来(进入时
    /// 从中间往两边错开 ≤ 0.12s 依次升起,退出时一起沉回底边),app 换了在竖条
    /// 上方放图标(跟在竖条后面淡入放大),两端渐隐。圆形视图里它常驻但高度为 0,
    /// 这样进出只是同一批视图的高度动画,没有插入 / 移除。整层 drawingGroup 合成、
    /// 不接点击,点击由 stripHitArea 按横坐标换算成帧号。
    private func stripLayer(_ g: RingGeo, fm: Bool) -> some View {
        let frames = state.frames, col = Self.stripCol
        let f = min(max(0, state.focusIndex), frames.count - 1)
        let half = g.stripW / 2
        let span = Int(half / col) + 2
        let lo = max(0, f - span), hi = min(frames.count - 1, f + span)
        var icons = Set<Int>()
        var lastIcon = -99
        for i in lo...hi where (i == 0 || frames[i - 1].appName != frames[i].appName) && i - lastIcon >= 2 {
            icons.insert(i); lastIcon = i
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(lo...hi), id: \.self) { i in
                stripBar(i, f: f, g: g, fm: fm, half: half, icon: icons.contains(i))
            }
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .drawingGroup()
        .offset(x: -tickShift * col)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func stripBar(_ i: Int, f: Int, g: RingGeo, fm: Bool, half: CGFloat, icon: Bool) -> some View {
        let app = state.frames[i].appName
        let H = g.size.height, col = Self.stripCol
        let d = abs(i - f), cur = i == f
        let x: CGFloat = g.c.x + CGFloat(i - f) * col
        let fade: Double = Double(min(1, max(0, (half - abs(x - g.c.x)) / 120)))
        let delay: Double = fm ? min(0.12, Double(d) * 0.004) : 0.03
        // 往窗口底边下多伸 6pt,藏掉竖条底下的圆角
        let boxH: CGFloat = RingGeo.stripH + 6
        let barH: CGFloat = fm ? (cur ? 106 : 62) : 0
        let glow = cur && fm
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineBarColor.barColor(for: app))
                .frame(width: 12, height: barH)
                .shadow(color: glow ? pal.curglow : .clear, radius: glow ? 6 : 0)
        }
        .frame(width: col, height: boxH, alignment: .bottom)
        .position(x: x, y: H + 6 - boxH / 2)
        .opacity(fade)
        .animation(Self.focusAnim.delay(delay), value: fm)
        if icon {
            RealAppIcon(appName: app, size: 32)
                .scaleEffect(fm ? 1 : 0.5, anchor: .bottom)
                .opacity(fm ? fade : 0)
                .position(x: x, y: H - RingGeo.stripH + 16)
                .animation(Self.focusAnim.delay(fm ? delay + 0.1 : 0), value: fm)
        }
    }

    /// 条带的点击区:点在哪一列就跳到哪一帧。
    private func stripHitArea(_ g: RingGeo) -> some View {
        let w = g.stripW
        return Color.clear
            .frame(width: w, height: RingGeo.stripH)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                setFocus(state.focusIndex + Int(((p.x - w / 2) / Self.stripCol).rounded()))
            }
            .position(x: g.c.x, y: g.size.height - RingGeo.stripH / 2)
    }

    /// 聚焦条带底下那层由下往上的淡底,两端跟条带一起渐隐。
    private func stripBackdrop(_ g: RingGeo) -> some View {
        LinearGradient(colors: [Theme.hover, .clear], startPoint: .bottom, endPoint: .top)
            .frame(width: g.stripW, height: RingGeo.stripH)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .position(x: g.c.x, y: g.size.height - RingGeo.stripH / 2)
            .allowsHitTesting(false)
    }

    // MARK: Inside the circle

    private var dayBinding: Binding<Date> {
        Binding(get: { state.selectedDay }, set: { state.selectedDay = $0 })
    }

    private func shiftDay(_ n: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: n, to: state.selectedDay),
              d <= Date() else { return }
        state.selectedDay = d
    }

    private func datePill(_ g: RingGeo, _ sl: ShotLayout) -> some View {
        let fk = g.fk
        let canNext = (Calendar.current.date(byAdding: .day, value: 1, to: day0) ?? .distantFuture) <= Date()
        let db = services?.db
        return HStack(spacing: 0) {
            Button { shiftDay(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 14 * fk, weight: .medium))
                    .padding(.horizontal, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(pal.muted)
            Button { ui.calendarOpen.toggle() } label: {
                HStack(spacing: 7) {
                    Text((isToday ? "Today · " : "") + Fmt.dayLabel(state.selectedDay))
                        .font(.system(size: 15 * fk, weight: .semibold))
                    Image(systemName: "calendar").font(.system(size: 13 * fk)).opacity(0.55)
                }
                .foregroundStyle(pal.fg)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $ui.calendarOpen, arrowEdge: .bottom) {
                CalendarPopover(selected: dayBinding, isPresented: $ui.calendarOpen,
                                availability: db.map { db in { days in await TimelineFeed.daysWithFrames(days, db: db) } })
            }
            Button { shiftDay(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 14 * fk, weight: .medium))
                    .padding(.horizontal, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(pal.muted).opacity(canNext ? 1 : 0.25).disabled(!canNext)
        }
        .frame(height: 34 * g.k)
        .padding(.horizontal, 2)
        .background(Capsule().fill(pal.pill))
        .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
        .onTapGesture { }   // 药丸空白处不落到下面的拖窗手势
        .position(x: g.c.x, y: sl.pillY)
    }

    @ViewBuilder
    private func innerLayer(_ g: RingGeo, _ sl: ShotLayout) -> some View {
        if let f = currentFrame {
            let k = g.k, fk = g.fk
            if let url = f.browserUrl, !url.isEmpty {
                let secure = url.hasPrefix("https://")
                HStack(spacing: 8) {
                    Image(systemName: secure ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 11 * fk))
                        .foregroundStyle(secure ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))
                    Text(Fmt.displayURL(url))
                        .font(.system(size: 13.5 * fk, design: .monospaced))
                        .foregroundStyle(pal.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 14)
                .frame(height: 32 * k)
                .frame(maxWidth: 460 * k)
                .background(Capsule().fill(pal.pill))
                .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 460 * k)
                .position(x: g.c.x, y: sl.urlY)
            }
            // 原图完整显示:按比例放进框里,不裁边、不切圆角
            FrameShot(frame: f, contentMode: .fit, pt: shotPx)
                .frame(width: sl.w, height: sl.h)
                .contentShape(Rectangle())
                .onTapGesture { toggleFocus() }
                .position(x: g.c.x, y: sl.cy)
            HStack(spacing: 9) {
                RealAppIcon(appName: f.appName, size: 22 * fk)
                Text(f.appName.isEmpty ? "(unknown app)" : f.appName)
                    .font(.system(size: 15 * fk, weight: .bold, design: .monospaced))
                    .foregroundStyle(pal.fg)
                    .lineLimit(1).layoutPriority(1)
                Text("·").font(.system(size: 15 * fk)).foregroundStyle(pal.fg.opacity(0.3))
                Text(f.windowName)
                    .font(.system(size: 15 * fk, design: .monospaced))
                    .foregroundStyle(pal.muted)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Fmt.hms(f.timestamp))
                    .font(.system(size: 15 * fk, design: .monospaced))
                    .foregroundStyle(pal.muted)
                    .layoutPriority(1)
            }
            .frame(width: sl.infoW)
            .position(x: g.c.x, y: sl.infoY)
        }
    }

    // MARK: Corners

    private func corners(_ g: RingGeo, hideToday: Bool) -> some View {
        let focus = currentFrame?.timestamp ?? Date()
        let title = isToday ? "TODAY" : Fmt.monthDay(state.selectedDay).uppercased()
        return TimelineCorners(
            g: g, pal: pal, model: model, focusIndex: state.focusIndex, focusTime: focus,
            dayTitle: title, hideToday: hideToday, apps: activeApps, audio: transcripts, audioMoments: audioMoments,
            hotApp: $hotApp,
            jumpToFrame: { setFocus($0) },
            jumpToTime: { seek($0) })
    }
}

/// 只给滚轮监听 / Esc 用的引用型状态 —— NSEvent 闭包里要读写它。
@Observable
final class TimelineUI {
    var focused = false
    var calendarOpen = false
    /// 指针位置只由 RingTooltip 读,移动鼠标时只重画 tooltip 那一层。
    var hoverPoint: CGPoint = .zero
    @ObservationIgnored var wheelBlocked = false
    @ObservationIgnored var size: CGSize = .zero
    @ObservationIgnored var wheelAcc: CGFloat = 0
    @ObservationIgnored var monitor: Any?
    @ObservationIgnored private var lastStep: TimeInterval = 0

    /// 拨帧限速。每换一帧 = 一张 3600px 主图解码 + 停稳后两条 SQL + 10 张预取;
    /// 触控板甩一下每个事件能有上百 pt,原来一秒能走一两百帧。现在:
    /// - 22pt 一步:鼠标滚轮一格(按行滚,×22 换算)正好一帧;
    /// - 两步至少隔 40ms,即每秒 ≤ 25 帧;
    /// - 连拨时先显示长边 480px 的预览(按 chunk 整批预解),主图按显示尺寸解,
    ///   没缓存时晚 30ms、有预览时晚 50ms 才解,连拨中一闪而过的帧不解清晰图;
    /// - 预取和四周列表等焦点停稳 180ms 才跑。
    static let wheelStep: CGFloat = 22
    static let minStepInterval: TimeInterval = 0.04

    /// 长按方向键播放:按下 0.3s 后每 45ms 走一帧(≈22 帧/秒,刚好赶在主图
    /// 50ms 解码延迟之前,播放中只显示预览)。到头、松手、app 失焦都停。
    static let playDelay: TimeInterval = 0.3
    static let playInterval: TimeInterval = 0.045
    @ObservationIgnored private var playTimer: Timer?
    @ObservationIgnored private var playKey: UInt16?

    func play(key: UInt16, step: @escaping @MainActor () -> Bool) {
        stopPlay(key: nil)
        playKey = key
        let start = Timer(timeInterval: Self.playDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playKey == key else { return }
                let t = Timer(timeInterval: Self.playInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if !NSApp.isActive || !step() { self.stopPlay(key: nil) }
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                self.playTimer = t
            }
        }
        RunLoop.main.add(start, forMode: .common)
        playTimer = start
    }

    /// key 为 nil = 无条件停;否则只在松开的正是在播的那个键时停。
    func stopPlay(key: UInt16?) {
        guard key == nil || key == playKey else { return }
        playTimer?.invalidate()
        playTimer = nil
        playKey = nil
    }

    func canStep() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStep >= Self.minStepInterval else { return false }
        lastStep = now
        return true
    }
}

/// 跟着指针走的 tooltip,靠近窗口右 / 下边时翻到指针另一侧。
private struct RingTooltip<Content: View>: View {
    let ui: TimelineUI
    let size: CGSize
    let pal: RingPalette
    @ViewBuilder let content: () -> Content
    @State private var tipSize: CGSize = .zero

    var body: some View {
        let p = ui.hoverPoint
        let x = p.x + 16 + tipSize.width > size.width - 8 ? p.x - tipSize.width - 16 : p.x + 16
        let y = p.y + 14 + tipSize.height > size.height - 8 ? p.y - tipSize.height - 14 : p.y + 14
        content()
            .padding(.horizontal, 13).padding(.vertical, 10)
            .frame(minWidth: 200, maxWidth: 330, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.tip))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.tipb, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 15, y: 10)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }
}

private enum RingHover: Equatable {
    case block(Int), gap(Int), audio(Int)
}

private struct RingDrag {
    var a0: Double
    var moved: Bool
}

// =============================================================================
// MARK: - TimelineControls (date nav + calendar popover) — native styling
// =============================================================================
//
// Uses stock SwiftUI button styles so the bar looks like the rest of macOS:
//   - chevrons / refresh: .borderless icon buttons (hover handled by system)
//   - date trigger: .bordered button (the standard "pill" look used in
//     Calendar, Reminders, the menu-bar clock, Finder's column-view header,
//     etc.)
//   - system font (SF Pro) on the date

// `internal`(去 private):Input 图谱(InputActivityChartView)复用这套
// 「和 timeline 一致的日期切换栏 + 日历弹窗」,不重复实现。
struct TimelineControlsBar: View {
    @Binding var currentDate: Date
    let onRefresh: () -> Void
    @State private var calendarOpen = false

    private var canGoForward: Bool {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) else { return false }
        return next <= Date()
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer()

            Button {
                if let d = Calendar.current.date(byAdding: .day, value: -1, to: currentDate) {
                    currentDate = d
                }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())   // 整个矩形可点,不只图标字形
            }
            .buttonStyle(.bouncyIcon)

            Button { calendarOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                    Text(dateFmt.string(from: currentDate))
                }
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $calendarOpen, arrowEdge: .bottom) {
                CalendarPopover(selected: $currentDate, isPresented: $calendarOpen)
            }

            Button {
                if let d = Calendar.current.date(byAdding: .day, value: 1, to: currentDate),
                   d <= Date() { currentDate = d }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bouncyIcon)
            .disabled(!canGoForward)

            Button {
                currentDate = Date()
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bouncyIcon)

            Spacer()
        }
        .controlSize(.extraLarge)
        .font(.system(size: 22))
    }

    private var dateFmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }
}

// =============================================================================
// MARK: - Calendar Popover
// =============================================================================

struct CalendarPopover: View {
    @Binding var selected: Date
    @Binding var isPresented: Bool
    /// 传了就按月查哪些天有采集:没采集的天灰掉、不可点(Timeline 用);
    /// nil 时所有过去的天都可点(Input 图谱用)。
    var availability: (([Date]) async -> Set<Date>)? = nil
    @State private var anchor: Date = Date()
    @State private var captured: Set<Date>? = nil
    @Environment(\.colorScheme) private var colorScheme
    private let cal = Calendar(identifier: .gregorian)

    init(selected: Binding<Date>, isPresented: Binding<Bool>,
         availability: (([Date]) async -> Set<Date>)? = nil) {
        self._selected = selected
        self._isPresented = isPresented
        self.availability = availability
        self._anchor = State(initialValue: selected.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18), lineWidth: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.bouncyIcon)
                Spacer()
                Text(monthTitle(anchor)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18), lineWidth: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.bouncyIcon)
            }

            HStack(spacing: 0) {
                ForEach(["Su","Mo","Tu","We","Th","Fr","Sa"], id: \.self) { d in
                    Text(d).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }

            let days = monthGrid(anchor)
            VStack(spacing: 4) {
                ForEach(0..<6) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7) { col in
                            let idx = row * 7 + col
                            if idx < days.count, let date = days[idx] {
                                let inMonth = cal.isDate(date, equalTo: anchor, toGranularity: .month)
                                let isSel = cal.isDate(date, inSameDayAs: selected)
                                let isFuture = date > Date()
                                let noCapture = captured.map { !$0.contains(cal.startOfDay(for: date)) } ?? false
                                DayCell(date: date, inMonth: inMonth, isSelected: isSel, isFuture: isFuture,
                                        noCapture: noCapture) {
                                    if !isFuture && !noCapture {
                                        selected = date
                                        isPresented = false
                                    }
                                }
                            } else { Color.clear.frame(maxWidth: .infinity, minHeight: 30) }
                        }
                    }
                }
            }
        }
        .foregroundStyle(Theme.textPrimary.opacity(0.9))
        .padding(14)
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.98))
        .task(id: monthTitle(anchor)) {
            guard let availability else { return }
            let days = monthGrid(anchor).compactMap { $0 }.map { cal.startOfDay(for: $0) }
            captured = await availability(days)
        }
    }

    private func shiftMonth(_ delta: Int) {
        anchor = cal.date(byAdding: .month, value: delta, to: anchor) ?? anchor
    }
    private func monthTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: d)
    }
    private func monthGrid(_ a: Date) -> [Date?] {
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: a)) else { return [] }
        let weekday = cal.component(.weekday, from: monthStart)
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let prevLast = cal.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart
        let pre = weekday - 1
        var cells: [Date?] = []
        for i in stride(from: pre - 1, through: 0, by: -1) {
            cells.append(cal.date(byAdding: .day, value: -i, to: prevLast))
        }
        for i in 0..<daysInMonth { cells.append(cal.date(byAdding: .day, value: i, to: monthStart)) }
        while cells.count < 42 {
            let last = cells.last?.flatMap { $0 } ?? monthStart
            if let next = cal.date(byAdding: .day, value: 1, to: last) { cells.append(next) }
            else { cells.append(nil) }
        }
        return Array(cells.prefix(42))
    }
}

struct DayCell: View {
    let date: Date
    let inMonth: Bool
    let isSelected: Bool
    let isFuture: Bool
    var noCapture: Bool = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action: action) {
            let day = Calendar.current.component(.day, from: date)
            // 选中态背景:dark 用浅色块,light 用深色块。文字色取背景的反色。
            let selectedFill: Color = (colorScheme == .light)
                ? Color.black.opacity(0.85)
                : Color.white.opacity(0.92)
            let selectedFg: Color = (colorScheme == .light)
                ? Color.white
                : Color.black
            Text("\(day)")
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(
                    isFuture     ? Theme.textPrimary.opacity(0.20)
                    : isSelected ? selectedFg
                    : noCapture  ? Theme.textPrimary.opacity(0.25)
                    : inMonth    ? Theme.textPrimary.opacity(0.88)
                    :              Theme.textPrimary.opacity(0.32)
                )
                .background(
                    isSelected
                    ? AnyView(RoundedRectangle(cornerRadius: 5).fill(selectedFill))
                    : AnyView(Color.clear)
                )
                .contentShape(Rectangle())   // 整格可点,不只数字字形
        }
        .buttonStyle(.bouncyIcon)
        .disabled(isFuture || noCapture)
    }
}

// =============================================================================
// MARK: - No-media placeholder
// =============================================================================

/// Shown when a TimelineFrame has neither a loadable JPG snapshot nor an
/// MP4 chunk — the metadata is in the DB but the underlying pixels never
/// landed on disk (capture failed or files were pruned).
private struct NoMediaPlaceholder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.hover)                    // 动态灰阶,light/dark 都看得见
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
            VStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textPrimary.opacity(0.35))
                Text("No image saved for this frame")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.45))
            }
        }
    }
}

struct RealAppIcon: View {
    let appName: String
    let size: CGFloat
    @State private var realIcon: NSImage? = nil

    var body: some View {
        ZStack {
            if let img = realIcon {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Circle().fill(TimelineBarColor.barColor(for: appName))
                Text(String(appName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .task(id: appName) { await load() }
    }

    private func load() async {
        if let cached = AppNameIconCache.shared.get(appName) { self.realIcon = cached; return }
        if AppNameIconCache.shared.isKnownMiss(appName) { self.realIcon = nil; return }
        self.realIcon = nil   // 复用到新 app 名时先清,避免闪现上一个 app 的图标
        let name = appName
        let img = await Task.detached(priority: .userInitiated) {
            AppIconLoader.icon(forAppName: name)
        }.value
        AppNameIconCache.shared.store(img, for: name)
        // .task(id: appName) 在 appName 变化时取消本任务,但 detached 的加载
        // 不跟着取消 —— 慢加载晚归时不能覆盖新 app 已经写好的图标(先清后写
        // 挡不住乱序回写;同款修法见 ImageLoader)。缓存照常写,丢的只是这次展示。
        if !Task.isCancelled {
            self.realIcon = img   // nil 自然回退占位图
        }
    }
}

// =============================================================================
// MARK: - Color helper (port of Orphies' appNameToBarColor)
// =============================================================================

enum TimelineBarColor {
    /// Brighter than the React original's `hsl(hue, 35%, 65%)` because
    /// SwiftUI uses HSB (not HSL) — at the same numeric values the colors
    /// come out much darker and basically invisible on a black background.
    /// Tuned by eye for dark-mode visibility.
    static func barColor(for appName: String) -> Color {
        if appName.isEmpty { return Color(hue: 0, saturation: 0, brightness: 0.6) }
        var hash: UInt64 = 5381
        for ch in appName.unicodeScalars { hash = (hash &* 33) &+ UInt64(ch.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.88)
    }
}

// =============================================================================
// MARK: - Empty state
// =============================================================================

private struct EmptyState: View {
    let loading: Bool
    let hasDB: Bool
    var body: some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
                Text("Loading frames…").font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.5))
            } else if !hasDB {
                Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 32))
                    .foregroundStyle(Theme.textPrimary.opacity(0.3))
                Text("No ~/.portrait/metadata/screen.sqlite found")
                    .font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.5))
            } else {
                Image(systemName: "moon.zzz").font(.system(size: 32))
                    .foregroundStyle(Theme.textPrimary.opacity(0.3))
                Text("No capture this day").font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your Mac was off or capture was paused.").font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary.opacity(0.55))
            }
        }
    }
}

// =============================================================================
// MARK: - Ring geometry / palette / paths
// =============================================================================

/// 圆的几何。半径取窗口能放下的最大值:左右各留 20pt 边 + 至少 180pt 侧栏 +
/// 10pt 间隙,上下留 22pt;时刻标签外沿在 440/392·R。
struct RingGeo {
    static let edge: CGFloat = 20
    let size: CGSize
    let c: CGPoint
    let r: CGFloat
    let k: CGFloat
    let sideW: CGFloat

    init(size: CGSize) {
        self.size = size
        let ext: CGFloat = 440.0 / 392.0
        let rw = (size.width / 2 - Self.edge - 180 - 10) / ext
        let rh = (size.height / 2 - 22) / ext
        let r = max(160, min(392, rw, rh))
        self.r = r
        k = r / 392
        c = CGPoint(x: size.width / 2, y: size.height / 2)
        sideW = max(180, min(300, size.width / 2 - Self.edge - 10 - r * ext))
    }

    var band: CGFloat { 18 * k }
    var r1: CGFloat { r - band / 2 }
    var r2: CGFloat { r + band / 2 }
    var ra: CGFloat { 406 * k }
    /// 圆里的字号跟着缩,但不小于稿子的 78%,否则看不清。
    var fk: CGFloat { max(0.78, k) }

    func pt(_ rad: CGFloat, _ deg: Double) -> CGPoint {
        let t = deg * .pi / 180
        return CGPoint(x: c.x + rad * CGFloat(sin(t)), y: c.y - rad * CGFloat(cos(t)))
    }
    func angle(at p: CGPoint) -> Double {
        let a = atan2(Double(p.x - c.x), Double(c.y - p.y)) * 180 / .pi
        return a < 0 ? a + 360 : a
    }
    func dist(_ p: CGPoint) -> CGFloat { hypot(p.x - c.x, p.y - c.y) }

    /// 聚焦条带高度(图标槽 32 + 竖条最高 100 + 余量)。
    static let stripH: CGFloat = 140

    /// 聚焦视图左列右沿 / 右列左沿(占窗口宽的比例)。
    static let focusLeftR: CGFloat = 0.21
    static let focusRightL: CGFloat = 0.785
    /// 聚焦视图里左右两列之间的空地(两侧各留 16pt),截图放在这一段。
    var midL: CGFloat { size.width * Self.focusLeftR + 16 }
    var midR: CGFloat { size.width * Self.focusRightL - 16 }
    /// 聚焦条带宽:面板都在 0.80H 以上收住,条带在它们下面铺满窗口(两边留 edge)。
    var stripW: CGFloat { size.width - 2 * Self.edge }

    /// 截图和它上方日期药丸 / URL / 信息行的位置。圆形视图:16:10 贴着内圈的
    /// 最大矩形,四角落在内圈上。聚焦视图:在 midL…midR 之间放到最大,中心比
    /// 窗口中心略高,上面一摞(到药丸上沿约 128pt)放在页面
    /// 切换栏下面,下面让出条带。
    func shot(focused: Bool) -> ShotLayout {
        if !focused {
            let h = 404 * k
            return ShotLayout(w: 646 * k, h: h, cy: c.y, infoW: 646 * k - 80,
                              infoY: c.y - h / 2 - 11 * fk - 10 * k,
                              urlY: c.y - 262 * k, pillY: c.y - 312 * k)
        }
        let infoGap = 11 * fk + 10 * k, urlGap = 36 * k, pillGap = 44 * k
        let top = 50 + 17 * k + pillGap + urlGap + infoGap
        let bottom = size.height - Self.stripH - 12
        let cy = min(c.y - 12 * k, (top + bottom) / 2)
        let h = max(120, min((midR - midL) / 1.6, 2 * (cy - top), 2 * (bottom - cy)))
        let infoY = cy - h / 2 - infoGap
        return ShotLayout(w: h * 1.6, h: h, cy: cy, infoW: h * 1.6 - 20, infoY: infoY,
                          urlY: infoY - urlGap, pillY: infoY - urlGap - pillGap)
    }
}

struct ShotLayout {
    let w: CGFloat
    let h: CGFloat
    let cy: CGFloat
    let infoW: CGFloat
    let infoY: CGFloat
    let urlY: CGFloat
    let pillY: CGFloat
    func rect(_ g: RingGeo) -> CGRect { CGRect(x: g.c.x - w / 2, y: cy - h / 2, width: w, height: h) }
}

struct RingPalette {
    let dark: Bool
    private var base: Color { dark ? .white : .black }
    var fg: Color { Theme.textPrimary }
    var muted: Color { base.opacity(dark ? 0.58 : 0.55) }
    var faint: Color { base.opacity(dark ? 0.36 : 0.34) }
    var track: Color { base.opacity(dark ? 0.055 : 0.06) }
    var tick: Color { base.opacity(dark ? 0.30 : 0.28) }
    var pill: Color { base.opacity(dark ? 0.06 : 0.045) }
    var pillb: Color { base.opacity(dark ? 0.10 : 0.08) }
    var row: Color { base.opacity(dark ? 0.045 : 0.035) }
    var rowb: Color { base.opacity(dark ? 0.06 : 0.05) }
    var tip: Color { dark ? Color(red: 0.125, green: 0.125, blue: 0.14).opacity(0.85) : Color.white.opacity(0.85) }
    var tipb: Color { base.opacity(0.1) }
    var seg: Color { dark ? Color.white.opacity(0.14) : .white }
    var curglow: Color { dark ? Color.white.opacity(0.65) : Color.black.opacity(0.45) }
    var accent: Color { Theme.accent }
    var accentbg: Color { Theme.accent.opacity(dark ? 0.15 : 0.12) }
    var accentb: Color { Theme.accent.opacity(dark ? 0.32 : 0.30) }
    var audio: Color { dark ? Color(red: 0.66, green: 0.62, blue: 1) : Color(red: 0.55, green: 0.48, blue: 1) }
    var glow: Color {
        dark ? Color(red: 0.43, green: 0.37, blue: 1).opacity(0.16)
             : Color(red: 0.71, green: 0.63, blue: 0.94).opacity(0.42)
    }
}

enum RingPaths {
    private static func sw(_ a: Double) -> Angle { .degrees(a - 90) }

    static func arc(_ g: RingGeo, _ r: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: g.c, radius: r, startAngle: sw(a0), endAngle: sw(a1), clockwise: false)
        return p
    }

    /// 圆角环形段:四个角用二次曲线收圆;rc = 段厚一半时两头是半圆。
    static func roundSeg(_ g: RingGeo, _ r1: CGFloat, _ r2: CGFloat,
                         _ a0: Double, _ a1: Double, _ rcIn: CGFloat) -> Path {
        let span = CGFloat((a1 - a0) * .pi / 180)
        let rc = max(0, min(rcIn, (r2 - r1) / 2, span * r1 / 2))
        let d2 = Double(rc / r2) * 180 / .pi, d1 = Double(rc / r1) * 180 / .pi
        var p = Path()
        p.move(to: g.pt(r2, a0 + d2))
        p.addArc(center: g.c, radius: r2, startAngle: sw(a0 + d2), endAngle: sw(a1 - d2), clockwise: false)
        p.addQuadCurve(to: g.pt(r2 - rc, a1), control: g.pt(r2, a1))
        p.addLine(to: g.pt(r1 + rc, a1))
        p.addQuadCurve(to: g.pt(r1, a1 - d1), control: g.pt(r1, a1))
        p.addArc(center: g.c, radius: r1, startAngle: sw(a1 - d1), endAngle: sw(a0 + d1), clockwise: true)
        p.addQuadCurve(to: g.pt(r1 + rc, a0), control: g.pt(r1, a0))
        p.addLine(to: g.pt(r2 - rc, a0))
        p.addQuadCurve(to: g.pt(r2, a0 + d2), control: g.pt(r2, a0))
        p.closeSubpath()
        return p
    }
}

private struct Annulus: Shape {
    let center: CGPoint
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        return p
    }
}

private struct Triangle: Shape {
    let up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// =============================================================================
// MARK: - Day model (app blocks / gaps / totals / audio spans)
// =============================================================================

struct RingBlock {
    let app: String
    let start: Date
    var end: Date
    let f0: Int
    var f1: Int
    let title: String
    let url: String?
}

struct RingSpan {
    let start: Date
    let end: Date
    var count: Int = 0
}

struct AppTotal {
    let app: String
    var secs: TimeInterval
    var longest: Int   // index into blocks
}

/// 一段 = 同一 app 连续、相邻帧间隔 ≤ 3 分钟;段尾 = 下一帧时间,间隔 > 3 分钟
/// 时只延 10 秒。EventSession 的 session 也按这个切。
struct DayModel {
    var blocks: [RingBlock] = []
    var gaps: [RingSpan] = []
    var totals: [AppTotal] = []
    var audio: [RingSpan] = []
    var captured: TimeInterval = 0

    init() {}

    init(frames: [TimelineFrame], moments: [Date]) {
        for (i, f) in frames.enumerated() {
            let gapPrev = i > 0 ? f.timestamp.timeIntervalSince(frames[i - 1].timestamp) : .infinity
            if blocks.isEmpty || f.appName != blocks[blocks.count - 1].app || gapPrev > 180 {
                blocks.append(RingBlock(app: f.appName, start: f.timestamp, end: f.timestamp,
                                        f0: i, f1: i + 1, title: f.windowName, url: f.browserUrl))
            }
            var end = f.timestamp.addingTimeInterval(10)
            if i + 1 < frames.count, frames[i + 1].timestamp.timeIntervalSince(f.timestamp) <= 180 {
                end = frames[i + 1].timestamp
            }
            blocks[blocks.count - 1].end = end
            blocks[blocks.count - 1].f1 = i + 1
        }
        for i in blocks.indices.dropFirst() where blocks[i].start.timeIntervalSince(blocks[i - 1].end) > 180 {
            gaps.append(RingSpan(start: blocks[i - 1].end, end: blocks[i].start))
        }
        var byApp: [String: AppTotal] = [:]
        for (i, b) in blocks.enumerated() {
            let d = b.end.timeIntervalSince(b.start)
            captured += d
            var t = byApp[b.app] ?? AppTotal(app: b.app, secs: 0, longest: i)
            t.secs += d
            let cur = blocks[t.longest]
            if d > cur.end.timeIntervalSince(cur.start) { t.longest = i }
            byApp[b.app] = t
        }
        totals = byApp.values.sorted { $0.secs > $1.secs }
        // 声音细圈:相邻转录 ≤ 90 秒并成一段,段尾 = 最后一条 + 30 秒
        var first: Date? = nil, last: Date? = nil, n = 0
        for m in moments.sorted() {
            if let l = last, m.timeIntervalSince(l) <= 90 { last = m; n += 1; continue }
            if let f0 = first, let l = last { audio.append(RingSpan(start: f0, end: l.addingTimeInterval(30), count: n)) }
            first = m; last = m; n = 1
        }
        if let f0 = first, let l = last { audio.append(RingSpan(start: f0, end: l.addingTimeInterval(30), count: n)) }
    }

    /// 帧 i 所在的 block(blocks 按 f0 升序)。
    func blockIndex(ofFrame i: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if i < blocks[mid].f0 { hi = mid - 1 } else if i >= blocks[mid].f1 { lo = mid + 1 } else { return mid }
        }
        return nil
    }
}

enum Fmt {
    private static func make(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = f; return d
    }
    private static let hmF = make("HH:mm"), hmsF = make("HH:mm:ss")
    private static let dayF = make("EEE, MMM d"), mdF = make("MMM d")
    static func hm(_ d: Date) -> String { hmF.string(from: d) }
    static func hms(_ d: Date) -> String { hmsF.string(from: d) }
    static func dayLabel(_ d: Date) -> String { dayF.string(from: d) }
    static func monthDay(_ d: Date) -> String { mdF.string(from: d) }
    /// 不到一分钟写秒数(session 常常不到一分钟)。
    static func dur(_ s: TimeInterval) -> String {
        if s < 60 { return "\(max(1, Int(s.rounded())))s" }
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(m)m" : "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
    static func displayURL(_ url: String) -> String {
        if let r = url.range(of: "://") { return String(url[r.upperBound...]) }
        return url
    }
}

/// 一帧的截图:JPG / MP4 抽帧 / 没有像素时的占位。
private struct FrameShot: View {
    let frame: TimelineFrame
    let contentMode: ContentMode
    /// 解码尺寸(pt),见 TimelineView.shotPx。
    let pt: CGFloat
    /// 解码前等 30ms(连拨时一闪而过的帧不解);有预览时至少等 50ms,见
    /// AsyncDiskThumbnail.previewSettle。
    private let delay: Duration = .milliseconds(30)
    var body: some View {
        // Color.clear 严格取槽位尺寸,图 overlay 上去 —— 直接放 fill 的图会上报
        // 超过槽位的布局尺寸。
        Color.clear.overlay {
            if !frame.hasViewableMedia {
                NoMediaPlaceholder()
            } else if let path = frame.snapshotPath {
                AsyncDiskThumbnail(path: path, targetPixelSize: pt, contentMode: contentMode,
                                   decodeDelay: delay, previewKey: ImageThumbnailCache.previewKey(frame))
            } else if let vpath = frame.videoPath {
                AsyncMP4FrameThumbnail(videoPath: vpath, offsetMs: frame.videoOffsetMs,
                                       fps: frame.videoFps, targetPixelSize: pt,
                                       contentMode: contentMode, decodeDelay: delay,
                                       previewKey: ImageThumbnailCache.previewKey(frame))
            }
        }
        .clipped()
    }
}

// =============================================================================
// MARK: - Corners around the circle
// =============================================================================

/// 圆四周四个角。位置钉死:上排两个标题在一条线上,下排两个标题在圆心水平线
/// 下方 24pt;左列左对齐、右列右对齐。折叠状态只随用户操作变,换帧不动。
/// 四个角面板的字号系数:面板收窄给圆让位,字跟着小一号;窗口小于
/// 1600×960 时再乘 panelScale(见 PanelScale)。
private let panelFontBase: CGFloat = 0.88

private struct TimelineCorners: View {
    @Environment(\.panelScale) private var panelScale
    private var panelFont: CGFloat { panelFontBase * panelScale }
    let g: RingGeo
    let pal: RingPalette
    let model: DayModel
    let focusIndex: Int
    let focusTime: Date
    let dayTitle: String
    /// 聚焦视图里只收起 Today,另外三个角照常显示、照常跟焦点更新。
    let hideToday: Bool
    let apps: [ActiveAppEntry]
    let audio: [AudioTranscriptEntry]
    let audioMoments: [Date]
    @Binding var hotApp: String?
    let jumpToFrame: (Int) -> Void
    let jumpToTime: (Date) -> Void

    @State private var appsOpen = false
    @State private var todayOpen = false
    @State private var appHeights: [String: CGFloat] = [:]
    @State private var esCardH: CGFloat = 96
    @State private var audioContentH: CGFloat = 0
    @State private var audioScrollToken = 0
    @State private var audioScrollAnimated = false

    private let top: CGFloat = 60, hd: CGFloat = 24, foldH: CGFloat = 34, gap: CGFloat = 8
    private let todayRowH: CGFloat = 26
    private var H: CGFloat { g.size.height }
    private var leftX: CGFloat { RingGeo.edge }
    private var rightX: CGFloat { g.size.width - RingGeo.edge - g.sideW }
    /// 聚焦视图里三个面板各占一块按窗口比例钉死的区域(Today 收起),放不下就在
    /// 区域里滚:Active Apps 左列 0.07H–0.49H,Audio 左列 0.50H–0.80H,左列右沿
    /// 0.21W;Event Session 右列 0.785W 起、0.06H 起往下到 0.75H(卡片在顶上)。
    /// 位置 / 宽高跟着同一个 spring 过去。
    private var leftW: CGFloat { hideToday ? g.size.width * RingGeo.focusLeftR - leftX : g.sideW }
    /// 标题行不高过页面切换栏底下(y 48)。
    private var appsTop: CGFloat { hideToday ? max(48, H * 0.07) : top }
    private var esX: CGFloat { hideToday ? g.size.width * RingGeo.focusRightL : rightX }
    private var esTop: CGFloat { hideToday ? H * 0.06 : top }
    private var esW: CGFloat { hideToday ? g.size.width * (1 - RingGeo.focusRightL) - RingGeo.edge : g.sideW }
    private var bottomRow: CGFloat { g.c.y + 24 }
    private let anim = Animation.easeInOut(duration: 0.3)

    private struct Fold {
        var listH: CGFloat
        var label: String?
        var scroll: Bool
        var bottom: CGFloat
    }

    private func stack(_ hs: [CGFloat]) -> CGFloat {
        hs.isEmpty ? 0 : hs.reduce(0, +) + gap * CGFloat(hs.count - 1)
    }

    /// Active Apps:收起时不越过圆心水平线,放不下的最后一行写 “+N more”;
    /// 展开时给下面的 Audio 至少留 170pt,自己再超出就组内滚。
    private var appsFold: Fold {
        let listTop = appsTop + hd
        let hs = apps.map { appHeights[$0.id] ?? 56 }
        if hideToday {
            let lh = max(0, min(stack(hs), H * 0.49 - listTop))
            return Fold(listH: lh, label: nil, scroll: true, bottom: listTop + lh)
        }
        if appsOpen {
            let lh = max(0, min(stack(hs), H - 20 - 170 - listTop - gap - foldH))
            return Fold(listH: lh, label: "Show less", scroll: true, bottom: listTop + lh + gap + foldH)
        }
        let limit = g.c.y - 8
        if listTop + stack(hs) <= limit {
            return Fold(listH: stack(hs), label: nil, scroll: false, bottom: listTop + stack(hs))
        }
        var n = hs.count
        while n > 0, listTop + stack(Array(hs.prefix(n))) + gap + foldH > limit { n -= 1 }
        let lh = stack(Array(hs.prefix(n)))
        return Fold(listH: lh, label: "+\(hs.count - n) more", scroll: false, bottom: listTop + lh + gap + foldH)
    }

    /// Today:默认跟在 EventSession 下面,放得下几行显示几行;展开时往上长,
    /// 最多长到 EventSession 卡片下面,再放不下就在框里滚。
    private var todayLayout: (top: CGFloat, fold: Fold) {
        let n = model.totals.count
        func st(_ k: Int) -> CGFloat { k == 0 ? 0 : CGFloat(k) * todayRowH + gap * CGFloat(k - 1) }
        let esBottom = top + hd + 2 + esCardH
        var tTop = max(bottomRow, esBottom + 24)
        if todayOpen {
            let need = hd + st(n) + gap + foldH
            tTop = min(tTop, max(esBottom + 24, H - 20 - need))
            let listTop = tTop + hd
            let lh = max(0, min(st(n), H - 20 - foldH - gap - listTop))
            return (tTop, Fold(listH: lh, label: "Show less", scroll: true, bottom: listTop + lh + gap + foldH))
        }
        let listTop = tTop + hd
        if listTop + st(n) <= H - 20 {
            return (tTop, Fold(listH: st(n), label: nil, scroll: false, bottom: listTop + st(n)))
        }
        var k = n
        while k > 0, listTop + st(k) + gap + foldH > H - 20 { k -= 1 }
        return (tTop, Fold(listH: st(k), label: "+\(n - k) more apps", scroll: false,
                           bottom: listTop + st(k) + gap + foldH))
    }

    /// 当前那条转录:离焦点 8 秒内的(高亮);没有就取时间上最近的。
    private var nearAudioID: String? {
        audio.filter { abs($0.timestamp.timeIntervalSince(focusTime)) < 8 }
            .min { abs($0.timestamp.timeIntervalSince(focusTime)) < abs($1.timestamp.timeIntervalSince(focusTime)) }?.id
    }
    private var currentAudioID: String? {
        nearAudioID ?? audio.min {
            abs($0.timestamp.timeIntervalSince(focusTime)) < abs($1.timestamp.timeIntervalSince(focusTime))
        }?.id
    }

    var body: some View {
        let af = appsFold
        let audioTop = hideToday ? H * 0.50 : max(bottomRow, af.bottom + 24)
        let audioAvail = max(40, (hideToday ? H * 0.80 : H - 20) - (audioTop + hd))
        let audioH = audioContentH > 0 ? min(audioContentH, audioAvail) : audioAvail
        let tl = todayLayout
        let w = g.sideW, lw = leftW
        ZStack(alignment: .topLeading) {
            // ── Active Apps ──
            SectionTitle(pal: pal, title: "ACTIVE APPS", count: "\(apps.count)", action: reset)
                .place(leftX, appsTop, lw)
            SideScroll(height: af.listH, enabled: af.scroll, pal: pal) {
                ForEach(apps) { a in
                    appRow(a)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { appHeights[a.id] = $0 }
                }
            }
            .place(leftX, appsTop + hd, lw)
            if let l = af.label {
                FoldRow(pal: pal, label: l, open: appsOpen) {
                    withAnimation(anim) { appsOpen.toggle() }
                    scrollAudio(animated: true, after: 0.32)
                }
                .place(leftX, appsTop + hd + af.listH + gap, lw)
            }

            // ── Audio ──
            SectionTitle(pal: pal, title: "AUDIO", count: "\(audio.count)", action: reset)
                .place(leftX, audioTop, lw)
            SideScroll(height: audioH, enabled: true, pal: pal, contentHeight: $audioContentH,
                       target: currentAudioID, token: audioScrollToken, animated: audioScrollAnimated) {
                if audio.isEmpty {
                    audioPlaceholder
                } else {
                    ForEach(audio) { e in audioRow(e, near: e.id == nearAudioID).id(e.id) }
                }
            }
            .place(leftX, audioTop + hd, lw)

            // ── Event Session ──
            eventSession.place(esX, esTop, esW)

            // ── Today ──
            ZStack(alignment: .topLeading) {
                SectionTitle(pal: pal, title: dayTitle, count: "\(Fmt.dur(model.captured)) captured", action: reset)
                    .place(rightX, tl.top, w)
                SideScroll(height: tl.fold.listH, enabled: tl.fold.scroll, pal: pal) {
                    ForEach(Array(model.totals.enumerated()), id: \.element.app) { _, t in todayRow(t) }
                }
                .place(rightX, tl.top + hd, w)
                if let l = tl.fold.label {
                    FoldRow(pal: pal, label: l, open: todayOpen) { withAnimation(anim) { todayOpen.toggle() } }
                        .place(rightX, tl.top + hd + tl.fold.listH + gap, w)
                }
            }
            .compositingGroup()
            .opacity(hideToday ? 0 : 1)
            .allowsHitTesting(!hideToday)
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .onChange(of: audio) { scrollAudio(animated: false, after: 0) }
        .onAppear { scrollAudio(animated: false, after: 0.05) }
    }

    private func scrollAudio(animated: Bool, after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            audioScrollAnimated = animated
            audioScrollToken &+= 1
        }
    }

    /// 点四个角任意一个标题:所有展开收回,Audio 平滑转回当前这条。
    private func reset() {
        withAnimation(anim) { appsOpen = false; todayOpen = false }
        scrollAudio(animated: true, after: 0.05)
    }

    // MARK: Rows

    private func appRow(_ a: ActiveAppEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RealAppIcon(appName: a.appName, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.appName.isEmpty ? "(unknown app)" : a.appName)
                    .font(.system(size: 14.5 * panelFont, weight: .semibold)).foregroundStyle(pal.fg)
                if !a.windowName.isEmpty {
                    Text(a.windowName).font(.system(size: 13 * panelFont)).foregroundStyle(pal.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let u = a.browserUrl, !u.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 10 * panelFont))
                        Text(Fmt.displayURL(u)).font(.system(size: 12 * panelFont, design: .monospaced))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .foregroundStyle(pal.faint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(pal.row))
    }

    private func speaker(_ e: AudioTranscriptEntry) -> String {
        if let n = e.speakerName, !n.isEmpty { return n }
        if let id = e.speakerId { return "Speaker \(id)" }
        return e.device.isEmpty ? "Audio" : e.device
    }

    private func audioRow(_ e: AudioTranscriptEntry, near: Bool) -> some View {
        AudioRowView(pal: pal, time: Fmt.hms(e.timestamp), speaker: speaker(e),
                     isInput: e.isInput, text: e.text, near: near) {
            // 点一条转录:跳到那个时刻;Active Apps 展开着就先收回(动画走完再跳)
            if appsOpen {
                withAnimation(anim) { appsOpen = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { jumpToTime(e.timestamp) }
            } else {
                jumpToTime(e.timestamp)
            }
        }
    }

    private var audioPlaceholder: some View {
        let prev = audioMoments.last { $0 < focusTime }
        let next = audioMoments.first { $0 > focusTime }
        return VStack(alignment: .leading, spacing: 2) {
            Text("No audio around this moment.")
            if let p = prev { jumpLink("Previous: ", p) }
            if let n = next { jumpLink("Next: ", n) }
        }
        .font(.system(size: 14 * panelFont))
        .foregroundStyle(pal.faint)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(pal.row))
    }

    private func jumpLink(_ label: String, _ t: Date) -> some View {
        HStack(spacing: 0) {
            Text(label)
            Button(Fmt.hm(t)) { jumpToTime(t) }.buttonStyle(.plain).foregroundStyle(pal.accent)
        }
    }

    private var eventSession: some View {
        let n = model.blocks.count
        let si = model.blockIndex(ofFrame: focusIndex) ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            SectionTitle(pal: pal, title: "EVENT SESSION", count: nil, action: reset) {
                HStack(spacing: 2) {
                    navButton("chevron.left", enabled: si > 0) { jumpToFrame(model.blocks[si - 1].f0) }
                    Text("\(n == 0 ? 0 : si + 1) / \(n)").font(.system(size: 12 * panelFont, design: .monospaced))
                    navButton("chevron.right", enabled: si + 1 < n) { jumpToFrame(model.blocks[si + 1].f0) }
                }
            }
            if model.blocks.indices.contains(si) {
                let b = model.blocks[si]
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RealAppIcon(appName: b.app, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.app.isEmpty ? "(unknown app)" : b.app)
                                .font(.system(size: 16 * panelFont, weight: .semibold)).foregroundStyle(pal.fg)
                                .lineLimit(1)
                            Text("\(Fmt.hms(b.start)) – \(Fmt.hms(b.end)) · \(Fmt.dur(b.end.timeIntervalSince(b.start)))")
                                .font(.system(size: 12.5 * panelFont, design: .monospaced)).foregroundStyle(pal.faint)
                                .lineLimit(1)
                        }
                    }
                    Text("Not summarized yet.")
                        .font(.system(size: 14 * panelFont)).foregroundStyle(pal.muted)
                        .padding(.top, 10)
                }
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 14, trailing: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(pal.row))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(pal.rowb, lineWidth: 1))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { esCardH = $0 }
            }
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12 * panelFont, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.muted)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }

    private func todayRow(_ t: AppTotal) -> some View {
        let color = TimelineBarColor.barColor(for: t.app)
        let frac = CGFloat(t.secs / max(1, model.totals.first?.secs ?? 1))
        return HStack(spacing: 9) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(t.app.isEmpty ? "(unknown app)" : t.app).font(.system(size: 14 * panelFont)).foregroundStyle(pal.fg)
                .lineLimit(1).frame(width: 108, alignment: .leading)
            Capsule().fill(pal.track).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { p in Capsule().fill(color).frame(width: p.size.width * frac) }
                }
            Text(Fmt.dur(t.secs)).font(.system(size: 12.5 * panelFont, design: .monospaced)).foregroundStyle(pal.muted)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: todayRowH)
        .background(Capsule().fill(hotApp == t.app ? pal.pill : .clear))
        .contentShape(Capsule())
        .onHover { on in
            if on { hotApp = t.app } else if hotApp == t.app { hotApp = nil }
        }
        .onTapGesture { jumpToFrame(model.blocks[t.longest].f0) }
    }
}

private extension View {
    func place(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> some View {
        frame(width: w, alignment: .topLeading).offset(x: x, y: y)
    }
}

/// 角上的标题:不跟列表一起滚;点一下四个角都恢复原样。
private struct SectionTitle<Trailing: View>: View {
    @Environment(\.panelScale) private var panelScale
    private var panelFont: CGFloat { panelFontBase * panelScale }
    let pal: RingPalette
    let title: String
    let count: String?
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).font(.system(size: 12 * panelFont, weight: .semibold)).kerning(0.96)
            if let count { Text(count).font(.system(size: 12 * panelFont, design: .monospaced)) }
            Spacer(minLength: 0)
            trailing()
        }
        .foregroundStyle(hovering ? pal.fg : pal.faint)
        .padding(.horizontal, 4)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(pal: RingPalette, title: String, count: String?, action: @escaping () -> Void) {
        self.init(pal: pal, title: title, count: count, action: action) { EmptyView() }
    }
}

/// “+N more / Show less” 那一行:单独一层,固定在列表下面,不跟着滚、不被渐隐压暗。
private struct FoldRow: View {
    @Environment(\.panelScale) private var panelScale
    private var panelFont: CGFloat { panelFontBase * panelScale }
    let pal: RingPalette
    let label: String
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(.system(size: 14 * panelFont, weight: open ? .semibold : .regular))
            .foregroundStyle(open ? pal.accent : (hovering ? pal.fg : pal.muted))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(open || hovering ? pal.accentbg : pal.row))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(open || hovering ? pal.accentb : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

private struct AudioRowView: View {
    @Environment(\.panelScale) private var panelScale
    private var panelFont: CGFloat { panelFontBase * panelScale }
    let pal: RingPalette
    let time: String
    let speaker: String
    let isInput: Bool
    let text: String
    let near: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(time).font(.system(size: 11.5 * panelFont, design: .monospaced)).foregroundStyle(pal.faint)
                Text(speaker).font(.system(size: 12.5 * panelFont, weight: .semibold)).foregroundStyle(pal.muted)
                Image(systemName: isInput ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9 * panelFont)).foregroundStyle(pal.faint)
            }
            Text(text)
                .font(.system(size: 14 * panelFont)).lineSpacing(3)
                .foregroundStyle(near ? pal.fg : pal.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(near || hovering ? pal.accentbg : pal.row))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(near || hovering ? pal.accentb : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// 角上的滚动列表:没有滚动条;上/下还有内容时露出 ▲/▼(点一下翻约 70%),
/// 并只在那个方向加渐隐。
struct SideScroll<Content: View>: View {
    let height: CGFloat
    let enabled: Bool
    let pal: RingPalette
    var contentHeight: Binding<CGFloat>? = nil
    var target: String? = nil
    var token: Int = 0
    var animated: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var pos = ScrollPosition(edge: .top)
    @State private var metrics = Metrics()

    private struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
    }

    private var canUp: Bool { enabled && metrics.offset > 2 }
    private var canDn: Bool { enabled && metrics.offset + metrics.container < metrics.content - 2 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollDisabled(!enabled)
            .scrollPosition($pos)
            .onScrollGeometryChange(for: Metrics.self) { s in
                Metrics(offset: s.contentOffset.y, content: s.contentSize.height, container: s.containerSize.height)
            } action: { _, m in
                metrics = m
                if let b = contentHeight, abs(b.wrappedValue - m.content) > 0.5 { b.wrappedValue = m.content }
            }
            .frame(height: max(0, height))
            .mask(fadeMask)
            .overlay(alignment: .top) { arrow(up: true).opacity(canUp ? 1 : 0).offset(y: -2) }
            .overlay(alignment: .bottom) { arrow(up: false).opacity(canDn ? 1 : 0).offset(y: 2) }
            .onChange(of: token) {
                guard let target else { return }
                if animated {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
                } else {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: enabled) { if !enabled { pos.scrollTo(edge: .top) } }
        }
    }

    private var fadeMask: LinearGradient {
        let h = max(1, height)
        var stops: [Gradient.Stop] = canUp
            ? [.init(color: .clear, location: 0), .init(color: .black, location: min(0.4, 16 / h))]
            : [.init(color: .black, location: 0)]
        stops += canDn
            ? [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)]
            : [.init(color: .black, location: 1)]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    private func arrow(up: Bool) -> some View {
        ArrowButton(pal: pal, up: up) {
            let step = metrics.container * 0.7
            let y = up ? max(0, metrics.offset - step)
                       : min(max(0, metrics.content - metrics.container), metrics.offset + step)
            withAnimation(.easeInOut(duration: 0.3)) { pos.scrollTo(y: y) }
        }
        .allowsHitTesting(up ? canUp : canDn)
    }
}

struct ArrowButton: View {
    let pal: RingPalette
    let up: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Triangle(up: up)
            .fill(hovering ? pal.fg : pal.muted)
            .frame(width: 12, height: 7)
            .frame(width: 24, height: 14)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}
