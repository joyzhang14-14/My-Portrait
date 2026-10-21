import Foundation
import GRDB
import ServiceManagement
import TOMLKit

/// Premium offload 的 CLI:
///   --premium-export                      先导入结果,再按全部已搬链导出并上传(不封区间、不看有没有新区间)
///   --premium-export --seal-check         helper(LaunchAgent)每个 :00 / :30 调:导入 → 封区间
///                                       检查 → 有链搬到 Premium、有新区间或积压、且连得上时导出、
///                                       上传;有事发生时追加一行到 <数据根>/logs/premium-export.log
///   --premium-export --dry-run-dir DIR --interval-from <ms> --interval-to <ms>
///   --premium-import                      下载并导入 Premium 上 done 的结果(导入失败过的也重试)
///   --premium-rollback <bundle_id>
///   --premium-selftest        封区间 / 台账 / 上传台账 / 导入 / 导出 / 判定逻辑在临时根目录上的集成自检
///                           (不碰真实数据,收件服务换成进程内的假服务)
///
/// 导出按各链 provider 算 pending(只导 provider 为 Premium 的链)。
/// `--dry-run-dir`:四条链都视为搬到 Premium,把 [from, to) 当作一个未处理的区间生成 v2
/// 测试包写进 DIR,不写台账、不上传;树镜像原样(这段已经产生的事件还在树里)。
/// 导出 / 导入 / 封区间与 app 之间靠交换锁(`.staging/premium.lock`)互斥;调度锁不跨进程,
/// 手动跑时最好先退出 app。
enum PremiumCLI {

