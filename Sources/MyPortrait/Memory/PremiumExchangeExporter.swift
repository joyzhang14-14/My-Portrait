import Foundation
import GRDB
import GraphPhysics
import os.log

private let exportLog = Logger(subsystem: "com.myportrait.memory", category: "premium-export")

/// 把待处理的活打成输入包、交给 `PremiumRemote` 传到 Premium 服务器(界面上叫 My Portrait Premium;服务器每天凌晨一轮处理收到的所有包)。
///
/// app tick(每 15 分钟)跑 `runSealCheck`,helper(用户级 LaunchAgent,见 `PremiumNightlyAgent`)每个 :00 / :30 跑同一个入口
/// (`MyPortrait --premium-export --seal-check`)。每次都先按 `IntervalSegmenter` 的规则封区间(最后一帧有效记录之后空了
/// 2 小时就封);有链搬到 Premium 时,上次发包之后又封了区间、或 event 链还有没发出去的区间(`exportDue`)就导出,
/// Premium 连不上(地址不通、密钥无效)时这轮不导出、下一轮再试。`chains` = provider 为 Premium、频率不是 off、且有待处理
/// 工作的链。一个包最多装一天的区间(`oneDayOfIntervals`),积压时同一次检查里一包一天地接着打。
/// 只算 provider 为 Premium 的链(`SchedulerSettings.offloadedChains`)。event 的 pending 是区间台账里 needsWork、
/// 且还没在路上(`PremiumRemote.State.sentIntervals`:已发出、结果还没导入)的区间,personality 的是就绪的本地日
/// (`EventIntervalStore`,在路上的区间也算进来),portrait / classify / writing style 沿用 MemoryScheduler 的判据。
/// 前面的包还没处理完也照样发:同一个用户积压的几个包 Premium 合成一份处理,结果挂在最新的那个上,较早的标 merged。
/// 包在锁里写好、打成 tar.gz、台账记 `pending_upload`,放锁后才上传。
enum PremiumExchangeExporter {

    /// 导出需要的全部输入(在主线程上一次性取好,之后的 IO 都在后台)。
    struct Input: Sendable {
        var trigger: String = PremiumExchange.triggerNightly
        var chains: [String]
        var pending: PremiumPending
        /// `_distill_anchor` / `_classify_anchor` 两行。
        var processingLog: [PremiumProcessingLogEntry]
        var aboutUserBlock: String
        var params: PremiumParams
        var appVersion: String
    }

    enum ExportResult: Sendable {
        case exported(bundleId: String, archive: URL)
        case noWork
        case skipped(String)
    }

    struct SealCheckResult: Sendable {
        /// 本次新封的区间。
        var sealed: [EventInterval]
        /// nil = 没有链搬到 Premium,不导出。
        var export: ExportResult?
    }

    // MARK: - 封区间检查 + 导出(helper / app tick)

