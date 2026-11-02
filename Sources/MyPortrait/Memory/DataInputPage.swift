import SwiftUI

/// Data 页的 Input(圆形版):中间是当天 0–24 点的圆,外圈是打字的 app 段,
/// 圆里是每分钟击键的面积图(按 app 分色堆叠),圆心是当天总击键。
///   左下  各 app 击键 + 当天统计   右上  搜索 + 一段的全文   右下  切好段的输入
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
    private var current: InputSegment? {
        segments.first { $0.id == selectedId } ?? segments.last
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ring
            centerText.position(c)
            // 换天的药丸和 Timeline 一样放在圆里靠上
            datePill.position(x: c.x, y: c.y - R + 62)

            dayStats
                .frame(width: sideW, height: max(160, H - 22 - listTop))
                .offset(x: leftX, y: listTop)
            rightTop
                .frame(width: sideW, height: H * 0.5 - rightTopY)
                .offset(x: W - rightPad - sideW, y: rightTopY)
            segmentList
                .frame(width: sideW, height: H * 0.5 - 34)
                .offset(x: W - rightPad - sideW, y: H * 0.5 + 12)
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
        let b = buckets, segs = segments, cur = current, selected = selectedId != nil
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
            // 外圈:每段打字一节,圆头
            let day0 = Int64(day.timeIntervalSince1970 * 1000)
            for s in segs {
                let m0 = Double(s.startMs - day0) / 60_000, m1 = max(m0 + 1.5, Double(s.endMs - day0) / 60_000)
                let path = Path { p in
                    p.addArc(center: c, radius: R, startAngle: .degrees(m0 / 4 - 90), endAngle: .degrees(m1 / 4 - 90), clockwise: false)
                }
                ctx.stroke(path, with: .color(color(s.app)), style: StrokeStyle(lineWidth: 18, lineCap: .round))
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
                    ctx.fill(p, with: .color(color(b.apps[ai]).opacity(0.8)))
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
            selectedId = segments.min { dist($0, ms) < dist($1, ms) }?.id
        }
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
            Text(Self.dayFmt.string(from: day)).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pal.fg).padding(.horizontal, 8)
            Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday).opacity(isToday ? 0.3 : 1)
        }
        .buttonStyle(.plain).foregroundStyle(pal.muted)
        .padding(.horizontal, 12).frame(height: 32)
        .background(Capsule().fill(pal.pill))
        .overlay(Capsule().stroke(pal.pillb, lineWidth: 1))
    }

    private func step(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day) { day = n; selectedId = nil }
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

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("INPUT", "\(shown.count)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { s in
                        let on = s.id == selectedId
                        Button { selectedId = s.id } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 7) {
                                    Text(Self.hm(s.startMs)).font(.system(size: fs(11.5), design: .monospaced)).foregroundStyle(pal.faint)
                                    Circle().fill(color(s.app)).frame(width: 8, height: 8)
                                    Text(InputCaptureView.appLabel(s.app)).font(.system(size: fs(12.5), weight: .semibold))
                                        .foregroundStyle(pal.muted).lineLimit(1)
                                }
                                Text(s.text.split(separator: "\n").first.map(String.init) ?? "")
                                    .font(.system(size: fs(14))).foregroundStyle(pal.fg).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 14).fill(on ? pal.accentbg : pal.row))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? pal.accentb : .clear, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
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
                if let s = current {
                    Text(selectedId == nil ? "LATEST" : "SEGMENT")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(pal.faint)
                    HStack(spacing: 9) {
                        Circle().fill(color(s.app)).frame(width: 12, height: 12)
                        Text(InputCaptureView.appLabel(s.app)).font(.system(size: fs(18), weight: .semibold)).foregroundStyle(pal.fg)
                    }
                    Text("\(Self.hm(s.startMs)) – \(Self.hm(s.endMs))   \(s.keys) keys")
                        .font(.system(size: fs(12.5), design: .monospaced)).foregroundStyle(pal.muted)
                    ScrollView {
                        Text(s.text).font(.system(size: fs(14.5))).foregroundStyle(pal.fg)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
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

    private var dayStats: some View {
        var byApp: [String: Int] = [:]
        for s in segments { byApp[s.app, default: 0] += s.keys }
        let rows = byApp.sorted { $0.value > $1.value }
        let mx = max(1, rows.first?.value ?? 1)
        let typing = segments.reduce(0) { $0 + max(1, Int(($1.endMs - $1.startMs) / 60_000)) }
        let peak = buckets.rawTotals.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            title(Calendar.current.isDateInToday(day) ? "TODAY" : Self.dayFmt.string(from: day).uppercased())
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(rows, id: \.key) { app, n in
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
                    }
                }
            }
            .scrollIndicators(.never)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile(totalKeys.formatted(), "keystrokes")
                tile(clicks.formatted(), "clicks")
                tile("\(typing / 60)h \(typing % 60)m", "typing time")
                tile("\(peak)", "peak keys / min")
            }
            .padding(.top, 8)
        }
    }

    private func tile(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: fs(17), weight: .bold)).foregroundStyle(pal.fg).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: fs(11.5))).foregroundStyle(pal.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12).fill(pal.row))
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
