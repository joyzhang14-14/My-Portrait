import SwiftUI

/// Memory 区 "Input" scope 的**图谱形态**(canvas 模式)。
///
/// 一天一张面积图:x 轴 = 当天**第一次打字到最后一次打字**的时段(动态,不固定
/// 24h),y 轴 = 每分钟总击键数(含退格,不减)。曲线下方阴影按 app 堆叠分色
/// (和 timeline 一致的 `AppColor`);数据做移动平均平滑,曲线更顺。
/// 顶部日期切换栏复用 timeline 的 `TimelineControlsBar`(日历弹窗切天)。
///
/// 数据源:`keystroke_log`(raw 每次击键),按本地某天 [00:00, +24h) 查
/// `WritingCaptureStore.keystrokesInRange`,后台聚合成 1440 个分钟桶后取活动段。
@MainActor
struct InputActivityChartView: View {
    @State private var selectedDay: Date = Date()
    @State private var buckets: MinuteBuckets = .empty
    @State private var loading = false
    /// 代际 token —— 快速切天时慢查询晚归不能盖掉新一天的结果。
    @State private var reloadGen = 0
    @Environment(\.colorScheme) private var colorScheme

    private var store: WritingCaptureStore? { WritingCaptureWorker.shared?.store }

    var body: some View {
        VStack(spacing: 0) {
            TimelineControlsBar(currentDate: $selectedDay, onRefresh: { Task { await reload() } })
                .padding(.top, 40)
                .padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            chartArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task(id: selectedDay) { await reload() }
    }

    @ViewBuilder
    private var chartArea: some View {
        if buckets.maxTotal == 0 {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(loading ? "Loading…" : "No typing on this day")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 图只占可用高度的 1/3,靠上;下方留空。
            GeometryReader { geo in
                InputActivityCanvas(buckets: buckets, colorScheme: colorScheme)
                    .frame(height: geo.size.height / 3)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
            }
        }
    }

    @MainActor
    private func reload() async {
        guard let store else { buckets = .empty; return }
        reloadGen += 1
        let gen = reloadGen
        loading = true
        // 本地当天 [00:00, +24h) —— x 轴天然是本地时间,不用管 DB 的 UTC 切日。
        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        let endMs = startMs + 86_400_000

        let result = await Task.detached(priority: .userInitiated) { () -> MinuteBuckets in
            let ks = (try? store.keystrokesInRange(
                startMs: startMs, endMs: endMs, excludeBundleIds: [])) ?? []
            return MinuteBuckets.aggregate(ks, dayStartMs: startMs)
        }.value

        guard gen == reloadGen else { return }   // 期间切到别的天 → 丢弃
        buckets = result
        loading = false
    }
}

// MARK: - 聚合结果

/// 一天 1440 分钟的击键分桶。堆叠面积图 + 总量曲线都从这里读。
/// counts/totals 已做移动平均平滑(Double);x 轴只画 [firstMinute, lastMinute]
/// 这段有活动的时段(当天第一次打字到最后一次打字)。
struct MinuteBuckets: Sendable {
    /// 堆叠顺序的 app bundle_id(总量小的在底,大的在上 —— 大块在顶更好读)。
    let apps: [String]
    /// counts[minute(0..1439)][appIndex] = 平滑后的该分钟该 app 击键数。
    let counts: [[Double]]
    /// totals[minute] = 平滑后该分钟所有 app 击键总数(= 堆叠顶 = 单色曲线)。
    let totals: [Double]
    let maxTotal: Double
    /// 有活动的分钟范围(x 轴左右端)。无数据时 0/0。
    let firstMinute: Int
    let lastMinute: Int

    static let empty = MinuteBuckets(apps: [], counts: [], totals: [],
                                     maxTotal: 0, firstMinute: 0, lastMinute: 0)

    /// 平滑窗口半径(分钟)。窗口 = 2r+1,边界处自动收缩。轻度即可 —— 视觉
    /// 圆滑交给渲染层的 Catmull-Rom,这里只压噪声、不削峰。
    private static let smoothRadius = 2

