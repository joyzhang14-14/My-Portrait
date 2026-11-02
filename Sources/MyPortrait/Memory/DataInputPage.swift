import SwiftUI

/// Data 页的 Input(圆形版):中间是当天 0–24 点的圆,外圈是打字的 app 段,
/// 圆里是每分钟击键的面积图(按 app 分色堆叠),圆心是当天总击键。
///   左下  当天统计(击键 / 点击 / 打字时长 / 峰值)   右上  搜索 + 一段的全文
///   右下  当天各 app 击键
/// 左上的导航由 DataPage 画。
struct DataInputPage: View {
    let size: CGSize
    let sideW: CGFloat
    let leftX: CGFloat
    let rightPad: CGFloat
    let listTop: CGFloat
    let rightTopY: CGFloat
    let pal: RingPalette
    let fs: (CGFloat) -> CGFloat

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var buckets = MinuteBuckets.empty
    @State private var segments: [InputSegment] = []
    @State private var selectedId: Int64? = nil
    @State private var query = ""
    @State private var loading = false
    @State private var clicks = 0
    @State private var calendarOpen = false
    /// 选中的 app(右下 TODAY 点一行 / 点外圈一段):外圈和面积图里只亮它。
    @State private var selectedApp: String? = nil

    /// 选中那段全文的实际高度(右上卡片按它伸缩,不留大片空白)。
    @State private var textH: CGFloat = 0

