import AppKit
import Foundation
import IOKit
import IOKit.ps
import Network
import Observation
import os.log

private let schedLog = Logger(subsystem: "com.myportrait.memory", category: "scheduler")

// MARK: - IOKit 合盖 / 电源 C 回调(开盖即断 helper)
//
// 由 IOServiceAddInterestNotification / IOPSNotificationCreateRunLoopSource 在
// main runloop 上回调。无捕获的顶层函数 → 可直接当 C 函数指针。经单例跳回
// @MainActor 调 onLidOrPowerChange,由它 refreshKeepAwake。

private func portraitLidInterestCallback(
    _ refcon: UnsafeMutableRawPointer?, _ service: io_service_t,
    _ messageType: UInt32, _ messageArgument: UnsafeMutableRawPointer?
) {
    Task { @MainActor in MemoryScheduler.shared.onLidOrPowerChange("clamshell") }
}

private func portraitPowerSourceCallback(_ refcon: UnsafeMutableRawPointer?) {
    Task { @MainActor in MemoryScheduler.shared.onLidOrPowerChange("power") }
}

/// 记忆流水线的调度器。两个 job（频率各自可配 off/daily/weekly/monthly）：
///   - event   ：跑当天及之前未处理日的 event 聚类 + impact 评分（per-day）。
///   - portrait ：跑 distill（事件 → 画像蒸馏），用 `_distill_anchor` 哨兵行记状态。
///
/// "event / portrait" 是调度器身份（跑什么），频率是它的配置（多久跑一次）。
/// 每次触发最多处理 7 个数据日（`dayCap`），从最旧的未处理日开始。
///
/// 失败语义（见 ProcessingStatus）：
///   - 真实失败 → status=failed，retry_count +1；retry_count ≥ 3 → dead_letter。
///   - 撞 LLM 额度 → status=budget_deferred，retry_count 不变，自动重试。
///   - dead_letter 的日 / 阶段被排除出自动处理，等用户在 Settings 手动重置。
///
/// 状态全部落在 `processing_log` 表。`active_processor` + `heartbeat_ms` 做崩溃
/// 保护：每个 LLM 步（event / impact / distill）持锁并每 30s 续心跳；启动时
/// `recoverStaleLocks` 把心跳过期的 in_progress 行当一次失败回收（retry +1）。
///
/// 进程内并发由 `@MainActor` + 3 把分离的锁保证:
///   - `eventRunning`        :event job 跑着,屏蔽所有其它 job(它 rebalance
///                              重写整个 events/,distill/personality 同跑会
///                              读到撕裂状态)
///   - `distillRunning`      :distill 跑着,屏蔽 event 和自己重入(distill
///                              跟 personality 可以并行 —— 写盘目录不重叠)
///   - `personalityRunning`  :personality 跑着,屏蔽 event 和自己重入
/// 写作采集 worker **完全独立**,不参与上面三把锁(它走另一套 DB 表,跟
/// memory pipeline 零交集,在用户手动调试时不被 memory 阻塞)。
@MainActor
@Observable
final class MemoryScheduler {

    static let shared = MemoryScheduler()

    /// 失败 / 撞额度 / dead_letter 的日，给 Settings 的 "Needs attention" 用。
    struct AttentionItem: Identifiable, Sendable {
        var id: String { date }
        let date: String
        let retryCount: Int
        /// 出问题的阶段及其状态。
        let problems: [(stage: ProcessingStage, status: ProcessingStatus)]
    }

    private enum StepOutcome { case success, failed, budgetExhausted }

    private let store = ProcessingLogStore()

    /// 每次触发处理的数据日上限。
    /// 每次 event-processing 跑最多处理几个未处理日 —— 由 Settings 配置。
    private var dayCap: Int { ConfigStore.shared.current.memory.eventDayCap }
    // maxRetries 已下线 —— 用户方向是"永不放弃"。失败永远会自动重试,但用
    // long-backoff 控制频率,避免一直挂的 LLM 烧 token。见 backoffMs(retry:)。
    // dead_letter case 仍保留(老 DB 行兼容),但不再产生 + needsWork=true。
    /// 原始数据"收齐"判定：数据日结束（UTC 次日 0 点）后再等这么久。
    private let rawGraceSeconds: TimeInterval = 10 * 60
    /// tick 周期。
    private let tickInterval: TimeInterval = 15 * 60
    /// distill 锚行的 date 值。anchor 是 distill 这个 processor 的锁身份，与
    /// 运行频率无关。定义 / 语义见 `ProcessingLogStore.distillAnchorDate`。
    private let distillAnchor = ProcessingLogStore.distillAnchorDate
    // classify(EventClassifier 自动分 folder)已下线 —— 改成 chat AI 通过
    // mp-folders 按用户对话需求手动整理。anchor case 在 ProcessingLog 里保留
    // (DB 历史值 + 崩溃恢复仍需识别老 inProgress),不再有 scheduler hook。
    // personality 不用 anchor —— 它是 per-day 流水线(每天的 events 各自有
    // 各自的 personality_status 列),进度直接落在日期行里。

    /// 心跳超过这个时长视为死锁。默认 10min（单日 Backfill 多轮 LLM 可能 >5min
    /// 仍在正常跑）。可经 env `MYPORTRAIT_SCHEDULER_STALE_MS` 覆盖（测试用）。
    private let staleLockMs: Int64 = {
        if let s = ProcessInfo.processInfo.environment["MYPORTRAIT_SCHEDULER_STALE_MS"],
           let v = Int64(s) {
            return v
        }
        return 10 * 60 * 1000
    }()

    /// 四把分离的锁。View 侧 @Observable 跟踪它们,Run 按钮根据 canRunXxx
    /// 实时灰掉 + tooltip 说理由。
    private(set) var eventRunning = false
    // classifyRunning 已下线(EventClassifier 砍掉了)。canRunEvent 不再需要
    // classify 锁。
    private(set) var distillRunning = false
    private(set) var personalityRunning = false

    /// 一个 pipeline 的实时进度(给 Settings 的 Run now 进度条)。
    /// fraction = 0…1 的总体完成度,nil = 不确定(indeterminate 条);
    /// stage = 当前阶段名;detail = 子单元说明("Day 2/3 · batch 1/4")。
    struct StepProgress: Equatable {
        var fraction: Double? = nil
        var stage: String = ""
        var detail: String = ""
        var isIdle: Bool { stage.isEmpty }
    }

    /// 当前子阶段进度(给 Settings 的 Run now 实时显示)。stage 空 = 没跑。
    /// @Observable 自动跟踪,view 直接读。LLM 调用期间条不动(没有 token 级
    /// 信号),每完成一个单元(LLM batch / 落盘 cluster / category / day)进一格。
    private(set) var eventProgress = StepProgress()
    private(set) var distillProgress = StepProgress()
    private(set) var personalityProgress = StepProgress()
    /// tick() 自身的可重入防护(timer 与 startup 并发触发时只跑一次)。
    private var tickRunning = false
    /// 上次 tick 真正起跑的墙钟时刻。周期 catch-up 据此节流(距上次 ≥ tickInterval 才真跑)。
    private var lastTickAt: Date = .distantPast
    /// 合盖 / 开盖空闲都能 fire 的周期触发源(P0 探针实测 NSBackgroundActivityScheduler 最抗 DarkWake)。
    private var bgScheduler: NSBackgroundActivityScheduler?
    /// 兜底周期触发(DispatchSourceTimer 比 Foundation Timer 在后台略可靠)。
    private var catchUpTimer: DispatchSourceTimer?
    /// pause 代际计数。pauseInProgressJobs(willSleep / 用户退出)每次 +1;
    /// runStep / runXxxJob 开跑时快照,跑完发现不一致 = 运行期间被 pause
    /// 接管过(行已 paused + 锁已释放 + staging 已 reject)→ 结果作废:
    /// 不 applyOutcome、不 releaseLock、不再处理剩余天。否则系统睡眠只
    /// suspend 进程不杀任务,唤醒后复活的旧任务会跟 didWake 的 paused→failed
    /// 回收竞态(failed 被覆盖成 complete / 双重 bumpRetry / 手动 staged run
    /// 绕过审核直接落盘)。
    private var pauseGeneration = 0

    /// 用户点了 Stop 的 pipeline owner 集合。requestStop 杀掉**当前**在飞的
    /// LLM 子进程后,day 循环还会给剩余天起**新** agent 继续跑("根本杀不掉")
    /// —— 各 runXxxJob 在循环顶部 consume 这个标记,中止剩余天。
    private var stopRequestedOwners: Set<String> = []

    /// UI 的 Stop 按钮入口:杀该 pipeline 当前的 LLM 子进程 + 标记中止剩余
    /// 循环。返回杀掉的进程数(给 status 文案)。对应 job 没在跑就只杀进程
    /// 不留标记(防 stale 标记把下一次 run 秒杀)。
    @discardableResult
    func requestStop(owner: String) -> Int {
        let running: Bool = switch owner {
        case PipelineOwner.event:       eventRunning
        case PipelineOwner.distill:     distillRunning
        case PipelineOwner.personality: personalityRunning
        default:                        false
        }
        if running { stopRequestedOwners.insert(owner) }
        let n = PiAgentRegistry.shared.stopGroup(owner)
        schedLog.notice("requestStop(\(owner, privacy: .public)): killed \(n) agent(s), abort-flag=\(running)")
        return n
    }

    /// 循环顶部消费 stop 标记。命中即清(一次 Stop 只中止一轮)。
    private func consumeStopRequest(_ owner: String) -> Bool {
        stopRequestedOwners.remove(owner) != nil
    }

    /// 每行每阶段最近一次失败的分类。**持久化到 ~/.portrait/scheduler/
    /// last_failures.json** —— 进程重启不丢,UI 一直能显示具体 kind。
    /// 单一真相:in-memory dict,任何写都同步落盘;启动时从盘加载。
    /// 文件格式:`{ "<date>": { "<stage.rawValue>": <LLMFailureKind json> } }`
    private var lastFailureByRowStage: [String: [ProcessingStage: LLMFailureKind]] = [:]
    /// 持久化文件 url。`~/.portrait/scheduler/last_failures.json`。
    private static var lastFailuresURL: URL {
        Storage.rootURL.appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("last_failures.json")
    }

    /// UI / 通知层查最近失败 kind。nil = 没有失败记录。
    func lastFailureKind(date: String, stage: ProcessingStage) -> LLMFailureKind? {
        lastFailureByRowStage[date]?[stage]
    }

    /// 写一条 failure kind,内存 + 落盘。所有失败写入点(runStep catch /
    /// recoverStaleLocks / recoverPausedJobs)的统一入口。
    private func recordFailure(date: String, stage: ProcessingStage, kind: LLMFailureKind) {
        lastFailureByRowStage[date, default: [:]][stage] = kind
        persistLastFailures()
        attentionVersion &+= 1
    }

