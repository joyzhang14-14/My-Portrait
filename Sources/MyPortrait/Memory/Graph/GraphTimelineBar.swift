import SwiftUI

/// Neural Graph 时间线的底部控制条(07-11 用户:仿 git / timeline,看每天的变化)。
///
/// 柱高 = 那天新诞生的 event 数;**点**柱状图跳到那天。
/// 换日三条路:点击、左右方向键(GraphRootView 订阅 AppKeyboard 广播)、播放。
struct GraphTimelineBar: View {
    let index: EventTimeline.Index
    @Binding var day: Date
    @Binding var playing: Bool
    /// 当日变化(root 在换日时算一次传进来 —— 放在 body 里算会每次渲染
    /// 都全量重算 weight)。
    let stats: EventTimeline.DayStats
    var onExit: () -> Void

    private let cal = Calendar(identifier: .gregorian)

    private var totalDays: Int {
        max(1, cal.dateComponents([.day], from: index.range.lowerBound,
                                  to: index.range.upperBound).day ?? 1)
    }
    private var dayOffset: Int {
        max(0, min(totalDays,
                   cal.dateComponents([.day], from: index.range.lowerBound, to: day).day ?? 0))
    }
    private var maxBirths: Int { max(1, index.birthsPerDay.values.max() ?? 1) }

    /// 一行、无外框:▶ | 日期 + 当天新增 | 柱状图 | 回到今天 | ✕。
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bouncyIcon)
            .help(playing ? "Pause" : "Play through time")

            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dayFmt.string(from: day))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                dayStats
            }
            .frame(width: 100, alignment: .leading)

            scrubber

            Button { day = index.range.upperBound } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.bouncyIcon)
            .help("Jump to today")

            Button(action: onExit) { Image(systemName: "xmark") }
                .buttonStyle(.bouncyIcon)
                .help("Exit timeline")
        }
        .frame(maxWidth: 760)
    }

    /// 柱状图 + 擦洗。柱 = 当天新诞生的 event 数;竖线 = 当前位置。
    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                let step = size.width / CGFloat(totalDays + 1)
                let bw = max(1, step * 0.8)
                var bars = Path()
                for i in 0...totalDays {
                    guard let d = cal.date(byAdding: .day, value: i,
                                           to: index.range.lowerBound) else { continue }
                    let n = index.birthsPerDay[cal.startOfDay(for: d)] ?? 0
                    guard n > 0 else { continue }
                    let bh = size.height * CGFloat(n) / CGFloat(maxBirths)
                    bars.addRect(CGRect(x: CGFloat(i) * step, y: size.height - bh,
                                        width: bw, height: bh))
                }
                ctx.fill(bars, with: .color(Theme.textPrimary.opacity(0.28)))
                // 已走过的部分用 accent 重画一遍
                var past = Path()
                for i in 0...dayOffset {
                    guard let d = cal.date(byAdding: .day, value: i,
                                           to: index.range.lowerBound) else { continue }
                    let n = index.birthsPerDay[cal.startOfDay(for: d)] ?? 0
                    guard n > 0 else { continue }
                    let bh = size.height * CGFloat(n) / CGFloat(maxBirths)
                    past.addRect(CGRect(x: CGFloat(i) * step, y: size.height - bh,
                                        width: bw, height: bh))
                }
                ctx.fill(past, with: .color(Theme.accent.opacity(0.85)))
                // 游标
                let x = CGFloat(dayOffset) * step + bw / 2
                var head = Path()
                head.move(to: CGPoint(x: x, y: 0))
                head.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(head, with: .color(Theme.accent), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            // 只接**点击**,不接拖动擦洗(08-31 用户):按住拖会连续换日,
            // 快到陨石根本来不及归位,画面全是半路上的球。换日只剩三条路:
            // 点柱状图、左右方向键、播放。
            .onTapGesture(coordinateSpace: .local) { loc in
                playing = false
                seek(toX: loc.x, width: w)
            }
            .frame(width: w, height: h)
        }
        .frame(height: 36)
    }

    /// 当天新增几条 event(0 时压成次要灰)。
    @ViewBuilder private var dayStats: some View {
        Text("+\(stats.born) new")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(stats.born > 0 ? Theme.textPrimary.opacity(0.7) : Color.secondary)
    }

    private func seek(toX x: CGFloat, width: CGFloat) {
        guard width > 1 else { return }
        let step = width / CGFloat(totalDays + 1)
        let i = max(0, min(totalDays, Int((x / step).rounded(.down))))
        if let d = cal.date(byAdding: .day, value: i, to: index.range.lowerBound),
           cal.startOfDay(for: d) != cal.startOfDay(for: day) {
            day = cal.startOfDay(for: d)
        }
    }

    nonisolated(unsafe) static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
