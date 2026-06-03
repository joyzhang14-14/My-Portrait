import SwiftUI
import AppKit
import GRDB
import MLX
import os.log

@main
struct MyPortraitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // 数据路径迁移最先跑 —— CLI 模式也起 Services,所以放最前面,确保
        // 任何模式下读路径前都已经搬完。Idempotent,重复跑不出错。
        PathMigration.runOnceIfNeeded()

        // CLI 调试命令在任何 SwiftUI / AppDelegate 设置之前拦截，否则会被窗口初始化拖慢。
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--rebuild-frames-fts") {
            print("=== rebuild-frames-fts ===")
            fflush(stdout)
            let services = Services()
            services.startManagedLifecycle()
            EmbedDumpCLI.runRebuildFramesFts(services: services)
        }
        if args.contains("--embed-search-test") {
            print("=== embed-search-test ===")
            fflush(stdout)
            let services = Services()
            services.startManagedLifecycle()
            EmbedDumpCLI.runSearchTest(services: services)
        }
        // DEV-ONLY: `--event-prompt-test <yyyy-MM-dd>` validates the proposed
        // per-event clustering prompt against one day's data. stdout only,
        // writes nothing. Disposable — remove with EventPromptTest.swift.
        if let idx = args.firstIndex(of: "--event-prompt-test"), idx + 1 < args.count {
            EventPromptTestCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--voice-test <audio-file>` runs voice training embedding
        // extraction on a real audio file. Verifies the new embedding-based
        // VoiceTrainer end-to-end without mic / transcription / diarization.
        if let idx = args.firstIndex(of: "--voice-test"), idx + 1 < args.count {
            VoiceTrainingTestCLI.run(audioPath: args[idx + 1])
            // run() exits the process internally.
        }
        // 维护 CLI: `--retranscribe-qwen [--apply]` 用 Qwen 重转已有 wav 音频段 +
        // 重新匹配 speaker(只读评估)。默认 dry-run;--apply 只替换 text(先备份)。
        if args.contains("--retranscribe-qwen") {
            var lim: Int? = nil
            if let i = args.firstIndex(of: "--limit"), i + 1 < args.count { lim = Int(args[i + 1]) }
            RetranscribeQwenCLI.run(apply: args.contains("--apply"), limit: lim,
                                    speakerOnly: args.contains("--speaker-only"))
            // run() exits the process internally.
        }
        // 维护 CLI: `--rematch-speakers [--apply] [--limit N]` 先合并同名簇,再用新
        // best-of-N 对已有 wav 段重算 speaker_id(文字不动)。默认 dry-run;--apply 才写库。
        if args.contains("--rematch-speakers") {
            var lim: Int? = nil
            if let i = args.firstIndex(of: "--limit"), i + 1 < args.count { lim = Int(args[i + 1]) }
            RematchSpeakersCLI.run(apply: args.contains("--apply"), limit: lim)
            // run() exits the process internally.
        }
        // 维护 CLI: `--clean-voiceprints [--apply] [--threshold 0.5]` 对具名簇做 medoid
        // 剪枝去污(丢离群脏样本 + 重算质心)。默认 dry-run;--apply 前自动整表备份。
        if args.contains("--clean-voiceprints") {
            var thr: Float = 0.5
            if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count, let v = Float(args[i + 1]) { thr = v }
            CleanVoiceprintsCLI.run(apply: args.contains("--apply"), threshold: thr)
            // run() exits the process internally.
        }
        // 一次性数据修复:按声纹 cosine 整理被 bug 版本打乱的说话人簇。
        if args.contains("--fix-speakers") {
            FixSpeakersCLI.run()
            // run() exits the process internally.
        }
        // 纠正:把所有检测簇合并进训练的 Joy(确认这批数据基本全是本人时用)。
        if args.contains("--consolidate-joy") {
            FixSpeakersCLI.consolidateNoisyJoy()
            // 内部 exit。
        }
        // `mp-query` 给 AI agent 用的本地数据查询接口(端口自 screenpipe
        // SKILL.md REST API,改成 CLI + JSON stdout)。app 启动时会把自身
        // symlink 成 ~/.portrait/bin/mp-query,pi-coding-agent / Claude
        // Code agent 通过 bash 调用拿 OCR / 转录 / activity summary 数据。
        if args.contains("--mp-query") {
            let idx = args.firstIndex(of: "--mp-query")!
            let rest = Array(args.dropFirst(idx + 1))
            MPQueryCLI.run(args: rest)
            // run() exits the process internally.
        }
        // `mp-folders` —— chat AI 整理 event folder 的工具面。同 mp-query 模式
        // (shell wrapper 在 ~/.portrait/bin/ 下,exec 主二进制 + --mp-folders)。
        if args.contains("--mp-folders") {
            let idx = args.firstIndex(of: "--mp-folders")!
            let rest = Array(args.dropFirst(idx + 1))
            MPFoldersCLI.run(args: rest)
        }
        // DEV-ONLY: `--backfill-day <yyyy-MM-dd>` runs the real Backfill for a
        // single day. Disposable — remove with EventPromptTest.swift.
        if let idx = args.firstIndex(of: "--backfill-day"), idx + 1 < args.count {
            BackfillDayCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--backfill-days <N>` runs the real Backfill over the
        // last N days in one process.
        if let idx = args.firstIndex(of: "--backfill-days"), idx + 1 < args.count,
           let n = Int(args[idx + 1]) {
            BackfillDaysCLI.run(daysBack: n)
            // run() exits the process internally.
        }
        // DEV-ONLY: `--dump-day <yyyy-MM-dd>` exports one day's sessions as JSON.
        if let idx = args.firstIndex(of: "--dump-day"), idx + 1 < args.count {
            DumpDayCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--materialize-day <yyyy-MM-dd> <clustering.json>` writes
        // events from a subagent-produced clustering JSON.
        if let idx = args.firstIndex(of: "--materialize-day"), idx + 2 < args.count {
            MaterializeDayCLI.run(day: args[idx + 1], clusteringPath: args[idx + 2])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--dump-events-by-category` exports distill input buckets.
        if args.contains("--dump-events-by-category") {
            DumpEventsByCategoryCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--materialize-portrait <category> <decisions.json>`.
        if let idx = args.firstIndex(of: "--materialize-portrait"), idx + 2 < args.count {
            MaterializePortraitCLI.run(category: args[idx + 1], decisionsPath: args[idx + 2])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--dump-events-for-scoring` exports baseline-impact events.
        if args.contains("--dump-events-for-scoring") {
            DumpEventsForScoringCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--apply-scores <scores.json>` writes subagent scores back.
        if let idx = args.firstIndex(of: "--apply-scores"), idx + 1 < args.count {
            ApplyScoresCLI.run(scoresPath: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--rescore` runs ImpactScorer over every event file.
        if args.contains("--rescore") {
            RescoreCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--distill` runs the full PortraitDistiller pass.
        if args.contains("--distill") {
            DistillCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--personality-prompt-test <yyyy-MM-dd>` runs PersonalityAgent
        // on one day, prints prompt + raw + parsed snapshot. Writes nothing.
        if let idx = args.firstIndex(of: "--personality-prompt-test"), idx + 1 < args.count {
            PersonalityPromptTestCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--personality-merge-test <yyyy-MM-dd>` runs agent → snapshot
        // → PersonalityMerger.merge, prints actions. Writes nothing (dry-run).
        if let idx = args.firstIndex(of: "--personality-merge-test"), idx + 1 < args.count {
            PersonalityMergeTestCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--personality-merge-apply <yyyy-MM-dd>` runs merge AND
        // writes the resulting concepts into portrait/personality/.
        if let idx = args.firstIndex(of: "--personality-merge-apply"), idx + 1 < args.count {
            PersonalityMergeApplyCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--personality-refresh-apply <yyyy-MM-dd>` runs the full
        // 3-source(events + portraits + OCR) personality pipeline AND落盘。
        if let idx = args.firstIndex(of: "--personality-refresh-apply"), idx + 1 < args.count {
            PersonalityRefreshApplyCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // AI 聊天编辑工具面(--ai-* 子命令)。dispatcher 命中 → exit;
        // 不命中 → fall through。给 chat 里的 AI 通过 Bash 调用。
        AIEditCLI.dispatch(args: args)
        // DEV-ONLY: `--repair-portrait` re-reads + re-writes every portrait /
        // event .md to fix stale on-disk frontmatter formatting.
        if args.contains("--repair-portrait") {
            RepairPortraitCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--migrate-portrait-ema` one-time Phase 3 migration —
        // backup + reset every portrait file to the EMA clean baseline.
        if args.contains("--migrate-portrait-ema") {
            MigratePortraitEMACLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--drop-portrait-impact` one-time migration —
        // backup + scrub `impact` line from every portrait .md frontmatter.
        if args.contains("--drop-portrait-impact") {
            DropPortraitImpactCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--drop-portrait-impact-residue` —— strip the 3 remaining
        // event-only fields (raw_impact / rebalance_count / impact_source).
        if args.contains("--drop-portrait-impact-residue") {
            DropPortraitImpactResidueCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--wipe-personality-concepts` —— backup + wipe
        // portrait/personality/ + personality_daily/ for the new architecture.
        if args.contains("--wipe-personality-concepts") {
            WipePersonalityCLI.run()
        }
        // EventClassifier 自动分 folder 已下线 —— chat AI 通过 mp-folders
        // 按用户对话需求手动整理。--classify-dry-run / --classify-run dispatch
        // 也跟着删了。
        // `--import-default-cron-jobs` seeds the two built-in cronJobs into
        // CronJobStore. Idempotent (matches by name). Exits when done.
        if args.contains("--import-default-cron-jobs") {
            DefaultCronJobsImportCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: MemoryScheduler 崩溃恢复 / retry / dead_letter 测试入口。
        // 见 SchedulerTestCLI.swift。各子命令内部 exit；--sched-lock 永久挂起。
        if args.contains("--sched-dump") {
            SchedulerTestCLI.dump()
        }
        if let idx = args.firstIndex(of: "--sched-lock"), idx + 2 < args.count {
            SchedulerTestCLI.lock(date: args[idx + 1], stageStr: args[idx + 2])
        }
        if args.contains("--sched-recover") {
            SchedulerTestCLI.recover()
        }
        if let idx = args.firstIndex(of: "--sched-reset"), idx + 1 < args.count {
            SchedulerTestCLI.reset(date: args[idx + 1])
        }
        if let idx = args.firstIndex(of: "--sched-inject"), idx + 3 < args.count {
            SchedulerTestCLI.inject(date: args[idx + 1], stageStr: args[idx + 2], kindStr: args[idx + 3])
        }
        if args.contains("--sched-budget-strings") {
            SchedulerTestCLI.budgetStrings()
        }
        // DEV-ONLY: 跟 UI Run Events 按钮等价 —— 走 staging,跑完进 Pending
        // review,**不入库**;UI 用户 Approve / Reject 拍板。
        if args.contains("--event-staged") {
            EventJobStagedCLI.run()
        }
        if args.contains("--sched-trigger-test") {
            SchedulerTestCLI.triggerTest()
        }
        if let idx = args.firstIndex(of: "--sched-would-process"), idx + 1 < args.count {
            SchedulerTestCLI.wouldProcess(date: args[idx + 1])
        }
        // `--typing-observe` 只跑 TypingObserver（AX 订阅 + print 日志），
        // 不启动 capture / Memory pipeline / 不开窗口。AX 回调靠主 run loop，
        // 所以这里**不 exit()**：只置一个标志，AppDelegate 据此跳过
        // Services / 窗口创建，让 NSApplication run loop 继续活着。
        if args.contains("--typing-observe") {
            AppDelegate.typingObserveOnly = true
        }
        // `--typing-observe-m1` 只跑 KeystrokeLedger（Layer 1 dev tool）：
        // 不 init Services / UI / Capture / Memory；每秒 print 一次最近 5s
        // 内的击键时间戳分布；Ctrl+C → ledger.stop() + exit(0)。
        if args.contains("--typing-observe-m1") {
            KeystrokeLedgerCLI.run()
            // run() 内部进入 RunLoop，不会返回。
        }
        // `--typing-observe-m3` 只跑 TypingObserver 的 L1+L2 流水线（dev tool）：
        // 不 init Services / UI / Capture / Memory；每条 IMEFoldEvent print
        // 一行；Ctrl+C → observer.stop() + exit(0)。
        // 同 --typing-observe：AX 回调靠主 run loop，所以**不 exit()**，只置标志，
        // AppDelegate 据此跳过 Services / 窗口创建。
        if args.contains("--typing-observe-m3") {
            AppDelegate.typingObserveM3Only = true
        }
        // `--typing-observe-m4` 跑完整 typing observer（L1+L2+L3+L4），写库。
        // 与 m3 不同：M4 需要 DB —— AppDelegate 会开 PortraitDBImpl（跑 migration，
        // 含 v13 把旧 typing_events DROP 重建）。关键事件 print 到终端；
        // Ctrl+C → observer.stop()（flush 所有 in-progress record）+ exit(0)。
        if args.contains("--typing-observe-m4") {
            AppDelegate.typingObserveM4Only = true
        }
        // `--writing-capture-*` 写作采集 worker CLI 入口(UI Run now 的等价物)。
        // 内部跑完 → exit,不开窗口 / Services / capture。详见 WritingCaptureCLI。
        if args.contains("--writing-capture-list") {
            WritingCaptureCLI.list()
        }
        if let idx = args.firstIndex(of: "--writing-capture-approve"), idx + 1 < args.count {
            WritingCaptureCLI.approve(date: args[idx + 1])
        }
        if let idx = args.firstIndex(of: "--writing-capture-reject"), idx + 1 < args.count {
            WritingCaptureCLI.reject(date: args[idx + 1])
        }
        if args.contains("--writing-capture-run") {
            // 后面跟可选的日期 YYYY-MM-DD
            let idx = args.firstIndex(of: "--writing-capture-run")!
            let nextArg: String? = (idx + 1 < args.count) ? args[idx + 1] : nil
            // 简单格式校验:YYYY-MM-DD 长度 10 + 含 "-"
            let date: String? = {
                guard let s = nextArg, s.count == 10, s.contains("-") else { return nil }
                return s
            }()
            WritingCaptureCLI.run(specificDate: date)
        }
        // v27 backlog 模式:不按天分,cursor → 现在,全量跑一次
        // 注意:`--writing-capture-backlog-no-ax` 必须先匹配,否则会被
        // `--writing-capture-backlog` 误判。
        if args.contains("--writing-capture-backlog-no-ax") {
            WritingCaptureCLI.runBacklog(includeAxText: false)
        } else if args.contains("--writing-capture-backlog") {
            WritingCaptureCLI.runBacklog()
        }
        // 一次性 backfill:今日 Safari Google Doc 帧重跑 Vision OCR
        if args.contains("--reocr-google-docs-today") {
            ReOcrCLI.runGoogleDocsToday()
        }
        if args.contains("--reocr-google-docs-today-mp4") {
            ReOcrCLI.runGoogleDocsTodayMP4()
        }
        if args.contains("--writing-capture-backlog-approve") {
            WritingCaptureCLI.approveBacklog()
        }
        if args.contains("--writing-capture-backlog-reject") {
            WritingCaptureCLI.rejectBacklog()
        }
        // `--writing-style-*` 独立提炼链路 CLI 入口。详见 WritingStyleCLI。
        if args.contains("--writing-style-run") {
            let mode: WritingStyleMode = args.contains("--auto") ? .auto : .manual
            WritingStyleCLI.run(mode: mode)
        }
        if args.contains("--writing-style-list") {
            WritingStyleCLI.list()
        }
        if let idx = args.firstIndex(of: "--writing-style-approve"), idx + 1 < args.count {
            WritingStyleCLI.approve(runId: args[idx + 1])
        }
        if let idx = args.firstIndex(of: "--writing-style-reject"), idx + 1 < args.count {
            WritingStyleCLI.reject(runId: args[idx + 1])
        }
        // `--import-screenpipe [path]` 从 ~/.screenpipe 把历史 frames + audio
        // transcripts 搬到 My-Portrait,只导比当前最早数据老的部分。
        if let idx = args.firstIndex(of: "--import-screenpipe") {
            let nextArg: String? = (idx + 1 < args.count) ? args[idx + 1] : nil
            // 路径参数必须以 / 开头,否则当成 flag 而不是 path。
            let pathArg: String? = (nextArg?.hasPrefix("/") == true) ? nextArg : nil
            ScreenpipeImportCLI.run(sourcePath: pathArg)
        }
        // 一次性触发 PortraitWeight.refreshDistillCategories() —— 不调 LLM,
        // 只按当前公式重算 social/background/experiences/interests/skills/
        // emotions 下所有 .md 的 weight。writing_style 顺手刷一遍。
        if args.contains("--portrait-weight-refresh") {
            PortraitWeight.refreshDistillCategories()
            PortraitWeight.refreshWritingStyle()
            print("[portrait-weight] refreshed distill categories + writing_style")
            exit(0)
        }
        AppKeyboard.install()
    }

    var body: some Scene {
        // No WindowGroup — the AppDelegate creates the main window via
        // AppKit so SwiftUI doesn't insert any toolbar chrome of its own.
        // The `Settings` scene gives us the standard ⌘, → Settings flow
        // via the App menu without polluting the main sidebar.
        Settings {
            SettingsScene()
                .frame(minWidth: 880, minHeight: 580)
        }
    }
}

// MARK: - NSWindow subclass that refuses to ever have an NSToolbar

/// SwiftUI's NavigationSplitView keeps trying to install a sidebar-toggle
/// toolbar item, which forces an NSToolbar layer on the window. Overriding
/// the `toolbar` setter to no-op makes the window flat-out reject any
/// attempt to attach one. Combined with `.fullSizeContentView` + transparent
/// title bar, this leaves a single chrome layer: the title bar with the
/// traffic-light buttons floating over the content.
final class ChromelessWindow: NSWindow {
    // **`nonisolated` 是关键**：NSWindow.toolbar 在 SDK 里是 @MainActor 隔离的，
    // Swift 6 会在 override 的 getter 里插 `_checkExpectedExecutor`。但 macOS
    // 的 Accessibility 子系统（NSAccessibilityGetObjectForAttributeUsingLegacyAPI）
    // 会从**后台线程**调 `accessibilityChildrenAttribute` → 间接调这个 getter →
    // executor 检查发现不在 main → `dispatch_assert_queue_fail` 整进程崩。
    // getter 只返回常量 nil、setter 空体，不碰任何 actor 状态，标 nonisolated
    // 完全安全，且能让任意线程调用它而不触发 executor 断言。
    nonisolated override var toolbar: NSToolbar? {
        get { nil }
        set { /* refuse — keep nil forever */ }
    }
}

// MARK: - AppDelegate — owns the single app window

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: ChromelessWindow!
    var services: Services!
    var statusBarMenu: StatusBarMenu!

    /// `--typing-observe` CLI 模式标志。init() 里置位，launching 时分支。
    /// 仅在 App init（启动早期，单线程）写一次，之后只读 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) static var typingObserveOnly = false

    /// `--typing-observe-m3` CLI 模式标志。L1+L2 流水线 dev tool，每条
    /// IMEFoldEvent print 一行。仅启动早期写一次 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) static var typingObserveM3Only = false

    /// `--typing-observe-m4` CLI 模式标志。完整 L1+L2+L3+L4 流水线 dev tool，
    /// 写库。仅启动早期写一次 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) static var typingObserveM4Only = false

    /// `--typing-observe` 模式下持有的 observer（持有它以保证存活 + 退出时 stop）。
    private var typingObserver: TypingObserver?

    /// `--typing-observe-m4` 模式下持有的 DB 实现（持有它防 DatabasePool 释放）。
    private var m4DBImpl: PortraitDBImpl?

    /// SIGINT dispatch source —— 静态引用顶住生命周期，否则会被立即释放。
    /// 仅在 launching（MainActor）写一次 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) private static var sigintSource: DispatchSourceSignal?

    private let lifecycleLog = Logger(subsystem: "com.myportrait", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CLI 模式：只跑 TypingObserver 流水线，跳过 Services / 窗口创建。
        // 主 run loop 仍需活着（AX 回调靠它），所以不开窗口但不退出。
        // observe / m3 不写 DB；m4 跑完整流水线、写库。
        if Self.typingObserveOnly || Self.typingObserveM3Only || Self.typingObserveM4Only {
            NSApp.setActivationPolicy(.accessory)

            let observer: TypingObserver
            let modeName: String
            if Self.typingObserveM4Only {
                // M4 dev flag：完整 L1+L2+L3+L4，写库。先开 DB 跑 migration
                // （含 v13 —— 旧 typing_events 会被 DROP 重建）。
                let dbImpl: PortraitDBImpl
                do {
                    dbImpl = try PortraitDBImpl()
                } catch {
                    print("[m4] DB open failed: \(error)")
                    exit(1)
                }
                m4DBImpl = dbImpl  // 持有防 DatabasePool 释放
                observer = TypingObserver(
                    store: TypingEventStore(dbPool: dbImpl.dbPool),
                    keystrokeStore: KeystrokeStore(dbPool: dbImpl.dbPool),
                    modeLabel: "m4-dev")
                // M4 关键事件（burst / 跨记录 delete / flush）print 到终端。
                // 启动 banner 由 start() 自己 print，不走这里。
                observer.onDevLog = { print("[m4] \($0)") }
                modeName = "--typing-observe-m4"
            } else if Self.typingObserveM3Only {
                observer = TypingObserver(modeLabel: "m3-dev")
                // M3 dev flag：每条 IMEFoldEvent print 一行（dev tool 允许 print）。
                observer.onFoldEvent = { events in
                    for e in events {
                        print("[m3] \(e.kind) \"\(e.text)\" script=\(e.script) trace=\(e.traceTag?.description ?? "-")")
                    }
                }
                modeName = "--typing-observe-m3"
            } else {
                observer = TypingObserver(modeLabel: "observe-dev")
                modeName = "--typing-observe"
            }

            observer.start()
            typingObserver = observer
            // Ctrl+C → 走 stop() 清理路径再退出。SIGINT 在 main queue 上回调。
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            src.setEventHandler { [weak self] in
                self?.typingObserver?.stop()
                exit(0)
            }
            src.resume()
            signal(SIGINT, SIG_IGN)  // 默认 handler 终止进程，先忽略让 dispatch source 接管
            // 防 src 被释放：用 associated 静态引用顶住其生命周期。
            Self.sigintSource = src
            print("[TypingObserver] \(modeName) mode — press Ctrl+C to stop")
            return
        }

        // 1. 服务层先起（无 UI 依赖，可在权限请求前 init）
        services = Services()
        statusBarMenu = StatusBarMenu(settings: services.settings, permissions: services.permissions)
        // Sparkle:启动时实例化 controller(startingUpdater=true 自动开始
        // 后台检查 + 周期轮询)。引用单例让它持续活着。Info.plist 的
        // SUFeedURL / SUPublicEDKey 是 Sparkle 自己读的。
        _ = UpdaterService.shared

        // 确保磁盘目录结构存在
        do {
            try Storage.ensureExists()
        } catch {
            lifecycleLog.error("Storage.ensureExists failed: \(error.localizedDescription, privacy: .public)")
        }

        NSApp.setActivationPolicy(.regular)

        window = ChromelessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 835),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 500)
        // NSWindow 背景色跟随 system appearance(light/dark)。light 用接近
        // AmbientBackground 顶端的奶白,dark 仍是纯黑,避免 sidebar 出现一道
        // 跟其余视图不一致的色块。
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                ? NSColor(red: 0.97, green: 0.96, blue: 0.99, alpha: 1.0)
                : .black
        }
        // Explicit unhide — some macOS 26 chrome configurations hide these
        // by default when the title bar is transparent.
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        // 关掉 NSWindow 默认的 state restoration —— 用户上次手动 resize
        // 后,macOS 会偷偷把那个尺寸记下,下次启动 contentRect 被覆盖,
        // 看上去"初始窗口变大了"。关掉后每次启动都老老实实 1200×835。
        window.isRestorable = false
        window.setContentSize(NSSize(width: 1200, height: 835))

        // Host the SwiftUI ContentView inside the AppKit window.
        // Inject the Services container + captureSettings into the environment
        // so any descendant view can read \.services (db / coordinator / reporter)
        // or \.captureSettings (toggle bindings for the Settings UI).
        //
        // **不在这里钉 .preferredColorScheme(.dark)** —— 之前钉死的话 ContentView
        // 自己读 config.display.theme 设的 preferredColorScheme 会被外层这条
        // 盖掉,Settings 切 Light/Dark/System 跟没切一样。让 ContentView 决定。
        let hosting = NSHostingView(
            rootView: ContentView()
                .environment(\.services, services)
                .environment(\.captureSettings, services.settings)
                .environmentObject(services.settings)
        )
        hosting.autoresizingMask = [.width, .height]
        // Default sizingOptions let SwiftUI's intrinsic size feed back into the
        // window — when frames reload on a date switch the intrinsic size
        // transiently changes and the visible content "shrinks" vertically.
        // Empty options keeps the window size fixed regardless of content.
        hosting.sizingOptions = []
        window.contentView = hosting

        // 红绿灯关窗 = 只隐藏窗口（app 继续在后台跑采集 / 转录管线）。
        // 配合 applicationShouldTerminateAfterLastWindowClosed = false。
        window.isReleasedWhenClosed = false

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wire config → window/app chrome. Theme / always-on-top / app name
        // / Dock icon / launch-at-login all flow through this once ConfigStore
        // changes (vim edits or in-app toggles both fire the trampoline).
        ConfigApplier.shared.install(window: window, statusBar: statusBarMenu)
        // 自建造鱼通知:浮窗在首次 post 时懒装载,这里不用预先做任何事。
        // 不再用 UNUserNotificationCenter,所以也不需要请求系统权限。

        // 3. 启动 services 生命周期管理。
        //    - compactor / transcriber 立即开始（空转零成本）
        //    - coordinator / audio **由 settings 驱动**：默认开关都 OFF →
        //      首启不弹屏幕录制 / 麦克风权限。用户在 Settings 面板打开后才启。
        services.startManagedLifecycle()

        // 4. Full Disk Access 启动检查。FDA 没有 request API,只能 deep-link
        // 到 System Settings。第一轮 refresh 是同步的,刚才 startManagedLifecycle
        // 内部已经触发;直接读最新状态。用户主动 dismiss 过就不再 nag,直到
        // 重新启动 + 状态从未授权过(避免每次启动都打扰)。
        promptForFullDiskAccessIfNeeded()
    }

    /// 启动时如果 FDA 没授权,弹一个 NSAlert 引导用户去 System Settings 加
    /// 这个 app。**macOS 16 之后系统对 TCC 弹窗收紧**,不能 in-process 强弹
    /// 系统对话框,只能用我们自己的 NSAlert + deep link 跳过去。
    /// 用户点过「Don't ask again」就在 UserDefaults 记一笔,后续启动跳过;
    /// 但 PermissionMonitor 3 秒轮询仍然会更新状态,UI 侧的徽章能反映出来。
    /// `@MainActor` —— 内部全调 PermissionMonitor (@MainActor) +
    /// NSAlert / NSApp 的 main-actor-isolated API。
    @MainActor
    private func promptForFullDiskAccessIfNeeded() {
        guard services?.permissions.fullDiskAccess != .granted else { return }
        let kDismissedKey = "permissions.fullDiskAccess.promptDismissed"
        if UserDefaults.standard.bool(forKey: kDismissedKey) { return }

        let alert = NSAlert()
        alert.messageText = "Full Disk Access needed"
        alert.informativeText = """
        My Portrait reads files outside its sandbox (Mail, Safari, your \
        ~/Library data sources) to build a complete personal-memory index. \
        macOS requires Full Disk Access for this.

        Click Open Settings to add My Portrait to the list, then toggle it \
        on. You'll need to relaunch for the new permission to take effect.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Don't ask again")
        // 让弹窗回到主应用上下文 —— 否则 macOS 26 偶尔把它丢到后台。
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            services.permissions.openSettings(for: .fullDisk)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: kDismissedKey)
        default:
            break   // Later: 下次启动再问
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关窗不退出 —— 采集 / 转录在后台继续。退出走菜单栏 Quit (Cmd-Q)。
        false
    }

    /// 点 Dock 图标重新打开主窗口（窗口已隐藏时）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    /// 把主窗口拉到前台。菜单栏 "Open My Portrait" 和 Dock 重开都走这里。
    @objc func showMainWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // typing-observe / m3 / m4 模式：只需停 observer（m4 会 flush 所有
        // in-progress record 落库）。
        if Self.typingObserveOnly || Self.typingObserveM3Only || Self.typingObserveM4Only {
            typingObserver?.stop()
            return
        }
        // 进程退出前尽量优雅停止所有子系统（刷盘、关 SCStream、停 compaction、停录音）。
        // **两半分开**避免死锁:主线程那半(取消 task / 停 MainActor 监听)本就在主
        // 线程,直接同步跑;actor 那半放 detached task 等 —— 它们不碰主线程,主线程
        // 在 sem.wait 也不会跟它们死锁。
        //   (原来把整个 @MainActor 的 stopManagedLifecycle 丢进 detached task,要
        //    hop 回被 sem.wait 卡死的主线程 → 永远跑不完,清理白等 1s 一行没执行。)
        let services = self.services
        services?.stopMainActorParts()
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await services?.stopActorParts()
            sem.signal()
        }
        // 现在清理真会执行,给足时间刷盘/关流(仍远低于系统 ~5s 强杀兜底)。
        _ = sem.wait(timeout: .now() + 3.0)
    }
}

// MARK: - App-level keyboard monitor — broadcasts arrow keys via NotificationCenter

enum AppKeyboard {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            #if DEBUG
            print("[Keyboard] keyDown keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "")")
            #endif
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            let isAlt = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 123:    // LeftArrow
                NotificationCenter.default.post(name: .leftArrowPressed, object: isAlt)
                return nil
            case 124:    // RightArrow
                NotificationCenter.default.post(name: .rightArrowPressed, object: isAlt)
                return nil
            default:
                return event
            }
        }
    }
}

extension Notification.Name {
    static let leftArrowPressed = Notification.Name("MyPortrait.LeftArrow")
    static let rightArrowPressed = Notification.Name("MyPortrait.RightArrow")
}
