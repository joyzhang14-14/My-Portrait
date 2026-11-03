import Foundation

/// Data → Input 两个视图(按 app 浏览 + 打字活动图)的**读取门面**。
///
/// 两个视图都只显示元输入:`keystroke_log` 经 `InputSegments` 切段拼字,不显示
/// 整理过的 writing_records(10-25 update)。库永远是真实的
/// `~/.portrait/metadata/input.sqlite`(dev mode 只切文件类路径,不切 DB),演示环境要么
/// 显示真实击键——那是最不能出现在录屏里的东西——要么整页空白。所以在这一层
/// 分叉一次:dev mode 用 `~/.portrait-dev/input_records.json` 合成的击键。
///
/// 调用方(InputCaptureView / InputActivityChartView)因此完全不需要知道
/// dev mode 存在,也不再各自持有一个 `store` 可选值。
@MainActor
enum WritingCaptureBrowse {

    private static var isDemo: Bool { DevMode.isOn }

    private static var store: WritingCaptureStore? {
        WritingCaptureStore.shared
    }

    /// 数据源在不在。false = 走空态提示(真实环境是 store 没建;
    /// 演示环境是 `input_records.json` 缺失或解析失败)。
    static var isAvailable: Bool {
        isDemo ? !DevMode.demoInputRecords.isEmpty : store != nil
    }

    private static var demoKeystrokes: [KeystrokeEntry] {
        DevMode.demoKeystrokes(records: DevMode.demoInputRecords)
    }

    /// 左列的 app 列表。
    static func apps() async -> [InputAppSummary] {
        if isDemo {
            return Dictionary(grouping: demoKeystrokes.filter { $0.char != nil }, by: \.bundleId)
                .map { InputAppSummary(app: $0.key, keys: $0.value.count,
                                       lastMs: $0.value.map(\.tsMs).max() ?? 0) }
                .sorted { $0.lastMs > $1.lastMs }
        }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.keystrokeAppSummaries()) ?? []
        }.value
    }

    /// 某 app 在 `beforeMs` 之前的若干段,新的在前。`nextBefore` 非 nil = 更早还有,
    /// 下一页从那里接着取。按击键条数分页:这一页最早那段可能被页边截断,
    /// 所以扔掉它、下一页从它开头重取。
    static func segments(app: String, beforeMs: Int64) async -> (segments: [InputSegment], nextBefore: Int64?) {
        let limit = 4000
        let ks: [KeystrokeEntry]
        if isDemo {
            ks = Array(demoKeystrokes.filter { $0.bundleId == app && $0.tsMs < beforeMs }.suffix(limit))
        } else {
            guard let store else { return ([], nil) }
            ks = await Task.detached(priority: .userInitiated) {
                (try? store.keystrokesForApp(app, beforeMs: beforeMs, limit: limit)) ?? []
            }.value
        }
        var segs = InputSegments.build(ks)
        guard ks.count == limit, let first = ks.first else { return (segs.reversed(), nil) }
        // 页边那段可能残缺:不止一段时扔掉最早那段,下一页从它开头取;只有一段就照收。
        if segs.count > 1, let oldest = segs.first {
            segs.removeFirst()
            return (segs.reversed(), oldest.startMs)
        }
        return (segs.reversed(), first.tsMs)
    }

    /// 活动图的原料:时间窗内的逐次击键。
    /// 某段时间里的点击次数;演示数据没有点击,返回 0。
    static func clicks(startMs: Int64, endMs: Int64) async -> Int {
        guard !isDemo, let store else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            (try? store.clickCount(startMs: startMs, endMs: endMs)) ?? 0
        }.value
    }

    /// 击键库里记到过的输入法;演示数据没有,返回空。
    static func inputSources() async -> [InputSourceUsage] {
        guard !isDemo, let store else { return [] }
        return await Task.detached(priority: .utility) {
            (try? store.inputSources()) ?? []
        }.value
    }

    static func keystrokes(startMs: Int64, endMs: Int64,
                           excludeBundleIds: Set<String>) async -> [KeystrokeEntry] {
        if isDemo {
            return demoKeystrokes
                .filter { $0.tsMs >= startMs && $0.tsMs < endMs
                          && !excludeBundleIds.contains($0.bundleId) }
        }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.keystrokesInRange(startMs: startMs, endMs: endMs,
                                          excludeBundleIds: excludeBundleIds)) ?? []
        }.value
    }

    /// writing-style 的 record chip 跳转:record 的 app 和开始时间,跳到那时那个 app 的元输入。
    static func jumpTarget(forRecord id: Int64) -> (app: String, startMs: Int64)? {
        if isDemo {
            guard let r = DevMode.demoInputRecords.first(where: { $0.id == id }) else { return nil }
            return (r.app, r.startTs)
        }
        guard let store, let g = store.groupForRecord(id: id),
              let ts = store.writingRecordStartTs(id: id) else { return nil }
        return (g.app, ts)
    }
}