    /// 纯函数,后台线程跑。keystroke 已按 ts 升序,但不依赖顺序。
    static func aggregate(_ ks: [KeystrokeEntry], dayStartMs: Int64) -> MinuteBuckets {
        guard !ks.isEmpty else { return .empty }

        // 1) 先统计每 app 全天总量,定堆叠顺序(升序:小的在底)。
        var appTotals: [String: Int] = [:]
        for k in ks { appTotals[k.bundleId, default: 0] += 1 }
        let apps = appTotals.sorted { $0.value < $1.value }.map { $0.key }
        let appIndex = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1, $0) })

        // 2) 逐击键落分钟桶(原始整数)。
        var raw = Array(repeating: Array(repeating: 0, count: apps.count), count: 1440)
        var rawTot = Array(repeating: 0, count: 1440)
        for k in ks {
            let m = Int((k.tsMs - dayStartMs) / 60_000)
            guard m >= 0, m < 1440, let ai = appIndex[k.bundleId] else { continue }
            raw[m][ai] += 1
            rawTot[m] += 1
        }

        // 3) 活动范围 = 第一次/最后一次打字的分钟。
        guard let first = rawTot.firstIndex(where: { $0 > 0 }),
              let last = rawTot.lastIndex(where: { $0 > 0 }) else { return .empty }

        // 4) 移动平均平滑(每 app 列 + 总量;线性运算,各层平滑后仍精确堆叠成总量)。
        var counts = Array(repeating: Array(repeating: 0.0, count: apps.count), count: 1440)
        for ai in apps.indices {
            let col = (0..<1440).map { raw[$0][ai] }
            let sm = movingAverage(col, radius: smoothRadius)
            for m in 0..<1440 { counts[m][ai] = sm[m] }
        }
        let totals = movingAverage(rawTot, radius: smoothRadius)
        let maxTotal = (first...last).map { totals[$0] }.max() ?? 0

        return MinuteBuckets(apps: apps, counts: counts, totals: totals,
                             maxTotal: maxTotal, firstMinute: first, lastMinute: last)
    }

    /// 前缀和 O(n) 滑动平均。边界窗口收缩(不补零,免得两端被压低)。
    private static func movingAverage(_ a: [Int], radius r: Int) -> [Double] {
        let n = a.count
        var prefix = Array(repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + a[i] }
        var out = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            out[i] = Double(prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return out
    }
}

// MARK: - Canvas 渲染

