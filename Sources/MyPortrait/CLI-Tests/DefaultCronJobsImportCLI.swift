import Foundation

/// `--import-default-cron-jobs` — 一次性入口,把两个内置 cron job 写到
/// CronJobStore(对应 ~/.portrait/cron_jobs/ 里的两个目录)。
///
/// 幂等:按 `name` 去重,已存在则跳过。Prompts 是从 screenpipe 的两个真实
/// activated pipe(Obsidian-updater + todo-list-assistant)迁过来的,
/// todo 那个改成了用 My-Portrait 自带的 TimelineContext 注入
/// (`window: lastHours(1)`)而不是 screenpipe 的 localhost:3030 HTTP API。
enum DefaultCronJobsImportCLI {

    private static let obsidianPrompt = """
    每天晚上检查我的 Obsidian 仓库并执行 git commit + git push。

    要求:
    1. 用环境变量 OBSIDIAN_VAULT_PATH 定位 Obsidian vault / git 仓库位置(这是从 Settings → Connections → Obsidian 配的路径,会自动注入到环境变量里)。
    2. 先 cd 到该路径并执行 git status,检查是否有未提交变更;如果没有,简短说明今天没有变化并结束。
    3. 如果有变化,跑 git diff 看具体内容,生成准确、简洁的 commit message,明确描述本次修改了什么。
    4. 执行 git add -A、git commit -m "<message>"、git push。
    5. 如果 push 失败,说明失败原因(网络/凭证/冲突)。
    6. 不要编造修改内容,commit message 必须基于真实 diff。

    ## 通知规则(关键)

    **只在以下情况**,在你的回复**末尾**追加 `### Notify` 区块(1-3 行,直接说重点,中文):
    - ✅ 提交并 push 成功 → `### Notify\\n✅ pushed: <commit message>`
    - ❌ push 失败 → `### Notify\\n❌ push failed: <原因>`

    **今天没有变化** → **不要**写 `### Notify` 区块。系统会自动跳过通知,不打扰用户。

    不要把过程独白("我来检查一下...""现在让我...")放进 Notify 区块。
    """

    private static let followupPrompt = """
    你是"待办跟进"助手。每小时跑一次,目标是发现**用户自己可能忘了的承诺 / 跟进项 / 卡住的事**——
    不是复述他刚才做了什么。

    **输入**:本 prompt 前面已经自动注入了"最近 3 小时活动"上下文(屏幕 OCR、转录、打字记录),
    可以直接读。**如果近 3h 没什么信号、或你怀疑用户在跨日承诺上有遗漏**,主动调:
      - `mp-query memories --scope events --start "7d ago"` —— 翻这周的事件 .md(已 LLM 蒸馏 + 带 tag)
      - `mp-query writing --start "7d ago" --q "<关键词>"` —— 用户实际敲过的字,比 OCR 准
      - `mp-query memories --scope portrait` —— 长期画像,看用户在意什么 / 在跟谁打交道
      - `mp-query read --path events/<day>/<file>.md` —— 看具体某条事件的全文
    用这些去**关联**:今天的承诺 vs 上周说过但没做的;邮件里答应回复但没回的;构建挂着没修的。
    跨日/跨模态相关才是这个 cron 的价值。

    ## 第 1 步:读取已有 todo 文件

    读取 ~/.portrait/cron_jobs/follow-up-reminders/output/todos.md。文件不存在就当作全新开始。
    **必读** —— 决定第 4 步该不该 Notify 全靠它里面的 `notified` 字段。

    ## 第 2 步:扫描行动项

    先扫注入的"最近 3 小时活动",找:
    - 用户做出的承诺("我会发那个""我跟进一下""明天我回你"等)
    - 别人分配给用户的任务
    - 提到的截止日期 / deadline
    - 用户还没回的消息
    - 失败 / 报错的任务(构建挂了、命令报错)

    如果近 3h 信号薄,**再用 mp-query 往前翻 / 往 portrait 拉**(见上面"输入"段)。
    特别关注:**上周 todos.md 里仍 open 的 urgent**,这次跑该不该升级 / 推进 / 标完成。

    **如果上下文 + mp-query 都没找到任何行动项,直接说"暂无新待办"结束,不要更新文件,不要编造。**

    ## 第 3 步:更新 todo 文件

    写入 ~/.portrait/cron_jobs/follow-up-reminders/output/todos.md,Markdown 格式:

    ```markdown
    # Todo List
    Last updated: <ISO 时间戳>

    ## Urgent (do today)
    - [ ] Task — 出处:在哪/谁/什么时候 — notified: <ISO时间戳 或 空>

    ## This Week
    - [ ] Task — 出处

    ## Waiting on
    - [ ] Waiting on <人> — 何时回查

    ## Completed (last 3 days)
    - [x] Task — 完成于 <日期>
    ```

    **规则**:
    - 去重:同一任务不要重复列(同义合并:"发那份 doc 给 Sarah" = "把 doc 给 Sarah")
    - 看到完成证据(邮件发了、回了消息、构建过了、文件提交了)→ 标完成
    - 7 天前的项移除
    - 不要编造、不要无中生有
    - Urgent 项必须带 `notified` 字段(空 = 还没通知过用户)

    ## 第 4 步:通知规则(关键:防复弹)

    扫第 3 步写出来的 Urgent 列表,挑出**值得 Notify 的子集**:
      - `notified` 为**空** → 这是首次出现的 urgent,**值得 Notify**
      - `notified` 是 **24 小时前的时间戳** → 用户可能忘了,**值得 Notify**(再提一次)
      - `notified` 在 **24 小时内** → **不要 Notify**(刚提过,别打扰)

    **如果挑不出任何"值得 Notify"的项,不要写 `### Notify` 区块**(系统会跳过通知)。
    **如果有,在回复末尾追加**:

    ```
    ### Notify
    🔔 待跟进:
    - <最紧急 1>
    - <最紧急 2>
    (共 N 项)
    ```

    然后**把刚 Notify 的那些项的 `notified` 字段更新为当前 ISO 时间戳**,写回 todos.md
    (跟第 3 步是同一次写;别忘了)。

    不要把过程独白放进 Notify 区块。保持 ≤5 行。

    ## ⚠ 反模式

    - 别只看屏幕 OCR 就交差 —— mp-query 不用是浪费,跨日相关才是这个 cron 的价值
    - 别把 "用户 5 分钟前刚做的事" 当 urgent —— 那是他正在做,不是忘的事
    - 别在 24h 内对同一项重复 Notify
    - 别编造来源("出处:在某处" 是禁词,出处必须具体到 app/人/时间)
    """

    static func run() {
        MainActor.assumeIsolated {
            let store = CronJobStore.shared
            let existing = Set(store.cronJobs.map(\.name))

            let defaults: [CronJob] = [
                CronJob(name: "Obsidian Updater",
                        prompt: obsidianPrompt,
                        window: .none,
                        schedule: .dailyAt(hour: 21),
                        isEnabled: true,
                        connections: ["obsidian"]),
                CronJob(name: "Follow-up Reminders",
                        prompt: followupPrompt,
                        window: .lastHours(3),
                        schedule: .everyMinutes(60),
                        isEnabled: true,
                        connections: [])
            ]

            for cronJob in defaults {
                if existing.contains(cronJob.name) {
                    print("[import-default-cron-jobs] skip (exists): \(cronJob.name)")
                } else {
                    store.add(cronJob)
                    print("[import-default-cron-jobs] added: \(cronJob.name)")
                }
            }
        }
        exit(0)
    }
}