    static func run(args: [String]) {
        Task { @MainActor in
            do {
                try await dispatch(args)
                exit(0)
            } catch {
                fputs("[premium] ERROR: \(error.localizedDescription)\n", stderr)
                if args.contains("--seal-check") { appendHelperLog("ERROR: \(error.localizedDescription)") }
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// helper 由 launchd 拉起,没有终端:结果追加到 `<数据根>/logs/premium-export.log`。
    private static func appendHelperLog(_ line: String) {
        let url = Storage.dailyLogsDir.appendingPathComponent("premium-export.log")
        try? FileManager.default.createDirectory(at: Storage.dailyLogsDir, withIntermediateDirectories: true)
        let data = Data("\(PremiumExchange.isoNow()) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private struct CLIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    private static func dispatch(_ args: [String]) async throws {
        if args.contains("--premium-selftest") {
            try await PremiumImportSelfTest.run()
            return
        }
        _ = ConfigStore.shared    // 先加载配置:上传请求带的名字读 ConfigStore.snapshot
        let db = try PortraitDBImpl()
        if args.contains("--premium-export") {
            if let dirArg = value(after: "--dry-run-dir", in: args) {
                guard let from = value(after: "--interval-from", in: args).flatMap({ Int64($0) }),
                      let to = value(after: "--interval-to", in: args).flatMap({ Int64($0) }), to > from else {
                    throw CLIError(message: "--dry-run-dir needs --interval-from <ms> --interval-to <ms> (to > from)")
                }
                let input = try PremiumExchangeExporter.gatherDryRunInput(dbPool: db.dbPool, fromMs: from, toMs: to)
                let parent = URL(fileURLWithPath: (dirArg as NSString).expandingTildeInPath, isDirectory: true)
                let pool = db.dbPool
                let dir = try await Task.detached {
                    try PremiumExchangeExporter.writeBundle(
                        input: input, bundleId: PremiumExchange.makeBundleId(),
                        root: Storage.rootURL, parentDir: parent, dbPool: pool)
                }.value
                let iv = input.pending.eventIntervals.first
                print("[premium-export] dry-run bundle: \(dir.path)")
                print("[premium-export] interval \(iv?.id ?? "?") · \(iv?.frameCount ?? 0) frame(s) · personality days \(input.pending.personalityDays) · chains \(input.chains)")
                print("[premium-export] tree mirror is the current tree: events this range already produced are still in it")
                return
            }
            if args.contains("--seal-check") {
                let r = await PremiumExchangeExporter.runSealCheck(dbPool: db.dbPool, lockWait: 600, importFirst: true)
                let sealed = r.sealed.map { "\($0.id) \($0.trigger) \($0.frameCount) frame(s)" }
                let export = r.export.map { e -> String in
                    if case .skipped(let why) = e { return "skipped: \(why)" }
                    return "\(e)"
                } ?? "off (no chain on Premium)"
                let line = "seal-check: sealed [\(sealed.joined(separator: ", "))] · export \(export)"
                print("[premium-export] \(line)")
                var quiet = r.sealed.isEmpty
                switch r.export {
                case .exported?: quiet = false
                case .skipped(let why)? where why != PremiumExchangeExporter.notDueReason: quiet = false
                default: break
                }
                if !quiet { appendHelperLog(line) }
                return
            }
            let r = await PremiumExchangeExporter.exportNow(dbPool: db.dbPool, lockWait: 600)
            print("[premium-export] \(r)")
            if case .skipped(let why) = r { throw CLIError(message: why) }
            return
        }
        if args.contains("--premium-import") {
            let (reports, failed) = await PremiumExchangeImporter.runIfNeeded(dbPool: db.dbPool, notify: false,
                                                                             retryFailed: true)
            if reports.isEmpty && failed == 0 { print("[premium-import] nothing imported") }
            for r in reports {
                print("[premium-import] \(r.bundleId) [\(r.status)] \(r.line)")
                for c in r.conflicts { print("  conflict: \(c)") }
            }
            if failed > 0 { throw CLIError(message: "\(failed) bundle(s) failed to import") }
            return
        }
        if let id = value(after: "--premium-rollback", in: args) {
            try PremiumExchangeImporter.rollback(bundleId: id, root: Storage.rootURL, dbPool: db.dbPool)
            print("[premium-rollback] restored trees + ledger rows from backup \(id)")
            return
        }
    }
}

/// 集成自检:临时根目录 + 临时库(跑完整迁移)。封区间规则各分支(纯函数)、区间台账
/// (T0 / 夜间 / 补漏 / Run now / 状态推进 / 退避)、personality 就绪(含同包区间)、v2 输入包与打包、
/// 上传台账(假收件服务:连不上照封不发、每日一次、上一个包没导入完不导出、拒收 / 404);再构造一个
/// 结果包(改一个文件 / 新增一个文件 / 一个冲突 / 一个删除 / 一份 db_ops),验证完整性判定、三方合并、
/// 快照、幂等、回滚、失败还原、重复结果不回退台账、下载核对与确认。
@MainActor
enum PremiumImportSelfTest {

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func write(_ s: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }

    private static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private static func count(_ pool: DatabasePool, _ sql: String) throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    /// `PremiumNightlyAgent.refresh` 跑在假的状态序列上:statuses 每读一次取下一个(读完停在最后
    /// 一个),probes 同理;记下对系统做了哪些操作。
    private static func checkAgentRefresh() async {
        typealias Agent = PremiumNightlyAgent
        final class Fake {
            var statuses: [SMAppService.Status]
            var probes: [Agent.ProbeOutcome]
            var registerErrors: [Int?]
            var calls: [String] = []
            init(_ statuses: [SMAppService.Status], _ probes: [Agent.ProbeOutcome], registerErrors: [Int?] = []) {
                self.statuses = statuses; self.probes = probes; self.registerErrors = registerErrors
            }
            func next<T>(_ list: inout [T]) -> T { list.count > 1 ? list.removeFirst() : list[0] }
        }
        func run(_ f: Fake, maxProbes: Int = 5) async -> Agent.RefreshResult {
            let ops = Agent.Ops(
                status: { f.next(&f.statuses) },
                unregister: { f.calls.append("unregister") },
                register: {
                    f.calls.append("register")
                    if !f.registerErrors.isEmpty, let code = f.next(&f.registerErrors) {
                        throw NSError(domain: "SMAppServiceErrorDomain", code: code)
                    }
                },
                probe: { let p = f.next(&f.probes); f.calls.append("probe:\(p)"); return p })
            return await Agent.refresh(ops, maxProbes: maxProbes)
        }

        var f = Fake([.enabled], [.killed, .configFailure, .ran])
        check(await run(f) == .done && f.calls == ["unregister", "register", "probe:killed",
                                                   "probe:configFailure", "unregister", "register", "probe:ran"],
              "stale launch constraint: killed → 78 → resubmit → helper runs")
        f = Fake([.enabled], [.ran])
        check(await run(f) == .done && f.calls == ["unregister", "register", "probe:ran"],
              "fresh BTM record: one probe")
        f = Fake([.notRegistered], [.ran])
        check(await run(f) == .done && f.calls == ["register", "probe:ran"], "not registered → register only, no unregister")
        f = Fake([.requiresApproval], [.ran])
        check(await run(f) == .userDisabled && f.calls.isEmpty,
              "turned off in Login Items → no unregister / register / probe")
        f = Fake([.notRegistered], [.ran], registerErrors: [Int(kSMErrorLaunchDeniedByUser)])
        check(await run(f) == .userDisabled && f.calls == ["register"], "register denied by user → stop, no probe")
        f = Fake([.enabled, .requiresApproval], [.ran])
        check(await run(f) == .userDisabled && f.calls == ["unregister", "register"],
              "needs approval after register → stop, no probe")
        f = Fake([.enabled], [.configFailure, .ran], registerErrors: [nil, Int(kSMErrorLaunchDeniedByUser)])
        check(await run(f) == .userDisabled && f.calls == ["unregister", "register", "probe:configFailure",
                                                           "unregister", "register"],
              "denied on resubmit → stop")
        f = Fake([.enabled], [.killed])
        check(await run(f, maxProbes: 3) == .failed("helper still failing after 3 probes")
              && f.calls.filter { $0.hasPrefix("probe") }.count == 3, "never recovers → failed after maxProbes")
        f = Fake([.enabled], [.noRun])
        check(await run(f) == .failed("no new run after kickstart"), "no new run → failed")
        f = Fake([.enabled], [.ran], registerErrors: [Int(kSMErrorInvalidSignature)])
        check(await run(f) == .failed("register threw code=\(kSMErrorInvalidSignature)") && f.calls == ["unregister", "register"],
              "other register error → failed")

        // launchctl print 解析:只认一个 tab 缩进的顶层行
        let killed = Agent.JobState(print: """
            gui/501/com.joyzhang.myportrait.premium-export = {
            \tstate = not running
            \tBTM uuid = 1F3C2492-BF0B-495F-B36A-53A776C421FB
            \truns = 1
            \tlast terminating signal = Killed: 9
            \tresource coalition = {
            \t\tstate = active
            \t}
            }
            """)
        check(killed.killed && killed.runs == 1 && !killed.running && killed.lastRunFailed
              && killed.btmUUID == "1F3C2492-BF0B-495F-B36A-53A776C421FB", "print parse: killed by signal 9")
        let config = Agent.JobState(print: "x = {\n\tstate = not running\n\truns = 3\n\tlast exit code = 78: EX_CONFIG\n}")
        check(config.lastExit == 78 && config.lastRunFailed && config.runs == 3, "print parse: exit 78")
        let running = Agent.JobState(print: "x = {\n\tstate = running\n\truns = 2\n\tpid = 28463\n\tlast exit code = 0\n}")
        check(running.running && running.lastExit == 0 && !running.lastRunFailed, "print parse: running, last exit 0")
        let never = Agent.JobState(print: "x = {\n\tstate = not running\n\truns = 0\n\tlast exit code = (never exited)\n}")
        check(never.lastExit == nil && !never.lastRunFailed, "print parse: never exited")
        let spawning = Agent.JobState(print: "x = {\n\tstate = xpcproxy\n\truns = 2\n\tpid = 60569\n\tlast terminating signal = Killed: 9\n}")
        check(spawning.killed && !spawning.running && !spawning.idle && !spawning.lastRunFailed,
              "print parse: xpcproxy carries the previous run's signal → not judged")
        let amfi = Agent.JobState(print: "x = {\n\tstate = not running\n\truns = 1\n\tlast exit reason = OS_REASON_CODESIGNING\n}")
        check(amfi.killed && amfi.idle && amfi.lastRunFailed,
              "print parse: first AMFI kill shows only exit reason CODESIGNING → killed")
    }

    /// 探针固定返回「有活」,只看链配置决定哪些字段进 pending;没搬的链不调探针。
    private static func checkPendingPerChain() {
        func settings(_ chains: [String], wsFreq: SchedulerFrequency = .daily) -> SchedulerSettings {
            var s = SchedulerSettings()
            s.event.frequency = .daily; s.portrait.frequency = .daily
            s.personality.frequency = .daily; s.writingStyle.frequency = wsFreq
            for (key, kp) in SchedulerSettings.offloadableChains where chains.contains(key) {
                s[keyPath: kp].providerId = Provider.premium.rawValue
                s[keyPath: kp].model = Provider.premium.defaultModel
            }
            return s
        }
        var probed: Set<String> = []
        var bundleIvs: Set<String>?
        func pending(_ s: SchedulerSettings) -> PremiumPending {
            probed = []
            bundleIvs = nil
            return PremiumExchangeExporter.computePending(
                s,
                eventIntervals: { probed.insert("event"); return [PremiumIntervalEntry(id: "iv:1")] },
                personalityDays: {
                    probed.insert("personality"); bundleIvs = $0
                    return [PremiumPersonalityDayEntry(day: "2026-01-02")]
                },
                portraitHasWork: { probed.insert("portrait"); return true },
                classifyHasWork: { probed.insert("classify"); return true },
                writingUnprocessed: { probed.insert("writing_style"); return 5 })
        }

        let none = pending(settings([]))
        check(none.isEmpty && probed.isEmpty && settings([]).offloadedChains.isEmpty,
              "no chain offloaded → empty pending, no probe")

        let ev = pending(settings(["event", "portrait"]))
        check(ev.eventIntervals.map(\.id) == ["iv:1"] && ev.classifyPending && ev.distillPending,
              "event + portrait offloaded → event intervals, classify, distill")
        check(ev.personalityDays.isEmpty && !ev.writingStyleEnabled && ev.writingRecordsUnprocessed == 0,
              "personality / writing style stay local → empty in pending")
        check(probed == ["event", "classify", "portrait"], "only offloaded chains probed")

        let pw = pending(settings(["personality", "writing_style"]))
        check(pw.eventIntervals.isEmpty && !pw.classifyPending && !pw.distillPending,
              "event local → no event intervals, classify false; portrait local → distill false")
        check(pw.personalityDays == ["2026-01-02"] && pw.personalityLog.map(\.day) == ["2026-01-02"]
              && pw.writingStyleEnabled && pw.writingRecordsUnprocessed == 5,
              "personality + writing style offloaded → personality days (+ log rows), writing records")
        check(bundleIvs == [], "event local → personality readiness gets no same-bundle intervals")
        _ = pending(settings(["event", "personality"]))
        check(bundleIvs == ["iv:1"], "event + personality offloaded → personality readiness counts this bundle's intervals")

        let wsOff = pending(settings(["writing_style"], wsFreq: .off))
        check(!wsOff.writingStyleEnabled && wsOff.writingRecordsUnprocessed == 0 && wsOff.isEmpty,
              "writing style offloaded but frequency off → nothing pending")

        let all = settings(["event", "portrait", "personality", "writing_style"])
        check(all.offloadedChains == ["event", "portrait", "personality", "writing_style"],
              "offloadedChains lists all four in config order")

        // —— 连上 Premium 全切 / 断开恢复 ——
        var moved = settings(["writing_style"])
        moved.event.providerId = Provider.deepseek.rawValue; moved.event.model = "deepseek-v4-pro"
        moved.portrait.providerId = Provider.ollama.rawValue; moved.portrait.model = "qwen3:8b"
        let saved = moved.moveAllToPremium()
        check(moved.offloadedChains.count == 4 && moved.event.model == Provider.premium.defaultModel,
              "Premium connect → all four chains on Premium")
        check(saved["event"]?.model == "deepseek-v4-pro" && saved["writing_style"]?.providerId == Provider.premium.rawValue,
              "Premium connect saves each chain's previous choice")
        moved.personality.providerId = Provider.chatgpt.rawValue     // 连上后手动改过
        moved.restoreFromPremium(saved) { $0 == .deepseek || $0 == .chatgpt }
        check(moved.event.providerId == Provider.deepseek.rawValue && moved.event.model == "deepseek-v4-pro",
              "Premium disconnect → chain back on its previous provider and model")
        check(moved.portrait.providerId.isEmpty && moved.portrait.model.isEmpty,
              "Premium disconnect → previous provider not connected → empty")
        check(moved.writingStyle.providerId.isEmpty, "Premium disconnect → chain that was on Premium before → empty")
        check(moved.personality.providerId == Provider.chatgpt.rawValue,
              "Premium disconnect → chain changed by hand after connect stays")
        var idle = SchedulerConfig()
        idle.providerId = "retired-provider"
        let unknownIdle = !MemoryScheduler.runsLocally(idle)
        idle.providerId = ""
        let emptyIdle = !MemoryScheduler.runsLocally(idle)
        check(unknownIdle && emptyIdle && !MemoryScheduler.runsLocally(moved.writingStyle),
              "chain with an unknown, empty or Premium provider doesn't run locally")
        var cfg = MyPortraitConfig()
        cfg.premium.previousProviders = saved
        let round = (try? TOMLEncoder().encode(cfg)).flatMap { try? TOMLDecoder().decode(MyPortraitConfig.self, from: $0) }
        check(round?.premium.previousProviders == saved, "previous_providers survives a TOML round trip")
        check(PremiumRemote.deviceId.count == 64 && PremiumRemote.deviceId == PremiumRemote.deviceId.lowercased(),
              "device id = sha256 hex of the hardware UUID")

        // —— pending 按 chains 过滤 ——
        let full = PremiumPending(eventIntervals: [PremiumIntervalEntry(id: "iv:1")], personalityDays: ["d2"],
                                distillPending: true, classifyPending: true, writingStyleEnabled: true,
                                writingRecordsUnprocessed: 3,
                                personalityLog: [PremiumPersonalityDayEntry(day: "d2")])
        check(full.chainsWithWork == ["event", "portrait", "personality", "writing_style"],
              "chainsWithWork in event → portrait → personality → writing_style order")
        let onlyP = full.only(["portrait"])
        check(onlyP.distillPending && onlyP.eventIntervals.isEmpty && !onlyP.classifyPending
              && onlyP.personalityDays.isEmpty && onlyP.personalityLog.isEmpty && !onlyP.writingStyleEnabled
              && onlyP.writingRecordsUnprocessed == 0 && onlyP.chainsWithWork == ["portrait"],
              "only([portrait]) blanks the other chains")
        let onlyE = full.only(["event", "writing_style"])
        check(onlyE.eventIntervals.map(\.id) == ["iv:1"] && onlyE.classifyPending && !onlyE.distillPending
              && onlyE.writingStyleEnabled && onlyE.writingRecordsUnprocessed == 3,
              "only([event, writing_style]) keeps classify with event")
        let wsIdle = PremiumPending(eventIntervals: [], personalityDays: [], distillPending: true,
                                  classifyPending: false, writingStyleEnabled: true,
                                  writingRecordsUnprocessed: 0)
        check(wsIdle.chainsWithWork == ["portrait"] && !wsIdle.only(wsIdle.chainsWithWork).writingStyleEnabled,
              "nightly: writing style on but 0 records → not in chains, flag cleared")
    }

    /// 封区间规则各分支(纯函数,不碰 DB)。
    private static func checkSegmenter() {
        typealias S = IntervalSegmenter
        typealias Fr = IntervalSegmenter.Frame
        let m: Int64 = 60_000, h: Int64 = 3_600_000
        let base: Int64 = 1_800_000_000_000
        var nextId: Int64 = 0
        func frames(_ from: Int64, _ to: Int64, every: Int64, active: Bool) -> [Fr] {
            stride(from: from, through: to, by: Int(every)).map { t -> Fr in
                nextId += 1
                return Fr(id: nextId, ts: t, nonIdle: active)
            }
        }
        let work = frames(base + h, base + 10 * h, every: 2 * m, active: true)
        let idleTail = frames(base + 10 * h + 30_000, base + 10 * h + 30 * m, every: 30_000, active: false)
        let lastActive = base + 10 * h

        // 离开 1h50m:不封。
        check(S.gapCuts(frames: work + idleTail, lastCut: base, nowMs: lastActive + 110 * m).isEmpty,
              "segmenter: 1h50m since last active frame → no cut")
        // 离开满 2h,屏幕 30 分钟后熄:截止点 = 最后一个 idle 帧 +1ms(第一个 ≥5 min 全帧空档)。
        let nowA = lastActive + 2 * h
        check(S.gapCuts(frames: work + idleTail, lastCut: base, nowMs: nowA) == [lastActive + 30 * m + 1],
              "segmenter: ongoing gap reaches 2h → cut at start of first ≥5 min all-frame gap")
        // 屏幕常亮,idle 帧一直到现在:没有全帧空档 → 最后一个非空转帧 +1ms。
        let screenOn = frames(lastActive + 30_000, nowA - 30_000, every: 30_000, active: false)
        check(S.gapCuts(frames: work + screenOn, lastCut: base, nowMs: nowA) == [lastActive + 1],
              "segmenter: idle frames until now → cut after last active frame")
        // 屏幕 7 分钟前才熄:那个空档起点晚于 now − 10 min,不用 → 最后一个非空转帧 +1ms。
        let lateOff = frames(lastActive + 30_000, nowA - 7 * m, every: 30_000, active: false)
        check(S.gapCuts(frames: work + lateOff, lastCut: base, nowMs: nowA) == [lastActive + 1],
              "segmenter: quiet gap newer than now − 10 min is not used")
        // 白天:10:00 离开 2.5h 又回来、17:00 离开 3h 又回来,一次检查按时间顺序封两个区间;
        // 1h50m 的空档不切;回来之后才 5 分钟,不封第三个。
        let day2 = frames(lastActive + 150 * m, lastActive + 7 * h, every: 2 * m, active: true)
        let short = frames(lastActive + 7 * h + 110 * m, lastActive + 9 * h, every: 2 * m, active: true)
        let day3 = frames(lastActive + 12 * h, lastActive + 13 * h, every: 2 * m, active: true)
        let busy = work + idleTail + day2 + short + day3
        let nowD = lastActive + 13 * h + 5 * m
        let cutsD = S.gapCuts(frames: busy, lastCut: base, nowMs: nowD)
        check(cutsD == [lastActive + 30 * m + 1, lastActive + 9 * h + 1],
              "segmenter: one check seals every closed ≥2h gap in order, daytime gaps too, 1h50m gap not cut")
        // 与检查时刻无关:晚一天再查,已结束空档的截止点不变,只多出现在进行中的那个。
        let later = S.gapCuts(frames: busy, lastCut: base, nowMs: nowD + 24 * h)
        check(later == cutsD + [lastActive + 13 * h + 1],
              "segmenter: cuts depend only on frame history, not on when the check runs")
        // 上一截止点刚封过,下一个 2h 空档照封。
        check(S.gapCuts(frames: busy, lastCut: cutsD[0], nowMs: nowD) == [cutsD[1]],
              "segmenter: a fresh cut does not hold back the next — the following 2h gap is sealed")
        // 上一截止点之后只有 idle 帧 / 什么都没有:不封。
        check(S.gapCuts(frames: idleTail, lastCut: base, nowMs: nowA).isEmpty,
              "segmenter: only idle frames since last cut → no cut")
        check(S.gapCuts(frames: work, lastCut: lastActive + 1, nowMs: nowA).isEmpty,
              "segmenter: frames before last cut are ignored")
        // Run now / 补漏。
        check(S.runNowCut(lastCut: base, nowMs: base + 2 * m) == base + m
              && S.runNowCut(lastCut: base + 2 * m, nowMs: base + 2 * m + 30_000) == nil,
              "segmenter: run-now cut = now − 60 s, only after last cut")
        let bf = S.backfillRange([Fr(id: 9, ts: 5, nonIdle: true), Fr(id: 7, ts: 3, nonIdle: false)])
        check(bf?.start == 3 && bf?.end == 6 && bf?.maxId == 9 && S.backfillRange([]) == nil,
              "segmenter: backfill range = [earliest, latest + 1ms), max frame id")
        // T0。
        let iso = ISO8601DateFormatter()
        func ms(_ s: String) -> Int64 { Int64(iso.date(from: s)!.timeIntervalSince1970 * 1000) }
        check(S.originCut(days: [("2026-01-02", true), ("2026-01-01", true)], firstFrameMs: nil, nowMs: 0)
              == ms("2026-01-03T00:00:00Z"), "T0: all complete → end of the last day")
        check(S.originCut(days: [("2026-01-01", true), ("2026-01-02", false), ("2026-01-03", true)],
                          firstFrameMs: nil, nowMs: 0) == ms("2026-01-02T00:00:00Z"),
              "T0: first day not complete → its start")
        check(S.originCut(days: [], firstFrameMs: ms("2026-01-05T13:00:00Z"), nowMs: 0) == ms("2026-01-05T00:00:00Z")
              && S.originCut(days: [], firstFrameMs: nil, nowMs: 42) == 42,
              "T0: no day rows → start of first frame's UTC day, or now")
        // 本地日(钉死偏移)。
        check(S.localDay(ms("2026-09-22T06:59:00Z"), tzOffsetMin: -420) == "2026-09-21"
              && S.localDay(ms("2026-09-22T07:00:00Z"), tzOffsetMin: -420) == "2026-09-22",
              "local day follows the pinned offset")
        let w = S.dayWindow("2026-09-22", tzOffsetMin: -420)
        check(w?.start == ms("2026-09-22T07:00:00Z") && w?.end == ms("2026-09-23T07:00:00Z"),
              "day window = local [00:00, 24:00)")
        check(S.touchedDays(startMs: ms("2026-09-21T20:00:00Z"), endMs: ms("2026-09-23T08:00:00Z"), tzOffsetMin: -420)
              == ["2026-09-21", "2026-09-22", "2026-09-23"], "touched local days")
        let d1 = ms("2026-01-01T22:00:00Z"), d2 = ms("2026-01-02T01:00:00Z")
        check(S.attributeDay(frameTs: [d1, d1 + m, d1 + 2 * m, d2, d2 + m], spans: [(d1, d2 + m)], tzOffsetMin: 0)
              == "2026-01-01", "attribute day: more frames wins")
        let f1 = ms("2026-01-01T23:30:00Z")
        check(S.attributeDay(frameTs: [f1, f1 + m, d2, d2 + m], spans: [(f1, d2 + m)], tzOffsetMin: 0)
              == "2026-01-02", "attribute day: tie → longer share of the span wins")
        let e1 = ms("2026-01-01T23:00:00Z"), e2 = ms("2026-01-02T01:00:00Z")
        check(S.attributeDay(frameTs: [e1, e2], spans: [(e1, e2)], tzOffsetMin: 0) == "2026-01-01",
              "attribute day: full tie → the day it starts")
        // 切断统计。
        check(S.cutsSession(base, nonIdleTs: [base - 2 * m, base + 2 * m])
              && !S.cutsSession(base, nonIdleTs: [base - 2 * m])
              && !S.cutsSession(base, nonIdleTs: [base - 6 * m, base + 2 * m]),
              "session cut = active frames within 5 min on both sides")
    }

    /// 进程内的假收件服务:记下收到的包、按 `statuses` 回状态、按 `results` 给结果。
    final class FakePremium: PremiumRemote.Transport, @unchecked Sendable {
        var reachable = true
        var rejectNextUpload: Int?
        var uploads: [String: Data] = [:]
        var statuses: [String: PremiumRemote.BundleStatus] = [:]
        var results: [String: Data] = [:]
        var acked: [String] = []

        func health() async throws {
            guard reachable else { throw PremiumRemote.RemoteError(message: "offline") }
        }
        func me() async throws -> PremiumRemote.Me {
            try await health()
            return PremiumRemote.Me(user: "Selftest", bundles: Array(statuses.values))
        }
        func upload(bundleId: String, file: URL, sha256: String) async throws -> PremiumRemote.BundleStatus {
            try await health()
            if let code = rejectNextUpload {
                rejectNextUpload = nil
                throw PremiumRemote.RemoteError(message: "rejected", code: code)
            }
            let data = try Data(contentsOf: file)
            guard PremiumExchange.sha256Hex(data) == sha256 else {
                throw PremiumRemote.RemoteError(message: "sha mismatch", code: 400)
            }
            uploads[bundleId] = data
            let st = PremiumRemote.BundleStatus(bundleId: bundleId, status: "queued", ahead: 0)
            statuses[bundleId] = st
            return st
        }
        func status(bundleId: String) async throws -> PremiumRemote.BundleStatus {
            try await health()
            guard let st = statuses[bundleId] else { throw PremiumRemote.RemoteError(message: "没有这个包", code: 404) }
            return st
        }
        func download(bundleId: String, to: URL) async throws -> String {
            try await health()
            guard let d = results[bundleId] else { throw PremiumRemote.RemoteError(message: "no result", code: 409) }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: to)
            return PremiumExchange.sha256Hex(d)
        }
        func ack(bundleId: String) async throws {
            try await health()
            acked.append(bundleId)
        }
    }

    /// 发包时机、一包一天、在路上的区间、交换锁。
    private static func checkExportRules(tmp: URL) async throws {
        typealias E = PremiumExchangeExporter
        typealias R = PremiumRemote

        // 发包时机:上次发包之后又封了区间,或 event 链还有没发出去的区间。
        check(E.exportDue(lastCut: 100, lastExportCutMs: nil, pendingIntervals: 0)
              && E.exportDue(lastCut: 200, lastExportCutMs: 100, pendingIntervals: 0),
              "export due: an interval was sealed since the last upload")
        check(!E.exportDue(lastCut: 100, lastExportCutMs: 100, pendingIntervals: 0)
              && !E.exportDue(lastCut: nil, lastExportCutMs: nil, pendingIntervals: 0),
              "export not due: nothing sealed since the last upload")
        check(E.exportDue(lastCut: 100, lastExportCutMs: 100, pendingIntervals: 3),
              "export due: event intervals not sent yet (backlog sent in batches)")

        // 一个包最多一天的区间:从最早的区间开始 24 小时内开始的。
        let day: Int64 = 86_400_000
        let ivs = [0, day / 2, day - 1, day, 3 * day].enumerated().map {
            PremiumIntervalEntry(id: "iv:\($0.offset)", startMs: Int64($0.element))
        }
        check(E.oneDayOfIntervals(ivs).map(\.id) == ["iv:0", "iv:1", "iv:2"]
              && E.oneDayOfIntervals(Array(ivs.suffix(1))).map(\.id) == ["iv:4"]
              && E.oneDayOfIntervals([]).isEmpty,
              "bundle holds at most one day of intervals, oldest first, at least one")

        // 在路上的区间不再发;导入一个包时连同并进它的包一起删。
        var st = R.State()
        st.uploads = [
            R.Upload(bundleId: "b0", trigger: "nightly", chains: ["event"], createdAt: "", status: "merged", intervals: ["iv:0"]),
            R.Upload(bundleId: "b1", trigger: "nightly", chains: ["event"], createdAt: "", status: "queued", intervals: ["iv:1"]),
            R.Upload(bundleId: "bf", trigger: "nightly", chains: ["event"], createdAt: "", status: R.statusImportFailed,
                     intervals: ["iv:9"]),
        ]
        st.uploads[0].mergedInto = "b1"
        check(st.sentIntervals == ["iv:0", "iv:1"], "in flight: queued and merged bundles' intervals, not import_failed")
        st.drop("b1")
        check(st.uploads.map(\.bundleId) == ["bf"], "importing a bundle drops it and the bundles merged into it")

        let lockRoot = tmp.appendingPathComponent("lockroot", isDirectory: true)
        let l1 = await PremiumExchange.FileLock.acquire(root: lockRoot, wait: 0)
        let l2 = await PremiumExchange.FileLock.acquire(root: lockRoot, wait: 0)
        check(l1 != nil && l2 == nil, "exchange lock: second holder is refused")
        l1?.release()
        let l3 = await PremiumExchange.FileLock.acquire(root: lockRoot, wait: 0)
        check(l3 != nil, "exchange lock: free again after release")
        l3?.release()
    }

    /// 封区间检查 + 上传,收件服务换成 `FakePremium`:连不上时区间照封、不打包;没有新东西不发;
    /// 连上且有新区间时打包,台账记 pending_upload 和包里的区间,`flushUploads` 传上去;前一个包还在排队时
    /// 新封的区间照发(只带新的);服务端合并的包跟着结果走;服务端拒收的包删掉;网络错误留着下次重传。
    private static func checkUploadGate(tmp: URL) async throws {
        typealias E = PremiumExchangeExporter
        typealias R = PremiumRemote
        let fake = FakePremium()
        R.transportOverride = fake
        defer { R.transportOverride = nil }
        let cfg = PremiumConfig()

        let pool = try PortraitDBImpl(path: tmp.appendingPathComponent("reach.sqlite").path).dbPool
        let store = EventIntervalStore(dbPool: pool)
        let m: Int64 = 60_000, h: Int64 = 3_600_000
        let t0 = Int64(ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!.timeIntervalSince1970 * 1000)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO processing_log (date, raw_status, event_status, impact_status, updated_at_ms)
                VALUES ('2026-01-01', 'complete', 'complete', 'complete', 0)
                """)
            for t in stride(from: t0 + h, through: t0 + 10 * h, by: Int(5 * m)) {
                try db.execute(sql: """
                    INSERT INTO frames (timestamp_ms, app_name, snapshot_path, capture_trigger, full_text, created_at_ms)
                    VALUES (:t, 'App', 'x.jpg', 'click', 'text', :t)
                    """, arguments: ["t": t])
            }
            for t in stride(from: t0 + 16 * h, through: t0 + 18 * h, by: Int(5 * m)) {   // 空档之后又一段
                try db.execute(sql: """
                    INSERT INTO frames (timestamp_ms, app_name, snapshot_path, capture_trigger, full_text, created_at_ms)
                    VALUES (:t, 'App', 'x.jpg', 'click', 'text', :t)
                    """, arguments: ["t": t])
            }
        }
        let root = tmp.appendingPathComponent("reach-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var writes = 0
        func round(_ nowMs: Int64, due: Bool = true) async -> E.SealCheckResult {
            let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
            return await E.sealThenExport(
                seal: { try store.sealCheck(now: now, tzOffsetMin: 0) }, due: { due }, offloaded: true,
                unreachable: { await R.unreachableReason(cfg) },
                write: {
                    writes += 1
                    do {
                        let sent = R.readState(root).sentIntervals          // 同 pendingNow:在路上的不再发
                        let ivs = try store.needsWork().filter { !sent.contains($0.id) }.map(PremiumIntervalEntry.init)
                        let input = E.Input(
                            chains: ["event"],
                            pending: PremiumPending(eventIntervals: ivs,
                                                  personalityDays: [], distillPending: false, classifyPending: false,
                                                  writingStyleEnabled: false, writingRecordsUnprocessed: 0),
                            processingLog: [], aboutUserBlock: "", params: selftestParams, appVersion: "selftest")
                        let r = try E.packageForUpload(input: input, root: root, dbPool: pool)
                        if case .exported(let id, _) = r {
                            R.updateState(root) { s in
                                s.uploads.append(.init(bundleId: id, trigger: "nightly", chains: ["event"],
                                                       createdAt: "", status: R.statusPendingUpload,
                                                       intervals: ivs.map(\.id)))
                            }
                        }
                        return r
                    } catch { return .skipped("export failed: \(error)") }
                })
        }
        func skipped(_ r: E.SealCheckResult) -> String? {
            if case .skipped(let why)? = r.export { return why }
            return nil
        }

        fake.reachable = false
        let r1 = await round(t0 + 14 * h + m)
        let sealedId = r1.sealed.first?.id ?? "?"
        let ledgerIds = try store.needsWork().map(\.id)
        check(r1.sealed.count == 1 && r1.sealed.first?.trigger == "gap" && ledgerIds == [sealedId],
              "seal check, Premium not reachable: gap interval still sealed into the ledger")
        check(skipped(r1) == "Premium not reachable (offline)" && writes == 0,
              "seal check, Premium not reachable: export skipped with the reason, nothing packed")
        fake.reachable = true
        let r2 = await round(t0 + 14 * h + 31 * m, due: false)
        check(skipped(r2) == E.notDueReason && writes == 0, "seal check, nothing new since the last upload: not packed")
        let r3 = await round(t0 + 15 * h)
        var packed = "", manifestOK = false
        if case .exported(let id, let archive)? = r3.export {
            packed = id
            let dir = tmp.appendingPathComponent("unpacked-\(id)", isDirectory: true)
            try R.unpack(archive, into: dir)
            if let man = try? JSONDecoder().decode(PremiumBundleManifest.self,
                                                   from: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) {
                let framesRel = "frames/\(sealedId).jsonl"
                manifestOK = man.pending.eventIntervals.map(\.id) == [sealedId] && PremiumExchange.isDone(dir)
                    && man.files[framesRel] == PremiumExchange.fileSHA(dir.appendingPathComponent(framesRel))
                    && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("RUN_NOW").path)
            }
        }
        check(writes == 1 && manifestOK && !FileManager.default.fileExists(
                atPath: R.uploadDir(root).appendingPathComponent(packed).path),
              "seal check, reachable and due: packed as tar.gz (interval, DONE, frame hashes), bundle dir removed")
        check(packed.split(separator: "-").last?.count == 8, "bundle id carries an 8-char random suffix")
        check(R.readState(root).uploads.first?.status == R.statusPendingUpload
              && R.readState(root).sentIntervals == [sealedId], "ledger: pending_upload with its interval before the upload")

        fake.reachable = false
        await R.flushUploads(root: root, cfg: cfg)
        check(R.readState(root).uploads.first?.status == R.statusPendingUpload
              && FileManager.default.fileExists(atPath: R.archiveURL(root, packed).path),
              "upload while offline: stays pending, archive kept for the retry")
        fake.reachable = true
        await R.flushUploads(root: root, cfg: cfg)
        check(fake.uploads[packed] != nil && R.readState(root).uploads.first?.status == "queued"
              && !FileManager.default.fileExists(atPath: R.archiveURL(root, packed).path),
              "upload: server got the archive, ledger → queued, local archive removed")
        let r4 = await round(t0 + 20 * h + m)
        var second = ""
        if case .exported(let id, _)? = r4.export { second = id }
        let secondIvs = R.readState(root).uploads.first { $0.bundleId == second }?.intervals ?? []
        check(writes == 2 && r4.sealed.count == 1 && secondIvs == r4.sealed.map(\.id) && !secondIvs.contains(sealedId),
              "earlier bundle still queued: the newly sealed interval goes out in its own bundle, the sent one is not resent")

        fake.statuses[packed]?.status = "running"
        fake.statuses[packed]?.stage = "event:\(sealedId)"
        await R.refresh(root: root, cfg: cfg)
        let ran = R.readState(root).uploads.first { $0.bundleId == packed }
        check(ran?.status == "running" && ran?.stage == "event:\(sealedId)",
              "refresh: server status and stage copied into the ledger")
        await R.flushUploads(root: root, cfg: cfg)
        fake.statuses[packed]?.status = "merged"
        fake.statuses[packed]?.mergedInto = second
        await R.refresh(root: root, cfg: cfg)
        let merged = R.readState(root).uploads.first { $0.bundleId == packed }
        check(merged?.status == "merged" && merged?.mergedInto == second && R.readState(root).sentIntervals.contains(sealedId),
              "refresh: a bundle merged on the server stays in flight, pointing at the bundle that carries its result")
        R.updateState(root) { $0.drop(second) }
        check(R.readState(root).uploads.isEmpty, "result imported: the bundle and the one merged into it leave the ledger")

        // 服务端拒收(4xx)→ 删掉,下次按台账重新导出;404 的包从台账删掉。
        R.updateState(root) { s in
            s.uploads = [.init(bundleId: "20260102T000000Z-mac-0000beef", trigger: "nightly", chains: ["event"],
                               createdAt: "", status: R.statusPendingUpload)]
        }
        try Data("x".utf8).write(to: R.archiveURL(root, "20260102T000000Z-mac-0000beef"))
        fake.rejectNextUpload = 422
        await R.flushUploads(root: root, cfg: cfg)
        check(R.readState(root).uploads.isEmpty && R.readState(root).lastExport?.outcome.hasPrefix("rejected") == true,
              "upload rejected by the server: dropped, last_export notes it")
        R.updateState(root) { s in
            s.uploads = [.init(bundleId: "gone", trigger: "nightly", chains: ["event"], createdAt: "", status: "queued")]
        }
        await R.refresh(root: root, cfg: cfg)
        check(R.readState(root).uploads.isEmpty, "refresh: bundle unknown to the server (404) dropped")

        let probe = await R.probe(cfg, root: root)
        fake.reachable = false
        let probeOff = await R.probe(cfg, root: root)
        fake.reachable = true
        check(probe.healthy && probe.user == "Selftest" && !probeOff.healthy && probeOff.problem != nil,
              "Detect: reachable + key valid → healthy with the user name; offline → the reason")
    }

    /// 区间台账 + personality 就绪 + v2 输入包,在独立的临时库上跑(时区偏移固定 0)。
    private static func checkLedger(tmp: URL) async throws {
        let fm = FileManager.default
        let dbImpl = try PortraitDBImpl(path: tmp.appendingPathComponent("ledger.sqlite").path)
        let pool = dbImpl.dbPool
        let store = EventIntervalStore(dbPool: pool)
        let m: Int64 = 60_000, h: Int64 = 3_600_000
        let t0 = Int64(ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!.timeIntervalSince1970 * 1000)
        func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
        func addFrames(_ from: Int64, _ to: Int64, every: Int64, trigger: String) throws {
            try pool.write { db in
                for t in stride(from: from, through: to, by: Int(every)) {
                    try db.execute(sql: """
                        INSERT INTO frames (timestamp_ms, app_name, snapshot_path, capture_trigger, full_text, created_at_ms)
                        VALUES (:t, 'App', 'x.jpg', :trig, 'text', :t)
                        """, arguments: ["t": t, "trig": trigger])
                }
            }
        }
        func counted(_ sql: String, _ args: StatementArguments = [:]) throws -> Int {
            try pool.read { db in try Int.fetchOne(db, sql: sql, arguments: args) ?? 0 }
        }

        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO processing_log (date, raw_status, event_status, impact_status, updated_at_ms)
                VALUES ('2026-01-01', 'complete', 'complete', 'complete', 0)
                """)
        }
        try addFrames(t0 - h, t0 - h, every: m, trigger: "click")                  // T0 之前
        try addFrames(t0 + h, t0 + 10 * h, every: 5 * m, trigger: "click")         // 109 帧
        try addFrames(t0 + 10 * h + 30_000, t0 + 10 * h + 30 * m, every: 30_000, trigger: "idle")  // 60 帧

        // 空档封口 + T0。
        let s1 = try store.sealCheck(now: date(t0 + 14 * h + m), tzOffsetMin: 0)
        let origin = try store.origin()
        check(origin == t0, "ledger: T0 = end of the last complete processing_log day")
        check(s1.count == 1 && s1[0].trigger == "gap" && s1[0].startMs == t0
              && s1[0].endMs == t0 + 10 * h + 30 * m + 1 && s1[0].frameCount == 169 && s1[0].id == "iv:\(t0)",
              "ledger: gap interval [T0, first quiet gap) with 169 frames")
        check(try store.sealCheck(now: date(t0 + 14 * h + 31 * m), tzOffsetMin: 0).isEmpty,
              "ledger: second check with no new gap seals nothing")

        // 晚到帧 + Run now。
        try addFrames(t0 + 5 * h, t0 + 5 * h, every: m, trigger: "click")          // 晚到
        try addFrames(t0 + 14 * h + 10 * m, t0 + 14 * h + 20 * m, every: 10 * m, trigger: "click")
        let s2 = try store.sealRunNow(now: date(t0 + 15 * h), tzOffsetMin: 0)
        check(s2.map(\.trigger) == ["backfill", "run_now"], "ledger: run now seals backfill first, then run_now")
        if s2.count == 2 {
            check(s2[0].startMs == t0 + 5 * h && s2[0].endMs == t0 + 5 * h + 1 && s2[0].frameCount == 1
                  && s2[0].afterFrameId == s1.first?.maxFrameId,
                  "ledger: backfill interval covers the late frame only (id floor = previous max)")
            check(s2[1].startMs == t0 + 10 * h + 30 * m + 1 && s2[1].endMs == t0 + 15 * h - m && s2[1].frameCount == 2,
                  "ledger: run_now interval [last cut, now − 60 s)")
        }
        let lastCut = try store.lastCut() ?? 0
        let wrong = try counted("""
            SELECT COUNT(*) FROM frames f
            WHERE f.timestamp_ms >= :t0 AND f.timestamp_ms < :cut AND (
              SELECT COUNT(*) FROM event_intervals i
              WHERE i.id != 'iv:origin' AND f.timestamp_ms >= i.start_ms AND f.timestamp_ms < i.end_ms
                AND f.id > i.after_frame_id AND f.id <= i.max_frame_id) != 1
            """, ["t0": t0, "cut": lastCut])
        check(wrong == 0, "ledger: every frame in [T0, last cut) belongs to exactly one interval (\(wrong) off)")
        let all = try store.all()
        var perInterval = true
        for iv in all {
            let n = try await pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames WHERE \(EventIntervalStore.intervalFrameSQL)",
                                 arguments: EventIntervalStore.frameArguments(iv)) ?? 0
            }
            if n != iv.frameCount { perInterval = false }
        }
        check(perInterval, "ledger: intervalFrameSQL returns frame_count rows for each interval")