    /// 清掉某 stage 的 failure 记录(success 时调),内存 + 落盘。
    private func clearFailure(date: String, stage: ProcessingStage) {
        lastFailureByRowStage[date]?.removeValue(forKey: stage)
        if lastFailureByRowStage[date]?.isEmpty == true {
            lastFailureByRowStage.removeValue(forKey: date)
        }
        persistLastFailures()
        attentionVersion &+= 1
    }

    /// @Observable 计数 —— attention 列表需重读时增。UI 通过引用此属性
    /// 让 SwiftUI 跟踪,scheduler 内部 status / kind 变化触发自动 reload,
    /// 否则 retry 成功后 attention 行不会主动消失(attentionDays 是
    /// nonisolated DB 读,UI 不知道该重查)。
    /// 包装溢出(&+=)而非 +=,避免 Int max 边界(实际上跑几辈子也到不了)。
    private(set) var attentionVersion: Int = 0

    /// 启动时从盘加载。失败 / 不存在 → 内存留空,后续写入仍会建文件。
    private func loadLastFailures() {
        let url = Self.lastFailuresURL
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [String: LLMFailureKind]].self, from: data)
        else { return }
        var out: [String: [ProcessingStage: LLMFailureKind]] = [:]
        for (date, stageMap) in raw {
            var inner: [ProcessingStage: LLMFailureKind] = [:]
            for (sName, kind) in stageMap {
                if let stage = ProcessingStage(rawValue: sName) {
                    inner[stage] = kind
                }
            }
            if !inner.isEmpty { out[date] = inner }
        }
        lastFailureByRowStage = out
    }

    /// 写盘:序列化 in-memory dict 到 JSON。最佳努力,失败只 log。
    private func persistLastFailures() {
        let url = Self.lastFailuresURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // 翻译 ProcessingStage → rawValue 让 JSON encode。
            var raw: [String: [String: LLMFailureKind]] = [:]
            for (date, stageMap) in lastFailureByRowStage {
                var inner: [String: LLMFailureKind] = [:]
                for (stage, kind) in stageMap {
                    inner[stage.rawValue] = kind
                }
                raw[date] = inner
            }
            let data = try JSONEncoder().encode(raw)
            try data.write(to: url, options: .atomic)
        } catch {
            schedLog.error("persist last_failures.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 给 UI(NeedAttention)拿一行 DB row,算 nextRetryLabel 用。
    nonisolated func attentionRow(date: String) -> ProcessingLogRow? {
        store.row(for: date)
    }

    /// 给 UI 用的"真有 stage 在跑" probe —— 读 DB,不信 in-memory eventRunning
    /// (如果 runStep 内 await 死 hang,defer 不跑 → in-memory flag 永远 stale)。
    /// 任一 row 的指定 stages 是 in_progress → true。
    /// - event/impact 共属 "event processing" pipeline,任一 in_progress 都算
    /// - distill 单独
    /// - personality 单独
    nonisolated func hasInProgressRowForEvent() -> Bool {
        store.allRows().contains { $0.event == .inProgress || $0.impact == .inProgress }
    }
    nonisolated func hasInProgressRowForDistill() -> Bool {
        store.allRows().contains { $0.distill == .inProgress }
    }
    nonisolated func hasInProgressRowForPersonality() -> Bool {
        store.allRows().contains { $0.personality == .inProgress }
    }

    /// 指定 row 的指定 stages 是否全部 complete —— 手动 run 收尾时判断
    /// "这次 run 真跑成了还是有阶段失败/被跳过"。row 不存在按未完成算。
    nonisolated func stagesComplete(date: String, stages: [ProcessingStage]) -> Bool {
        guard let row = store.row(for: date) else { return false }
        return stages.allSatisfy { row.status(of: $0) == .complete }
    }

    // MARK: - View bindings(canRunXxx + 解释文案)
    /// 当前是否有事件家族(distill or personality)在跑。
    var portraitFamilyRunning: Bool { distillRunning || personalityRunning }

    /// 能不能现在起 event job(必须自己空闲 + portrait/personality 都空闲)。
    var canRunEvent: Bool { !eventRunning && !portraitFamilyRunning }
    /// 能不能现在起 distill(必须 event 空闲 + 自己空闲;personality/classify 不挡)。
    var canRunDistill: Bool { !eventRunning && !distillRunning }
    /// 能不能现在起 personality(必须 event 空闲 + 自己空闲;distill 不挡)。
    var canRunPersonality: Bool { !eventRunning && !personalityRunning }


    // UserDefaults 键：记录两个 job 上次跑的本地日，避免一天内重复触发。
    private let kLastEvent          = "scheduler.lastEventRun"
    // kLastClassify 已下线(EventClassifier 砍掉)。老 UserDefaults key 保留
    // 不读 = 静默忽略。
    private let kLastPortrait       = "scheduler.lastPortraitRun"
    private let kLastPersonality    = "scheduler.lastPersonalityRun"
    private let kLastWritingCapture = "scheduler.lastWritingCaptureRun"
    private let kLastWritingStyle    = "scheduler.lastWritingStyleRun"

    private init() {}

    // MARK: - 生命周期

    /// App 启动调用：先回收死锁，立刻 tick 一次，再起周期 timer。
    func start() {
        // 自愈 helper 注册:开关开着就刷新一次(rebuild 后 cdhash 变也能对上 LWCR,
        // 不再"开关开着却 EX_CONFIG 起不来")。开关没开则 no-op,无副作用。
        SleepHelperClient.shared.syncRegistration()
        loadLastFailures()   // 必须在 recoverStaleLocks 之前 — recover 写 kind 时
                             // 会读老值(避免覆盖更早的 user-required kind)
        recoverStaleLocks()
        discardOrphanStagingSnapshots()
        startCatchUpTriggers()
        registerSleepWakeHooks()
        registerLidPowerHooks()
        registerNetworkMonitor()
        Task { await tick() }
    }

    func stop() {
        bgScheduler?.invalidate()
        bgScheduler = nil
        catchUpTimer?.cancel()
        catchUpTimer = nil
        KeepAwakeAssertion.shared.set(false, owner: "memory")
        sleepObserver.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        wakeObserver.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObserver = nil
        wakeObserver = nil
        unregisterLidPowerHooks()
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Sleep/Wake + Network hooks

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool = true

    // IOKit 合盖 / 电源事件(开盖即断 helper):任一变化立即 refreshKeepAwake,
    // 不等 60s 周期。这样开盖瞬间 disablesleep 立刻回 0。
    private var clamshellNotifyPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?

    private func registerSleepWakeHooks() {
        // 系统休眠前 → pause 所有 in_progress(跟 applicationWillTerminate 同
        // 路径,不计 retry)。LLM 服务不支持续接 → pause 比"被 macOS suspend
        // 然后心跳冻结被当 stale lock 失败回收"安全。
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                schedLog.notice("system willSleep → pausing in-progress jobs")
                MemoryScheduler.shared.pauseInProgressJobs()
            }
        }
        // 唤醒后立刻 tick 一次(不等下个 15min)— 让 paused 行立刻被 recover
        // 转 pending,该跑的下次重启不要等。
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                schedLog.notice("system didWake → recovering paused + immediate tick")
                MemoryScheduler.shared.recoverStaleLocks()
                await MemoryScheduler.shared.tick()
            }
        }
    }

    /// 合盖 / 电源变化的即时钩子 —— 让 helper「开盖即断」。
    /// 合盖事件:IOPMrootDomain 的 general-interest 通知(盖子开合会发)。
    /// 电源事件:IOPSNotification(拔/插电会发)。任一变化都 refreshKeepAwake,
    /// 由它按 `active && isOnAC && isLidClosed` 重新决定是否持 disablesleep。
    private func registerLidPowerHooks() {
        // —— 合盖变化 ——
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching("IOPMrootDomain"))
        if rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                               .defaultMode)
            var notifier: io_object_t = 0
            IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest,
                                             portraitLidInterestCallback, nil, &notifier)
            clamshellNotifyPort = port
            clamshellNotifier = notifier
        }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }

        // —— 电源变化 ——
        if let src = IOPSNotificationCreateRunLoopSource(portraitPowerSourceCallback, nil)?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSourceRunLoopSource = src
        }
    }

    private func unregisterLidPowerHooks() {
        if let src = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSourceRunLoopSource = nil
        }
        if clamshellNotifier != 0 { IOObjectRelease(clamshellNotifier); clamshellNotifier = 0 }
        if let port = clamshellNotifyPort {
            IONotificationPortDestroy(port)   // 一并移除其 runloop source
            clamshellNotifyPort = nil
        }
    }

    /// IOKit C 回调跳回主线程后调这里(fileprivate 让同文件顶层回调可达)。
    fileprivate func onLidOrPowerChange(_ reason: String) {
        schedLog.info("lid/power change (\(reason, privacy: .public)) → refreshKeepAwake")
        refreshKeepAwake()
    }

    // MARK: - Catch-up triggers(合盖 / 开盖空闲都能推进)

    /// 起周期触发源,替代原来的 15min Foundation Timer。普通 Timer 在合盖
    /// DarkWake / 开盖 idle-sleep 里不 fire(P0 探针 scripts/darkwake-probe.swift
    /// 实测),会让管线一睡就停到开盖。这里两路冗余,都汇到同一个幂等、节流的
    /// periodicCatchUp:
    ///   主:NSBackgroundActivityScheduler —— 探针实测在 DarkWake 里 fire 得最勤。
    ///   兜底:DispatchSourceTimer —— 比 Foundation Timer 在后台略可靠。
    /// 真正的 tick 仍按 tickInterval 节流,频繁 fire 只是多几次 no-op 检查。
    /// ⚠️ 注意:合盖 DarkWake 窗口 ~45s,本地 MLX(进程内可续算)能跨窗口磨完,
    /// 但单次 >45s 的云 RPC 被 suspend 会断、按 backoff 重试到开盖才成 —— 按工作
    /// 类型分路处理留给 P2(本 P1 只修触发层,对现状严格不劣)。
    private func startCatchUpTriggers() {
        bgScheduler?.invalidate()
        let bas = NSBackgroundActivityScheduler(identifier: "com.myportrait.scheduler.catchup")
        bas.repeats = true
        bas.interval = 60
        bas.tolerance = 30
        bas.qualityOfService = .utility
        bas.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.periodicCatchUp(reason: "bg-activity")
                completion(NSBackgroundActivityScheduler.Result.finished)
            }
        }
        bgScheduler = bas

        catchUpTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in
            Task { @MainActor in await self?.periodicCatchUp(reason: "backup-timer") }
        }
        t.resume()
        catchUpTimer = t
    }

    /// 周期源每分钟来一次,但只在距上次 tick ≥ tickInterval 才真跑(节流)。
    /// 真跑前先 recoverStaleLocks() —— 跟 didWake 同款:把 willSleep 暂停的 /
    /// 真崩溃残留的行恢复,这样合盖 DarkWake 窗口里也能续上,不再只等开盖 didWake。
    private func periodicCatchUp(reason: String) async {
        // 巡检兜底:idle(无任务)时核对一次 keep-awake —— 若系统残留 disablesleep=1
        // (helper 异常死亡留下),refreshKeepAwake → setKeepAwake(false) 会主动清。
        // 有任务在跑时本就该持有,跳过,不每分钟打扰 helper。
        if !(eventRunning || distillRunning || personalityRunning) {
            refreshKeepAwake()
        }
        guard Date().timeIntervalSince(lastTickAt) >= tickInterval else { return }
        schedLog.info("periodic catch-up (\(reason, privacy: .public)) — recover + tick")
        recoverStaleLocks()
        await tick()
    }

    /// 有 memory 管线在跑 + 插电 → 持 idle-sleep 断言,让**开盖空闲**时机器不打盹、
    /// 把活全速跑完(走开一会儿也不掉速)。合盖时此断言无效(挡不住 clamshell),
    /// 自动回落 DarkWake 慢速,无害。用 owner "memory" 引用计数,不踩转录的断言。
    /// 在三个 job 的起止(running 标志翻转处)各调一次。
    private func refreshKeepAwake() {
        let active = eventRunning || distillRunning || personalityRunning
        let want = active && PowerMonitor.isOnAC
        // IOPMAssertion:开盖空闲也要防打盹,不加合盖门槛。
        KeepAwakeAssertion.shared.set(want, owner: "memory")
        // pmset turbo:让机器**合盖**也完全清醒(IOPMAssertion 挡不住 clamshell)。
        // 只有用户在 onboarding 里启用过、且 helper 已被系统批准(.enabled)时才真正
        // 生效,否则 SleepHelperClient 内部静默 no-op(唯一真相=批准状态,无 config 闸)。
        // ⚠️ 只在**合盖**时才持有 —— 开盖瞬间(clamshell 事件触发本函数)立即松手,
        // 不让 disablesleep 留在开盖状态(开盖本就有 IOPMAssertion 兜空闲睡眠)。
        let lidWant = want && PowerMonitor.isLidClosed
        SleepHelperClient.shared.setKeepAwake(lidWant, owner: "memory")
    }

    private func registerNetworkMonitor() {
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let nowOk = (path.status == .satisfied)
                let wasOk = self.lastPathSatisfied
                self.lastPathSatisfied = nowOk
                // 从 unsatisfied → satisfied:网络回来了,立刻 tick(让 transient
                // network 失败的 row 不用等 backoff 完整窗口)。
                if !wasOk && nowOk {
                    schedLog.notice("network came back online → immediate tick")
                    await self.tick()
                }
            }
        }
        mon.start(queue: DispatchQueue(label: "scheduler.network-monitor"))
        pathMonitor = mon
    }

    /// 周期检查：每个调度器按各自频率到点、且今天还没跑过就跑。
    func tick() async {
        // tick 本身防重入。每个 runXxxJob 内部还会按 canRunXxx 二次把关,
        // 跟手动触发 / 上一次 tick 残留并发安全。
        guard !tickRunning else { return }
        tickRunning = true
        defer { tickRunning = false }
        lastTickAt = Date()   // 标记本次 tick 起跑;周期 catch-up 据此节流(见 periodicCatchUp)
        // 有手动触发的结果在等审核 / AI 编辑 draft 在等审 → 暂停定时调度,
        // 避免 distill / personality 跑完覆盖了用户没拍板的改动。
        guard !MemoryStaging.hasPending(.events),
              !MemoryStaging.hasPending(.portrait),
              !MemoryStaging.hasPending(.personality),
              !EditDraft.hasAnyPending() else {
            schedLog.info("tick: manual run / AI edit draft pending — skip")
            return
        }
        let s = ConfigStore.shared.current.scheduler
        let now = Date()

        // **两级触发顺序**(每个 job 仍按各自频率 + 一天一次去重):
        //   Tier 1 = event / writing-capture —— 上游,生产 events / writing_records。
        //   Tier 2 = portrait / personality / writing-style —— 下游,消费 Tier 1
        //            写出来的东西。
        // 规则:Tier-1 先跑(已 await 完成,保证收尾);若本 tick 有 Tier-1 跑过,
        // **不等下一个 tick,而是留 10s 缓冲后在本 tick 接着跑 Tier-2** —— 上游
        // 一跑完下游马上接力,不必干等 15 分钟。10s 缓冲让 event rebalance 重写
        // 的 events/ 盘上写入 / DB 落定,Tier-2 读到稳定状态。
        // Tier-1 内部(event ↔ writing-capture)彼此无先后,可同 tick 一起跑。
        //
        // **追赶分支(catchUp)**:daily 频率下,只要有 pending 活 + 今天没跑过,
        // 任何 tick 都触发(不必等到点)。解决"电脑半夜睡着 → scheduled tick
        // 错过 → 整天跳过"的滞后。weekly/monthly 维持"scheduled 日 + 到点"语义。
        //
        // **重试(needsRetry)**:failed / budget_deferred 的下游(weekly/monthly
        // 频率没 catchUp 兜底)合进同一按天分支,跟着每天触发一次重试 —— 不单
        // 开每-tick 重试,否则 budget_deferred 会每 15 分钟真打一次 LLM(429)。

        // ===== Tier 1 =====
        var tier1Ran = false

        // **eventToday 只挡 daily-scheduled trigger,不挡 retry** —— 跟下面
        // portrait/personality 的 retry 分支同款修法(Tier-1 此前漏修):当天
        // 跑过一次后某天 failed/budget_deferred,backoff 到点也要能当天重试,
        // 否则 UI 显示 "~10 min" 实际要等到次日,Reset 按钮也形同虚设。
        let eventToday   = lastRunDay(kLastEvent) != localDayString(now)
        let eventCatchUp = s.event.frequency == .daily && eventJobHasWork()
        let eventRetry   = s.event.frequency != .off && eventNeedsRetry()
        let eventScheduled = eventToday
            && (Self.shouldTriggerNow(config: s.event, now: now) || eventCatchUp)
        if eventScheduled || eventRetry {
            if eventScheduled { setLastRun(kLastEvent, now) }   // retry 不更新 lastRun
            await runEventJob()
            tier1Ran = true
        }

        // 写作采集:自动只是「把 staged 准备好」,等用户在 Pending review
        // 里 Approve/Reject,不直接 commit 到 writing_records。Tier 1(上游)。
        if Self.shouldTriggerNow(config: s.writingCapture, now: now),
           lastRunDay(kLastWritingCapture) != localDayString(now) {
            setLastRun(kLastWritingCapture, now)
            await runWritingCaptureJob()
            tier1Ran = true
        }

        // 有 Tier-1 跑过 → **本 tick 接着跑 Tier-2**(不等下一个 tick),只在
        // 中间留 10s 缓冲:让 event rebalance 的盘上写入 / DB 落定,Tier-2 读到
        // 稳定状态。Tier-1 已 await 完成(顺序保证),缓冲只是 settle time。
        if tier1Ran {
            schedLog.info("tick: tier-1 (event/writing-capture) ran — 10s buffer, then tier-2 in this tick")
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
        }

        // classify(自动 EventClassifier 分 folder)已下线 —— chat AI 通过
        // mp-folders 手动整理。tick 不再有 classify 分支。

        // ===== Tier 2 =====
        // **portraitToday 只挡 daily-scheduled trigger,不挡 retry** ——
        // retry 已被 backoffMs(10min→1h→6h→24h)节流,daily 双重 guard 会让
        // 中午跑失败的 row 等到第二天才再试。bug:6-03 personality 13:08 失败
        // → portraitToday=false → 不再触发 → attention 行 9 小时都在显示。
        let portraitToday   = lastRunDay(kLastPortrait) != localDayString(now)
        let portraitCatchUp = s.portrait.frequency == .daily && portraitJobHasWork()
        let portraitRetry   = s.portrait.frequency != .off && portraitNeedsRetry()
        let portraitScheduled = portraitToday
            && (Self.shouldTriggerNow(config: s.portrait, now: now) || portraitCatchUp)
        if portraitScheduled || portraitRetry {
            if portraitScheduled { setLastRun(kLastPortrait, now) }   // retry 不更新 lastRun
            await runPortraitJob()
        }

        let personalityToday   = lastRunDay(kLastPersonality) != localDayString(now)
        let personalityCatchUp = s.personality.frequency == .daily && personalityJobHasWork()
        let personalityRetry   = s.personality.frequency != .off && personalityNeedsRetry()
        let personalityScheduled = personalityToday
            && (Self.shouldTriggerNow(config: s.personality, now: now) || personalityCatchUp)
        if personalityScheduled || personalityRetry {
            if personalityScheduled { setLastRun(kLastPersonality, now) }
            await runPersonalityJob()
        }

        // writing_style:auto 模式 → 直接落 portrait/writing_style/,不审核。
        // 跟 writing capture 一样不参与 event/portrait/personality 三锁。Tier 2(下游)。
        if Self.shouldTriggerNow(config: s.writingStyle, now: now),
           lastRunDay(kLastWritingStyle) != localDayString(now) {
            setLastRun(kLastWritingStyle, now)
            await runWritingStyleJob()
        }
    }

    /// 跑 writing_style auto —— 跟 writing capture 同模式:失败 swallow + log,
    /// 不阻塞下一次 tick。dependency gate:writing_style 是 writing_capture 的
    /// 下游,没新 writing_records 可消费就早退,避免空跑。
    func runWritingStyleJob() async {
        guard let distiller = WritingStyleDistiller.shared else {
            schedLog.warning("writingStyle tick: distiller not initialized — skip")
            return
        }
        // dependency gate:0 unprocessed → 跳本次 tick,不调 distiller。
        // distiller.runAuto 内部也有同样的 gate(双层兜底),但这里先查能省 token
        // 的 nap-guard / refresh-weights 一连串开销。
        let unprocessed = (try? distiller.store.unprocessedCount()) ?? 0
        guard unprocessed > 0 else {
            schedLog.info("writingStyle tick: 0 unprocessed writing_records — skip (waiting for writing_capture)")
            store.appendPipelineRun(trigger: "scheduler", pipeline: "Speech style", outcome: "no-work", reason: nil)
            return
        }
        do {
            let s = try await distiller.runAuto()
            schedLog.info("writingStyle auto: status=\(s.status.rawValue, privacy: .public) records=\(s.recordsCount) drafts=\(s.draftsCount)")
            NotificationCenterService.shared.post(.schedulerRun(
                pipeline: "Speech style",
                success: true,
                summary: "\(s.recordsCount) record\(s.recordsCount == 1 ? "" : "s") · \(s.draftsCount) draft\(s.draftsCount == 1 ? "" : "s")"
            ))
            store.appendPipelineRun(trigger: "scheduler", pipeline: "Speech style", outcome: "success", reason: nil)
        } catch {
            schedLog.warning("writingStyle auto failed: \(String(describing: error), privacy: .public)")
            NotificationCenterService.shared.post(.schedulerRun(
                pipeline: "Speech style",
                success: false,
                summary: error.localizedDescription
            ))
            store.appendPipelineRun(trigger: "scheduler", pipeline: "Speech style", outcome: "failure", reason: error.localizedDescription)
        }
    }

    /// 跑写作采集 worker(backlog 模式)—— 跟手动 Run 一样,从 cursor 跑到现在
    /// 一次性出一个 staged batch。失败 swallow + log,不阻塞下一次 tick。
    /// 已经有 pending_review / processing → backlog 内部自带 guard 跳过,不会
    /// 重复跑。
    func runWritingCaptureJob() async {
        guard let worker = WritingCaptureWorker.shared else {
            schedLog.warning("writingCapture tick: worker not initialized — skip")
            return
        }
        do {
            let summary = try await worker.runBacklog()
            schedLog.info("writingCapture backlog: status=\(summary.status.rawValue, privacy: .public) records=\(summary.recordsCount) discarded=\(summary.discardedCount)")
            // recordsCount == 0 = 没新写作可处理,跟 .noWork 等价 → 静默,不弹噪音。
            if summary.recordsCount > 0 {
                NotificationCenterService.shared.post(.schedulerRun(
                    pipeline: "Writing capture",
                    success: true,
                    summary: "\(summary.recordsCount) record\(summary.recordsCount == 1 ? "" : "s")"
                        + (summary.discardedCount > 0 ? " · \(summary.discardedCount) discarded" : "")
                ))
                store.appendPipelineRun(trigger: "scheduler", pipeline: "Writing capture", outcome: "success", reason: nil)
            } else {
                store.appendPipelineRun(trigger: "scheduler", pipeline: "Writing capture", outcome: "no-work", reason: nil)
            }
        } catch {
            schedLog.warning("writingCapture backlog failed: \(String(describing: error), privacy: .public)")
            NotificationCenterService.shared.post(.schedulerRun(
                pipeline: "Writing capture",
                success: false,
                summary: error.localizedDescription
            ))
            store.appendPipelineRun(trigger: "scheduler", pipeline: "Writing capture", outcome: "failure", reason: error.localizedDescription)
        }
    }

    /// 给定调度器配置与当前时刻，判断现在是否落在它的触发窗口内
    /// （频率匹配 + 到点）。是否"今天已跑过"由调用方另做去重。
    static func shouldTriggerNow(config: SchedulerConfig, now: Date) -> Bool {
        guard config.frequency != .off else { return false }
        let cal = Calendar.current

        switch config.frequency {
        case .off:
            return false
        case .daily:
            break   // 每天都匹配
        case .weekly:
            // Calendar.weekday 是 1…7（1=周日）；config.dayOfWeek 是 0…6。
            let wd = cal.component(.weekday, from: now) - 1
            guard wd == config.dayOfWeek else { return false }
        case .monthly:
            let day = cal.component(.day, from: now)
            guard day == effectiveDayOfMonth(config.dayOfMonth, now: now, cal: cal) else {
                return false
            }
        }

        // 到点：当前时刻 ≥ 配置时刻（按分钟比较）。
        let nowMinutes = cal.component(.hour, from: now) * 60
            + cal.component(.minute, from: now)
        return nowMinutes >= config.hour * 60 + config.minute
    }

    /// monthly 的 day-of-month edge case：选 31 但当月只有 30 天 → 落到当月
    /// 最后一天。
    static func effectiveDayOfMonth(_ requested: Int, now: Date, cal: Calendar) -> Int {
        let lastDay = cal.range(of: .day, in: .month, for: now)?.count ?? 28
        return min(max(requested, 1), lastDay)
    }

    /// runEventJob / runPortraitJob 的结果。手动触发的 UI 用它区分
    /// "真跑了" / "没活干直接罢工" / "调度器在忙"。
    enum JobOutcome: Sendable {
        /// 跑了。`days` 是处理的 ProcessingLog 行 key —— event job 是日期串，
        /// portrait job 是 ["_distill_anchor"]。Reject 时用来重置回 pending。
        case ran(days: [String])
        case noWork        // 没有待处理的天 / 画像已最新 —— 直接罢工
        case busy          // 调度器或另一次触发正在跑
    }

    /// 一次 pipeline 运行的触发来源 —— 记进 pipeline_runs(Changelog 页展示)。
    enum RunTrigger: String, Sendable {
        case runNow = "run-now"
        case scheduler = "scheduler"
    }

    /// event job 现在有没有活干（有未处理的天）。手动触发拍快照前先 check，
    /// 没活就直接罢工、不浪费快照。
    func eventJobHasWork() -> Bool {
        !pendingDays(cap: dayCap).isEmpty
    }

    /// portrait job 现在有没有活干（distill 哨兵 needsWork）。
    func portraitJobHasWork() -> Bool {
        _ = store.ensureRow(for: distillAnchor)
        return (store.row(for: distillAnchor)?.distill ?? .idle).needsWork
    }

    // classifierJobHasWork / scanAllEventPaths 已下线(EventClassifier 砍掉)。

    /// personality job 现在有没有活干（per-day 待处理列表非空）。
    func personalityJobHasWork() -> Bool {
        !pendingPersonalityDays(cap: dayCap).isEmpty
    }

    // MARK: - event job：event 聚类 + impact 评分（per-day）

    /// 处理至多 `dayCap` 个未完成的数据日（旧 → 新）。每天 event → impact
    /// 顺序跑，各自持锁 + 心跳。手动触发与定时触发走同一个函数。
    @discardableResult
    func runEventJob(trigger: RunTrigger = .scheduler) async -> JobOutcome {
        guard canRunEvent else { return .busy }
        eventRunning = true
        refreshKeepAwake()
        defer { eventRunning = false; refreshKeepAwake() }
        stopRequestedOwners.remove(PipelineOwner.event)   // 清 stale 标记
        eventProgress = StepProgress(fraction: 0, stage: "Reading timeline")
        defer { eventProgress = StepProgress() }

        let days = pendingDays(cap: dayCap)
        guard !days.isEmpty else {
            schedLog.info("event job: no pending days")
            store.appendPipelineRun(trigger: trigger.rawValue, pipeline: "Event processing", outcome: "no-work", reason: nil)
            return .noWork
        }
        print("[Scheduler] event job — \(days.count) day(s) to process")
        DiagLog.event("scheduler.event.start", ctx: [
            "days":  days.map { ProcessingLogStore.dayString($0) },
            "count": days.count,
        ])
        // pause 代际快照 —— 见 pauseGeneration 注释。
        let pauseGen = pauseGeneration

        for (idx, day) in days.enumerated() {
            // 运行期间被 pause 接管(willSleep / 退出)→ 立即中止剩余天。
            // 手动 staged run 的快照已被 pause reject,继续写会绕过审核;
            // 当 .busy 返回(不 markRan、不发 success 通知)。
            guard pauseGen == pauseGeneration else { return .busy }
            // 用户点了 Stop → 当前步的 agent 已被杀(步已标 failed),这里
            // 中止剩余天,别再起新 agent。返回 .ran(已动过的天):手动路径
            // 的 autoFinishEmptyStaging 会把没跑完的天重置回 pending。
            if consumeStopRequest(PipelineOwner.event) {
                schedLog.notice("event job: stopped by user — aborting remaining days")
                return .ran(days: days.prefix(idx).map { ProcessingLogStore.dayString($0) })
            }
            let ds = ProcessingLogStore.dayString(day)
            _ = store.ensureRow(for: ds)

            // raw gate：数据还没收齐就跳过，下次触发再处理。
            guard isRawReady(day) else {
                store.setStatus(date: ds, stage: .raw, status: .pending)
                continue
            }
            store.setStatus(date: ds, stage: .raw, status: .complete)

            // 进度:总体 = (已完成天数 + 当天内部进度) / 总天数。当天内部
            // 进度的分段:0-0.06 读帧,0.06-0.60 LLM 聚类(按 batch 推进),
            // 0.60-0.68 落盘(按 cluster 推进),0.70 event 步完,0.70-0.98
            // impact(按评分 batch 推进)。LLM 调用中条不动是预期(无 token 级信号)。
            let dayN = Double(days.count)
            let dayLabel = "Day \(idx + 1)/\(days.count)"
            func setEventProgress(_ dayFrac: Double, _ stage: String, _ detail: String) {
                eventProgress = StepProgress(
                    fraction: (Double(idx) + min(1, max(0, dayFrac))) / dayN,
                    stage: stage, detail: detail
                )
            }

            // event 步。
            var row = store.row(for: ds) ?? ProcessingLogRow(date: ds)
            if row.event.needsWork {
                setEventProgress(0, "Building events", dayLabel)
                await runStep(date: ds, stage: .event, processor: "event", rollbackDay: day) {
                    let nb = self.daysBackToCover(day)
                    // skipWeightPass:weight pass 挪到 days 循环结束后只跑
                    // 一次(下面),否则 dayCap=7 时全树重写 7 遍。
                    let r = try await Backfill.run(daysBack: nb, onlyDay: day, skipWeightPass: true) { p in
                        switch p.unit {
                        case .llmBatch(let i, let n) where n > 0:
                            setEventProgress(0.06 + 0.54 * Double(i - 1) / Double(n),
                                             "Building events",
                                             "\(dayLabel) · clustering batch \(i)/\(n)")
                        case .materialise(let i, let n) where n > 0:
                            setEventProgress(0.60 + 0.08 * Double(i) / Double(n),
                                             "Building events",
                                             "\(dayLabel) · writing event \(i)/\(n)")
                        default:
                            setEventProgress(0.03, "Building events", "\(dayLabel) · \(p.phase)")
                        }
                    }
                    return r.llmFailedDays == 0 ? .success : .failed
                }
                row = store.row(for: ds) ?? row
            }

            // impact 步：仅当 event 已 complete。按日扫 events/<day>/ 下的 unscored。
            if row.event == .complete, row.impact.needsWork {
                setEventProgress(0.70, "Scoring impact", dayLabel)
                await runStep(date: ds, stage: .impact, processor: "impact", rollbackDay: nil) {
                    let dir = PortraitPaths.eventsDayDir(for: day)
                    let cfg = ConfigStore.shared.current.scheduler.event
                    let r = try await ImpactScorer(provider: cfg.resolvedProvider, model: cfg.resolvedModel).rescoreAll(root: dir) { p in
                        guard p.batchCount > 0 else { return }
                        setEventProgress(0.70 + 0.28 * Double(p.batchIndex) / Double(p.batchCount),
                                         "Scoring impact",
                                         "\(dayLabel) · \(p.scoredCount)/\(p.totalCount) events scored")
                    }
                    return r.failedCount == 0 ? .success : .failed
                }
            }
        }

        // 最后一天处理中被 pause 接管 → 同样中止收尾(rebalance / mark
        // pending / markRan 都不该跑)。
        guard pauseGen == pauseGeneration else { return .busy }

        // weight pass：跟 rebalance 一样，整个 event 处理跑完只跑一次
        // （逐天的 Backfill.run 传了 skipWeightPass）。pause 中止时跟
        // rebalance 一起被上面的 guard 跳过；个别天失败不影响它跑。
        eventProgress = StepProgress(fraction: 0.98, stage: "Recomputing weights")
        await Backfill.weightPass()

        // 周预算 rebalance：整个 event 处理跑完只跑一次（不是按天跑 N 次，
        // 否则一次 run 就把 rebalance_count 烧到 maxRebalances 把事件冻死）。
        eventProgress = StepProgress(fraction: 0.99, stage: "Rebalancing")
        _ = MemoryBudget_applyToDisk()

        // 新事件到了 → distill 锚点重新标 pending,下一次 tick 自动 catch up。
        // (老 classify anchor 不再 mark pending —— EventClassifier 已下线。)
        _ = store.ensureRow(for: distillAnchor)
        store.setStatus(date: distillAnchor, stage: .distill, status: .pending)

        // 同时把这些天的 personality_status 标 pending —— 事件变了,
        // 那天的 personality 也得重跑(per-day,跟 distill 不一样)。
        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            let row = store.row(for: ds)
            // 仅 event+impact 都 complete 的天才有意义跑 personality。
            if row?.event == .complete, row?.impact == .complete {
                store.setStatus(date: ds, stage: .personality, status: .pending)
            }
        }

        let dayStrings = days.map { ProcessingLogStore.dayString($0) }
        let outcome: JobOutcome = .ran(days: dayStrings)
        // 最后一天处理中被 Stop → 不发通知(用户自己停的,别报"auto-recovering")。
        if !consumeStopRequest(PipelineOwner.event) {
            postPipelineOutcomeAlert(
                pipeline: "Event processing",
                dates: dayStrings,
                successSummary: "Processed \(days.count) day\(days.count == 1 ? "" : "s")",
                trigger: trigger
            )
        }
        return outcome
    }

    // classify job(自动 EventClassifier 跑 LLM 分 folder)已整段下线 ——
    // 改成 chat AI 通过 mp-folders 手动按用户对话需求整理。

    // MARK: - portrait job：distill

    /// 跑一次完整 distill，状态记在 `_distill_anchor` 哨兵行（持锁 + 心跳，
    /// 崩溃可恢复）。distiller 扫盘上所有非归档事件 —— 失败日的事件已被 event
    /// job 清除，所以盘上事件天然只来自 event 处理成功的日。
    @discardableResult
    func runPortraitJob(trigger: RunTrigger = .scheduler) async -> JobOutcome {
        guard canRunDistill else { return .busy }
        distillRunning = true
        refreshKeepAwake()
        defer { distillRunning = false; refreshKeepAwake() }
        stopRequestedOwners.remove(PipelineOwner.distill)   // 清 stale 标记
        distillProgress = StepProgress(fraction: 0, stage: "Distilling portrait")
        defer { distillProgress = StepProgress() }

        _ = store.ensureRow(for: distillAnchor)
        let distill = store.row(for: distillAnchor)?.distill ?? .idle
        guard distill.needsWork else {
            schedLog.info("portrait job: distill is \(distill.rawValue, privacy: .public) — skip")
            store.appendPipelineRun(trigger: trigger.rawValue, pipeline: "Portrait distillation", outcome: "no-work", reason: nil)
            return .noWork
        }
        print("[Scheduler] portrait job — distilling")
        DiagLog.event("scheduler.distill.start")
        // pause 代际快照 —— 见 pauseGeneration 注释。
        let pauseGen = pauseGeneration

        await runStep(date: distillAnchor, stage: .distill, processor: "distill", rollbackDay: nil) {
            let cfg = ConfigStore.shared.current.scheduler.portrait
            let r = try await PortraitDistiller(provider: cfg.resolvedProvider, model: cfg.resolvedModel).distill { p in
                // categoryIndex:每个 category 开始前发 idx(0-based),结束后发
                // idx+1 —— 条按 category 推进,detail 显示当前类目 + 已写条数。
                guard p.categoryCount > 0 else { return }
                // ×0.95:最后一个 category 完成 ≠ 整步结束(distill 内部还有
                // Archiver 收尾),别提前顶到 100% 让人误以为卡住。
                self.distillProgress = StepProgress(
                    fraction: 0.95 * Double(p.categoryIndex) / Double(p.categoryCount),
                    stage: "Distilling portrait",
                    detail: "\(p.category) · \(min(p.categoryIndex + 1, p.categoryCount))/\(p.categoryCount) categories"
                        + (p.written > 0 ? " · \(p.written) updated" : "")
                )
            }
            if r.llmFailedCategories > 0 {
                // 记真因(第一个失败 category 的错误原文)。不记的话 applyOutcome
                // 的 fallback 只写笼统的 "distill step reported failure",
                // attention / 通知里看不出到底是限流、解析还是空响应。
                self.recordFailure(
                    date: self.distillAnchor, stage: .distill,
                    kind: .unknownTransient(reason: r.firstFailureReason
                        ?? "\(r.llmFailedCategories) category(ies) failed")
                )
                return .failed
            }
            return .success
        }
        // 运行期间被 pause 接管 → 当 .busy 返回(不 markRan、不发通知)。
        guard pauseGen == pauseGeneration else { return .busy }
        // 用户 Stop(agent 已被杀,步已标 failed)→ 不发通知。distill 单步,
        // 无剩余循环要中止,consume 只为吞掉标记 + 静音。
        if !consumeStopRequest(PipelineOwner.distill) {
            postPipelineOutcomeAlert(
                pipeline: "Portrait distillation",
                dates: [distillAnchor],
                successSummary: "Long-term portrait updated",
                trigger: trigger
            )
        }
        return .ran(days: [distillAnchor])
    }

    // MARK: - personality job:per-day events → personality(events + OCR 验证)

    /// 跑 personality refresh,**per-day**:遍历 event+impact 都 complete、
    /// 但 personality 还需做的天,最多 `dayCap` 个(从最旧未做开始)。跟
    /// distill(anchor 模式)不同 —— personality 跟 events 一样按天滚动,
    /// 进度落在每天那行的 `personality_status` 列。
    @discardableResult
    func runPersonalityJob(trigger: RunTrigger = .scheduler) async -> JobOutcome {
        guard canRunPersonality else { return .busy }
        personalityRunning = true
        refreshKeepAwake()
        defer { personalityRunning = false; refreshKeepAwake() }
        stopRequestedOwners.remove(PipelineOwner.personality)   // 清 stale 标记
        defer { personalityProgress = StepProgress() }

        let days = pendingPersonalityDays(cap: dayCap)
        guard !days.isEmpty else {
            schedLog.info("personality job: no pending days")
            store.appendPipelineRun(trigger: trigger.rawValue, pipeline: "Personality refresh", outcome: "no-work", reason: nil)
            return .noWork
        }
        print("[Scheduler] personality job — \(days.count) day(s) to process")
        DiagLog.event("scheduler.personality.start", ctx: [
            "days": days.map { ProcessingLogStore.dayString($0) },
        ])
        // pause 代际快照 —— 见 pauseGeneration 注释。
        let pauseGen = pauseGeneration

        for (idx, day) in days.enumerated() {
            // 运行期间被 pause 接管 → 中止剩余天,当 .busy 返回
            // (不 markRan、不发 success 通知)。
            guard pauseGen == pauseGeneration else { return .busy }
            // 用户 Stop → 中止剩余天(同 event job;被杀那天已标 failed,
            // autoFinishEmptyStaging 会重置它回 pending)。
            if consumeStopRequest(PipelineOwner.personality) {
                schedLog.notice("personality job: stopped by user — aborting remaining days")
                return .ran(days: days.prefix(idx).map { ProcessingLogStore.dayString($0) })
            }
            let ds = ProcessingLogStore.dayString(day)
            let dayLabel = "\(ds) · day \(idx + 1)/\(days.count)"
            // day 内子进度:PersonalityRefresh.Phase → 当天预算带。带宽 ≈
            // 各阶段典型耗时占比(snapshot 是最重的 LLM 调用,占大头)。
            func setPersonalityProgress(_ dayFrac: Double, _ detail: String) {
                personalityProgress = StepProgress(
                    fraction: (Double(idx) + min(1, max(0, dayFrac))) / Double(days.count),
                    stage: "Refreshing personality",
                    detail: detail
                )
            }
            setPersonalityProgress(0.02, dayLabel)
            await runStep(date: ds, stage: .personality,
                          processor: "personality", rollbackDay: nil) {
                let cfg = ConfigStore.shared.current.scheduler.personality
                let r = try await PersonalityRefresh(provider: cfg.resolvedProvider, model: cfg.resolvedModel, clusterModel: cfg.resolvedModelLight).refresh(day: day) { phase in
                    switch phase {
                    case .snapshot:
                        setPersonalityProgress(0.05, "\(dayLabel) · daily snapshot (LLM)")
                    case .ocrVerify(let i, let n) where n > 0:
                        setPersonalityProgress(0.45 + 0.10 * Double(i) / Double(n),
                                               "\(dayLabel) · OCR check tag \(i)/\(n)")
                    case .ocrVerify:
                        setPersonalityProgress(0.55, "\(dayLabel) · OCR check")
                    case .cluster:
                        setPersonalityProgress(0.58, "\(dayLabel) · clustering tags (LLM)")
                    case .merge:
                        setPersonalityProgress(0.72, "\(dayLabel) · merging concepts (LLM)")
                    case .apply:
                        setPersonalityProgress(0.95, "\(dayLabel) · writing concepts")
                    }
                }
                print("[Scheduler] personality \(ds): events \(r.eventsTotal)→\(r.eventsAboveWeight)(>w\(PersonalityRefresh.minEventWeight)) → snapshot \(r.snapshotTags) → ocr kept \(r.ocrKept)/dropped \(r.ocrDropped) | created=\(r.apply.created) merged=\(r.apply.merged) skipped=\(r.apply.skipped)")
                // **可疑空值 → .failed 触发重试**,别静默标 complete 永久锁死。
                // 只针对"有高权重事件 + LLM 提了 tag,却被 OCR 验证全丢光"这一种 ——
                // 这是真 bug 现场(配合 minOCRFrames 降到 15,重试有机会通过)。
                // 真低活跃日(eventsAboveWeight==0)或 LLM 判断无特质(snapshotTags==0)
                // 是合法的空,照常 .success,不重试、不噪音。
                if r.eventsAboveWeight > 0, r.snapshotTags > 0, r.ocrKept == 0 {
                    schedLog.notice("personality \(ds, privacy: .public): \(r.snapshotTags) tag(s) all dropped at OCR gate → .failed (will retry)")
                    return .failed
                }
                return .success
            }
        }
        // 最后一天处理中被 pause 接管 → 同样中止收尾。
        guard pauseGen == pauseGeneration else { return .busy }
        let dayStrings = days.map { ProcessingLogStore.dayString($0) }
        // 最后一天处理中被 Stop → 不发通知(用户自己停的)。
        if !consumeStopRequest(PipelineOwner.personality) {
            postPipelineOutcomeAlert(
                pipeline: "Personality refresh",
                dates: dayStrings,
                successSummary: "Refreshed \(days.count) day\(days.count == 1 ? "" : "s")",
                trigger: trigger
            )
        }
        return .ran(days: dayStrings)
    }

    // MARK: - 单步执行（持锁 + 心跳 + 结果落库）

    /// 跑一个 LLM 步：先持锁起心跳，跑 `work`，再按结果落库、释放锁。
    /// `work` 返回 `.success` / `.failed`，撞额度时抛 `BudgetExhaustedError`。
    private func runStep(
        date: String,
        stage: ProcessingStage,
        processor: String,
        rollbackDay: Date?,
        _ work: () async throws -> StepOutcome
    ) async {
        // 先持锁（写 active_processor + 初始心跳），再标 in_progress。
        // 这个顺序下，若在两步之间崩溃，recoverStaleLocks 仍能凭 active_processor
        // 发现并释放锁。
        store.acquireLock(date: date, processor: processor)
        store.setStatus(date: date, stage: stage, status: .inProgress)
        // 清掉这 stage 的旧 failure kind —— 准备让本次 run 的结果覆盖。
        // 防 bug:上次 paused recovery 写 .appInterruptionRestarted,
        // 之后 LLM 跑也失败但 kind 没被新错误覆盖(例如 isRawReady 跳过 /
        // Backfill 早期 throw before 写 kind)→ postPipelineOutcomeAlert
        // 拿到 stale "interrupted" → 每次启动都弹"中断了"通知,即使本次
        // 根本没在跑中断。
        clearFailure(date: date, stage: stage)
        let hb = startHeartbeat(for: date)
        // pause 代际快照 —— 见 pauseGeneration 注释。
        let pauseGen = pauseGeneration

        // 按 stage 派 pipeline owner —— Stop 时只杀本 pipeline 的 LLM 子进程。
        let owner = Self.pipelineOwner(for: stage)
        // 60min 兜底 timeout —— detached timer task,到点杀 owner 的 LLM
        // 子进程。PiAgent 的 stdin/stdout 断开 → work() 内 await 抛错 →
        // catch 走 .failed → defer 自然清 eventRunning,UI 不再卡死 "Running"。
        // work() 正常返回 → defer 取消 timer。
        let stageRaw = stage.rawValue
        let timeoutTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
            if !Task.isCancelled {
                schedLog.error("\(date, privacy: .public)/\(stageRaw, privacy: .public): timeout after 60min — killing LLM children")
                await MemoryScheduler.shared._fireStepTimeout(owner: owner)
            }
        }
        defer { timeoutTask.cancel() }

        let outcome: StepOutcome
        do {
            outcome = try await PiAgentRegistry.$owner.withValue(owner) { try await work() }
        } catch let e as BudgetExhaustedError {
            schedLog.notice("\(date)/\(processor): budget exhausted — \(e.message, privacy: .public)")
            // BudgetExhaustedError 仍走 .budgetExhausted(老路径不动),但同时
            // 让 classifier 分一下 — 区分 transient throttle vs permanent quota
            // exhaustion,供 UI banner 区分 "auto-recovering" vs "Top up & click
            // Problem solved"。
            recordFailure(date: date, stage: stage, kind: ErrorClassifier.classify(e))
            outcome = .budgetExhausted
        } catch {
            let kind = ErrorClassifier.classify(error)
            recordFailure(date: date, stage: stage, kind: kind)
            schedLog.error("\(date)/\(processor) failed [\(kind.shortLabel, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            outcome = .failed
        }
        hb.cancel()

        // 代际校验:work() 期间发生过 pauseInProgressJobs → 该行已被标
        // paused + 释放锁,状态由 didWake 的 recoverStaleLocks 接管。这里
        // 不能再 applyOutcome / releaseLock:否则唤醒后复活的本任务会把刚
        // 恢复成 failed 的行覆盖成 complete、或再 bumpRetry 双重记账,甚至
        // 释放掉之后新一次 run 持有的锁。
        guard pauseGen == pauseGeneration else {
            schedLog.notice("\(date, privacy: .public)/\(processor, privacy: .public): paused mid-flight — discarding outcome (recovery path owns this row)")
            return
        }

        applyOutcome(date: date, stage: stage, outcome: outcome, rollbackDay: rollbackDay)
        store.releaseLock(date: date)
    }

    /// runStep 60min timer 到点回调 —— **只杀本 pipeline(owner)的 LLM 子进程**,
    /// 不动并行 pipeline / 写作采集 worker / 用户 chat(stopAll 会一锅端,
    /// stopGroup 才精准),defer 自然清 in-memory flag。
    func _fireStepTimeout(owner: String) {
        _ = PiAgentRegistry.shared.stopGroup(owner)
    }

    /// 按 stage 派 pipeline owner —— 超时 / pause 只杀本 pipeline 的 LLM 子进程。
    private static func pipelineOwner(for stage: ProcessingStage) -> String {
        switch stage {
        case .distill:     return PipelineOwner.distill
        case .personality: return PipelineOwner.personality
        default:           return PipelineOwner.event   // raw / event / impact / classify
        }
    }

    /// 把一个步的结果落库：成功 → complete；撞额度 → budget_deferred（不计
    /// retry）；失败 → retry +1，回滚（event 步删当天 event），retry ≥ 上限转
    /// dead_letter。
    private func applyOutcome(
        date: String,
        stage: ProcessingStage,
        outcome: StepOutcome,
        rollbackDay: Date?
    ) {
        switch outcome {
        case .success:
            store.setStatus(date: date, stage: stage, status: .complete)
            // 成功 → 清掉这 stage 的 last failure(UI 不再显示陈旧 kind)
            clearFailure(date: date, stage: stage)
            print("[Scheduler] \(date)/\(stage.rawValue): complete")

        case .budgetExhausted:
            store.setStatus(date: date, stage: stage, status: .budgetDeferred)
            print("[Scheduler] \(date)/\(stage.rawValue): budget_deferred (retry_count unchanged)")

        case .failed:
            // 回滚：event 步失败删当天 event 目录，重跑不污染数据。
            // impact / distill 幂等（重扫 unscored / 整体重蒸馏），无需显式回滚。
            if let day = rollbackDay {
                deleteEvents(on: day)
            }
            // 永远走 .failed —— 不再升级 .deadLetter。retry_count++ 仍记录,但只
            // 用来算 backoff 间隔,不作为"放弃"门槛。频率由 backoffMs(retry:) 控制。
            let n = store.bumpRetry(date: date)
            store.setStatus(date: date, stage: stage, status: .failed)
            // work() **返回** .failed(而非 throw,如部分天 llmFailedDays>0)时,
            // runStep 的 catch 没触发 → recordFailure 没被调用,kind 为空 →
            // postPipelineOutcomeAlert / attention 这套现成失败逻辑识别不到,会误判
            // 成功(误记 success)。补 fallback kind(.unknownTransient 就是为"没分到
            // 具体类的失败"设计的桶)。已有 kind(throw 路径写过)则不覆盖。
            if lastFailureKind(date: date, stage: stage) == nil {
                recordFailure(date: date, stage: stage,
                              kind: .unknownTransient(reason: "\(stage.rawValue) step reported failure"))
            }
            print("[Scheduler] \(date)/\(stage.rawValue): failed (retry_count=\(n), next retry in \(backoffMs(retry: n) / 1000)s)")
            DiagLog.warn("scheduler.stage.failed", ctx: [
                "date": date, "stage": stage.rawValue, "retry": n,
            ])
        }
    }

    /// 失败后到下次允许重试的最小间隔。retry_count 越大,等得越久,封顶 24h。
    /// 0 → 立刻;1 → 10min;2 → 1h;3 → 6h;4+ → 24h。
    /// 用户主动点 "Reset" 会把 retry_count 归零 → 立即重试。
    private func backoffMs(retry: Int) -> Int64 {
        switch retry {
        case 0:     return 0
        case 1:     return  10 * 60 * 1000          // 10 min
        case 2:     return  60 * 60 * 1000          // 1 h
        case 3:     return 6 * 60 * 60 * 1000       // 6 h
        default:    return 24 * 60 * 60 * 1000      // 24 h cap
        }
    }

    // MARK: - 通知收口 helper

    /// 5 个 runXxxJob 末尾共用:扫该次涉及的 days × stages,按 last failure
    /// kind 决定发一条通知(success / needs-fix / auto-recovering),避免一次 run
    /// 弹两条噪音。
    /// - `pipeline`:UI 名 (e.g. "Event processing")
    /// - `dates`:本次 run 涉及的 ProcessingLog row date(锚行也算 1 个)
    /// - `successSummary`:全成功时用的 summary 文案
    func postPipelineOutcomeAlert(pipeline: String, dates: [String], successSummary: String, trigger: RunTrigger = .scheduler) {
        // 扫 dates 找最严重的 failure kind:优先 user-required > auto-transient。
        var userRequired: LLMFailureKind?
        var autoTransient: (kind: LLMFailureKind, retry: Int, updatedAtMs: Int64)?
        for date in dates {
            guard let row = store.row(for: date) else { continue }
            for stage in ProcessingStage.allCases where row.status(of: stage) == .failed
                || row.status(of: stage) == .budgetDeferred
                || row.status(of: stage) == .deadLetter {
                if let kind = lastFailureByRowStage[date]?[stage] {
                    if kind.isUserRequired, userRequired == nil {
                        userRequired = kind
                    } else if !kind.isUserRequired, autoTransient == nil {
                        autoTransient = (kind, row.retryCount, row.updatedAtMs)
                    }
                }
            }
        }
        if let kind = userRequired {
            NotificationCenterService.shared.post(.pipelineNeedsFix(
                pipeline: pipeline,
                kindLabel: kind.shortLabel,
                userMessage: kind.userMessage
            ))
            store.appendPipelineRun(trigger: trigger.rawValue, pipeline: pipeline, outcome: "failure", reason: kind.shortLabel)
            return
        }
        if let auto = autoTransient {
            NotificationCenterService.shared.post(.pipelineAutoRecovering(
                pipeline: pipeline,
                kindLabel: auto.kind.shortLabel,
                nextRetryLabel: nextRetryLabel(retryCount: auto.retry, updatedAtMs: auto.updatedAtMs)
            ))
            store.appendPipelineRun(trigger: trigger.rawValue, pipeline: pipeline, outcome: "auto-recovering", reason: auto.kind.shortLabel)
            return
        }
        // 全 complete / 无失败 kind → 老 success 通知。
        NotificationCenterService.shared.post(.schedulerRun(
            pipeline: pipeline,
            success: true,
            summary: successSummary
        ))
        store.appendPipelineRun(trigger: trigger.rawValue, pipeline: pipeline, outcome: "success", reason: nil)
    }

    /// 给 UI / 通知用的人话:"in 10 min" / "in 1 h" / "in 6 h" / "in 24 h" /
    /// "now"。基于 row 的 retry_count + updatedAtMs 算从现在还要等多久。
    nonisolated func nextRetryLabel(retryCount: Int, updatedAtMs: Int64) -> String {
        let backoff: Int64 = {
            switch retryCount {
            case 0:     return 0
            case 1:     return  10 * 60 * 1000
            case 2:     return  60 * 60 * 1000
            case 3:     return 6 * 60 * 60 * 1000
            default:    return 24 * 60 * 60 * 1000
            }
        }()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let remainingMs = max(0, (updatedAtMs + backoff) - now)
        if remainingMs == 0 { return "next tick" }
        let mins = remainingMs / 60_000
        if mins < 60 { return "~\(max(1, mins)) min" }
        let hrs = mins / 60
        return "~\(hrs) h"
    }

    /// 一行 stage 现在是否到点该重试。failed/budgetDeferred/deadLetter 才需要
    /// 算 backoff;pending/idle/paused 立即 ready。
    private func backoffReady(status: ProcessingStatus, retryCount: Int, updatedAtMs: Int64) -> Bool {
        switch status {
        case .idle, .pending, .paused: return true
        case .failed, .budgetDeferred, .deadLetter:
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return now >= updatedAtMs + backoffMs(retry: retryCount)
        case .inProgress, .complete, .partial: return false
        }
    }

    // MARK: - 崩溃恢复

    /// 启动时回收死锁：心跳过期的 in_progress 行 —— 处理器在持锁期间崩了。
    /// 当一次失败处理（retry +1、event 回滚），跟显式失败一致，这样反复崩溃
    /// 最终也会到 dead_letter。
    func recoverStaleLocks() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for row in store.allRows() {
            guard row.activeProcessor != nil else { continue }
            let hb = row.heartbeatMs ?? 0
            guard now - hb > staleLockMs else { continue }

            schedLog.notice("recovering stale lock on \(row.date, privacy: .public) (processor=\(row.activeProcessor ?? "?", privacy: .public), heartbeat age=\(now - hb)ms)")
            print("[Scheduler] crash recovery: \(row.date) had stale lock (processor=\(row.activeProcessor ?? "?"))")
            store.releaseLock(date: row.date)

            let day = ProcessingLogStore.day(from: row.date)
            // 真崩溃路径(SIGKILL / 断电 / force quit)— 跟 paused 一样,用户
            // 视角都是"上次没跑完",写同一个 kind。recordFailure 同时落盘,
            // UI 重启后仍能显示"interrupted"banner。
            let stagesAffected: [ProcessingStage] = [.event, .impact, .classify, .distill, .personality]
                .filter { row.status(of: $0) == .inProgress }
            if row.event == .inProgress {
                applyOutcome(date: row.date, stage: .event, outcome: .failed, rollbackDay: day)
            }
            if row.impact == .inProgress {
                applyOutcome(date: row.date, stage: .impact, outcome: .failed, rollbackDay: nil)
            }
            if row.classify == .inProgress {
                applyOutcome(date: row.date, stage: .classify, outcome: .failed, rollbackDay: nil)
            }
            if row.distill == .inProgress {
                applyOutcome(date: row.date, stage: .distill, outcome: .failed, rollbackDay: nil)
            }
            if row.personality == .inProgress {
                applyOutcome(date: row.date, stage: .personality, outcome: .failed, rollbackDay: nil)
            }
            for stage in stagesAffected {
                recordFailure(date: row.date, stage: stage, kind: .appInterruptionRestarted)
            }
        }

        // ─── paused 行回收 ───
        // 用户主动退出(applicationWillTerminate)留下的 paused 行 —— 跟 stale
        // lock 不同,**不计 retry**(retry_count 不动 → backoff=0 → 下个 tick
        // 立即跑)。但标 .failed 不是 .pending,这样:
        //   - attentionItems 自动捡到(failed/budget_deferred/dead_letter 都算)
        //   - lastFailureByRowStage 写 .appInterruptionRestarted 让 UI / 通知
        //     正确显示"上次中断,自动续跑"
        //   - 退出时 reject 过 staging,UI 不会显示假 "Pending review"
        // event 步仍需 deleteEvents 回滚(可能写了一半 .md),其他步幂等。
        var pausedPipelines: Set<String> = []
        for row in store.allRows() {
            let day = ProcessingLogStore.day(from: row.date)
            var hadPausedStages: [ProcessingStage] = []
            if row.event == .paused {
                if let day { deleteEvents(on: day) }
                store.setStatus(date: row.date, stage: .event, status: .failed)
                hadPausedStages.append(.event)
                pausedPipelines.insert("Event processing")
            }
            if row.impact == .paused {
                store.setStatus(date: row.date, stage: .impact, status: .failed)
                hadPausedStages.append(.impact)
                pausedPipelines.insert("Event processing")
            }
            if row.classify == .paused {
                store.setStatus(date: row.date, stage: .classify, status: .failed)
                hadPausedStages.append(.classify)
            }
            if row.distill == .paused {
                store.setStatus(date: row.date, stage: .distill, status: .failed)
                hadPausedStages.append(.distill)
                pausedPipelines.insert("Portrait distillation")
            }
            if row.personality == .paused {
                store.setStatus(date: row.date, stage: .personality, status: .failed)
                hadPausedStages.append(.personality)
                pausedPipelines.insert("Personality refresh")
            }
            // 持久化 kind 让 attention UI 显示 "Auto-recovering · interrupted"
            // + UI 的 "Auto-recovering · next retry next tick"(retry=0 → backoffReady true)。
            for stage in hadPausedStages {
                recordFailure(date: row.date, stage: stage, kind: .appInterruptionRestarted)
            }
            if !hadPausedStages.isEmpty {
                schedLog.notice("resumed paused row \(row.date, privacy: .public) → failed + appInterruptionRestarted (no retry++)")
                print("[Scheduler] resume paused: \(row.date) → failed (interrupted, immediate retry)")
            }
        }
        // 每个被中断的 pipeline 弹一条独立通知 — 让用户知道"上次中断已自动续跑"。
        // 用独立 kind 而非 .pipelineAutoRecovering,这样可以单独 toggle off
        // (频繁关电脑的用户不想每次开机都弹这个,但保留其它 scheduler 通知)。
        for pipeline in pausedPipelines {
            NotificationCenterService.shared.post(
                .pipelineInterruptionRestarted(pipeline: pipeline)
            )
        }
    }

    /// 启动时清理「孤儿 staging 快照」:有 backup 目录但 days 清单
    /// (xxx_days.json)不存在 = 手动 staged run 在 markRan 之前真崩溃
    /// (SIGKILL / 断电)。这种快照结果不完整、不可审,留着会让
    /// hasPending 一直 true → tick() 顶部 guard 每 15 分钟直接 return,
    /// 五条定时管线无限期停摆。只删 backup、不动 live 树(没有清单不知道
    /// 哪些天动过,盲目回滚会丢已 complete 的天;崩溃那天的半成品由
    /// recoverStaleLocks 的 stale-lock 回收 → 重跑负责清理)。
    /// 清单存在 = run 跑完等审核,是合法 pending,不动。
    ///
    /// ⚠️ 只能在 start() 启动路径调,不能放进 recoverStaleLocks ——
    /// 后者 didWake 也会调,而手动 run 可能正跨睡眠进行中(backup 在、
    /// 清单还没写),在那里清会误杀活着的 run。
    private func discardOrphanStagingSnapshots() {
        for k in [MemoryStaging.Kind.events, .portrait, .personality]
        where MemoryStaging.isOrphan(k) {
            do {
                try MemoryStaging.discardOrphan(k)
                schedLog.notice("discarded orphan staging snapshot '\(k.rawValue, privacy: .public)' (run crashed before manifest) — scheduled jobs unblocked")
                print("[Scheduler] discarded orphan staging snapshot '\(k.rawValue)' (run crashed mid-way; live tree kept)")
            } catch {
                schedLog.error("discard orphan staging '\(k.rawValue, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 用户主动退出时调(applicationWillTerminate)。扫所有 row,把任一 stage
    /// 处于 in_progress 的标为 paused + 释放锁,**不计 retry** —— 跟真崩溃
    /// (SIGKILL / 断电)的 stale-lock 路径区分开。同步 DB 写,毫秒级,不阻塞
    /// 退出。下次启动 recoverStaleLocks 末尾会把 paused 转回 pending 重跑。
    ///
    /// LLM 本身不支持续接 → 重跑 = 从头跑,event 步靠 deleteEvents 保证幂等。
    /// 同时 reject 对应 staging snapshot —— 用户主动退出 ≠ "run done",拍的
    /// snapshot 没完整结果可审,留着会让重启 UI 显示"假 Pending review"
    /// (events 已删但 staging 还在)卡死流程。
    func pauseInProgressJobs() {
        // 代际 +1:让所有在飞 runStep / runXxxJob 恢复执行时发现自己已被
        // 接管,丢弃结果、中止剩余天(见 pauseGeneration 注释)。
        pauseGeneration += 1
        var pausedCount = 0
        var pausedKinds: Set<MemoryStaging.Kind> = []
        var pausedOwners: Set<String> = []
        for row in store.allRows() {
            var pausedThisRow = false
            for stage in ProcessingStage.allCases {
                if row.status(of: stage) == .inProgress {
                    store.setStatus(date: row.date, stage: stage, status: .paused)
                    pausedThisRow = true
                    if let k = Self.stagingKind(for: stage) {
                        pausedKinds.insert(k)
                    }
                    pausedOwners.insert(Self.pipelineOwner(for: stage))
                }
            }
            if pausedThisRow {
                store.releaseLock(date: row.date)
                pausedCount += 1
                print("[Scheduler] pause on shutdown: \(row.date) (active stages → paused)")
            }
        }
        if pausedCount > 0 {
            schedLog.notice("paused \(pausedCount) in-progress row(s) on shutdown — will resume on next launch")
        }
        // 杀掉被 pause 的 pipeline 在飞的 LLM 子进程 —— 系统睡眠只 suspend
        // 进程不杀子进程,不杀的话唤醒后任务复活继续写盘/打 LLM。只按 owner
        // 杀本组,不动 writing-capture / chat。被杀的 work() 抛错后,runStep
        // 的代际校验负责丢弃结果。
        for owner in pausedOwners {
            let n = PiAgentRegistry.shared.stopGroup(owner)
            if n > 0 {
                print("[Scheduler] pause: stopped \(n) LLM agent(s) of pipeline '\(owner)'")
            }
        }
        // Reject 任何被 paused 牵连的 staging snapshot。run 还没跑完 → days
        // 清单缺失 → reject 内部走孤儿路径:只丢 backup、保留 live 树(整树
        // 回滚会抹掉多天 run 里已 complete 的天);中断那天的半成品由上面的
        // paused 回收 deleteEvents + 重跑清理。多 row 同 stage 也只 reject
        // 一次(MemoryStaging 是 kind-级)。
        for k in pausedKinds where MemoryStaging.hasPending(k) {
            do {
                try MemoryStaging.reject(k)
                print("[Scheduler] rejected staging '\(k.rawValue)' on pause (snapshot discarded, live tree kept)")
            } catch {
                schedLog.error("staging \(k.rawValue, privacy: .public) reject failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 把 ProcessingStage 翻成它写 staging snapshot 时用的 MemoryStaging.Kind。
    /// raw 不走 staging(直接读 timeline);classify 已下线但 enum 还在。
    private static func stagingKind(for stage: ProcessingStage) -> MemoryStaging.Kind? {
        switch stage {
        case .raw:         return nil
        case .event:       return .events
        case .impact:      return .events
        case .classify:    return .classify
        case .distill:     return .portrait
        case .personality: return .personality
        }
    }

    // MARK: - UI 支持：重置 / 待处理列表

    /// 手动重置某天 / `_distill_anchor`：把 failed / dead_letter /
    /// budget_deferred 的阶段回退 pending，retry_count 归零，释放锁。
    /// 下次 tick 会重新尝试。
    func resetDay(_ date: String) {
        guard let row = store.row(for: date) else { return }
        for stage in ProcessingStage.allCases {
            switch row.status(of: stage) {
            case .failed, .deadLetter, .budgetDeferred:
                store.setStatus(date: date, stage: stage, status: .pending)
            default:
                break
            }
        }
        store.setRetryCount(date: date, count: 0)
        store.releaseLock(date: date)
        print("[Scheduler] reset \(date) → pending, retry_count=0")
    }

    /// Reject staged run 专用:把这次 run **拥有的阶段**(含已 complete 的)
    /// 翻回 pending。文件树已被快照还原,状态必须跟着回去 —— 否则一次成功
    /// 且有产出的 run 被 Reject 后,"树回滚了、状态还 complete",这些天
    /// 永不重跑,产出永久丢失,Run 按钮还灰着没法手动救。
    /// 跟 resetDay 区分:resetDay 服务 attention 重试,只翻 failed 系状态、
    /// 刻意不动 complete;这里只翻调用方指明的阶段,不跨 kind 误伤。
    func resetStagesForReject(date: String, stages: [ProcessingStage]) {
        guard let row = store.row(for: date) else { return }
        for stage in stages {
            switch row.status(of: stage) {
            case .complete, .failed, .deadLetter, .budgetDeferred:
                store.setStatus(date: date, stage: stage, status: .pending)
            default:
                break
            }
        }
        store.setRetryCount(date: date, count: 0)
        store.releaseLock(date: date)
        print("[Scheduler] reject-reset \(date) stages=\(stages.map(\.rawValue)) → pending")
    }

    /// "我接受现状,不再跑" —— 用户 Dismiss attention 行时调。把 failed /
    /// budget_deferred / dead_letter 阶段标 complete + 清 last failure kind,
    /// 从 attention 列表永久消失。跟 resetDay 区分:
    ///   - resetDay → 阶段回 pending,下次 tick 重试(用户:再试一次)
    ///   - dismissDay → 阶段标 complete,scheduler 不再碰它(用户:不在乎了)
    func dismissDay(_ date: String) {
        guard let row = store.row(for: date) else { return }
        for stage in ProcessingStage.allCases {
            switch row.status(of: stage) {
            case .failed, .deadLetter, .budgetDeferred:
                store.setStatus(date: date, stage: stage, status: .complete)
                clearFailure(date: date, stage: stage)
            default:
                break
            }
        }
        store.releaseLock(date: date)
        print("[Scheduler] dismiss \(date) → complete, kind cleared")
    }

    /// 需要用户关注的日：任一阶段处于 failed / dead_letter / budget_deferred。
    /// nonisolated:纯 DB 读 + 数据变换,不碰 MainActor 状态,可在后台调用
    /// 避免阻塞 UI(被 MemorySettingsView.reload 从 detached task 调)。
    nonisolated func attentionDays() -> [AttentionItem] {
        store.allRows().compactMap { row in
            let problems = ProcessingStage.allCases.compactMap {
                stage -> (stage: ProcessingStage, status: ProcessingStatus)? in
                let s = row.status(of: stage)
                switch s {
                case .failed, .deadLetter, .budgetDeferred: return (stage, s)
                default: return nil
                }
            }
            guard !problems.isEmpty else { return nil }
            return AttentionItem(date: row.date, retryCount: row.retryCount, problems: problems)
        }
    }

    // MARK: - 测试钩子（dev-only，被 SchedulerTestCLI 调用）

    /// 注入结果跑真实的 `runStep` —— 验证 applyOutcome 的 success / failed /
    /// budget_deferred 三个分支走的是生产代码路径。
    enum InjectedResult { case success, failure, budget }

    func runInjectedStep(date: String, stage: ProcessingStage, result: InjectedResult) async {
        await runStep(
            date: date, stage: stage, processor: stage.rawValue,
            rollbackDay: ProcessingLogStore.day(from: date)
        ) {
            switch result {
            case .success: return .success
            case .failure: return .failed
            case .budget:
                throw BudgetExhaustedError(processor: "injected-test",
                                           message: "simulated 429 quota exceeded")
            }
        }
    }

    // MARK: - 候选日筛选

    /// 待处理的数据日：有采集帧、raw 已收齐、且 event 或 impact 阶段还需处理。
    /// 按日期升序、上限 `cap`。
    ///
    /// 纳入：event/impact 处于 idle / pending / failed / budget_deferred。
    /// 排除：complete（已完成）、in_progress（在跑或待恢复）、dead_letter（放弃）。
    func pendingDays(cap: Int) -> [Date] {
        let cal = utcCalendar()
        var days: [Date] = TimelineDB().availableDays(monthsBack: 3)
            .compactMap { cal.date(from: $0) }
        days.sort()

        var out: [Date] = []
        for day in days {
            guard isRawReady(day) else { continue }
            let row = store.row(for: ProcessingLogStore.dayString(day))
            if isEventCandidate(row) {
                out.append(day)
                if out.count >= cap { break }
            }
        }
        return out
    }

    /// tick / event job 是否还会处理某天 —— 与 pendingDays 用的是同一谓词。
    /// dead_letter / 全 complete → false。测试 / UI 可查。
    func wouldProcessInEventJob(date: String) -> Bool {
        isEventCandidate(store.row(for: date))
    }

    /// 一天是否需要 event job 处理(event 或 impact 阶段还有活 + 已过 backoff 窗口)。
    private func isEventCandidate(_ row: ProcessingLogRow?) -> Bool {
        guard let row else { return true }              // 无行 = idle = 需 event
        if row.event.needsWork,
           backoffReady(status: row.event, retryCount: row.retryCount, updatedAtMs: row.updatedAtMs) {
            return true
        }
        if row.event == .complete, row.impact.needsWork,
           backoffReady(status: row.impact, retryCount: row.retryCount, updatedAtMs: row.updatedAtMs) {
            return true
        }
        return false
    }

    /// event job 是否处于待重试态(任一天的 event/impact 失败/撞额度,且 backoff 到点)。
    private func eventNeedsRetry() -> Bool {
        for row in store.allRows() {
            if row.isAnchor { continue }
            for status in [row.event, row.impact] {
                switch status {
                case .failed, .budgetDeferred, .deadLetter:
                    if backoffReady(status: status, retryCount: row.retryCount, updatedAtMs: row.updatedAtMs) {
                        return true
                    }
                default: continue
                }
            }
        }
        return false
    }

    /// distill 是否处于待重试态(failed / budget_deferred / dead_letter)+ backoff 到点。
    private func portraitNeedsRetry() -> Bool {
        guard let row = store.row(for: distillAnchor) else { return false }
        switch row.distill {
        case .failed, .budgetDeferred, .deadLetter:
            return backoffReady(status: row.distill, retryCount: row.retryCount, updatedAtMs: row.updatedAtMs)
        default: return false
        }
    }

    /// personality 是否处于待重试态(任一天的 personality 失败/撞额度,且 backoff 到点)。
    private func personalityNeedsRetry() -> Bool {
        for row in store.allRows() {
            if row.isAnchor { continue }
            switch row.personality {
            case .failed, .budgetDeferred, .deadLetter:
                if backoffReady(status: row.personality, retryCount: row.retryCount, updatedAtMs: row.updatedAtMs) {
                    return true
                }
            default: continue
            }
        }
        return false
    }

    /// personality job 的候选天:event+impact 都 complete、personality 还
    /// 需做(idle / pending / failed / budget_deferred / dead_letter)+ 已过 backoff
    /// 窗口。跳 in_progress / complete。按日期升序、上限 `cap`。
    func pendingPersonalityDays(cap: Int) -> [Date] {
        let cal = utcCalendar()
        var days: [Date] = TimelineDB().availableDays(monthsBack: 3)
            .compactMap { cal.date(from: $0) }
        days.sort()

        var out: [Date] = []
        for day in days {
            let ds = ProcessingLogStore.dayString(day)
            guard let row = store.row(for: ds) else { continue }
            guard row.event == .complete, row.impact == .complete else { continue }
            guard row.personality.needsWork,
                  backoffReady(status: row.personality, retryCount: row.retryCount, updatedAtMs: row.updatedAtMs)
            else { continue }
            out.append(day)
            if out.count >= cap { break }
        }
        return out
    }

    /// 原始数据"收齐"：数据日 UTC 结束后再过 `rawGraceSeconds`。
    private func isRawReady(_ day: Date) -> Bool {
        let cal = utcCalendar()
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return Date() > dayEnd.addingTimeInterval(rawGraceSeconds)
    }

    /// Backfill 的 `daysBack` 需覆盖到目标日 —— 算出 day 距今多少天 + 1。
    private func daysBackToCover(_ day: Date) -> Int {
        let cal = utcCalendar()
        let today = cal.startOfDay(for: Date())
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: today).day ?? 0
        return max(1, d + 1)
    }

    /// 删某个数据日产生的全部 event 文件（失败日回滚）。
    private func deleteEvents(on day: Date) {
        let dir = PortraitPaths.eventsDayDir(for: day)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        var removed = 0
        for name in items where name.hasSuffix(".md") {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            print("[Scheduler] rollback: purged \(removed) event file(s) from \(dir.lastPathComponent)/")
        }
    }

    // MARK: - 心跳

    /// 起一个独立 Task，每 30s 刷新某行的心跳，直到被 cancel。
    /// `Task.detached` —— 与 LLM 调用的 async context 完全独立：即使
    /// `await` 在等网络挂起，这个循环照跑，stale detection 不会误杀在跑的步。
    private func startHeartbeat(for date: String) -> Task<Void, Never> {
        let store = self.store
        return Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                _ = store.heartbeat(date: date)
            }
        }
    }

    // MARK: - 工具

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private func localDayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func lastRunDay(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    private func setLastRun(_ key: String, _ date: Date) {
        UserDefaults.standard.set(localDayString(date), forKey: key)
    }
}
