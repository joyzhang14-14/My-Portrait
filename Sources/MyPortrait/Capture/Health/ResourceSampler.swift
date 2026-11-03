import Foundation
import Observation

/// 本进程 CPU / 内存采样,给 Settings → Health 的两张趋势图。
///   - 细:主窗口可见时每 2 秒一次,留最近 10 分钟(Last 5 minutes 用)
///   - 粗:始终每 60 秒一次,留最近 24 小时(Last hour / Last 24 hours 用)
/// 内存 = phys_footprint,和活动监视器「内存」列同口径;CPU = 两次采样之间
/// 本进程用掉的 CPU 时间 / 墙钟时间(多核可超过 100%)。只算主进程。
@MainActor @Observable
final class ResourceSampler {
    static let shared = ResourceSampler()

    struct Sample: Sendable {
        let t: Date
        let cpu: Double
        let memMB: Double
    }

    /// 门槛:超过 warn 那段画橙,超过 bad 画红。后台平时 ~80 MB,前台 OCR 时 300–600 MB 属正常。
    static let cpuWarn = 50.0, cpuBad = 100.0
    static let memWarn = 700.0, memBad = 1024.0
    static let fineInterval: TimeInterval = 2, coarseInterval: TimeInterval = 60

    private(set) var fine: [Sample] = []
    private(set) var coarse: [Sample] = []

    @ObservationIgnored private var fineTimer: Timer?
    @ObservationIgnored private var coarseTimer: Timer?
    @ObservationIgnored private var lastFine: (wall: TimeInterval, cpu: TimeInterval)?
    @ObservationIgnored private var lastCoarse: (wall: TimeInterval, cpu: TimeInterval)?

    private init() {}

    /// HealthMonitor 启动时调;`windowVisible` 决定细采样开不开。
    func start(windowVisible: Bool) {
        guard coarseTimer == nil else { return }
        lastCoarse = Self.clock()
        let t = Timer(timeInterval: Self.coarseInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ResourceSampler.shared.takeCoarse() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        coarseTimer = t
        setFine(windowVisible)
    }

    /// 主窗口显示 / 隐藏时调:只有看得见时才每 2 秒采一次。
    func setFine(_ on: Bool) {
        if on, fineTimer == nil {
            lastFine = Self.clock()
            let t = Timer(timeInterval: Self.fineInterval, repeats: true) { _ in
                MainActor.assumeIsolated { ResourceSampler.shared.takeFine() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            fineTimer = t
        } else if !on {
            fineTimer?.invalidate()
            fineTimer = nil
        }
    }

    /// 当前要提醒的问题(没有 = nil):最近 2 分钟 CPU 平均过警戒线,或内存过警戒线。
    var issue: String? {
        let cut = Date().addingTimeInterval(-120)
        let recent = fine.filter { $0.t > cut }
        if recent.count >= 10, recent.reduce(0, { $0 + $1.cpu }) / Double(recent.count) >= Self.cpuWarn {
            return "CPU high"
        }
        if let m = (fine.last ?? coarse.last)?.memMB, m >= Self.memWarn { return "Memory high" }
        return nil
    }

    /// 问题从什么时候开始(连续超线的第一笔)。
    var issueSince: Date? {
        guard let issue else { return nil }
        let s = fine.isEmpty ? coarse : fine
        var since: Date?
        for x in s.reversed() {
            let over = issue == "CPU high" ? x.cpu >= Self.cpuWarn : x.memMB >= Self.memWarn
            if over { since = x.t } else { break }
        }
        return since
    }

    private func takeFine() {
        guard let s = Self.sample(since: &lastFine) else { return }
        fine.append(s)
        let cut = Date().addingTimeInterval(-600)
        if let i = fine.firstIndex(where: { $0.t >= cut }), i > 0 { fine.removeFirst(i) }
    }

    private func takeCoarse() {
        guard let s = Self.sample(since: &lastCoarse) else { return }
        coarse.append(s)
        let cut = Date().addingTimeInterval(-86_400)
        if let i = coarse.firstIndex(where: { $0.t >= cut }), i > 0 { coarse.removeFirst(i) }
    }

    private static func sample(since last: inout (wall: TimeInterval, cpu: TimeInterval)?) -> Sample? {
        let now = clock()
        defer { last = now }
        guard let prev = last, now.wall > prev.wall else { return nil }
        let cpu = max(0, (now.cpu - prev.cpu) / (now.wall - prev.wall) * 100)
        let mem = HealthMonitor.physFootprintMB()
        guard mem > 0 else { return nil }
        return Sample(t: Date(), cpu: cpu, memMB: Double(mem))
    }

    /// (墙钟秒, 本进程累计 CPU 秒 = user + system)
    private static func clock() -> (wall: TimeInterval, cpu: TimeInterval) {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let cpu = Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
            + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        return (ProcessInfo.processInfo.systemUptime, cpu)
    }
}