    // 动态高度:底部两块(STATS / TODAY)按 app 行数往上长,最多长到给右上卡片留 140;
    // 右上卡片按内容长,内容多时往下压底部两块(它们变矮、列表滚动),底部两块至少留 200
    private var appCount: Int { Set(segments.map(\.app)).count }
    private var bottomH: CGFloat {
        let maxH = H - 22 - (rightTopY + 44 + 140 + 16)
        return max(200, min(maxH, 34 + CGFloat(appCount) * 28))
    }
    private var cardH: CGFloat {
        let avail = H - 22 - min(bottomH, 200) - 16 - (rightTopY + 44)
        let need: CGFloat
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            need = 32 + 34 + CGFloat(shown.count) * 30
        } else if current != nil {
            need = 32 + 78 + textH
        } else {
            need = 70
        }
        return max(110, min(avail, need))
    }

    /// 底部两块的实际高度:被右上卡片压过之后剩下的部分。
    private var lowH: CGFloat { min(bottomH, H - 22 - 16 - (rightTopY + 44 + cardH)) }

    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }
    private var c: CGPoint { CGPoint(x: W / 2, y: H / 2) }
    /// 外圈半径:撑满窗口高度,两侧留给面板。
    private var R: CGFloat { max(160, min(H / 2 - 70, W / 2 - leftX - sideW - 30)) }
    private var r0: CGFloat { R * 0.43 }
    private var r1: CGFloat { R - R * 0.19 }

    private var shown: [InputSegment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? segments : segments.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
    /// 可选的段:TODAY 里选了 app 就只在这个 app 的段里选,否则全部 app。
    private var pool: [InputSegment] {
        guard let a = selectedApp else { return segments }
        return segments.filter { $0.app == a }
    }
    /// 选中的是一整段连续打字:前后停顿不到 3 分钟的段都算一段时间,
    /// 卡片里把这段时间的输入逐段列出来(没选 app = 所有 app,选了 = 只那个 app)。
    private var current: InputSegment? {
        let groups = segmentGroups
        let g = groups.first { $0.contains { $0.id == selectedId } } ?? groups.last
        guard let g, let first = g.first, let last = g.last else { return nil }
        if g.count == 1 { return first }
        return InputSegment(id: first.id, app: first.app, startMs: first.startMs,
                            endMs: g.map(\.endMs).max() ?? last.endMs,
                            text: g.map(\.text).joined(separator: "\n"),
                            keys: g.reduce(0) { $0 + $1.keys })
    }

    /// 段按连续打字分组(离这组最晚结束时刻不到 3 分钟就并进来)。
    private var segmentGroups: [[InputSegment]] {
        var out: [[InputSegment]] = []
        var groupEnd: Int64 = .min
        for s in pool.sorted(by: { $0.startMs < $1.startMs }) {
            if !out.isEmpty, s.startMs - groupEnd < 180_000 {
                out[out.count - 1].append(s)
                groupEnd = max(groupEnd, s.endMs)
            } else {
                out.append([s])
                groupEnd = s.endMs
            }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ring
            centerText.position(c)
            // 换天的药丸和 Timeline 一样放在圆里靠上
            datePill.position(x: c.x, y: c.y - R + 62)

            statTiles
                .frame(width: sideW, height: lowH, alignment: .topLeading)
                .offset(x: leftX, y: H - 22 - lowH)
                .animation(.spring(duration: 0.3, bounce: 0.1), value: cardH)
            rightTop
                .frame(width: sideW, height: 44 + cardH)
                .offset(x: W - rightPad - sideW, y: rightTopY)
                .animation(.spring(duration: 0.3, bounce: 0.1), value: cardH)
            appBars
                .frame(width: sideW, height: lowH)
                .offset(x: W - rightPad - sideW, y: H - 22 - lowH)
                .animation(.spring(duration: 0.3, bounce: 0.1), value: cardH)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .task(id: day) { await reload() }
    }

    // MARK: 圆

    private func pt(_ r: CGFloat, _ minute: Double) -> CGPoint {
        let a = minute / 1440 * 2 * .pi
        return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
    }

    private func color(_ bundle: String) -> Color { AppColor.color(for: InputCaptureView.appLabel(bundle)) }

    private var ring: some View {
        let b = buckets, cur = current, selected = selectedId != nil
        let blocks = self.blocks, hotApp = selectedApp
        let g = RingGeo(size: size)
        return Canvas { ctx, _ in
            // 底圈 + 整点小圆点
            ctx.stroke(Path { p in p.addArc(center: c, radius: R, startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                       with: .color(pal.track), lineWidth: 18)
            for h in 0..<24 {
                let major = h % 3 == 0
                let p = pt(R + 23, Double(h * 60)), rr: CGFloat = major ? 2.6 : 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)),
                         with: .color(pal.tick.opacity(major ? 1 : 0.6)))
                if major {
                    ctx.draw(Text(String(format: "%02d", h)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pal.muted), at: pt(R + 42, Double(h * 60)))
                }
            }
            // 外圈:同 Timeline 的 app 圈 —— 连续同一个 app 并成一段圆角环形块,
            // 块间留 2.4pt 缝;选中 app 的块变粗,其余变淡
            let day0 = Int64(day.timeIntervalSince1970 * 1000)
            let gapDeg = 2.4 / Double(R) * 180 / .pi
            for bl in blocks {
                let hot = bl.app == hotApp
                let a0 = bl.m0 / 4 + gapDeg / 2
                let a1 = max(a0 + 0.25, bl.m1 / 4 - gapDeg / 2)
                let grow: CGFloat = hot ? 4 : 0
                let path = RingPaths.roundSeg(g, R - 9 - grow, R + 9 + grow, a0, a1, 9 + grow)
                ctx.fill(path, with: .color(color(bl.app).opacity(hotApp != nil && !hot ? 0.3 : 1)))
            }
            // 面积图:按 app 堆叠
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r0, y: c.y - r0, width: r0 * 2, height: r0 * 2)),
                       with: .color(pal.track), lineWidth: 1)
            if b.maxTotal > 0 {
                var base = Array(repeating: 0.0, count: 1440)
                for ai in b.apps.indices.reversed() {
                    var top = base
                    for m in 0..<1440 { top[m] += b.counts[m][ai] }
                    var p = Path()
                    for m in stride(from: 0, to: 1440, by: 2) {
                        let q = pt(r0 + CGFloat(top[m] / b.maxTotal) * (r1 - r0), Double(m))
                        m == 0 ? p.move(to: q) : p.addLine(to: q)
                    }
                    for m in stride(from: 1438, through: 0, by: -2) {
                        p.addLine(to: pt(r0 + CGFloat(base[m] / b.maxTotal) * (r1 - r0), Double(m)))
                    }
                    p.closeSubpath()
                    let dim = hotApp != nil && b.apps[ai] != hotApp
                    ctx.fill(p, with: .color(color(b.apps[ai]).opacity(dim ? 0.15 : 0.8)))
                    base = top
                }
            }
            // 选中的那段:内圈标出时间
            if selected, let s = cur {
                let m0 = Double(s.startMs - day0) / 60_000, m1 = max(m0 + 2, Double(s.endMs - day0) / 60_000)
                let path = Path { p in
                    p.addArc(center: c, radius: r0 - 10, startAngle: .degrees(m0 / 4 - 90), endAngle: .degrees(m1 / 4 - 90), clockwise: false)
                }
                ctx.stroke(path, with: .color(pal.accent), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            }
        }
        .frame(width: W, height: H)
        .contentShape(Circle().path(in: CGRect(x: c.x - R - 10, y: c.y - R - 10, width: R * 2 + 20, height: R * 2 + 20)))
        .onTapGesture(coordinateSpace: .local) { p in
            // 点圆里任意一处 → 选离那个时刻最近的一段
            var a = atan2(Double(p.x - c.x), Double(c.y - p.y))
            if a < 0 { a += 2 * .pi }
            let ms = Int64(day.timeIntervalSince1970 * 1000) + Int64(a / (2 * .pi) * 86_400_000)
            let hit = pool.min { dist($0, ms) < dist($1, ms) }
            selectedId = hit?.id
        }
    }

    /// 外圈的块:连续(间隔 < 3 分钟)同一个 app 的段并成一块,单位分钟。
    private var blocks: [(app: String, m0: Double, m1: Double)] {
        let day0 = Int64(day.timeIntervalSince1970 * 1000)
        var out: [(app: String, m0: Double, m1: Double)] = []
        for s in segments {
            let m0 = Double(s.startMs - day0) / 60_000, m1 = Double(s.endMs - day0) / 60_000 + 0.5
            if let last = out.last, last.app == s.app, m0 - last.m1 < 3 {
                out[out.count - 1].m1 = max(last.m1, m1)
            } else {
                out.append((s.app, m0, m1))
            }
        }
        return out
    }

    private func dist(_ s: InputSegment, _ ms: Int64) -> Int64 {
        ms < s.startMs ? s.startMs - ms : ms > s.endMs ? ms - s.endMs : 0
    }

    private var totalKeys: Int { segments.reduce(0) { $0 + $1.keys } }

    private var centerText: some View {
        VStack(spacing: 2) {
            if loading && segments.isEmpty {
                ProgressView().controlSize(.small)
            } else if segments.isEmpty {
                Text("No typing this day").font(.system(size: fs(15))).foregroundStyle(pal.muted)
            } else {
                Text(totalKeys.formatted()).font(.system(size: 40, weight: .bold)).foregroundStyle(pal.fg)
                Text("keystrokes").font(.system(size: fs(14))).foregroundStyle(pal.muted)
                Text("\(Self.hm(segments.first!.startMs)) – \(Self.hm(segments.last!.endMs)) active")
                    .font(.system(size: fs(12.5), design: .monospaced)).foregroundStyle(pal.faint)
            }
        }
        .allowsHitTesting(false)
    }

    private var datePill: some View {
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
            // 点日期弹出和 Timeline 同一个日历,直接选某天
            Button { calendarOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 13))
                    Text(Self.dayFmt.string(from: day)).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(pal.fg).padding(.horizontal, 8)
            }
            .popover(isPresented: $calendarOpen, arrowEdge: .bottom) {
                CalendarPopover(selected: Binding(get: { day }, set: { d in
                    day = Calendar.current.startOfDay(for: d); selectedId = nil
                }), isPresented: $calendarOpen)
            }
            Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday).opacity(isToday ? 0.3 : 1)
        }
        .buttonStyle(.plain).foregroundStyle(pal.muted)
        .padding(.horizontal, 12).frame(height: 32)
        .background(Capsule().fill(pal.pill))
        .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
    }

    private func step(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day) { day = n; selectedId = nil; selectedApp = nil }
    }

    // MARK: 角落

    private func title(_ t: String, _ trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.system(size: fs(12), weight: .semibold)).kerning(0.96)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.system(size: fs(12), design: .monospaced)) }
        }
        .foregroundStyle(pal.faint).padding(.horizontal, 4).padding(.bottom, 7)
    }

    private var rightTop: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(pal.faint)
                TextField("Search what you typed", text: $query).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Capsule().fill(pal.pill))
            .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 搜索:列出含这段文字的输入,点一条看全文
                    Text("\(shown.count) result\(shown.count == 1 ? "" : "s")")
                        .font(.system(size: fs(18), weight: .semibold)).foregroundStyle(pal.fg)
                    GeometryReader { g in SideScroll(height: g.size.height, enabled: true, pal: pal) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { s in
                                Button { selectedId = s.id; query = "" } label: {
                                    HStack(spacing: 8) {
                                        Text(Self.hm(s.startMs)).font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
                                        Circle().fill(color(s.app)).frame(width: 8, height: 8)
                                        Text(s.text.split(separator: "\n").first.map(String.init) ?? "")
                                            .font(.system(size: fs(14))).foregroundStyle(pal.fg).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } }
                } else if let s = current {
                    // 选中那块的时间区间里**所有 app** 的输入,一段一张小卡,按时间排
                    let inRange = pool.filter { $0.endMs >= s.startMs && $0.startMs <= s.endMs }
                    Text((selectedId == nil ? "LATEST" : "SELECTED")
                         + (selectedApp.map { " · " + InputCaptureView.appLabel($0).uppercased() } ?? ""))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(pal.faint)
                    Text("\(Self.hm(s.startMs)) – \(Self.hm(s.endMs))")
                        .font(.system(size: fs(18), weight: .semibold)).foregroundStyle(pal.fg)
                    Text("\(inRange.count) segment\(inRange.count == 1 ? "" : "s") · \(inRange.reduce(0) { $0 + $1.keys }) keys")
                        .font(.system(size: fs(12.5), design: .monospaced)).foregroundStyle(pal.muted)
                    GeometryReader { g in SideScroll(height: g.size.height, enabled: true, pal: pal,
                                                     contentHeight: $textH) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(inRange) { seg in
                                HStack(alignment: .top, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 2).fill(color(seg.app)).frame(width: 3)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(InputCaptureView.appLabel(seg.app)).font(.system(size: fs(12.5), weight: .semibold))
                                                .foregroundStyle(pal.muted)
                                            Text("\(Self.hm(seg.startMs)) · \(seg.keys) keys")
                                                .font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
                                        }
                                        Text(seg.text).font(.system(size: fs(14))).foregroundStyle(pal.fg)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(pal.pill))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } }
                } else {
                    Text("Nothing typed on this day.").font(.system(size: fs(14))).foregroundStyle(pal.faint)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(pal.row))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(pal.rowb, lineWidth: 1))
        }
    }

    /// 左下:当天统计,2×2 大数字,细线分隔(标题和右下 TODAY 齐平)。
    private var statTiles: some View {
        let typing = segments.reduce(0) { $0 + max(1, Int(($1.endMs - $1.startMs) / 60_000)) }
        let peak = buckets.rawTotals.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            title("STATS")
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    stat(totalKeys.formatted(), "keystrokes")
                    Rectangle().fill(pal.rowb).frame(width: 1)
                    stat(clicks.formatted(), "clicks")
                }
                Rectangle().fill(pal.rowb).frame(height: 1)
                HStack(spacing: 0) {
                    stat("\(typing / 60)h \(typing % 60)m", "typing time")
                    Rectangle().fill(pal.rowb).frame(width: 1)
                    stat("\(peak)", "peak keys / min")
                }
            }
        }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(v).font(.system(size: 30, weight: .bold)).foregroundStyle(pal.fg)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: fs(13))).foregroundStyle(pal.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    /// 右下:当天各 app 击键。
    private var appBars: some View {
        var byApp: [String: Int] = [:]
        for s in segments { byApp[s.app, default: 0] += s.keys }
        let rows = byApp.sorted { $0.value > $1.value }
        let mx = max(1, rows.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            title(Calendar.current.isDateInToday(day) ? "TODAY" : Self.dayFmt.string(from: day).uppercased())
            GeometryReader { g in SideScroll(height: g.size.height, enabled: true, pal: pal) {
                VStack(spacing: 4) {
                    ForEach(rows, id: \.key) { app, n in
                        let on = app == selectedApp
                        HStack(spacing: 9) {
                            Circle().fill(color(app)).frame(width: 10, height: 10)
                            Text(InputCaptureView.appLabel(app)).font(.system(size: fs(14))).foregroundStyle(pal.fg)
                                .lineLimit(1).frame(width: 110, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(pal.track)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(color(app)).frame(width: g.size.width * CGFloat(n) / CGFloat(mx))
                                    }
                            }
                            .frame(height: 6)
                            Text(n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)")
                                .font(.system(size: fs(12.5), design: .monospaced)).foregroundStyle(pal.muted)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .frame(height: 24)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? pal.accentbg : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? pal.accentb : .clear, lineWidth: 1))
                        .opacity(selectedApp != nil && !on ? 0.5 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedApp = on ? nil : app
                            // 选中的段不属于新选的 app → 回到这个 app 最近一段
                            if let a = selectedApp, let id = selectedId,
                               segments.first(where: { $0.id == id })?.app != a { selectedId = nil }
                        }
                    }
                }
            } }
        }
    }

    // MARK: 数据

    private func reload() async {
        guard WritingCaptureBrowse.isAvailable else { buckets = .empty; segments = []; return }
        loading = true
        let startMs = Int64(day.timeIntervalSince1970 * 1000)
        let ks = await WritingCaptureBrowse.keystrokes(startMs: startMs, endMs: startMs + 86_400_000, excludeBundleIds: [])
        clicks = await WritingCaptureBrowse.clicks(startMs: startMs, endMs: startMs + 86_400_000)
        let (agg, segs) = await Task.detached(priority: .userInitiated) {
            (MinuteBuckets.aggregate(ks, dayStartMs: startMs), InputSegments.build(ks))
        }.value
        buckets = agg
        segments = segs.sorted { $0.startMs < $1.startMs }
        loading = false
    }

    static func hm(_ ms: Int64) -> String {
        hmFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    nonisolated(unsafe) private static let hmFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d, yyyy"; return f
    }()
}
