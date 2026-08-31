import SwiftUI

/// Neural Graph 时间线的底部控制条(07-11 用户:仿 git / timeline,看每天的变化)。
///
/// 直接在柱状图上按住拖动擦洗日期(比滑块更接近 Timeline 的手感);柱高 =
/// 那天新诞生的 event 数。逐日微调走左右方向键(在 GraphRootView 收键)。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            scrubber
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard()
        .frame(maxWidth: 720)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bouncyIcon)
            .help(playing ? "Pause" : "Play through time")

            Text(Self.dayFmt.string(from: day))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .frame(width: 108, alignment: .leading)

            // 当天的**变化**(总数右上角 HUD 已有,这里不重复):
            // 新增 = 那天诞生的 event;合并 = 那天并进已有 event 的重复发生。
            dayStats

            Spacer()

            Button { day = index.range.upperBound } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.bouncyIcon)
            .help("Jump to today")

            Button(action: onExit) { Image(systemName: "xmark") }
                .buttonStyle(.bouncyIcon)
                .help("Exit timeline")
        }
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        playing = false
                        seek(toX: v.location.x, width: w)
                    }
            )
            .frame(width: w, height: h)
        }
        .frame(height: 34)
    }

    /// 当天变化:+新增 · 合并 · folder 数(带增减)。
    @ViewBuilder private var dayStats: some View {
        // 三组之间拉开间距 —— 挤在一起容易看成一句话(08-31 用户)。
        // 值为 0 时压成次要灰:0 不是"变化",不该跟真有变化的数字一样抢眼。
        HStack(spacing: 18) {
            Text("+\(stats.born)")
                .foregroundStyle(stats.born > 0 ? Color.green : Color.secondary)
            Text("\(stats.merged) merged")
                .foregroundStyle(stats.merged > 0 ? Color.yellow : Color.secondary)
            HStack(spacing: 4) {
                Text("\(stats.folders) folders").foregroundStyle(.secondary)
                if stats.folderDelta != 0 {
                    Text(stats.folderDelta > 0 ? "(+\(stats.folderDelta))"
                                               : "(\(stats.folderDelta))")
                        .foregroundStyle(stats.folderDelta > 0 ? Color.green : Color.red)
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
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
