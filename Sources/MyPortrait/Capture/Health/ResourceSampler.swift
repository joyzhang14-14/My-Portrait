import Foundation
import Observation

/// 本进程 CPU / 内存采样,给 Settings → Health 的两张趋势图。
///   - 细:主窗口可见时每 2 秒一次,只在内存里,留最近 10 分钟(Last 5 minutes 用)
///   - 粗:始终每 60 秒一次,追加到 ~/.portrait/logs/usage.csv,重启后接着画;
///     文件只留最近 24 小时,启动时和之后每小时裁一次(约 40 KB 封顶)
///   - 第一次没有 usage.csv 时,用 health.log 里每 5 分钟一行的 MEM 补上过去 24 小时的内存
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
        Task.detached(priority: .utility) {
            let loaded = Self.loadHistory()
            await MainActor.run { ResourceSampler.shared.coarse = loaded + ResourceSampler.shared.coarse }
        }
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
        let line = String(format: "%.0f,%.2f,%.0f\n", s.t.timeIntervalSince1970, s.cpu, s.memMB)
        // 整点前后那一笔顺带裁文件:只留 24 小时
        let prune = Calendar.current.component(.minute, from: s.t) == 0
        Self.io.async {
            Self.append(line)
            if prune { Self.prune() }
        }
    }

    // MARK: - usage.csv(每行 "unix秒,cpu%,内存MB";cpu = -1 表示不知道,来自 health.log 补的)

    nonisolated private static let io = DispatchQueue(label: "com.myportrait.usage.csv")
    nonisolated private static var logsDir: URL { HealthMonitor.logFileURL.deletingLastPathComponent() }
    nonisolated private static var fileURL: URL { logsDir.appendingPathComponent("usage.csv") }

    nonisolated private static func append(_ line: String) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }

    /// 只留最近 24 小时,整文件重写。
    nonisolated private static func prune() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let cut = Date().timeIntervalSince1970 - 86_400
        let kept = text.split(separator: "\n").filter { line in
            guard let t = line.split(separator: ",").first.flatMap({ Double($0) }) else { return false }
            return t >= cut
        }
        try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n"))
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 启动时读历史:先裁 usage.csv;没有它就从 health.log 的 MEM 行补内存。
    nonisolated private static func loadHistory() -> [Sample] {
        let cut = Date().addingTimeInterval(-86_400)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            io.sync { prune() }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                let f = line.split(separator: ",").compactMap { Double($0) }
                guard f.count == 3 else { return nil }
                let t = Date(timeIntervalSince1970: f[0])
                return t >= cut ? Sample(t: t, cpu: f[1], memMB: f[2]) : nil
            }
        }
        guard let log = try? String(contentsOf: HealthMonitor.logFileURL, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [Sample] = []
        for line in log.split(separator: "\n") where line.contains("] MEM ") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let t = iso.date(from: String(line[line.index(after: line.startIndex)..<close])), t >= cut,
                  let r = line.range(of: "MEM "),
                  let mb = Double(line[r.upperBound...].prefix(while: { $0.isNumber })) else { continue }
            out.append(Sample(t: t, cpu: -1, memMB: mb))
        }
        let lines = out.map { String(format: "%.0f,-1,%.0f", $0.t.timeIntervalSince1970, $0.memMB) }
        if !lines.isEmpty { io.sync { append(lines.joined(separator: "\n") + "\n") } }
        return out
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
