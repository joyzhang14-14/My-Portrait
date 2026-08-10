import Foundation

/// Memories → Input 两个视图(记录浏览 + 打字活动图)的**读写门面**。
///
/// 跟 `WritingStyleReview` 同一个理由和同一个套路:打字记录在
/// `writing_records` / `keystroke_log` 两张表里,而库永远是真实的
/// `~/.portrait/portrait.sqlite`(dev mode 只切文件类路径,不切 DB)。
/// 演示环境要么显示真实击键——那是最不能出现在录屏里的东西——要么整页空白。
/// 所以在这一层分叉一次:dev mode 读 `~/.portrait-dev/input_records.json`。
///
/// 调用方(InputCaptureView / InputActivityChartView)因此完全不需要知道
/// dev mode 存在,也不再各自持有一个 `store` 可选值。
@MainActor
enum WritingCaptureBrowse {

    private static var isDemo: Bool { DevMode.isOn }

    private static var store: WritingCaptureStore? {
        WritingCaptureWorker.shared?.store
    }

    /// 演示环境里"删掉"的 record id。JSON 是只读素材,不该被界面操作改写,
    /// 但删除按钮又得有反馈 —— 记在内存里,重启即恢复。
    private static var demoDeleted = Set<Int64>()

    /// 数据源在不在。false = 走空态提示(真实环境是 worker 没起来;
    /// 演示环境是 `input_records.json` 缺失或解析失败)。
    static var isAvailable: Bool {
        isDemo ? !DevMode.demoInputRecords.isEmpty : store != nil
    }

    private static var demoRecords: [WritingRecordViewRow] {
        DevMode.demoInputRecords.filter { !demoDeleted.contains($0.id) }
    }

    // MARK: - 读

    /// 左列的 app / url 分组。
    static func appSummaries() async -> [WritingCaptureAppSummary] {
        if isDemo { return summarize(demoRecords) }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.writingRecordAppSummaries()) ?? []
        }.value
    }

    /// 一个分组下的全部 record。
    static func records(app: String, url: String) async -> [WritingRecordViewRow] {
        if isDemo {
            return demoRecords
                .filter { $0.app == app && ($0.url ?? "") == url }
                .sorted { $0.startTs > $1.startTs }
        }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.writingRecordsForGroup(app: app, url: url)) ?? []
        }.value
    }

    /// 某一天(或任意时间窗)里的 record —— 活动图下方的列表。
    static func records(startMs: Int64, endMs: Int64) async -> [WritingRecordViewRow] {
        if isDemo {
            return demoRecords
                .filter { $0.startTs >= startMs && $0.startTs < endMs }
                .sorted { $0.startTs < $1.startTs }
        }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.writingRecordsInRange(startMs: startMs, endMs: endMs)) ?? []
        }.value
    }

    /// 活动图的原料:时间窗内的逐次击键。
    static func keystrokes(startMs: Int64, endMs: Int64,
                           excludeBundleIds: Set<String>) async -> [KeystrokeEntry] {
        if isDemo {
            return DevMode.demoKeystrokes(records: demoRecords)
                .filter { $0.tsMs >= startMs && $0.tsMs < endMs
                          && !excludeBundleIds.contains($0.bundleId) }
        }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.keystrokesInRange(startMs: startMs, endMs: endMs,
                                          excludeBundleIds: excludeBundleIds)) ?? []
        }.value
    }

    /// record 属于哪个 (app, url) 分组 —— 图谱 / writing-style 跳转用。
    static func group(forRecord id: Int64) -> (app: String, url: String)? {
        if isDemo {
            guard let r = demoRecords.first(where: { $0.id == id }) else { return nil }
            return (r.app, r.url ?? "")
        }
        return store?.groupForRecord(id: id)
    }

    /// record 的开始时间 —— 跳转时用来把活动图切到那一天。
    static func startTs(forRecord id: Int64) -> Int64? {
        if isDemo { return demoRecords.first(where: { $0.id == id })?.startTs }
        return store?.writingRecordStartTs(id: id)
    }

    // MARK: - 写

    static func deleteRecord(id: Int64) async {
        if isDemo { demoDeleted.insert(id); return }
        guard let store else { return }
        await Task.detached(priority: .userInitiated) {
            try? store.deleteWritingRecord(id: id)
        }.value
    }

    static func deleteGroup(app: String, url: String) async {
        if isDemo {
            demoRecords.filter { $0.app == app && ($0.url ?? "") == url }
                .forEach { demoDeleted.insert($0.id) }
            return
        }
        guard let store else { return }
        await Task.detached(priority: .userInitiated) {
            try? store.deleteWritingRecordsForGroup(app: app, url: url)
        }.value
    }

    // MARK: - 演示分组

    /// 真实那条由 SQL 的 GROUP BY 出结果;演示这条只能自己聚一次。
    private static func summarize(_ rows: [WritingRecordViewRow]) -> [WritingCaptureAppSummary] {
        var byKey: [String: (app: String, url: String, count: Int, last: Int64)] = [:]
        for r in rows {
            let url = r.url ?? ""
            let key = r.app + "\u{1}" + url
            if var cur = byKey[key] {
                cur.count += 1
                cur.last = max(cur.last, r.endTs)
                byKey[key] = cur
            } else {
                byKey[key] = (r.app, url, 1, r.endTs)
            }
        }
        return byKey.values
            .map { WritingCaptureAppSummary(app: $0.app, url: $0.url,
                                            recordCount: $0.count, lastEndedAt: $0.last) }
            .sorted { $0.lastEndedAt > $1.lastEndedAt }
    }
}
