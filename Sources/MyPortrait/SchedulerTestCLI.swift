import Foundation

/// DEV-ONLY 测试入口：验证 MemoryScheduler 的崩溃恢复 / retry / dead_letter /
/// budget_deferred / 重置。配合真实 `kill -9` 使用。
///
/// 子命令（经 App.swift 的 args 分发）：
///   --sched-dump                       打印 processing_log 全表
///   --sched-lock <date|_distill_anchor> <stage>  持锁 + 标 in_progress + 起心跳，
///                                       然后永久 sleep（供 kill -9）
///   --sched-recover                    跑 recoverStaleLocks，再打印全表
///   --sched-reset <date|_distill_anchor>        手动重置该行，再打印
///   --sched-inject <date> <stage> <success|fail|budget>
///                                       注入结果跑真实 runStep（验 applyOutcome）
///   --sched-budget-strings             验 BudgetSignal.isExhausted 分类
///
/// stage ∈ raw|event|impact|distill。建议配 env
/// `MYPORTRAIT_SCHEDULER_STALE_MS=4000` 把死锁阈值压到 4s 方便测试。
@MainActor
enum SchedulerTestCLI {

    private static let store = ProcessingLogStore()

    /// ProcessingLogStore 走裸 sqlite3、不跑迁移。先构造一次 PortraitDBImpl 让
    /// GRDB 把 v1–v9 迁移（含 processing_log + retry_count）落地。
    private static func ensureMigrated() {
        _ = try? PortraitDBImpl()
    }

    // MARK: - dump

    static func dump() {
        ensureMigrated()
        printTable()
        exit(0)
    }

    private static func printTable() {
        let rows = store.allRows()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        print("=== processing_log (\(rows.count) row(s)) ===")
        if rows.isEmpty { print("(empty)") }
        for r in rows {
            let hbAge = r.heartbeatMs.map { "\((now - $0) / 1000)s" } ?? "-"
            print("""
            \(r.date)  raw=\(r.raw.rawValue) event=\(r.event.rawValue) \
            impact=\(r.impact.rawValue) distill=\(r.distill.rawValue)  \
            retry=\(r.retryCount)  lock=\(r.activeProcessor ?? "-")  hb_age=\(hbAge)
            """)
        }
        fflush(stdout)
    }

    private static func parseStage(_ s: String) -> ProcessingStage? {
        ProcessingStage(rawValue: s)
    }

    // MARK: - lock（供 kill -9）