        // 状态推进 + 退避。
        let now = EventIntervalStore.nowMs()
        check(try store.needsWork(nowMs: now).map(\.trigger) == ["gap", "backfill", "run_now"],
              "ledger: needsWork lists new intervals by start")
        let s1Id = s1.first?.id ?? ""
        try await pool.write { db in
            try db.execute(sql: "UPDATE event_intervals SET trigger = 'nightly' WHERE id = :id", arguments: ["id": s1Id])
        }
        check(try store.interval(id: s1Id)?.trigger == "gap", "ledger: a row stored as nightly reads as gap")
        let n1 = s1[0].id, bfId = s2.first?.id ?? "", rnId = s2.last?.id ?? ""
        try store.setStatus(id: n1, stage: .event, status: .complete)
        check(try store.needsWork(nowMs: now).map(\.id).contains(n1), "ledger: event complete, impact idle → still needs work")
        try store.setStatus(id: n1, stage: .impact, status: .complete)
        check(!(try store.needsWork(nowMs: now).map(\.id).contains(n1)), "ledger: event + impact complete → done")
        try store.setStatus(id: bfId, stage: .event, status: .failed)
        let rc = try store.bumpRetry(id: bfId)
        let later = EventIntervalStore.nowMs()
        let waitingNow = try store.needsWork(nowMs: later).map(\.id)
        let waitingLater = try store.needsWork(nowMs: later + 11 * m).map(\.id)
        check(rc == 1 && !waitingNow.contains(bfId) && waitingLater.contains(bfId),
              "ledger: failed + retry 1 → back after the 10 min backoff")
        try store.setStatus(id: rnId, stage: .event, status: .inProgress)
        check(!(try store.needsWork(nowMs: later).map(\.id).contains(rnId)), "ledger: in_progress → not listed")
        check((try? store.setStatus(id: rnId, stage: .distill, status: .complete)) == nil,
              "ledger: only event / impact stages are accepted")

