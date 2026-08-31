import SwiftUI

/// Neural Graph 时间线的底部控制条(07-11 用户:仿 git / timeline,看每天的变化)。
///
/// 直接在柱状图上按住拖动擦洗日期(比滑块更接近 Timeline 的手感);柱高 =
/// 那天新诞生的 event 数。左右方向键逐日微调,空格播放/暂停。
struct GraphTimelineBar: View {
    let index: EventTimeline.Index
    @Binding var day: Date
    @Binding var playing: Bool
    /// 当天的图谱规模(由 root 传入,省得这里再算一遍)。
    let nodeCount: Int
    let folderCount: Int
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

            Text("\(nodeCount) nodes · \(folderCount) folders")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

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
