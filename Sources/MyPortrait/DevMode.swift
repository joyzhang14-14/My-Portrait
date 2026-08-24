import Foundation

/// 开发者模式 —— 让 app 的**界面**指向一套编造的演示数据(`~/.portrait-dev`),
/// 而后台采集与 pipeline 继续读写真实的 `~/.portrait`。用来调"新用户第一次
/// 打开"的观感、以及录演示视频而不暴露真实数据。
///
/// 三条铁律(08-09 update,改这个文件前先读):
///
/// 1. **capture 永远写 `~/.portrait`** —— dev mode 期间一帧都不能少。
/// 2. **pipeline 定时任务永远读写 `~/.portrait`** —— 它产出的是真实记忆。
/// 3. **config 按 section 切**:界面类(display / general / aiModels /
///    notifications / usage / chat / personalInfo)跟 dev 走;后台类
///    (capture / privacy / storage / scheduler / memory)永远读真实值,
///    且在 dev mode 下**只读**(ConfigStore.mutate 会把改动丢弃)。
///    这条线画在配置项上而不是调用方上,是因为后者要人工判断 ~85 处读取点,
///    漏一处(比如 storage.retentionDays)就是真删数据。
enum DevMode {
    /// `~/.portrait-dev` —— 演示数据根。**不进 git**(08-09 update):
    /// 生成脚本在 `Scripts/` 里进版本控制,数据本身随时可重新生成。
    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portrait-dev", isDirectory: true)
    }

    /// 开关是否**可见**。判据 = `~/.portrait-dev` 目录存在。
    ///
    /// 别人 clone 这个仓库、或装发布版 app,都没有这个目录 → 整张设置卡不渲染。
    /// **故意不做密钥**:本地 app 里"藏一个功能"从来不是安全边界(用户对自己
    /// 的机器有完全控制权),目录判据够用、零维护,而且不存在"私钥读取逻辑
    /// 要不要上 GitHub"这个自相矛盾的问题 —— 代码本来就是公开的。
    static var isAvailable: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private static let defaultsKey = "MyPortrait.devMode.enabled"

    /// 本进程当前是否处于 dev mode。**启动时读一次就冻结**。
    ///
    /// 路径在进程生命周期内必须恒定 —— 半路改变会让已经打开的 sqlite 连接、
    /// config 文件监听器、各视图的列表缓存分别指向两个根,状态必然对不上,
    /// 且很难查(表现是"某个面板还显示旧数据")。所以切换只写 UserDefaults,
    /// 重启后生效。
    ///
    /// 存 UserDefaults 而不是 config.toml —— config 自己就是被切换的对象之一,
    /// 把开关放进去会变成鸡生蛋。
    /// `let` 不只是风格 —— 它就是"冻结"本身:静态 let 由 swift_once 保证只求值
    /// 一次且线程安全,从类型上就写死了"运行中不可能变"。
    static let isOn: Bool = {
        UserDefaults.standard.bool(forKey: defaultsKey) && isAvailable
    }()

    /// 写下新状态。**调用方负责立刻重启** —— 见 `GeneralSettingsView.devModeCard`,
    /// 那里是一个按钮直接"切换并重启",不留"已改但未生效"的中间态。
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
        UserDefaults.standard.synchronize()   // 马上要 terminate,不能等系统自己刷
    }

    /// 演示人物的个人信息。dev config 是整份拷贝真实 config 来的,`personalInfo`
    /// 又是跟着 dev 走的 section —— 不覆盖的话 Personal Info 页会原样显示**真实
    /// 姓名、国籍、生日**,录演示视频第一页就泄了。
    ///
    /// 跟 `scripts/gen_dev_seed.py` 里的 Alex Rivera 是同一个人。改名字要两边一起改。
    static var demoPersonalInfo: PersonalInfoConfig {
        var p = PersonalInfoConfig()
        p.firstName = "Alex"
        p.lastName = "Rivera"
        p.alias = "alex"
        p.gender = .they
        p.nationality = "United States"
        p.languages = ["English", "Spanish"]
        p.birthDate = "1994-03-22"
        return p
    }

    // MARK: - Writing style 演示数据

    /// Writing Style 的待审核数据**不在文件里,在 sqlite 里**
    /// (`writing_style_runs` / `writing_style_staged`),而那个库永远是真实的
    /// `~/.portrait/portrait.sqlite` —— dev mode 只切文件类路径,不切 DB。
    /// 所以这条链路只能顶替查询结果:往真实库里插假 run 的话,distiller 见到
    /// pending_review 会**跳过之后所有跑批**,把真实提炼一直卡住。
    ///
    /// 内容放在 `~/.portrait-dev/writing_style_review.json`,跟 events /
    /// portrait 那些演示数据同一个地方 —— 改文案不用重新 build,存盘后切页
    /// 回来就是新的。文件由 `scripts/gen_dev_seed.py` 生成。
    ///
    /// **每次都重读、不缓存**:这个文件的唯一用途就是被手改,缓存等于把
    /// "不重新 build 也能改"这个理由抹掉。它只有几 KB,读盘代价可以忽略。
    static var writingStyleReviewURL: URL {
        rootURL.appendingPathComponent("writing_style_review.json")
    }

    /// run_id 是内部标识,不进 JSON —— 演示只可能有一条 run。
    static let demoWritingStyleRunId = "dev0demo0writing0style0run"

    /// 磁盘上那份演示数据的原样映射。字段大多可选 —— 这是给人手改的文件,
    /// 少写一个键应该是"用默认值",不该是"整页空白"。
    private struct Payload: Decodable {
        struct Run: Decodable {
            let mode: String?
            let startedAt: String?          // "yyyy-MM-dd HH:mm"
            let durationSeconds: Int?
            let recordsCount: Int?
        }
        struct Draft: Decodable {
            let action: String              // create / update / noop
            let slug: String
            let title: String
            let body: String
            let sourceRecordIds: [Int64]?
            let existingSlug: String?
        }
        struct Record: Decodable {
            let id: Int64
            let minutesBefore: Int?         // 相对 run 开始时间往前推
            let app: String
            let url: String?
            let text: String
            let kind: String?
            let contextSummary: String?
        }
        let unprocessedCount: Int?
        let run: Run?
        let drafts: [Draft]?
        let records: [Record]?
    }

    private static func loadWritingStyleReview() -> Payload? {
        guard let data = try? Data(contentsOf: writingStyleReviewURL) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(Payload.self, from: data)
    }

    /// 时间写成 "yyyy-MM-dd HH:mm" 方便手改;认不出来就退回一个固定时刻,
    /// 而不是取 now —— 演示数据每次打开都该长得一模一样,截图才可复现。
    private static func epochMs(_ s: String?) -> Int64 {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let s, let d = f.date(from: s) else { return 1_786_266_840_000 }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// 待审核的演示 run。文件不存在 / 解析失败 → nil,页面就是"没有待审核"。
    static var demoWritingStyleRun: WritingStyleRunRow? {
        guard let p = loadWritingStyleReview() else { return nil }
        let started = epochMs(p.run?.startedAt)
        return WritingStyleRunRow(
            id: 1,
            runId: demoWritingStyleRunId,
            mode: p.run?.mode == "auto" ? .auto : .manual,
            status: .pendingReview,
            startedAt: started,
            completedAt: started + Int64((p.run?.durationSeconds ?? 180) * 1000),
            recordsCount: p.run?.recordsCount ?? (p.records?.count ?? 0),
            // drafts 条数由列表本身算 —— 手改时少一个要同步的数字。
            draftsCount: p.drafts?.count ?? 0,
            errorMessage: nil
        )
    }

    static var demoWritingStyleDrafts: [WritingStyleStagedRow] {
        guard let p = loadWritingStyleReview() else { return [] }
        let started = epochMs(p.run?.startedAt)
        return (p.drafts ?? []).enumerated().map { i, d in
            WritingStyleStagedRow(
                id: Int64(i + 1),
                runId: demoWritingStyleRunId,
                createdAt: started,
                action: WritingStyleDraft.Action(rawValue: d.action) ?? .create,
                slug: d.slug,
                title: d.title,
                body: d.body,
                sourceRecordIds: d.sourceRecordIds ?? [],
                existingSlug: d.existingSlug
            )
        }
    }

    static var demoWritingStyleUnprocessed: Int {
        loadWritingStyleReview()?.unprocessedCount ?? 0
    }

    /// 详情页 "N refs" 弹窗里的原文。真实链路是按 id 去 `writing_records` 捞,
    /// 在 dev mode 下那会把**真实的聊天记录**摆到演示视频里,所以也顶替掉。
    static func demoWritingRecords(ids: [Int64]) -> [WritingStyleRecordInput] {
        guard let p = loadWritingStyleReview() else { return [] }
        let started = epochMs(p.run?.startedAt)
        let wanted = Set(ids)
        return (p.records ?? []).filter { wanted.contains($0.id) }.map { r in
            WritingStyleRecordInput(
                id: r.id,
                startTs: started - Int64((r.minutesBefore ?? 0) * 60_000),
                app: r.app,
                url: r.url,
                text: r.text,
                editLog: "[]",
                kind: r.kind ?? "other",
                contextSummary: r.contextSummary
            )
        }
    }

    // MARK: - Input(打字记录)演示数据

    /// Memories → Input 那两页的素材。跟 writing style 同理:`writing_records`
    /// / `keystroke_log` 在真实 sqlite 里,dev mode 不切库,只能顶替查询结果。
    /// 演示环境里显示真实击键是最不能接受的一种泄漏。
    ///
    /// 内容在 `~/.portrait-dev/input_records.json`,由
    /// `scripts/gen_dev_seed.py` 生成,改完存盘切页回来即生效(不缓存)。
    static var inputRecordsURL: URL {
        rootURL.appendingPathComponent("input_records.json")
    }

    private struct InputPayload: Decodable {
        struct Record: Decodable {
            let id: Int64
            let daysAgo: Int?               // 0 = 今天
            let start: String?              // "HH:mm"
            let durationMinutes: Int?
            let app: String                 // bundle id
            let url: String?
            let kind: String?
            let text: String
            let contextSummary: String?
            let confidence: Double?
            let source: String?
        }
        let records: [Record]?
    }

    private static func loadInputRecords() -> InputPayload? {
        guard let data = try? Data(contentsOf: inputRecordsURL) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(InputPayload.self, from: data)
    }

    /// 时间用「几天前 + 当天几点」而不是绝对时刻 —— 活动图默认看今天,
    /// 写死日期的话演示数据永远落在过去,打开就是空图。
    private static func timestamp(daysAgo: Int, hhmm: String) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let base = cal.startOfDay(for: day)
        let secs = (parts.first ?? 9) * 3600 + (parts.count > 1 ? parts[1] : 0) * 60
        return Int64((base.timeIntervalSince1970 + Double(secs)) * 1000)
    }

    static var demoInputRecords: [WritingRecordViewRow] {
        guard let p = loadInputRecords() else { return [] }
        return (p.records ?? []).map { r in
            let start = timestamp(daysAgo: r.daysAgo ?? 0, hhmm: r.start ?? "09:00")
            let end = start + Int64(max(1, r.durationMinutes ?? 3) * 60_000)
            return WritingRecordViewRow(
                id: r.id,
                startTs: start,
                endTs: end,
                app: r.app,
                url: r.url,
                location: nil,
                text: r.text,
                editLog: demoEditLog(text: r.text, start: start, end: end),
                confidence: r.confidence ?? 0.92,
                contextSummary: r.contextSummary,
                source: r.source ?? "ax_cleaned",
                kind: r.kind ?? "other",
                workerRunId: nil,
                createdAt: end
            )
        }
    }

    /// edit_log 由正文**推出来**而不是手写 —— 手写一份跟正文对不上的时序,
    /// 详情页的回放会自相矛盾;而让人手改 JSON 时还要同步维护它,这份演示
    /// 数据就没人愿意改了。切成三段 commit,看起来就是"分几次敲完"。
    private static func demoEditLog(text: String, start: Int64, end: Int64) -> String {
        let chars = Array(text)
        guard chars.count > 12 else { return "[]" }
        let cuts = [chars.count / 3, chars.count * 2 / 3, chars.count]
        let span = max(1, end - start)
        let entries = cuts.enumerated().map { i, upTo in
            EditEntry(ts: start + span * Int64(i + 1) / Int64(cuts.count),
                      kind: "commit",
                      text: String(chars[0..<upTo]))
        }
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 活动图的击键流同样由正文推出来:每个字符一次击键,均匀铺在这条
    /// record 的时间窗里。这样图上的活动段跟下面列出的 record 严格对齐 ——
    /// 手写一份独立的击键序列必然对不上。
    static func demoKeystrokes(records: [WritingRecordViewRow]) -> [KeystrokeEntry] {
        var out: [KeystrokeEntry] = []
        var nextId: Int64 = 1
        for r in records {
            let chars = Array(r.text)
            guard !chars.isEmpty else { continue }
            let span = max(1, r.endTs - r.startTs)
            for (i, ch) in chars.enumerated() {
                out.append(KeystrokeEntry(
                    id: nextId,
                    tsMs: r.startTs + span * Int64(i) / Int64(chars.count),
                    bundleId: r.app,
                    char: String(ch),
                    isBackspace: 0
                ))
                nextId += 1
            }
        }
        return out.sorted { $0.tsMs < $1.tsMs }
    }
}
