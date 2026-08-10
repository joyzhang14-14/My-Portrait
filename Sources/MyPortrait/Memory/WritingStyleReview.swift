import Foundation

/// Writing style **待审核**数据的读写门面 —— UI 只跟它打交道。
///
/// 存在的理由是 dev mode 在这条链路上必须分叉,而分叉只该发生一次:
/// 待审核数据不在文件里而在 sqlite 里(`writing_style_runs` /
/// `writing_style_staged`),那个库永远是真实的 `~/.portrait/portrait.sqlite`
/// —— dev mode 只切文件类路径,不切 DB。所以 dev 演示只能顶替查询结果,
/// 而不能像 events / portrait 那样换个根目录就完事。
///
/// 收在这一层,跟 `Storage.uiRootURL`、`ConfigStore.activeConfigURL` 同一个
/// 套路:调用方写起来当作只有一条链路,不需要知道 dev mode 存在。反过来
/// 把 `if DevMode.isOn` 撒在视图里,漏一处就是**演示画面里混进真实数据**,
/// 而这条链路的真实数据是用户的聊天原文。
///
/// 读方法一律 `async`:真实那条的 sqlite 查询在内部 detach 到后台跑
/// (这些查询会全表扫 staged),演示那条直接返回常量。
@MainActor
enum WritingStyleReview {

    private static var isDemo: Bool { DevMode.isOn }

    /// 演示 run 是写死的常量,不点掉的话 Approve / Reject 按完列表马上又长
    /// 回来。状态活到进程结束 —— 想再看一遍重开 app 即可。
    private static var demoDismissed = false

    private static var store: WritingStyleStore? {
        WritingStyleDistiller.shared?.store
    }

    // MARK: - 读

    /// 等待审核的 run(正常最多一条 —— distiller 见到 pending 就跳过跑批)。
    static func pendingRuns() async -> [WritingStyleRunRow] {
        if isDemo {
            return demoDismissed ? [] : [DevMode.demoWritingStyleRun]
        }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.fetchPendingReviewRuns()) ?? []
        }.value
    }

    /// 还没进过 writing style 的 writing_records 条数(决定 Run 按钮能不能点)。
    static func unprocessedCount() async -> Int {
        if isDemo { return 18 }
        guard let store else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            (try? store.unprocessedCount()) ?? 0
        }.value
    }

    /// 一次 run 暂存的全部 draft。**会抛** —— 有一处调用方(WritingStylePreview)
    /// 要把读取失败显示出来,吞掉的话那个红色错误条永远不会亮。
    static func drafts(runId: String) async throws -> [WritingStyleStagedRow] {
        if isDemo { return DevMode.demoWritingStyleDrafts }
        guard let store else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try store.fetchStaged(runId: runId)
        }.value
    }

    /// run 的元信息(详情页顶部那行 mode · 时间 · 计数)。
    static func run(runId: String) async -> WritingStyleRunRow? {
        if isDemo { return DevMode.demoWritingStyleRun }
        guard let store else { return nil }
        return await Task.detached(priority: .userInitiated) {
            (try? store.fetchRun(runId: runId)) ?? nil
        }.value
    }

    /// draft 背后的 writing_records 原文("N refs" 弹窗)。
    static func sourceRecords(ids: [Int64]) async -> [WritingStyleRecordInput] {
        if isDemo { return DevMode.demoWritingRecords(ids: ids) }
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.fetchRecordsByIds(ids)) ?? []
        }.value
    }

    /// 现有 `writing_style/<slug>.md` 的正文(CHANGED draft 的 BEFORE 栏)。
    ///
    /// **走 `Storage.uiPortraitDir`(界面根)而不是 `PortraitPaths`** ——
    /// 后者恒指真实 `~/.portrait`,是 pipeline 落盘用的;界面读它的话
    /// dev mode 下这一栏会显示真实的 writing style 内容。
    static func existingFacetBody(slug: String) async -> String? {
        let url = Storage.uiPortraitDir
            .appendingPathComponent("writing_style", isDirectory: true)
            .appendingPathComponent(slug + ".md")
        return await Task.detached(priority: .userInitiated) {
            (try? PortraitFileIO.read(from: url))?.body
        }.value
    }

    // MARK: - 写

    /// 批准 —— draft 落盘到 `portrait/writing_style/`,records 标记已处理。
    /// 返回落盘条数。演示那条什么都不写。
    static func approve(runId: String) throws -> Int {
        if isDemo {
            demoDismissed = true
            return 0
        }
        guard let distiller = WritingStyleDistiller.shared else { return 0 }
        return try distiller.approveStaged(runId: runId)
    }

    /// 驳回 —— 清 staged,records 留着不标,下次跑批重新消费。
    static func reject(runId: String) throws {
        if isDemo {
            demoDismissed = true
            return
        }
        guard let distiller = WritingStyleDistiller.shared else { return }
        try distiller.rejectStaged(runId: runId)
    }

    /// 审批结果提示语。演示那条要说清楚"什么都没写",否则录屏里看着像真落了盘。
    static func actionMessage(_ verb: String, runId: String, applied: Int? = nil) -> String {
        if isDemo { return "\(verb) (demo) — nothing was written." }
        let short = String(runId.prefix(8))
        if let applied {
            return "\(verb) \(short) — \(applied) draft(s) applied to portrait/writing_style/."
        }
        return "\(verb) \(short) — staged cleared, records left unprocessed."
    }
}