        // personality 就绪(本地日 = UTC 日)。
        check(try store.readyPersonalityDays(nowMs: later).isEmpty, "personality: day not covered to 24:00 → not ready")
        try addFrames(t0 + 20 * h, t0 + 22 * h, every: 10 * m, trigger: "click")
        try addFrames(t0 + 24 * h + 30 * m, t0 + 26 * h, every: 10 * m, trigger: "click")
        let s3 = try store.sealCheck(now: date(t0 + 35 * h), tzOffsetMin: 0)
        check(s3.count == 2 && s3[0].endMs == t0 + 22 * h + 1 && s3[1].startMs == s3[0].endMs
              && s3[1].endMs == t0 + 26 * h + 1 && s3.allSatisfy { $0.trigger == "gap" },
              "ledger: one check seals both 2h gaps since the last cut, in order")
        check(try store.readyPersonalityDays(nowMs: later).isEmpty,
              "personality: covered, but overlapping intervals not complete → not ready")
        let bundleIds = Set(try store.all().map(\.id))
        check(try store.readyPersonalityDays(nowMs: later, inBundle: bundleIds).map(\.day) == ["2026-01-02"],
              "personality: every unfinished overlapping interval is in the same Premium bundle → listed")
        check(try store.readyPersonalityDays(nowMs: later, inBundle: bundleIds.subtracting([rnId])).isEmpty,
              "personality: an unfinished overlapping interval outside the bundle → not listed")
        for iv in try store.all() {
            try store.setStatus(id: iv.id, stage: .event, status: .complete)
            try store.setStatus(id: iv.id, stage: .impact, status: .complete)
        }
        let ready = try store.readyPersonalityDays(nowMs: later)
        check(ready.map(\.day) == ["2026-01-02"] && ready.first?.tzOffsetMin == 0 && ready.first?.status == .pending,
              "personality: covered + all overlapping intervals complete → ready (next day still open)")
        try store.setPersonalityStatus(day: "2026-01-02", tzOffsetMin: 0, status: .complete)
        check(try store.readyPersonalityDays(nowMs: later).isEmpty, "personality: each day runs once")
        try store.setPersonalityStatus(day: "2026-01-02", tzOffsetMin: 0, status: .failed)
        try store.bumpPersonalityRetry(day: "2026-01-02")
        let later2 = EventIntervalStore.nowMs()
        check(try store.readyPersonalityDays(nowMs: later2).isEmpty
              && (try store.readyPersonalityDays(nowMs: later2 + 11 * m)).map(\.day) == ["2026-01-02"],
              "personality: failed day comes back after backoff")

