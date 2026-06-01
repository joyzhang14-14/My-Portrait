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
    你是"待办跟进"助手。每小时跑一次。

    **输入**:本 prompt 之前已经自动注入了"最近 1 小时活动"上下文(屏幕 OCR、转录、打字记录)。直接读它,不要再去 curl 任何 HTTP 端点。

    ## 第 1 步:读取已有 todo 文件

    读取 ~/.portrait/cron_jobs/follow-up-reminders/output/todos.md。文件不存在就当作全新开始。

    ## 第 2 步:从上下文里提取行动项

    扫上面注入的"最近 1 小时活动",找:
    - 我做出的承诺("我会发那个""我跟进一下"等)
    - 别人分配给我的任务
    - 提到的截止日期
    - 我还没回的消息
    - 失败/报错的任务(构建挂了、命令报错)

    **如果上下文为空 / 没有任何行动项,直接说"暂无新待办"并结束,不要更新文件,不要编造。**

    ## 第 3 步:更新 todo 文件

    写入 ~/.portrait/cron_jobs/follow-up-reminders/output/todos.md,Markdown 格式:

    ```markdown
    # Todo List
    Last updated: <时间戳>

    ## Urgent (do today)
    - [ ] Task — 出处:在哪/谁/什么时候

    ## This Week
    - [ ] Task — 出处

    ## Waiting on
    - [ ] Waiting on <人> — 何时回查

    ## Completed (last 3 days)
    - [x] Task — 完成于 <日期>
    ```

    **规则**:
    - 去重:同一任务不要重复列
    - 看到完成证据(邮件发了、回了消息、构建过了)→ 标完成
    - 7 天前的项移除
    - 不要编造、不要无中生有

    ## 第 4 步:通知规则(关键)

    **只在出现新的紧急(Urgent)待办时**,在回复**末尾**追加 `### Notify` 区块:

    ```
    ### Notify
    🔔 新待办:
    - <最紧急任务 1>
    - <最紧急任务 2>
    (共 N 项 urgent)
    ```

    **只是 This Week / Waiting on 类、或本次没有新增 urgent → 不要**写 `### Notify` 区块。系统会自动跳过通知,不打扰用户。

    不要把过程独白放进 Notify 区块。Notify 区块写完整 markdown,但保持简洁(≤5 行最佳)。
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
                        window: .lastHours(1),
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