/// 面积图画布。堆叠阴影(按 app AppColor)→ 单色总量曲线 → 时间轴刻度。
/// Canvas 闭包保持精简(只调 draw* helper),避免 Swift 类型检查超时。
private struct InputActivityCanvas: View {
    let buckets: MinuteBuckets
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { ctx, size in
            let plot = plotRect(size)
            drawGrid(ctx, plot: plot)
            drawStackedArea(ctx, plot: plot)
            drawTotalCurve(ctx, plot: plot)
            drawAxis(ctx, plot: plot, size: size)
        }
    }

    // 左留 y 轴数字,底留时间标签。
    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 40, y: 6, width: max(1, size.width - 48), height: max(1, size.height - 26))
    }

    // x 轴范围 = 活动时段 [firstMinute, lastMinute],至少 1 分钟宽避免除零。
    private var span: Double { max(1.0, Double(buckets.lastMinute - buckets.firstMinute)) }

    private func x(_ minute: Int, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat((Double(minute - buckets.firstMinute)) / span) * plot.width
    }
    private func y(_ value: Double, _ plot: CGRect) -> CGFloat {
        let maxV = max(1.0, buckets.maxTotal)
        return plot.maxY - CGFloat(value / maxV) * plot.height
    }

    private var gridColor: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08)
    }
    private var curveColor: Color {
        colorScheme == .light ? Color.black.opacity(0.65) : Color.white.opacity(0.80)
    }

    /// 落在活动范围内的整点小时刻度(跨度小用 1h,大用 2/3h,避免拥挤)。
    private var hourTicks: [Int] {
        let firstH = (buckets.firstMinute + 59) / 60   // ceil
        let lastH = buckets.lastMinute / 60            // floor
        guard lastH >= firstH else { return [] }
        let spanH = lastH - firstH
        let step = spanH <= 6 ? 1 : (spanH <= 14 ? 2 : 3)
        return stride(from: firstH, through: lastH, by: step).map { $0 }
    }

    /// 每整点刻度一条竖线 + y 轴顶横线。
    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect) {
        var p = Path()
        for h in hourTicks {
            let px = x(h * 60, plot)
            p.move(to: CGPoint(x: px, y: plot.minY))
            p.addLine(to: CGPoint(x: px, y: plot.maxY))
        }
        p.move(to: CGPoint(x: plot.minX, y: plot.minY))
        p.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        ctx.stroke(p, with: .color(gridColor), lineWidth: 0.6)
    }

    /// 逐 app 从底往上堆叠:每层 = 上界(累计+本层)Catmull-Rom 平滑上去,再沿
    /// 下界(累计)平滑回来,闭合填 AppColor。上下界共享点集+同一插值公式,层间无缝。
    private func drawStackedArea(_ ctx: GraphicsContext, plot: CGRect) {
        let lo = buckets.firstMinute, hi = buckets.lastMinute
        var cumulative = Array(repeating: 0.0, count: 1440)
        for (ai, bundle) in buckets.apps.enumerated() {
            var upper = Array(repeating: 0.0, count: 1440)
            for m in lo...hi { upper[m] = cumulative[m] + buckets.counts[m][ai] }

            let upperPts = (lo...hi).map { CGPoint(x: x($0, plot), y: y(upper[$0], plot)) }
            let lowerPts = (lo...hi).map { CGPoint(x: x($0, plot), y: y(cumulative[$0], plot)) }

            var path = Path()
            path.move(to: upperPts[0])
            addCatmullRom(&path, upperPts)
            path.addLine(to: lowerPts[lowerPts.count - 1])
            addCatmullRom(&path, Array(lowerPts.reversed()))
            path.closeSubpath()

            let color = AppColor.color(for: InputCaptureView.appLabel(bundle))
            ctx.fill(path, with: .color(color.opacity(0.55)))

            cumulative = upper
        }
    }

    /// 单色曲线 = 每分钟总量顶部轮廓(Catmull-Rom 平滑)。
    private func drawTotalCurve(_ ctx: GraphicsContext, plot: CGRect) {
        let lo = buckets.firstMinute, hi = buckets.lastMinute
        let pts = (lo...hi).map { CGPoint(x: x($0, plot), y: y(buckets.totals[$0], plot)) }
        var path = Path()
        path.move(to: pts[0])
        addCatmullRom(&path, pts)
        ctx.stroke(path, with: .color(curveColor), lineWidth: 1.4)
    }

    /// 沿点序列追加 Catmull-Rom 平滑曲线段(path 须已 move 到 pts[0])。
    /// 标准 1/6 张力,把折线转成穿过每个点的圆滑贝塞尔 —— 峰变钟形。
    private func addCatmullRom(_ path: inout Path, _ pts: [CGPoint]) {
        guard pts.count > 1 else { return }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// 底部时间标签(整点刻度)+ 左侧峰值数字。
    private func drawAxis(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let labelColor = colorScheme == .light ? Color.black.opacity(0.45) : Color.white.opacity(0.45)
        for h in hourTicks {
            let text = Text(String(format: "%02d:00", h))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(labelColor)
            ctx.draw(text, at: CGPoint(x: x(h * 60, plot), y: plot.maxY + 12))
        }
        // y 轴峰值(顶部)。
        let peak = Text("\(Int(buckets.maxTotal.rounded()))")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(labelColor)
        ctx.draw(peak, at: CGPoint(x: plot.minX - 6, y: plot.minY + 4), anchor: .trailing)
    }
}