        // v2 输入包。
        let ivs = try store.all()
        let pday = PremiumPersonalityDayEntry(day: "2026-01-02", tzOffsetMin: 0, status: "pending", retryCount: 0)
        let input = PremiumExchangeExporter.Input(
            chains: ["event", "personality"],
            pending: PremiumPending(eventIntervals: ivs.map(PremiumIntervalEntry.init), personalityDays: ["2026-01-02"],
                                  distillPending: false, classifyPending: false, writingStyleEnabled: false,
                                  writingRecordsUnprocessed: 0, personalityLog: [pday]),
            processingLog: [PremiumProcessingLogEntry(date: "_distill_anchor", distillStatus: "idle")],
            aboutUserBlock: "", params: selftestParams, appVersion: "selftest")
        let root = tmp.appendingPathComponent("ledger-root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = try PremiumExchangeExporter.writeBundle(input: input, bundleId: "20260103T000000Z-v2", root: root,
                                                        parentDir: tmp.appendingPathComponent("v2", isDirectory: true),
                                                        dbPool: pool)
        let raw = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PremiumBundleManifest.self, from: raw)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        let pend = obj["pending"] as? [String: Any] ?? [:]
        check(manifest.schemaVersion == 2 && pend["event_days"] == nil && pend["event_intervals"] != nil
              && obj["personality_log"] != nil && (pend["personality_days"] as? [String]) == ["2026-01-02"],
              "v2 manifest: schema 2, pending.event_intervals + personality_days, personality_log, no event_days")
        let firstIv = (pend["event_intervals"] as? [[String: Any]])?.first ?? [:]
        check(["id", "start_ms", "end_ms", "tz_offset_min", "trigger"].allSatisfy { firstIv[$0] != nil },
              "v2 manifest: each interval carries id / start_ms / end_ms / tz_offset_min / trigger")
        var linesOK = true
        for iv in ivs {
            let text = read(dir.appendingPathComponent("frames/\(iv.id).jsonl")) ?? ""
            if text.split(separator: "\n").count != iv.frameCount { linesOK = false }
        }
        check(linesOK, "v2 bundle: frames/<interval_id>.jsonl has exactly the interval's frames")
        let dayFrames = try counted("SELECT COUNT(*) FROM frames WHERE timestamp_ms >= :s AND timestamp_ms < :e",
                                    ["s": t0, "e": t0 + 24 * h])
        check(read(dir.appendingPathComponent("frames/pday_2026-01-02.jsonl"))?
                .split(separator: "\n").count == dayFrames && dayFrames > 0,
              "v2 bundle: frames/pday_<day>.jsonl has all \(dayFrames) frames of that local day")
        check(PremiumExchange.isDone(dir), "v2 bundle: DONE valid")
    }

    private static let selftestParams = PremiumParams(
        dailyBudget: 50, peakProtection: 4.5, maxRebalances: 5, windowDays: 7,
        distillEvidenceThreshold: 3, archiveMaxWeight: 0.05, archiveMinDaysIdle: 30,
        weightHalfLifeDays: 180, beltWeightMax: 1.5, folderMinCoreEvents: 5,
        writingStyleBatch: 600, model: "qwen", modelLight: "qwen")

    static func run() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("premium-selftest-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent("root", isDirectory: true)
        let results = tmp.appendingPathComponent("results", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        print("[premium-selftest] temp root: \(tmp.path)")

        let dbImpl = try PortraitDBImpl(path: root.appendingPathComponent("portrait.sqlite").path)
        let pool = dbImpl.dbPool
        let suite = "premium-selftest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // —— 封区间规则 / 区间台账 / personality 就绪 / v2 输入包 ——
        print("[premium-selftest] segmenter")
        checkSegmenter()
        print("[premium-selftest] interval ledger + personality days + v2 bundle")
        try await checkLedger(tmp: tmp)

        // —— 基线:两条 writing_records + 一行 processing_log + 一个区间 ——
        try await pool.write { db in
            for id in [Int64(1), Int64(2)] {
                try db.execute(sql: """
                    INSERT INTO writing_records (id, start_ts, end_ts, app, text, edit_log,
                      confidence, source, created_at)
                    VALUES (:id, 0, 0, 'app', 't', '[{"kind":"commit"}]', 1, 'ax_cleaned', 0)
                    """, arguments: ["id": id])
            }
            try db.execute(sql: """
                INSERT INTO processing_log (date, raw_status, event_status, updated_at_ms)
                VALUES ('2026-01-01', 'complete', 'pending', 0)
                """)
            try db.execute(sql: """
                INSERT INTO event_intervals (id, start_ms, end_ms, tz_offset_min, sealed_at_ms, trigger,
                  frame_count, max_frame_id, event_status, impact_status, retry_count, updated_at_ms)
                VALUES ('iv:1000', 1000, 2000, 0, 2000, 'gap', 0, 0, 'pending', 'idle', 1, 0)
                """)
        }

        // —— 基线树(= 导出时刻)——
        let a = root.appendingPathComponent("events/2026-01-01/2026-01-01_a.md")
        let b = root.appendingPathComponent("events/2026-01-01/2026-01-01_b.md")
        let c = root.appendingPathComponent("portrait/interests/c.md")
        let d = root.appendingPathComponent("portrait/interests/d.md")
        let n = root.appendingPathComponent("events/2026-01-02/2026-01-02_new.md")
        let q = root.appendingPathComponent("events/_quarantine/q.md")
        try write("A0", a); try write("B0", b); try write("C0", c); try write("D0", d); try write("Q0", q)
        let base = PremiumExchange.hashTrees(root: root)
        check(base[q.path.replacingOccurrences(of: root.path + "/", with: "")] == nil,
              "_quarantine excluded from trees")

        // —— 导出后 Mac 本地又改了 b / d ——
        try write("B-mac", b); try write("D-mac", d)
        let preImport = PremiumExchange.hashTrees(root: root)

        // —— 导出:包写进 staging、打成 tar.gz;每个包一个新 id ——
        print("[premium-selftest] export")
        let input = PremiumExchangeExporter.Input(
            chains: ["event", "portrait", "writing_style"],
            pending: PremiumPending(eventIntervals: [PremiumIntervalEntry(id: "iv:1000", startMs: 1000, endMs: 2000,
                                                                      tzOffsetMin: 0, trigger: "gap")],
                                  personalityDays: [], distillPending: true,
                                  classifyPending: false, writingStyleEnabled: true,
                                  writingRecordsUnprocessed: 2),
            processingLog: [PremiumProcessingLogEntry(date: "_distill_anchor", distillStatus: "pending")],
            aboutUserBlock: "", params: selftestParams, appVersion: "selftest")
        let pkRoot = tmp.appendingPathComponent("pack-root", isDirectory: true)
        try fm.createDirectory(at: pkRoot, withIntermediateDirectories: true)
        for rel in PremiumExchange.listTreeFiles(root: root) {
            try write(read(root.appendingPathComponent(rel)) ?? "", pkRoot.appendingPathComponent(rel))
        }
        let e1 = try PremiumExchangeExporter.packageForUpload(input: input, root: pkRoot, dbPool: pool)
        let e2 = try PremiumExchangeExporter.packageForUpload(input: input, root: pkRoot, dbPool: pool)
        var nightlyManifest: PremiumBundleManifest?
        if case .exported(let id1, let arc1) = e1, case .exported(let id2, _) = e2 {
            let dir1 = tmp.appendingPathComponent("unpacked-e1", isDirectory: true)
            try PremiumRemote.unpack(arc1, into: dir1)
            check(PremiumExchange.isDone(dir1), "packed bundle has valid DONE")
            check(read(dir1.appendingPathComponent("writing_records.jsonl"))?
                    .split(separator: "\n").count == 2, "writing_records.jsonl has 2 rows")
            check(fm.fileExists(atPath: dir1.appendingPathComponent("frames/iv:1000.jsonl").path),
                  "frames/<interval_id>.jsonl written")
            nightlyManifest = try JSONDecoder().decode(
                PremiumBundleManifest.self, from: Data(contentsOf: dir1.appendingPathComponent("manifest.json")))
            check(nightlyManifest?.files["writing_records.jsonl"] == PremiumExchange.fileSHA(dir1.appendingPathComponent("writing_records.jsonl"))
                  && nightlyManifest?.files["frames/iv:1000.jsonl"] != nil,
                  "manifest files: frame file + writing records hashed")
            check(id1 != id2 && !fm.fileExists(atPath: PremiumRemote.uploadDir(pkRoot).appendingPathComponent(id1).path),
                  "each package gets a new id; bundle dir removed after packing")
        } else { check(false, "packageForUpload produced archives") }

        // —— manifest trigger / chains ——
        print("[premium-selftest] single-chain bundle")
        check(nightlyManifest?.trigger == "nightly" && nightlyManifest?.chains == ["event", "portrait", "writing_style"],
              "nightly manifest: trigger nightly + chains")
        var rnInput = input
        rnInput.chains = ["portrait"]
        rnInput.pending = input.pending.only(["portrait"])
        let rnParent = tmp.appendingPathComponent("runnow-parent", isDirectory: true)
        let rnDir = try PremiumExchangeExporter.writeBundle(input: rnInput, bundleId: "20260101T000001Z-rn",
                                                          root: root, parentDir: rnParent, dbPool: pool)
        let rnManifest = try JSONDecoder().decode(
            PremiumBundleManifest.self, from: Data(contentsOf: rnDir.appendingPathComponent("manifest.json")))
        check(rnManifest.trigger == "nightly" && rnManifest.chains == ["portrait"]
              && rnManifest.pending.eventIntervals.isEmpty && rnManifest.pending.distillPending
              && !rnManifest.pending.writingStyleEnabled,
              "portrait-only manifest: chains [portrait], other chains blank")
        check(!fm.fileExists(atPath: rnDir.appendingPathComponent("writing_records.jsonl").path)
              && ((try? fm.contentsOfDirectory(atPath: rnDir.appendingPathComponent("frames").path)) ?? []).isEmpty
              && rnManifest.files.isEmpty && PremiumExchange.isDone(rnDir),
              "portrait-only bundle: no writing records, no frames, valid DONE")

        // —— 发包时机 / 一包一天 / 在路上的区间 / 交换锁 ——
        print("[premium-selftest] export rules + exchange lock")
        try await checkExportRules(tmp: tmp)

        // —— 上传:连不上照封不发、没新东西不发、前一个包还在排队时照发新区间、合并、拒收与 404 ——
        print("[premium-selftest] upload gate (fake Premium)")
        try await checkUploadGate(tmp: tmp)

        // —— pending 只含 provider 为 Premium 的链 ——
        print("[premium-selftest] pending per offloaded chain")
        checkPendingPerChain()

        // —— 封区间 agent 刷新登记:注入 SMAppService 状态 / 试跑结果序列 ——
        print("[premium-selftest] seal-check agent refresh")
        await checkAgentRefresh()

        // —— Premium 结果包 ——
        let id = "20260101T000000Z-selftest"
        let outDir = results.appendingPathComponent(id, isDirectory: true)
        func makeResult(corrupt: Bool = false) throws {
            let dir = outDir
            try? fm.removeItem(at: dir)
            var result = base
            result.removeValue(forKey: "portrait/interests/c.md")
            let files: [(String, String)] = [
                ("events/2026-01-01/2026-01-01_a.md", "A1"),      // 改
                ("events/2026-01-01/2026-01-01_b.md", "B1"),      // 冲突
                ("events/2026-01-02/2026-01-02_new.md", "N1"),    // 新增
                ("portrait/interests/d.md", "D0"),                // Premium 没动
            ]
            for (rel, text) in files {
                try write(text, dir.appendingPathComponent(rel))
                result[rel] = PremiumExchange.sha256Hex(Data(text.utf8))
            }
            // 坏的放在排序靠后的文件上:前面的 a.md 已经写盘,才验得到整树还原。
            if corrupt { result["events/2026-01-02/2026-01-02_new.md"] = String(repeating: "0", count: 64) }
            let manifest = PremiumResultManifest(
                schemaVersion: 1, bundleId: id, pipelineVersion: "selftest", startedMs: 0, endedMs: 0,
                status: "complete", stages: nil, baseTrees: base, resultTrees: result,
                deleted: ["portrait/interests/c.md"], summary: ["new_events": 1])
            var ops = PremiumDbOps()
            ops.processingLog = [
                PremiumProcessingLogEntry(date: "2026-01-01", rawStatus: "complete", eventStatus: "complete",
                                        impactStatus: "complete", personalityStatus: "pending", retryCount: 0),
                PremiumProcessingLogEntry(date: "_distill_anchor", distillStatus: "complete"),
            ]
            ops.eventIntervals = [
                PremiumIntervalEntry(id: "iv:1000", startMs: 1000, endMs: 2000, tzOffsetMin: 0, trigger: "gap",
                                   eventStatus: "complete", impactStatus: "complete", retryCount: 0),
                PremiumIntervalEntry(id: "iv:5000", startMs: 5000, endMs: 6000, tzOffsetMin: 0, trigger: "run_now",
                                   eventStatus: "failed", impactStatus: "idle", retryCount: 1),
            ]
            ops.personalityDays = [PremiumPersonalityDayEntry(day: "2026-01-02", tzOffsetMin: 0,
                                                            status: "complete", retryCount: 0)]
            ops.distillChangelog = [.init(entityId: "interests/d.md", fieldName: "body", before: "x",
                                          after: "y", triggeredByEventId: "2026-01-01/2026-01-01_a.md",
                                          timestampMs: 123)]
            ops.writingStyle = .init(
                run: .init(runId: "run-selftest", mode: "auto", status: "auto_committed", startedAt: 1,
                           completedAt: 2, recordsCount: 2, draftsCount: 1, inputRecordIds: [1, 2],
                           errorMessage: nil),
                processedRecordIds: [1, 2], processedAtMs: 999)
            ops.pipelineRuns = [.init(pipeline: "Event processing", outcome: "success", detail: "1 day")]
            ops.journalAppend = ["2026-01-02": "\n## Daily memory budget (selftest)\n"]
            ops.lastRunDays = ["event": "2026-01-02"]
            ops.llmDumps = ["distill_parsefail_selftest.txt": "raw"]
            let enc = PremiumExchange.encoder()
            try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
            try enc.encode(ops).write(to: dir.appendingPathComponent("db_ops.json"))
            try write("# report", dir.appendingPathComponent("report.md"))
            try PremiumExchange.writeDone(bundleDir: dir)
        }

        // 1. 失败还原:哈希对不上 → 抛错,树原样。
        print("[premium-selftest] corrupt result")
        try makeResult(corrupt: true)
        var threw = false
        do { _ = try PremiumExchangeImporter.importBundle(id: id, dir: outDir, root: root,
                                                        dbPool: pool, defaults: defaults) }
        catch { threw = true }
        check(threw, "corrupt result rejected")
        check(PremiumExchange.hashTrees(root: root) == preImport, "trees restored after failed import")
        check(PremiumRemote.readState(root).lastImport?.outcome == "failed", "ledger last_import = failed")

        // 1b. 不完整:缺 db_ops.json / 缺结果树文件 → 不导。
        print("[premium-selftest] incomplete result")
        try makeResult()
        try fm.removeItem(at: outDir.appendingPathComponent("db_ops.json"))
        check(PremiumExchange.isDone(outDir) && !PremiumExchange.resultReady(outDir), "DONE but no db_ops.json → not ready")
        threw = false
        do { _ = try PremiumExchangeImporter.importBundle(id: id, dir: outDir, root: root,
                                                        dbPool: pool, defaults: defaults) }
        catch { threw = true }
        let stillPending = try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:1000' AND event_status='pending'")
        check(threw && PremiumExchange.hashTrees(root: root) == preImport && stillPending == 1,
              "no db_ops.json → nothing merged, ledger untouched")
        try makeResult()
        try fm.removeItem(at: outDir.appendingPathComponent("events/2026-01-02/2026-01-02_new.md"))
        check(!PremiumExchange.resultReady(outDir), "a result_trees file still missing → not ready")
        try makeResult()
        check(PremiumExchange.resultReady(outDir), "all files present → ready")

        // 2. 正常导入。
        print("[premium-selftest] import")
        try makeResult()
        let r1 = try PremiumExchangeImporter.importBundle(id: id, dir: outDir, root: root,
                                                        dbPool: pool, defaults: defaults)
        check(read(a) == "A1", "modified file written (mac == base)")
        check(read(n) == "N1", "new file written")
        check(read(b) == "B-mac", "conflict keeps Mac version")
        check(read(root.appendingPathComponent(".staging/premium_conflicts/\(id)/events/2026-01-01/2026-01-01_b.md")) == "B1",
              "conflict stores Premium version under .staging/premium_conflicts")
        check(!fm.fileExists(atPath: c.path), "deleted file removed (mac == base)")
        check(read(d) == "D-mac", "Premium-unchanged file keeps Mac edit")
        check(read(q) == "Q0", "_quarantine untouched")
        check(r1.written == 2 && r1.deleted == 1 && r1.conflicts.count == 1,
              "report counts (written 2, deleted 1, conflicts 1) — got \(r1.written)/\(r1.deleted)/\(r1.conflicts.count)")
        let row = ProcessingLogStore(path: root.appendingPathComponent("portrait.sqlite").path).row(for: "2026-01-01")
        check(row?.event == .complete && row?.impact == .complete && row?.personality == .pending,
              "processing_log upserted by column")
        check(try count(pool, "SELECT COUNT(*) FROM processing_log WHERE date='_distill_anchor' AND distill_status='complete'") == 1,
              "anchor row inserted")
        check(try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:1000' AND event_status='complete' AND impact_status='complete' AND retry_count=0") == 1,
              "event_intervals row updated by id")
        check(try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:5000' AND event_status='failed' AND retry_count=1 AND start_ms=5000") == 1,
              "event_intervals row Premium echoed in full inserted")
        check(try count(pool, "SELECT COUNT(*) FROM personality_days WHERE day='2026-01-02' AND status='complete'") == 1,
              "personality_days row upserted")
        check(try count(pool, "SELECT COUNT(*) FROM distill_changelog") == 1, "distill_changelog inserted")
        check(try count(pool, "SELECT COUNT(*) FROM writing_style_runs WHERE run_id='run-selftest'") == 1,
              "writing_style_runs inserted")
        check(try count(pool, "SELECT COUNT(*) FROM writing_records WHERE writing_style_processed_at=999") == 2,
              "writing_records marked processed")
        check(try count(pool, "SELECT COUNT(*) FROM pipeline_runs WHERE trigger='premium'") == 1,
              "pipeline_runs row with trigger premium")
        check(read(root.appendingPathComponent("journal/2026-01-02.md"))?.contains("selftest") == true,
              "journal appended")
        check(fm.fileExists(atPath: root.appendingPathComponent("llm_dump/distill_parsefail_selftest.txt").path),
              "llm_dump written")
        check(defaults.string(forKey: "scheduler.lastEventRun") != nil, "lastEventRun written")
        check(PremiumRemote.readState(root).lastImport?.outcome == "complete", "ledger last_import = complete")
        check(fm.fileExists(atPath: root.appendingPathComponent(".staging/premium_import_backup/\(id)/events").path),
              "backup snapshot written")
        let postImport = PremiumExchange.hashTrees(root: root)

        // 3. 幂等:同一个包再导一次,数据不变。
        print("[premium-selftest] re-import (idempotency)")
        try makeResult()
        let r2 = try PremiumExchangeImporter.importBundle(id: id, dir: outDir, root: root,
                                                        dbPool: pool, defaults: defaults)
        check(PremiumExchange.hashTrees(root: root) == postImport, "trees unchanged on re-import")
        check(r2.written == 0 && r2.deleted == 0, "re-import writes nothing")
        check(try count(pool, "SELECT COUNT(*) FROM distill_changelog") == 1, "changelog not duplicated")
        check(try count(pool, "SELECT COUNT(*) FROM writing_style_runs") == 1, "run not duplicated")
        check(try count(pool, "SELECT COUNT(*) FROM pipeline_runs WHERE trigger='premium'") == 1,
              "pipeline_runs not duplicated")
        let journal = read(root.appendingPathComponent("journal/2026-01-02.md")) ?? ""
        check(journal.components(separatedBy: "selftest").count == 2, "journal not duplicated")

        // 4. 回滚:回到首次导入前。
        print("[premium-selftest] rollback")
        try PremiumExchangeImporter.rollback(bundleId: id, root: root, dbPool: pool)
        check(PremiumExchange.hashTrees(root: root) == preImport, "trees restored to pre-import state")
        let back = ProcessingLogStore(path: root.appendingPathComponent("portrait.sqlite").path).row(for: "2026-01-01")
        check(back?.event == .pending && back?.impact == .idle, "processing_log row restored")
        check(try count(pool, "SELECT COUNT(*) FROM processing_log WHERE date='_distill_anchor'") == 0,
              "anchor row inserted by import removed")
        check(try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:1000' AND event_status='pending' AND impact_status='idle' AND retry_count=1") == 1,
              "event_intervals row restored")
        check(try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:5000'") == 0
              && (try count(pool, "SELECT COUNT(*) FROM personality_days")) == 0,
              "interval / personality rows inserted by import removed")
        check(try count(pool, "SELECT COUNT(*) FROM writing_records WHERE writing_style_processed_at IS NULL") == 2,
              "writing_records processed flag cleared")
        check(try count(pool, "SELECT COUNT(*) FROM writing_style_runs") == 0, "writing_style run removed")

        // 5. 重复处理的结果不回退已经 complete 的台账行。
        print("[premium-selftest] duplicate result keeps finished rows")
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE event_intervals SET event_status = 'complete', impact_status = 'complete', retry_count = 0
                WHERE id = 'iv:1000'
                """)
            try db.execute(sql: """
                INSERT INTO event_intervals (id, start_ms, end_ms, tz_offset_min, sealed_at_ms, trigger,
                  frame_count, max_frame_id, event_status, impact_status, retry_count, updated_at_ms)
                VALUES ('iv:3000', 3000, 4000, 0, 4000, 'nightly', 0, 0, 'complete', 'failed', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO personality_days (day, tz_offset_min, status, retry_count, updated_at_ms)
                VALUES ('2026-01-02', 0, 'complete', 0, 0)
                """)
        }
        try makeResult()
        var dup = PremiumDbOps()
        dup.eventIntervals = [
            PremiumIntervalEntry(id: "iv:1000", eventStatus: "failed", impactStatus: "idle", retryCount: 1),
            PremiumIntervalEntry(id: "iv:3000", eventStatus: "failed", impactStatus: "complete", retryCount: 0),
        ]
        dup.personalityDays = [PremiumPersonalityDayEntry(day: "2026-01-02", tzOffsetMin: 0, status: "failed",
                                                        retryCount: 1)]
        try PremiumExchange.encoder().encode(dup).write(to: outDir.appendingPathComponent("db_ops.json"))
        _ = try PremiumExchangeImporter.importBundle(id: id, dir: outDir, root: root, dbPool: pool, defaults: defaults)
        check(try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:1000' AND event_status='complete' AND impact_status='complete' AND retry_count=0") == 1,
              "event + impact complete → row left as is")
        check(try count(pool, "SELECT COUNT(*) FROM event_intervals WHERE id='iv:3000' AND event_status='complete' AND impact_status='complete'") == 1,
              "complete stage kept, the unfinished stage takes the result")
        check(try count(pool, "SELECT COUNT(*) FROM personality_days WHERE day='2026-01-02' AND status='complete' AND retry_count=0") == 1,
              "complete personality day left as is")

        // 6. 从假收件服务取结果:done 的下载、核对 sha256、解包;哈希对不上的不导;服务端 failed 的
        //    记进 last_import 后从台账删掉;导入后确认(ack),台账删掉那一条。
        print("[premium-selftest] download + ack (fake Premium)")
        do {
            let fake = FakePremium()
            PremiumRemote.transportOverride = fake
            defer { PremiumRemote.transportOverride = nil }
            let cfg = PremiumConfig()
            let dlRoot = tmp.appendingPathComponent("dl-root", isDirectory: true)
            try makeResult()
            let arc = tmp.appendingPathComponent("result.tar.gz")
            try PremiumRemote.pack(outDir, to: arc)
            let resData = try Data(contentsOf: arc)
            let resSha = PremiumExchange.sha256Hex(resData)
            fake.statuses[id] = .init(bundleId: id, status: "done", resultSha256: resSha)
            fake.results[id] = resData
            fake.statuses["bad"] = .init(bundleId: "bad", status: "done", resultSha256: String(repeating: "0", count: 64))
            fake.results["bad"] = resData
            fake.statuses["broke"] = .init(bundleId: "broke", status: "failed", summary: "event: boom")
            PremiumRemote.updateState(dlRoot) { s in
                s.uploads = [id, "bad", "broke"].map {
                    .init(bundleId: $0, trigger: "nightly", chains: ["event"], createdAt: "", status: "running")
                }
            }
            let ready = await PremiumExchangeImporter.collectResults(root: dlRoot, cfg: cfg, notify: false)
            check(ready.map(\.id) == [id] && ready.first.map { PremiumExchange.resultReady($0.dir) } == true,
                  "done result downloaded, sha256 checked, unpacked; a result with the wrong sha256 is not imported")
            let st = PremiumRemote.readState(dlRoot)
            check(!st.uploads.contains { $0.bundleId == "broke" } && st.lastImport?.outcome == "failed on Premium",
                  "bundle failed on Premium: dropped from the ledger, last_import notes it")
            await PremiumExchangeImporter.acknowledge(ready.map(\.id), root: dlRoot, cfg: cfg)
            let after = PremiumRemote.readState(dlRoot)
            check(fake.acked == [id] && !after.uploads.contains { $0.bundleId == id }
                  && after.uploads.contains { $0.bundleId == "bad" },
                  "ack: server told, ledger entry removed; the unimported one stays for the next try")
        }

        // 基线(只读真实树):Mac 自己的 PortraitFileIO 往返是否逐字节稳定。Premium 端
        // frontmatter 往返要对齐的就是这个;不稳定的文件导入时会显示成 Premium 改过。
        var total = 0, unstable: [String] = []
        for rel in PremiumExchange.listTreeFiles(root: Storage.rootURL)
        where rel.hasSuffix(".md") && !rel.hasPrefix("personality_daily/") && !rel.hasSuffix("/INDEX.md") {
            guard let raw = read(Storage.rootURL.appendingPathComponent(rel)),
                  let f = try? PortraitFileIO.parse(raw) else { continue }
            total += 1
            if PortraitFileIO.serialize(f) != raw { unstable.append(rel) }
        }
        print("  INFO  real tree PortraitFileIO round-trip: \(total - unstable.count)/\(total) byte-identical")
        for rel in unstable.prefix(5) { print("        unstable: \(rel)") }

        print(failures == 0 ? "[premium-selftest] ALL PASS" : "[premium-selftest] \(failures) FAILURE(S)")
        if failures > 0 { throw NSError(domain: "PremiumSelfTest", code: failures) }
    }
}
