import Foundation

/// Timeline 界面的取数门面 —— 三个查询都从这里走。
///
/// 存在的理由是 dev mode 要有一条**自己的** timeline:demo 环境里不该看见
/// 你过去几个月的真实录屏,但屏幕帧又是没法编造的(它们是真的 JPG / MP4)。
///
/// 做法不是再存一份 —— 真实那份是 9.6GB 库 + 8.5GB 视频,复制或双写的代价
/// 跟收益完全不成比例。改成**记录 dev mode 的开关区间**,dev mode 下只放行
/// 落在这些区间里的帧。看到的效果就是要的效果:第一次进 dev mode 时
/// timeline 是空的,之后只长你开着 dev mode 那段时间的内容。
///
/// 代价说清楚:dev timeline 不是独立副本,真实那边 retention 删掉旧数据,
/// dev 这边同一段也会跟着消失。
@MainActor
enum TimelineFeed {

    static func framesForDay(_ day: Date, db: PortraitDB) async -> [TimelineFrame] {
        let rows = (try? await db.framesForDay(day)) ?? []
        return DevTimelineSessions.keep(rows, at: \.timestamp)
    }

    static func activeAppsAround(_ moment: Date, windowSeconds: TimeInterval,
                                 db: PortraitDB) async -> [ActiveAppEntry] {
        let rows = (try? await db.activeAppsAround(
            timestamp: moment, windowSeconds: windowSeconds)) ?? []
        return DevTimelineSessions.keep(rows, at: \.lastSeen)
    }

    static func audioTranscriptsAround(_ moment: Date,
                                       beforeSeconds: TimeInterval,
                                       afterSeconds: TimeInterval,
                                       db: PortraitDB) async -> [AudioTranscriptEntry] {
        let rows = (try? await db.audioTranscriptsAround(
            timestamp: moment, beforeSeconds: beforeSeconds,
            afterSeconds: afterSeconds)) ?? []
        return DevTimelineSessions.keep(rows, at: \.timestamp)
    }
}

/// dev mode 的开机区间账本 —— `~/.portrait-dev/timeline_sessions.json`。
///
/// 一条区间 = 一次「dev mode 开着」的时段。`to` 由心跳每分钟往前推,所以
/// 进程被 SIGKILL / OOM 掉也不会留下一条无限长的开区间(最多多算一分钟),
/// 不需要依赖 applicationWillTerminate 一定被调用。
@MainActor
enum DevTimelineSessions {

    struct Span: Codable {
        var from: Int64
        var to: Int64
    }

    private static var url: URL {
        DevMode.rootURL.appendingPathComponent("timeline_sessions.json")
    }

    /// 心跳间隔。60s 意味着崩溃最多把 1 分钟的真实帧算进 dev timeline ——
    /// 对一个演示环境来说完全够,而写盘频率低到可以忽略(文件 200B 上下)。
    private static let heartbeat: TimeInterval = 60

    private static var spans: [Span] = []
    private static var loaded = false
    private static var beating = false

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Span].self, from: data)
        else { return }
        spans = decoded
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(spans) else { return }
        try? FileManager.default.createDirectory(
            at: DevMode.rootURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - 记录

    /// dev mode 启动时开一段新区间,并起心跳。真实模式下什么都不做。
    static func beginSession() {
        guard DevMode.isOn else { return }
        load()
        let t = nowMs
        // 每次切 dev mode 都要重启 app,调试期间重启很频繁 —— 不合并的话这个
        // 文件会堆成几百条几秒钟的碎区间。间隔 5 分钟内的直接续上一段:app
        // 没跑的时候采集也没跑,那段空白里本来就没有帧,合并不会多放行任何东西。
        if let last = spans.last, t - last.to < 5 * 60_000 {
            spans[spans.count - 1].to = t
        } else {
            spans.append(Span(from: t, to: t))
        }
        save()
        startHeartbeat()
    }

    /// 主动切回真实数据时精确收尾(心跳已经把 `to` 推到一分钟内,这里只是
    /// 把最后那点补齐)。
    static func endSession() {
        guard DevMode.isOn else { return }
        load()
        guard !spans.isEmpty else { return }
        spans[spans.count - 1].to = nowMs
        save()
    }

    private static func startHeartbeat() {
        guard !beating else { return }
        beating = true
        Task { @MainActor in
            while DevMode.isOn {
                try? await Task.sleep(nanoseconds: UInt64(heartbeat * 1_000_000_000))
                guard !spans.isEmpty else { continue }
                spans[spans.count - 1].to = nowMs
                save()
            }
        }
    }

    // MARK: - 过滤

    /// 非 dev mode 原样返回 —— 真实环境完全不受这一层影响。
    static func keep<T>(_ rows: [T], at time: KeyPath<T, Date>) -> [T] {
        guard DevMode.isOn else { return rows }
        load()
        guard !spans.isEmpty else { return [] }
        return rows.filter { row in
            let t = Int64(row[keyPath: time].timeIntervalSince1970 * 1000)
            return spans.contains { t >= $0.from && t <= $0.to }
        }
    }
}
