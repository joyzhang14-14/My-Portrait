import SwiftUI

/// Memory 区 "Input" scope 的**图谱形态**(canvas 模式)。
///
/// 一天一张面积图:x 轴 = 当天本地时间 00:00–24:00,y 轴 = 每分钟总击键数
/// (含退格,不减)。曲线下方阴影按 app 堆叠分色(和 timeline 一致的 `AppColor`)。
/// 顶部日期切换栏复用 timeline 的 `TimelineControlsBar`(日历弹窗切天)。
///
/// 数据源:`keystroke_log`(raw 每次击键),按本地某天 [00:00, +24h) 查
/// `WritingCaptureStore.keystrokesInRange`,后台聚合成 1440 个分钟桶。
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
            InputActivityCanvas(buckets: buckets, colorScheme: colorScheme)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
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
struct MinuteBuckets: Sendable {
    /// 堆叠顺序的 app bundle_id(总量小的在底,大的在上 —— 大块在顶更好读)。
    let apps: [String]
    /// counts[minute(0..1439)][appIndex] = 该分钟该 app 击键数。
    let counts: [[Int]]
    /// totals[minute] = 该分钟所有 app 击键总数(= 堆叠顶 = 单色曲线)。
    let totals: [Int]
    let maxTotal: Int

    static let empty = MinuteBuckets(apps: [], counts: [], totals: [], maxTotal: 0)

    /// 纯函数,后台线程跑。keystroke 已按 ts 升序,但不依赖顺序。
    static func aggregate(_ ks: [KeystrokeEntry], dayStartMs: Int64) -> MinuteBuckets {
        guard !ks.isEmpty else { return .empty }

        // 1) 先统计每 app 全天总量,定堆叠顺序(升序:小的在底)。
        var appTotals: [String: Int] = [:]
        for k in ks { appTotals[k.bundleId, default: 0] += 1 }
        let apps = appTotals.sorted { $0.value < $1.value }.map { $0.key }
        let appIndex = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1, $0) })

        // 2) 逐击键落分钟桶。
        var counts = Array(repeating: Array(repeating: 0, count: apps.count), count: 1440)
        var totals = Array(repeating: 0, count: 1440)
        for k in ks {
            let m = Int((k.tsMs - dayStartMs) / 60_000)
            guard m >= 0, m < 1440, let ai = appIndex[k.bundleId] else { continue }
            counts[m][ai] += 1
            totals[m] += 1
        }
        return MinuteBuckets(apps: apps, counts: counts, totals: totals,
                             maxTotal: totals.max() ?? 0)
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

    private func x(_ minute: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(minute / 1440.0) * plot.width
    }
    private func y(_ value: Double, _ plot: CGRect) -> CGFloat {
        let maxV = max(1.0, Double(buckets.maxTotal))
        return plot.maxY - CGFloat(value / maxV) * plot.height
    }

    private var gridColor: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08)
    }
    private var curveColor: Color {
        colorScheme == .light ? Color.black.opacity(0.65) : Color.white.opacity(0.80)
    }

    /// 每 3 小时一条竖线 + y 轴顶/中横线。
    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect) {
        var p = Path()
        for h in stride(from: 0, through: 24, by: 3) {
            let px = x(Double(h) * 60, plot)
            p.move(to: CGPoint(x: px, y: plot.minY))
            p.addLine(to: CGPoint(x: px, y: plot.maxY))
        }
        p.move(to: CGPoint(x: plot.minX, y: plot.minY))
        p.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        ctx.stroke(p, with: .color(gridColor), lineWidth: 0.6)
    }

    /// 逐 app 从底往上堆叠:每层 = 上界(累计+本层)回到下界(累计),闭合填 AppColor。
    private func drawStackedArea(_ ctx: GraphicsContext, plot: CGRect) {
        var cumulative = Array(repeating: 0, count: 1440)
        for (ai, bundle) in buckets.apps.enumerated() {
            var upper = Array(repeating: 0, count: 1440)
            for m in 0..<1440 { upper[m] = cumulative[m] + buckets.counts[m][ai] }

            var path = Path()
            path.move(to: CGPoint(x: x(0, plot), y: y(Double(upper[0]), plot)))
            for m in 1..<1440 {
                path.addLine(to: CGPoint(x: x(Double(m), plot), y: y(Double(upper[m]), plot)))
            }
            for m in stride(from: 1439, through: 0, by: -1) {
                path.addLine(to: CGPoint(x: x(Double(m), plot), y: y(Double(cumulative[m]), plot)))
            }
            path.closeSubpath()

            let color = AppColor.color(for: InputCaptureView.appLabel(bundle))
            ctx.fill(path, with: .color(color.opacity(0.55)))

            cumulative = upper
        }
    }

    /// 单色曲线 = 每分钟总量顶部轮廓。
    private func drawTotalCurve(_ ctx: GraphicsContext, plot: CGRect) {
        var path = Path()
        path.move(to: CGPoint(x: x(0, plot), y: y(Double(buckets.totals[0]), plot)))
        for m in 1..<1440 {
            path.addLine(to: CGPoint(x: x(Double(m), plot), y: y(Double(buckets.totals[m]), plot)))
        }
        ctx.stroke(path, with: .color(curveColor), lineWidth: 1.4)
    }

    /// 底部时间标签(0/6/12/18/24 时)+ 左侧峰值数字。
    private func drawAxis(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let labelColor = colorScheme == .light ? Color.black.opacity(0.45) : Color.white.opacity(0.45)
        for h in stride(from: 0, through: 24, by: 6) {
            let text = Text(String(format: "%02d:00", h))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(labelColor)
            ctx.draw(text, at: CGPoint(x: x(Double(h) * 60, plot), y: plot.maxY + 12))
        }
        // y 轴峰值(顶部)。
        let peak = Text("\(buckets.maxTotal)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(labelColor)
        ctx.draw(peak, at: CGPoint(x: plot.minX - 6, y: plot.minY + 4), anchor: .trailing)
    }
}