    /// 拿交换锁 → 封区间检查 → 有链搬到 Premium、有新区间或积压(`exportDue`)、且连得上时打包
    /// (`sealThenExport`;积压时接着打,每包一天,最多 `maxBundlesPerCheck` 个)→ 放锁 → 上传。
    /// `importFirst`:helper 先导入结果(app tick 自己已经导入过)。
    @MainActor
    static func runSealCheck(dbPool: DatabasePool, lockWait: TimeInterval,
                             importFirst: Bool) async -> SealCheckResult {
        let cfg = ConfigStore.shared.current.premium
        let offloaded = ConfigStore.shared.current.scheduler.offloadedChains
        if importFirst, !offloaded.isEmpty {
            _ = await PremiumExchangeImporter.runIfNeeded(dbPool: dbPool, notify: false, lockWait: lockWait)
        }
        guard let lock = await PremiumExchange.FileLock.acquire(wait: lockWait) else {
            return SealCheckResult(sealed: [], export: .skipped("exchange lock busy"))
        }
        let root = Storage.rootURL
        let s = ConfigStore.shared.current.scheduler
        let eventOffloaded = s.event.isOffloaded && s.event.frequency != .off
        let isDue: @Sendable () -> Bool = {
            let store = EventIntervalStore(dbPool: dbPool)
            let st = PremiumRemote.readState(root)
            let unsent = eventOffloaded
                ? ((try? store.needsWork().filter { !st.sentIntervals.contains($0.id) }.count) ?? 0) : 0
            return exportDue(lastCut: try? store.lastCut(), lastExportCutMs: st.lastExportCutMs, pendingIntervals: unsent)
        }
        let r = await sealThenExport(
            seal: { try EventIntervalStore(dbPool: dbPool).sealCheck() },
            due: isDue,
            offloaded: !offloaded.isEmpty,
            unreachable: { await PremiumRemote.unreachableReason(cfg) },
            write: { await export(dbPool: dbPool, lockWait: nil) })
        if case .exported? = r.export {
            for _ in 1..<maxBundlesPerCheck {
                guard await Task.detached(priority: .utility, operation: isDue).value,
                      case .exported = await export(dbPool: dbPool, lockWait: nil) else { break }
            }
        }
        lock.release()
        if !offloaded.isEmpty { await PremiumRemote.flushUploads(root: Storage.rootURL, cfg: cfg) }
        return r
    }

    /// 持交换锁之后的主体。先封区间(封区间是纯本地操作,不看 Premium 在不在);没有链搬到
    /// Premium → 不导出。封区间之后 `due` 说没有新区间也没有积压 → 不导出。`unreachable` 给出原因 = 这轮发不出去,
    /// 下一轮再试;否则 `write` 打包。
    @MainActor
    static func sealThenExport(seal: @escaping @Sendable () throws -> [EventInterval],
                               due: @escaping @Sendable () -> Bool, offloaded: Bool,
                               unreachable: () async -> String?,
                               write: () async -> ExportResult) async -> SealCheckResult {
        let sealed: [EventInterval]
        do {
            sealed = try await Task.detached(priority: .utility) { try seal() }.value
        } catch {
            exportLog.error("seal check failed: \(error.localizedDescription, privacy: .public)")
            sealed = []
        }
        guard offloaded else { return SealCheckResult(sealed: sealed, export: nil) }
        let isDue = await Task.detached(priority: .utility) { due() }.value
        guard isDue else { return SealCheckResult(sealed: sealed, export: .skipped(notDueReason)) }
        if let why = await unreachable() {
            exportLog.notice("export skipped: Premium not reachable (\(why, privacy: .public))")
            return SealCheckResult(sealed: sealed, export: .skipped("Premium not reachable (\(why))"))
        }
        return SealCheckResult(sealed: sealed, export: await write())
    }

    static let notDueReason = "no new interval"

    /// 一次检查最多打几个包(积压时一包一天地接着打;收件服务每 24 小时最多收 48 个)。
    static let maxBundlesPerCheck = 40

    /// 该不该发包:上次发包之后又封了区间(截止点往后走了),或 event 链搬到 Premium 且还有没发出去的
    /// 区间(积压按 `oneDayOfIntervals` 分批)。
    static func exportDue(lastCut: Int64?, lastExportCutMs: Int64?, pendingIntervals: Int) -> Bool {
        if pendingIntervals > 0 { return true }
        guard let lastCut else { return false }
        return lastCut > (lastExportCutMs ?? Int64.min)
    }

    /// 一个包最多装多少区间:最早那个区间开始后 24 小时内开始的区间(至少一个)。
    static let maxBundleSpanMs: Int64 = 86_400_000

    static func oneDayOfIntervals(_ ivs: [PremiumIntervalEntry]) -> [PremiumIntervalEntry] {
        guard let first = ivs.compactMap(\.startMs).min() else { return ivs }
        return ivs.filter { ($0.startMs ?? first) < first + maxBundleSpanMs }
    }

    // MARK: - 手动导出(CLI)

