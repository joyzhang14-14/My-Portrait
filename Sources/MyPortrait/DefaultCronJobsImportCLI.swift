import Foundation

/// `--import-default-cron-jobs` — one-time entry point that seeds two built-in
/// cronJobs into CronJobStore (UserDefaults `MyPortrait.cronJobs.v1`).
///
/// Idempotent: cronJobs are matched by `name`, so re-running skips ones that
/// already exist. Prints what it did and exits.
enum DefaultCronJobsImportCLI {

    private static let obsidianPrompt = """
    每天晚上检查我的 Obsidian 仓库并执行 git commit + git push。

    要求:
    1. 自动定位并使用我当前的 Obsidian vault / git 仓库位置（环境变量 OBSIDIAN_VAULT_PATH 给出了路径,优先用它）。
    2. 先检查是否有未提交变更;如果没有,就简短说明今天没有变化并结束。
    3. 如果有变化,分析变更内容后生成一个准确、简洁的 commit message,明确描述本次修改了什么。
    4. 执行 git add -A、git commit、git push。
    5. 如果 push 失败,说明失败原因。
    6. 不要编造修改内容,commit message 必须基于真实 diff。
    7. 输出本次处理结果:是否有变更、commit message、push 是否成功。
    """

    private static let followupPrompt = """
    你是"待办跟进"助手。基于下面提供的"最近 1 小时活动"上下文,提取需要跟进的行动项:
    - 我做出的承诺（"我会发那个""我跟进一下"）
    - 分配给我的任务
    - 提到的截止日期
    - 我还没回的消息
    - 失败的任务（报错、构建挂掉）

    如果上下文里没有任何行动项,直接说"暂无新待办"并结束,不要编造。

    否则输出一个待办清单,按这四组分类:
    ## 紧急（今天做）
    ## 本周
    ## 等待中（等某人 → 何时回查）
    ## 已完成（最近 3 天)

    规则:同一任务不重复列;有完成证据的标完成;7 天前的项去掉。
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