    static func lock(date: String, stageStr: String) {
        ensureMigrated()
        guard let stage = parseStage(stageStr) else {
            FileHandle.standardError.write(Data("bad stage: \(stageStr)\n".utf8))
            exit(1)
        }
        _ = store.ensureRow(for: date)
        store.acquireLock(date: date, processor: stage.rawValue)
        store.setStatus(date: date, stage: stage, status: .inProgress)

        // event 步：造一个当天 event 文件，验证崩溃回滚会删掉它。
        if stage == .event, let day = ProcessingLogStore.day(from: date) {
            let dir = PortraitPaths.eventsDayDir(for: day)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dummy = dir.appendingPathComponent("_kill_test_dummy.md")
            try? "# kill-test dummy event\n".write(to: dummy, atomically: true, encoding: .utf8)
            print("created dummy event file: \(dummy.path)")
        }

        print("LOCKED date=\(date) stage=\(stage.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier) — heartbeating every 1s, sleeping (kill -9 me)")
        fflush(stdout)

        // 真实心跳：每 1s 刷一次。kill -9 后这个 Task 随进程一起死，心跳停。
        let hbStore = Self.store
        Task.detached {
            while true {
                _ = hbStore.heartbeat(date: date)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // 永久挂起，模拟一个正在干活的处理器。
        RunLoop.main.run()
    }

    // MARK: - recover

    static func recover() {
        ensureMigrated()
        print("=== running recoverStaleLocks ===")
        fflush(stdout)
        MemoryScheduler.shared.recoverStaleLocks()
        print("=== after recovery ===")
        printTable()
        exit(0)
    }

    // MARK: - reset

    static func reset(date: String) {
        ensureMigrated()
        print("=== resetDay(\(date)) ===")
        MemoryScheduler.shared.resetDay(date)
        printTable()
        exit(0)
    }

    // MARK: - inject（验 applyOutcome 分支）

    static func inject(date: String, stageStr: String, kindStr: String) {
        guard let stage = parseStage(stageStr) else {
            FileHandle.standardError.write(Data("bad stage: \(stageStr)\n".utf8))
            exit(1)
        }
        let kind: MemoryScheduler.InjectedResult
        switch kindStr {
        case "success": kind = .success
        case "fail":    kind = .failure
        case "budget":  kind = .budget
        default:
            FileHandle.standardError.write(Data("bad kind: \(kindStr) (success|fail|budget)\n".utf8))
            exit(1)
        }
        ensureMigrated()
        _ = store.ensureRow(for: date)
        print("=== inject \(kindStr) → \(date)/\(stage.rawValue) ===")
        fflush(stdout)

        final class Done: @unchecked Sendable { var flag = false }
        let done = Done()
        Task {
            await MemoryScheduler.shared.runInjectedStep(date: date, stage: stage, result: kind)
            done.flag = true
        }
        while !done.flag {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        printTable()
        exit(0)
    }

    // MARK: - 查询：daily job 是否还会处理这天

    static func wouldProcess(date: String) {
        ensureMigrated()
        let yes = MemoryScheduler.shared.wouldProcessInEventJob(date: date)
        print("wouldProcessInEventJob(\(date)) = \(yes)")
        exit(0)
    }

    // MARK: - shouldTriggerNow 频率矩阵（case G/H）

    static func triggerTest() {
        print("=== shouldTriggerNow 频率矩阵 ===")
        let cal = Calendar.current
        func mk(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        func cfg(_ f: SchedulerFrequency, _ t: String, dow: Int = 0, dom: Int = 1) -> SchedulerConfig {
            SchedulerConfig(frequency: f, timeOfDay: t, dayOfWeek: dow, dayOfMonth: dom)
        }
        var pass = true
        func check(_ desc: String, _ c: SchedulerConfig, _ now: Date, _ expect: Bool) {
            let got = MemoryScheduler.shouldTriggerNow(config: c, now: now)
            let ok = got == expect
            if !ok { pass = false }
            print("  [\(ok ? "PASS" : "FAIL")] \(desc) → \(got) (expect \(expect))")
        }

        // off —— case H：永不触发。
        check("off / 任意时刻", cfg(.off, "03:00"), mk(2026, 4, 15, 12, 0), false)

        // daily —— case G：portrait 切 daily 后每天到点触发。
        check("daily 03:00 / now 02:00 未到点", cfg(.daily, "03:00"), mk(2026, 4, 15, 2, 0), false)
        check("daily 03:00 / now 03:30 到点",   cfg(.daily, "03:00"), mk(2026, 4, 15, 3, 30), true)

        // weekly —— 按当天星期动态构造匹配 / 不匹配。
        let wed = mk(2026, 4, 15, 5, 0)
        let wd = cal.component(.weekday, from: wed) - 1
        check("weekly 匹配星期+到点",   cfg(.weekly, "04:00", dow: wd),           wed, true)
        check("weekly 不匹配星期",     cfg(.weekly, "04:00", dow: (wd + 1) % 7), wed, false)
        check("weekly 匹配星期未到点", cfg(.weekly, "04:00", dow: wd), mk(2026, 4, 15, 3, 0), false)

        // monthly + day-of-month edge case。
        check("monthly 15号 / 当天到点", cfg(.monthly, "06:00", dom: 15), mk(2026, 4, 15, 7, 0), true)
        check("monthly 15号 / 非当天",   cfg(.monthly, "06:00", dom: 15), mk(2026, 4, 14, 7, 0), false)
        check("monthly 31号 / 4月只有30天→落到30号", cfg(.monthly, "06:00", dom: 31), mk(2026, 4, 30, 7, 0), true)
        check("monthly 31号 / 4月29号不触发",        cfg(.monthly, "06:00", dom: 31), mk(2026, 4, 29, 7, 0), false)

        print(pass ? "RESULT: PASS — 所有频率分支判定正确"
                   : "RESULT: FAIL — 上面有误判")
        exit(pass ? 0 : 1)
    }

    // MARK: - budget 字符串分类

    static func budgetStrings() {
        print("=== BudgetSignal.isExhausted classification ===")
        let budget = [
            "HTTP 429 Too Many Requests",
            "You exceeded your current quota, please check your plan and billing details",
            "rate limit exceeded for this model",
            "insufficient_quota",
            "Usage limit reached for your organization",
        ]
        let nonBudget = [
            "401 Unauthorized: invalid api key",
            "connection timed out",
            "LLM response contained no JSON",
            "internal server error 500",
        ]
        var pass = true
        for m in budget {
            let ok = BudgetSignal.isExhausted(m)
            print("  [budget]     isExhausted=\(ok)  \"\(m)\"")
            if !ok { pass = false }
        }
        for m in nonBudget {
            let ok = BudgetSignal.isExhausted(m)
            print("  [non-budget] isExhausted=\(ok)  \"\(m)\"")
            if ok { pass = false }
        }
        print(pass ? "RESULT: PASS — all classified correctly"
                   : "RESULT: FAIL — misclassification above")
        exit(pass ? 0 : 1)
    }
}