    /// CLI `--premium-export`:先导入结果,再按全部已搬链导出(不封区间、不看有没有新区间),然后上传。
    @MainActor
    static func exportNow(dbPool: DatabasePool, lockWait: TimeInterval) async -> ExportResult {
        _ = await PremiumExchangeImporter.runIfNeeded(dbPool: dbPool, notify: false, lockWait: lockWait)
        let r = await export(dbPool: dbPool, lockWait: lockWait)
        await PremiumRemote.flushUploads(root: Storage.rootURL, cfg: ConfigStore.shared.current.premium)
        return r
    }

    /// 持交换锁(跨进程)+ 三把调度锁打包,台账记 `pending_upload` 和包里的区间(上传由调用方放锁后做)。
    /// `lockWait` nil = 调用方已持交换锁。
    @MainActor
    private static func export(dbPool: DatabasePool, lockWait: TimeInterval?) async -> ExportResult {
        let config = ConfigStore.shared.current
        let offloaded = config.scheduler.offloadedChains
        guard !offloaded.isEmpty else { return .skipped("no chain offloaded") }
        // 与 tick 同规则:有手动 run 待审 / AI 编辑 draft 挂起 → 树不稳定,不导出。
        guard !MemoryStaging.hasPending(.events, root: Storage.rootURL),
              !MemoryStaging.hasPending(.portrait, root: Storage.rootURL),
              !MemoryStaging.hasPending(.personality, root: Storage.rootURL),
              !EditDraft.hasAnyPending() else { return .skipped("review pending") }
        let root = Storage.rootURL
        guard let input = gatherInput(dbPool: dbPool) else { return .noWork }
        let cut = try? EventIntervalStore(dbPool: dbPool).lastCut()

        var lock: PremiumExchange.FileLock?
        if let lockWait {
            lock = await PremiumExchange.FileLock.acquire(wait: lockWait)
            guard lock != nil else { return .skipped("exchange lock busy") }
        }
        defer { lock?.release() }
        let scheduler = MemoryScheduler.shared
        guard scheduler.acquireAllLocks() else { return .skipped("scheduler busy") }
        defer { scheduler.releaseAllLocks() }

        let result: ExportResult = await Task.detached(priority: .utility) {
            do {
                return try packageForUpload(input: input, root: root, dbPool: dbPool)
            } catch {
                exportLog.error("export failed: \(error.localizedDescription, privacy: .public)")
                return .skipped("export failed: \(error.localizedDescription)")
            }
        }.value
        if case .exported(let id, _) = result {
            PremiumRemote.updateState(root) { s in
                s.uploads.append(.init(bundleId: id, trigger: input.trigger, chains: input.chains,
                                       createdAt: PremiumExchange.isoNow(), status: PremiumRemote.statusPendingUpload,
                                       intervals: input.pending.eventIntervals.map(\.id)))
                s.lastExport = .init(bundleId: id, at: PremiumExchange.isoNow(), outcome: input.trigger)
                s.lastExportCutMs = cut ?? s.lastExportCutMs
            }
            exportLog.notice("packed bundle \(id, privacy: .public)")
        }
        return result
    }

    // MARK: - 取输入(主线程)

    /// 真实 pending。已经在路上(发出了、结果还没导入)的区间不再发;性格日就绪的判断把它们算作已有着落。
    @MainActor
    static func pendingNow(dbPool: DatabasePool) -> PremiumPending {
        let sched = MemoryScheduler.shared
        let store = EventIntervalStore(dbPool: dbPool)
        let sent = PremiumRemote.readState(Storage.rootURL).sentIntervals
        return computePending(
            ConfigStore.shared.current.scheduler,
            eventIntervals: {
                do { return try store.needsWork().filter { !sent.contains($0.id) }.map(PremiumIntervalEntry.init) } catch {
                    exportLog.error("event intervals: \(error.localizedDescription, privacy: .public)")
                    return []
                }
            },
            personalityDays: { inBundle in
                do {
                    return try store.readyPersonalityDays(inBundle: inBundle.union(sent)).map(PremiumPersonalityDayEntry.init)
                } catch {
                    exportLog.error("personality days: \(error.localizedDescription, privacy: .public)")
                    return []
                }
            },
            portraitHasWork: { sched.portraitJobHasWork() },
            classifyHasWork: { sched.classifierJobHasWork() },
            writingUnprocessed: { (try? WritingStyleStore(dbPool: dbPool).unprocessedCount()) ?? 0 })
    }

