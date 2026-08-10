import Foundation

/// 开发者模式 —— 让 app 的**界面**指向一套编造的演示数据(`~/.portrait-dev`),
/// 而后台采集与 pipeline 继续读写真实的 `~/.portrait`。用来调"新用户第一次
/// 打开"的观感、以及录演示视频而不暴露真实数据。
///
/// 三条铁律(08-09 用户定,改这个文件前先读):
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
    /// `~/.portrait-dev` —— 演示数据根。**不进 git**(用户 08-09 定):
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
    ///
    /// 中间态原本是有的(开关 + "Restart to apply" 提示行),但那个提示行读的是
    /// UserDefaults 这种 SwiftUI 看不见的值,拨完开关不会重画,得切到别的页面
    /// 再回来才出现。与其给它套一层可观察包装,不如取消中间态本身。
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
    ///
    /// 所以这条链路的演示数据只能写死在代码里,由 MemorySettingsView 在
    /// `DevMode.isOn` 时直接顶替 store 查询。往真实库里插假 run 是不行的:
    /// distiller 只要看见一条 pending_review 就**跳过之后所有跑批**,假数据
    /// 会把真实提炼一直卡住,而 Approve 还会把假 facet 写进真实 portrait。
    ///
    /// 时间戳写死(2026-08-09 09:14)而不是取 now —— 演示数据每次打开都该长
    /// 得一模一样,截图 / 录屏才可复现。
    static let demoWritingStyleRunId = "dev0demo0writing0style0run"
    private static let demoStartedAt: Int64 = 1_786_266_840_000
    private static let demoCompletedAt: Int64 = 1_786_267_020_000

    static var demoWritingStyleRun: WritingStyleRunRow {
        WritingStyleRunRow(
            id: 1,
            runId: demoWritingStyleRunId,
            mode: .manual,
            status: .pendingReview,
            startedAt: demoStartedAt,
            completedAt: demoCompletedAt,
            recordsCount: 34,
            draftsCount: 4,
            errorMessage: nil
        )
    }

    static var demoWritingStyleDrafts: [WritingStyleStagedRow] {
        [
            WritingStyleStagedRow(
                id: 1, runId: demoWritingStyleRunId, createdAt: demoCompletedAt,
                action: .create,
                slug: "thinks_in_fragments_then_tightens",
                title: "Drafts in fragments, then tightens on a second pass",
                body: """
                Alex rarely writes a finished sentence on the first try. Their edit logs show a \
                recognisable two-beat rhythm: a fast, comma-spliced first pass that gets the whole \
                thought onto the screen, then a slower pass that deletes the scaffolding.

                A Slack message that shipped as "Rolling this back — the retry loop double-counts \
                on 429s." started life as "so i think what's happening is that when we get a 429 we \
                retry but the counter doesn't reset so it counts twice, rolling back for now". The \
                hedges ("so i think", "what's happening is") are typed and then deleted, never \
                revised in place.

                The pattern holds across apps and audiences, which makes it a habit rather than a \
                register: the same delete-the-preamble move shows up in commit messages, in issue \
                comments, and in longer notes written in Obsidian.
                """,
                sourceRecordIds: [4821, 4822, 4830, 4844, 4851, 4877],
                existingSlug: nil
            ),
            WritingStyleStagedRow(
                id: 2, runId: demoWritingStyleRunId, createdAt: demoCompletedAt,
                action: .create,
                slug: "asks_land_as_offers",
                title: "Frames requests as offers rather than asks",
                body: """
                When Alex needs something from a teammate, the sentence almost never contains the \
                word "can you". Instead the ask is packaged as an offer to absorb the work: \
                "I can take the migration if you'd rather stay on the parser", "happy to write the \
                repro if that helps", "I'll draft something and you can tear it apart".

                This is consistent enough to be a voice marker, not politeness noise — across 11 \
                messages in this batch there is exactly one direct imperative, and it goes to a bot.

                The same construction disappears in code review, where the register flips to blunt \
                and declarative ("this allocates on every frame"). The softening is aimed at people's \
                time, not at their feelings.
                """,
                sourceRecordIds: [4835, 4841, 4858, 4860, 4869],
                existingSlug: nil
            ),
            WritingStyleStagedRow(
                id: 3, runId: demoWritingStyleRunId, createdAt: demoCompletedAt,
                action: .update,
                slug: "spanish_slips_in_when_delighted",
                title: "Spanish surfaces when delighted or exasperated, never when explaining",
                body: """
                Alex writes to colleagues in English, but the code-switch into Spanish is not random \
                — it tracks emotional peaks at both ends. Delight reads as "qué bueno, it finally \
                compiles" and "ya está"; exasperation as "otra vez" and "no me digas" muttered into \
                a commit message nobody was supposed to read.

                Explanatory writing stays monolingual. In the 34 records reviewed here, not one \
                design note, review comment, or documentation paragraph contains Spanish — the \
                switch only fires in reactions, and it fires within a second or two of the trigger, \
                with no backspacing.

                This run adds the exasperation half of the pattern; the earlier entry had only \
                captured the delight side.
                """,
                sourceRecordIds: [4826, 4839, 4862, 4871],
                existingSlug: "spanish_slips_in_when_delighted"
            ),
            WritingStyleStagedRow(
                id: 4, runId: demoWritingStyleRunId, createdAt: demoCompletedAt,
                action: .noop,
                slug: "terse_commit_subjects",
                title: "Commit subjects stay under fifty characters",
                body: """
                Nothing new this round. The existing entry already covers the habit, and the seven \
                commits in this batch all fit the pattern without adding nuance.
                """,
                sourceRecordIds: [4833, 4847],
                existingSlug: nil
            ),
        ]
    }

    /// 详情页 "N refs" 弹窗里的原文。真实链路是按 id 去 `writing_records` 捞,
    /// 在 dev mode 下那会把**真实的聊天记录**摆到演示视频里,所以这里也顶替掉。
    static func demoWritingRecords(ids: [Int64]) -> [WritingStyleRecordInput] {
        let all: [WritingStyleRecordInput] = [
            .init(id: 4821, startTs: demoStartedAt - 5_400_000, app: "Slack",
                  url: nil,
                  text: "Rolling this back — the retry loop double-counts on 429s.",
                  editLog: "[]", kind: "short_form",
                  contextSummary: "Replying in #backend after a deploy alert"),
            .init(id: 4826, startTs: demoStartedAt - 4_900_000, app: "Terminal",
                  url: nil,
                  text: "qué bueno, it finally compiles",
                  editLog: "[]", kind: "other",
                  contextSummary: "Typed into a commit message after a long build"),
            .init(id: 4835, startTs: demoStartedAt - 4_100_000, app: "Slack",
                  url: nil,
                  text: "I can take the migration if you'd rather stay on the parser",
                  editLog: "[]", kind: "short_form",
                  contextSummary: "DM with a teammate splitting up next sprint"),
            .init(id: 4844, startTs: demoStartedAt - 3_300_000, app: "Obsidian",
                  url: nil,
                  text: "The borrow checker isn't fighting me, it's telling me the lifetime is wrong.",
                  editLog: "[]", kind: "long_form",
                  contextSummary: "Evening note while learning Rust"),
            .init(id: 4862, startTs: demoStartedAt - 1_800_000, app: "Terminal",
                  url: nil,
                  text: "otra vez",
                  editLog: "[]", kind: "other",
                  contextSummary: "Commit message after the same test failed twice"),
        ]
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }
    }
}