    /// `chains` = 有待处理工作的链,pending 只留这些链;都没活 → nil。
    @MainActor
    static func gatherInput(dbPool: DatabasePool) -> Input? {
        let all = pendingNow(dbPool: dbPool)
        var chains = all.chainsWithWork
        guard !chains.isEmpty else { return nil }
        // event 在包里时,同样搬到 Premium 的 portrait / personality 也列进去:它们的活要等
        // event 跑完才出现(distill 锚由 Premium 在 finalize 后置 pending),不列就要晚一天。
        if chains.contains("event") {
            let s = ConfigStore.shared.current.scheduler
            let follow = [("portrait", s.portrait), ("personality", s.personality)]
                .filter { $0.1.isOffloaded && !chains.contains($0.0) }.map(\.0)
            chains = PremiumPending.chainOrder.filter { chains.contains($0) || follow.contains($0) }
        }
        let store = ProcessingLogStore()
        let da = store.row(for: ProcessingLogStore.distillAnchorDate)?.distill ?? .idle
        let ca = store.row(for: ProcessingLogStore.classifyAnchorDate)?.classify ?? .idle
        return makeInput(trigger: PremiumExchange.triggerNightly, chains: chains, pending: all.only(chains),
                         distill: da.rawValue, classify: ca.rawValue)
    }

    /// dry-run 测试包:把 [fromMs, toMs) 当作一个未处理的区间(帧不按 id 截断),四条链都
    /// 视为搬到 Premium;personality 带上完全落在这段里的本地日;distill / classify 视为
    /// pending;`chains` = event / portrait / personality,writing style 频率不是 off 时
    /// 再加 writing_style。不读写台账,树镜像原样。
    @MainActor
    static func gatherDryRunInput(dbPool: DatabasePool, fromMs: Int64, toMs: Int64) throws -> Input {
        let s = ConfigStore.shared.current.scheduler
        let off = IntervalSegmenter.currentOffsetMin(at: Date(timeIntervalSince1970: Double(fromMs) / 1000))
        let (n, maxId) = try dbPool.read { db -> (Int, Int64) in
            let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, MAX(id) AS max_id FROM frames
                WHERE \(EventIntervalStore.eventFrameFilter) AND timestamp_ms >= :s AND timestamp_ms < :e
                """, arguments: ["s": fromMs, "e": toMs])
            return (Int((r?["n"] as Int64?) ?? 0), (r?["max_id"] as Int64?) ?? 0)
        }
        let iv = PremiumIntervalEntry(
            id: "iv:\(fromMs)", startMs: fromMs, endMs: toMs, tzOffsetMin: off,
            trigger: EventIntervalStore.triggerGap, eventStatus: ProcessingStatus.pending.rawValue,
            impactStatus: ProcessingStatus.idle.rawValue, retryCount: 0, frameCount: n,
            afterFrameId: 0, maxFrameId: maxId)
        let days = IntervalSegmenter.touchedDays(startMs: fromMs, endMs: toMs, tzOffsetMin: off).filter {
            guard let w = IntervalSegmenter.dayWindow($0, tzOffsetMin: off) else { return false }
            return w.start >= fromMs && w.end <= toMs
        }
        let wsOn = s.writingStyle.frequency != .off
        let pending = PremiumPending(
            eventIntervals: [iv], personalityDays: days, distillPending: true, classifyPending: true,
            writingStyleEnabled: wsOn,
            writingRecordsUnprocessed: wsOn ? ((try? WritingStyleStore(dbPool: dbPool).unprocessedCount()) ?? 0) : 0,
            personalityLog: days.map {
                PremiumPersonalityDayEntry(day: $0, tzOffsetMin: off, status: ProcessingStatus.pending.rawValue,
                                         retryCount: 0)
            })
        return makeInput(trigger: PremiumExchange.triggerNightly,
                         chains: ["event", "portrait", "personality"] + (wsOn ? ["writing_style"] : []),
                         pending: pending, distill: ProcessingStatus.pending.rawValue,
                         classify: ProcessingStatus.pending.rawValue)
    }

    @MainActor
    private static func makeInput(trigger: String, chains: [String], pending: PremiumPending,
                                  distill: String, classify: String) -> Input {
        let config = ConfigStore.shared.current
        let m = config.memory
        let params = PremiumParams(
            dailyBudget: m.dailyBudget, peakProtection: m.peakProtection,
            maxRebalances: m.maxRebalances, windowDays: m.windowDays,
            distillEvidenceThreshold: m.distillEvidenceThreshold,
            archiveMaxWeight: m.archiveMaxWeight, archiveMinDaysIdle: m.archiveMinDaysIdle,
            weightHalfLifeDays: m.weightHalfLifeDays,
            beltWeightMax: GraphConstants.beltWeightMax,
            folderMinCoreEvents: GraphConstants.folderMinCoreEvents,
            writingStyleBatch: WritingStyleDistiller.defaultBatchCap,
            model: "qwen", modelLight: "qwen"
        )
        let log = [
            PremiumProcessingLogEntry(date: ProcessingLogStore.distillAnchorDate, distillStatus: distill),
            PremiumProcessingLogEntry(date: ProcessingLogStore.classifyAnchorDate, classifyStatus: classify),
        ]
        return Input(trigger: trigger, chains: chains, pending: pending, processingLog: log,
                     aboutUserBlock: MemoryPrompts.aboutUserBlock(config.personalInfo),
                     params: params, appVersion: PremiumExchange.appVersion)
    }

    /// 按「哪些链搬到 Premium」算 pending:只有 provider 为 Premium 且频率不是 off
    /// 的链才有活;没搬的链字段恒为空 / false / 0。event 不搬时 classify 也不搬。
    /// `personalityDays` 拿到本包的区间 id:这些区间在同一次运行里先跑,与它们重叠的本地日
    /// 也列进来(Premium 等它们 event / impact 都 complete 才跑)。
    /// 各探针只在对应链计入时才调。
    static func computePending(_ s: SchedulerSettings,
                               eventIntervals: () -> [PremiumIntervalEntry],
                               personalityDays: (Set<String>) -> [PremiumPersonalityDayEntry],
                               portraitHasWork: () -> Bool,
                               classifyHasWork: () -> Bool,
                               writingUnprocessed: () -> Int) -> PremiumPending {
        func on(_ key: String, _ c: SchedulerConfig) -> Bool { c.isOffloaded && c.frequency != .off }
        let eventOn = on("event", s.event)
        let wsOn = on("writing_style", s.writingStyle)
        let ivs = eventOn ? oneDayOfIntervals(eventIntervals()) : []
        let pdays = on("personality", s.personality) ? personalityDays(Set(ivs.map(\.id))) : []
        return PremiumPending(
            eventIntervals: ivs,
            personalityDays: pdays.map(\.day),
            distillPending: on("portrait", s.portrait) && portraitHasWork(),
            classifyPending: eventOn && classifyHasWork(),
            writingStyleEnabled: wsOn,
            writingRecordsUnprocessed: wsOn ? writingUnprocessed() : 0,
            personalityLog: pdays)
    }

    // MARK: - 打包(后台)

    /// 写包到 `.staging/premium_upload/<id>/`、打成 `<id>.tar.gz`、删掉目录。
    static func packageForUpload(input: Input, root: URL, dbPool: DatabasePool) throws -> ExportResult {
        let id = PremiumExchange.makeBundleId()
        let dir = try writeBundle(input: input, bundleId: id, root: root,
                                  parentDir: PremiumRemote.uploadDir(root), dbPool: dbPool)
        let archive = PremiumRemote.archiveURL(root, id)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PremiumRemote.pack(dir, to: archive)
        return .exported(bundleId: id, archive: archive)
    }

    /// 在 `parentDir/.<id>.partial/` 里写全包,rename 成 `parentDir/<id>/`,最后写 DONE。
    /// manifest 的 `files` 记帧文件与写作记录的 sha256。
    @discardableResult
    static func writeBundle(input: Input, bundleId: String, root: URL,
                            parentDir: URL, dbPool: DatabasePool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tmp = parentDir.appendingPathComponent(".\(bundleId).partial", isDirectory: true)
        let final = parentDir.appendingPathComponent(bundleId, isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // frames/<interval_id>.jsonl + frames/pday_<day>.jsonl
        let framesDir = tmp.appendingPathComponent("frames", isDirectory: true)
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        for iv in input.pending.eventIntervals {
            try writeIntervalFrames(iv, to: framesDir.appendingPathComponent("\(iv.id).jsonl"), dbPool: dbPool)
        }
        for p in input.pending.personalityLog {
            try writeDayFrames(p, to: framesDir.appendingPathComponent("pday_\(p.day).jsonl"), dbPool: dbPool)
        }

        // writing_records.jsonl
        if input.pending.writingStyleEnabled {
            try writeWritingRecords(to: tmp.appendingPathComponent("writing_records.jsonl"),
                                    limit: input.params.writingStyleBatch, dbPool: dbPool)
        }

        // 树镜像(原样字节复制),manifest.trees 按复制后的字节算。
        var trees: [String: String] = [:]
        for rel in PremiumExchange.listTreeFiles(root: root) {
            let src = root.appendingPathComponent(rel)
            let dst = tmp.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
            if let h = PremiumExchange.fileSHA(dst) { trees[rel] = h }
        }

        var files: [String: String] = [:]
        let names = (try? fm.contentsOfDirectory(atPath: framesDir.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".jsonl") {
            files["frames/\(name)"] = PremiumExchange.fileSHA(framesDir.appendingPathComponent(name))
        }
        if let h = PremiumExchange.fileSHA(tmp.appendingPathComponent("writing_records.jsonl")) {
            files["writing_records.jsonl"] = h
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let manifest = PremiumBundleManifest(
            bundleId: bundleId, exportedAtMs: nowMs, macNowMs: nowMs,
            appVersion: input.appVersion, trigger: input.trigger, chains: input.chains,
            pending: input.pending, processingLog: input.processingLog,
            personalityLog: input.pending.personalityLog, aboutUserBlock: input.aboutUserBlock,
            params: input.params, trees: trees, files: files)
        try PremiumExchange.encoder().encode(manifest)
            .write(to: tmp.appendingPathComponent("manifest.json"))

        try? fm.removeItem(at: final)
        try fm.moveItem(at: tmp, to: final)
        try PremiumExchange.writeDone(bundleDir: final)
        return final
    }

    // MARK: - DB 读

    /// 本地日 [00:00, 24:00) 的 UTC ms(偏移取台账里钉死的那个)。
    private static func dayBounds(_ p: PremiumPersonalityDayEntry) throws -> (Int64, Int64) {
        let off = p.tzOffsetMin ?? IntervalSegmenter.currentOffsetMin()
        guard let w = IntervalSegmenter.dayWindow(p.day, tzOffsetMin: off) else {
            throw NSError(domain: "PremiumExport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad day \(p.day)"])
        }
        return (w.start, w.end)
    }

    private struct FrameLine: Encodable {
        let id: Int64
        let timestamp_ms: Int64
        let app_name: String
        let window_name: String
        let browser_url: String?
        let ocr: String

        func encode(to encoder: Encoder) throws {
            enum K: String, CodingKey { case id, timestamp_ms, app_name, window_name, browser_url, ocr }
            var c = encoder.container(keyedBy: K.self)
            try c.encode(id, forKey: .id)
            try c.encode(timestamp_ms, forKey: .timestamp_ms)
            try c.encode(app_name, forKey: .app_name)
            try c.encode(window_name, forKey: .window_name)
            try c.encode(browser_url, forKey: .browser_url)   // null 也写出
            try c.encode(ocr, forKey: .ocr)
        }
    }

    private static func lineEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    /// 区间内全部帧(`EventIntervalStore.intervalFrameSQL`,不设上限),按时间升序。
    static func writeIntervalFrames(_ iv: PremiumIntervalEntry, to url: URL, dbPool: DatabasePool) throws {
        try writeFrameLines(where: EventIntervalStore.intervalFrameSQL, arguments: [
            "iv_start": iv.startMs ?? 0, "iv_end": iv.endMs ?? 0,
            "iv_after": iv.afterFrameId ?? 0, "iv_max": iv.maxFrameId ?? Int64.max,
        ], to: url, dbPool: dbPool)
    }

    /// 某本地日 [00:00, 24:00) 的全部帧(不过滤、不设上限),按时间升序。
    static func writeDayFrames(_ p: PremiumPersonalityDayEntry, to url: URL, dbPool: DatabasePool) throws {
        let (s, e) = try dayBounds(p)
        try writeFrameLines(where: "timestamp_ms >= :start AND timestamp_ms < :end",
                            arguments: ["start": s, "end": e], to: url, dbPool: dbPool)
    }

    private static func writeFrameLines(where cond: String, arguments: StatementArguments,
                                        to url: URL, dbPool: DatabasePool) throws {
        let enc = lineEncoder()
        var out = Data()
        try dbPool.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, timestamp_ms, app_name, COALESCE(window_name, '') AS window_name,
                       browser_url, COALESCE(ocr_backfill_text, full_text, '') AS ocr
                FROM frames
                WHERE \(cond)
                ORDER BY timestamp_ms ASC, id ASC
                """, arguments: arguments)
            while let r = try rows.next() {
                out.append(try enc.encode(FrameLine(
                    id: r["id"], timestamp_ms: r["timestamp_ms"],
                    app_name: (r["app_name"] as String?) ?? "",
                    window_name: r["window_name"], browser_url: r["browser_url"],
                    ocr: r["ocr"])))
                out.append(0x0A)
            }
        }
        try out.write(to: url)
    }

    private struct RecordLine: Encodable {
        let id: Int64
        let start_ts: Int64
        let app: String
        let url: String?
        let text: String
        let edit_log: String
        let kind: String
        let context_summary: String?

        func encode(to encoder: Encoder) throws {
            enum K: String, CodingKey { case id, start_ts, app, url, text, edit_log, kind, context_summary }
            var c = encoder.container(keyedBy: K.self)
            try c.encode(id, forKey: .id)
            try c.encode(start_ts, forKey: .start_ts)
            try c.encode(app, forKey: .app)
            try c.encode(url, forKey: .url)
            try c.encode(text, forKey: .text)
            try c.encode(edit_log, forKey: .edit_log)
            try c.encode(kind, forKey: .kind)
            try c.encode(context_summary, forKey: .context_summary)
        }
    }

    /// 复用 WritingStyleStore 的未处理查询(同过滤、同排序、同上限)。
    static func writeWritingRecords(to url: URL, limit: Int, dbPool: DatabasePool) throws {
        let enc = lineEncoder()
        var out = Data()
        for r in try WritingStyleStore(dbPool: dbPool).unprocessedRecords(limit: limit) {
            out.append(try enc.encode(RecordLine(
                id: r.id, start_ts: r.startTs, app: r.app, url: r.url, text: r.text,
                edit_log: r.editLog, kind: r.kind, context_summary: r.contextSummary)))
            out.append(0x0A)
        }
        try out.write(to: url)
    }
}
