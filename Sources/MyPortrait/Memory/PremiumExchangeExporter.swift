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
/// Premium 连不上(地址不通、密钥无效)或要了这个版本发不了的内容(`PremiumRemote.check`)时这轮不导出、下一轮再试;
/// 包里放什么按 Premium 这次说的(`Input.contents`)。`chains` = provider 为 Premium、频率不是 off、且有待处理
/// 工作的链。一个包最多装一天的区间(`oneDayOfIntervals`),积压时同一次检查里一包一天地接着打。
/// 包压缩后超过 `maxBundleBytes` 就对半拆:区间个数对半;只剩一个区间还超就按时间对半切成分片包(`part_from_ms` /
/// `part_to_ms`),分片还超再对半,Premium 收齐同一区间的分片再合起来处理。
/// 只算 provider 为 Premium 的链(`SchedulerSettings.offloadedChains`)。event 的 pending 是区间台账里 needsWork、
/// 且还没在路上(`PremiumRemote.State.sentIntervals`:已发出、结果还没导入)的区间,personality 的是就绪的本地日
/// (`EventIntervalStore`,在路上的区间也算进来),portrait / classify / writing style 沿用 MemoryScheduler 的判据。
/// 前面的包还没处理完也照样发:同一个用户积压的几个包 Premium 合成一份处理,结果挂在最新的那个上,较早的标 merged。
/// 包在锁里写好、打成 tar.gz、台账记 `pending_upload`,放锁后才上传。
/// 每次检查还看 Premium 要不要重跑某些日子(`PremiumRemote.Ask.redo`,管理端对所有用户下发):有就一天一个 `redo` 包地发
/// (`exportRedo`,最多 `maxRedoDaysInFlight` 天在路上;只发 provider 是 Premium 的项,那天没帧不发,都回报给 Premium),
/// Premium 把那天当新数据重跑、并回已有事件,结果导入时那天的事件与性格日以 Premium 的版本为准(结果 manifest 的 `overwrite`)。
enum PremiumExchangeExporter {

    /// 导出需要的全部输入(在主线程上一次性取好,之后的 IO 都在后台)。
    struct Input: Sendable {
        var trigger: String = PremiumExchange.triggerNightly
        var chains: [String]
        /// 包里放的内容(Premium 定,见 `PremiumRemote.check`)。
        var contents: [String]
        var pending: PremiumPending
        /// `_distill_anchor` / `_classify_anchor` 两行。
        var processingLog: [PremiumProcessingLogEntry]
        var aboutUserBlock: String
        var params: PremiumParams
        var appVersion: String
        /// 重跑的日子(只在 `redo` 包里有)。
        var redo: [PremiumRedoEntry]? = nil
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
        var ask: PremiumRemote.Ask?
        let r = await sealThenExport(
            seal: { try EventIntervalStore(dbPool: dbPool).sealCheck() },
            due: isDue,
            offloaded: !offloaded.isEmpty,
            unreachable: {
                switch await PremiumRemote.check(cfg) {
                case .success(let a): ask = a; return nil
                case .failure(let e): return e.message
                }
            },
            write: { await export(dbPool: dbPool, contents: ask?.contents ?? [], lockWait: nil) })
        if case .exported? = r.export {
            for _ in 1..<maxBundlesPerCheck {
                guard await Task.detached(priority: .utility, operation: isDue).value,
                      case .exported = await export(dbPool: dbPool, contents: ask?.contents ?? [], lockWait: nil) else { break }
            }
        }
        // 重跑与有没有新区间无关:这轮没问过 Premium 就现在问。
        if !offloaded.isEmpty {
            if ask == nil, case .success(let a) = await PremiumRemote.check(cfg) { ask = a }
            if let ask, !ask.redo.isEmpty { _ = await exportRedo(dbPool: dbPool, ask: ask) }
        }
        lock.release()
        if !offloaded.isEmpty { await PremiumRemote.flushUploads(root: Storage.rootURL, cfg: cfg) }
        return r
    }

    /// 持交换锁之后的主体。先封区间(封区间是纯本地操作,不看 Premium 在不在);没有链搬到
    /// Premium → 不导出。封区间之后 `due` 说没有新区间也没有积压 → 不导出。`unreachable` 给出原因 = 这轮发不出去
    /// (连不上,或 Premium 要的内容这个版本给不了),下一轮再试;否则 `write` 打包。
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

    /// 一个包最多装多少区间:最早那个区间开始后 24 小时内开始的区间(至少一个),再截到前 `limit` 个。
    static let maxBundleSpanMs: Int64 = 86_400_000

    static func oneDayOfIntervals(_ ivs: [PremiumIntervalEntry], limit: Int = .max) -> [PremiumIntervalEntry] {
        guard let first = ivs.compactMap(\.startMs).min() else { return Array(ivs.prefix(max(limit, 1))) }
        return Array(ivs.filter { ($0.startMs ?? first) < first + maxBundleSpanMs }.prefix(max(limit, 1)))
    }

    /// 打好的包压缩后的上限,与服务器单包上限一致。
    static let maxBundleBytes: Int64 = 500 << 20

    /// 一个区间按时间对半切时,分片最短多长(再短也超就照发)。
    static let minPartSpanMs: Int64 = 10 * 60_000

    /// 包超了上限、装了 `count` 个区间时,重打带一半(向上取整)。
    static func halfIntervals(_ count: Int) -> Int { max(1, (count + 1) / 2) }

    /// [from, to) 的对半切点;切出来的两半短于 `minPartSpanMs` 就不切(nil)。
    static func splitPoint(_ from: Int64, _ to: Int64) -> Int64? {
        to - from >= 2 * minPartSpanMs ? from + (to - from) / 2 : nil
    }

    // MARK: - 手动导出(CLI)

    /// CLI `--premium-export`:先导入结果,再按全部已搬链导出(不封区间、不看有没有新区间),然后上传。
    @MainActor
    static func exportNow(dbPool: DatabasePool, lockWait: TimeInterval) async -> ExportResult {
        _ = await PremiumExchangeImporter.runIfNeeded(dbPool: dbPool, notify: false, lockWait: lockWait)
        let cfg = ConfigStore.shared.current.premium
        let contents: [String]
        switch await PremiumRemote.check(cfg) {
        case .success(let a): contents = a.contents
        case .failure(let e): return .skipped("Premium not reachable (\(e.message))")
        }
        let r = await export(dbPool: dbPool, contents: contents, lockWait: lockWait)
        await PremiumRemote.flushUploads(root: Storage.rootURL, cfg: cfg)
        return r
    }

    /// 持交换锁(跨进程)+ 三把调度锁打包,台账记 `pending_upload` 和包里的区间(上传由调用方放锁后做)。
    /// `contents` = 这次 `PremiumRemote.check` 拿到的包内容。`lockWait` nil = 调用方已持交换锁。
    @MainActor
    private static func export(dbPool: DatabasePool, contents: [String], lockWait: TimeInterval?) async -> ExportResult {
        let config = ConfigStore.shared.current
        let offloaded = config.scheduler.offloadedChains
        guard !offloaded.isEmpty else { return .skipped("no chain offloaded") }
        // 与 tick 同规则:有手动 run 待审 / AI 编辑 draft 挂起 → 树不稳定,不导出。
        guard !MemoryStaging.hasPending(.events, root: Storage.rootURL),
              !MemoryStaging.hasPending(.portrait, root: Storage.rootURL),
              !MemoryStaging.hasPending(.personality, root: Storage.rootURL),
              !EditDraft.hasAnyPending() else { return .skipped("review pending") }
        let root = Storage.rootURL
        guard var input = gatherInput(dbPool: dbPool, contents: contents) else { return .noWork }
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

        func package(_ input: Input) async -> ExportResult {
            await Task.detached(priority: .utility) {
                do {
                    return try packageForUpload(input: input, root: root, dbPool: dbPool)
                } catch {
                    exportLog.error("export failed: \(error.localizedDescription, privacy: .public)")
                    return .skipped("export failed: \(error.localizedDescription)")
                }
            }.value
        }
        let packed = await packWithinCap(input, regather: { gatherInput(dbPool: dbPool, contents: contents, maxIntervals: $0) },
                                          package: package)
        let result = packed.result
        let ids = packed.ids
        input = packed.input
        if !ids.isEmpty {
            PremiumRemote.updateState(root) { s in
                for id in ids {
                    s.uploads.append(.init(bundleId: id, trigger: input.trigger, chains: input.chains,
                                           createdAt: PremiumExchange.isoNow(), status: PremiumRemote.statusPendingUpload,
                                           intervals: input.pending.eventIntervals.map(\.id)))
                }
                s.lastExport = .init(bundleId: ids[ids.count - 1], at: PremiumExchange.isoNow(), outcome: input.trigger)
                s.lastExportCutMs = cut ?? s.lastExportCutMs
            }
            exportLog.notice("packed bundle(s) \(ids.joined(separator: ", "), privacy: .public)")
        }
        return result
    }

    /// 打包;压缩后超过 `maxBundleBytes` 就对半拆:区间个数对半(`regather` 按个数重取输入,没带上的区间仍是待发,
    /// 下一个包接着带);只剩一个区间还超就按时间对半切成分片包,分片还超再对半。
    /// 返回最后一个包的结果、打出来的全部包 id(分片时多个,按时间先后)和实际打包用的输入。
    @MainActor
    static func packWithinCap(_ start: Input, regather: (Int) -> Input?,
                              package: (Input) async -> ExportResult) async -> (result: ExportResult, ids: [String], input: Input) {
        var input = start
        var result = await package(input)
        while case .exported(let id, let archive) = result, isOversized(archive),
              input.pending.eventIntervals.count > 1 {
            let k = halfIntervals(input.pending.eventIntervals.count)
            exportLog.notice("bundle \(id, privacy: .public) over the cap with \(input.pending.eventIntervals.count) intervals, repacking with \(k)")
            try? FileManager.default.removeItem(at: archive)
            guard let smaller = regather(k) else { return (.noWork, [], input) }
            input = smaller
            result = await package(input)
        }
        guard case .exported(let id, let archive) = result else { return (result, [], input) }
        guard isOversized(archive), input.pending.eventIntervals.count == 1,
              let iv = input.pending.eventIntervals.first, let s = iv.startMs, let e = iv.endMs,
              let mid = splitPoint(s, e) else { return (result, [id], input) }
        exportLog.notice("bundle \(id, privacy: .public) over the cap with one interval, splitting it by time")
        try? FileManager.default.removeItem(at: archive)
        let base = input
        func packParts(_ from: Int64, _ to: Int64) async -> [(String, URL)]? {
            var part = base
            part.pending.eventIntervals[0].partFromMs = from
            part.pending.eventIntervals[0].partToMs = to
            guard case .exported(let id, let archive) = await package(part) else { return nil }
            guard isOversized(archive), let mid = splitPoint(from, to) else {
                if isOversized(archive) {
                    exportLog.error("bundle \(id, privacy: .public) still over the cap at its smallest part")
                }
                return [(id, archive)]
            }
            try? FileManager.default.removeItem(at: archive)
            return await halves(from, mid, to)
        }
        func halves(_ from: Int64, _ mid: Int64, _ to: Int64) async -> [(String, URL)]? {
            guard let a = await packParts(from, mid) else { return nil }
            guard let b = await packParts(mid, to) else {
                for (_, url) in a { try? FileManager.default.removeItem(at: url) }
                return nil
            }
            return a + b
        }
        guard let parts = await halves(s, mid, e), let last = parts.last else {
            return (.skipped("export failed while splitting"), [], input)
        }
        return (.exported(bundleId: last.0, archive: last.1), parts.map(\.0), input)
    }

    // MARK: - 重跑(Premium 要重跑的日子)

    /// 最多几天重跑在路上(发出了、结果还没导入):Premium 一轮最多跑 7 个性格日,积压的包也不多占磁盘。
    static let maxRedoDaysInFlight = 7

    /// 下一批要发的重跑日子:还没在路上的(`inFlight` = `<请求 id>/<本地日>`),按日子从早到晚,最多 `limit` 天。
    static func nextRedoDays(_ redo: [PremiumRemote.Redo], inFlight: Set<String>,
                             limit: Int) -> [(redo: PremiumRemote.Redo, day: String)] {
        let todo = redo.flatMap { r in r.days.map { (redo: r, day: $0) } }.filter { !inFlight.contains("\($0.redo.id)/\($0.day)") }
        return Array(todo.sorted { ($0.day, $0.redo.id) < ($1.day, $1.redo.id) }.prefix(max(limit, 0)))
    }

    /// 重跑的项里这台能发的(那条链的 provider 是 Premium:event / impact 看 event 链,personality 看 personality 链)
    /// 和不发的(项 → 那条链现在用的 provider)。
    static func redoParts(_ chains: [String], _ s: SchedulerSettings) -> (keep: [String], skipped: [String: String]) {
        var keep: [String] = [], skipped: [String: String] = [:]
        for c in chains {
            let cfg = c == "personality" ? s.personality : s.event
            if cfg.isOffloaded { keep.append(c) } else {
                skipped[c] = Provider(rawValue: cfg.providerId)?.displayName ?? "no provider"
            }
        }
        return (keep, skipped)
    }

    /// 把 Premium 要重跑的日子打成包(调用方持交换锁,上传由调用方放锁后做):一天一份,只带 provider 是 Premium 的项
    /// (`redoParts`),都不是或那天没有帧就不打包;每天怎么处理的回报给 Premium。最多 `maxRedoDaysInFlight`
    /// 天在路上;台账记 `redo`(在路上时不再打)。返回打出来的包 id。
    @MainActor
    static func exportRedo(dbPool: DatabasePool, ask: PremiumRemote.Ask) async -> [String] {
        let root = Storage.rootURL
        guard !MemoryStaging.hasPending(.events, root: root),
              !MemoryStaging.hasPending(.portrait, root: root),
              !MemoryStaging.hasPending(.personality, root: root),
              !EditDraft.hasAnyPending() else { return [] }
        let inFlight = PremiumRemote.readState(root).redoInFlight
        let todo = nextRedoDays(ask.redo, inFlight: inFlight, limit: maxRedoDaysInFlight - inFlight.count)
        guard !todo.isEmpty else { return [] }
        let scheduler = MemoryScheduler.shared
        guard scheduler.acquireAllLocks() else { return [] }
        defer { scheduler.releaseAllLocks() }
        let sched = ConfigStore.shared.current.scheduler
        let transport = PremiumRemote.transport(ConfigStore.shared.current.premium)
        func report(_ redo: PremiumRemote.Redo, _ day: String, _ r: PremiumRemote.RedoReport) async {
            do { try await transport?.reportRedo(id: redo.id, day: day, report: r) } catch {
                exportLog.notice("reprocess \(day, privacy: .public): report failed, retry next check: \(error.localizedDescription, privacy: .public)")
            }
        }
        var all: [String] = []
        for (redo, day) in todo {
            let (keep, skipped) = redoParts(redo.chains, sched)
            let input: Input
            do {
                guard !keep.isEmpty else {
                    exportLog.notice("reprocess \(day, privacy: .public): nothing on Premium, not sent")
                    await report(redo, day, .init(sent: false, empty: false, skipped: skipped))
                    continue
                }
                guard try redoDayHasFrames(dbPool: dbPool, day: day) else {
                    exportLog.notice("reprocess \(day, privacy: .public): no frames that day, not sent")
                    await report(redo, day, .init(sent: false, empty: true, skipped: skipped))
                    continue
                }
                var mine = redo
                mine.chains = keep
                input = try gatherRedoInput(dbPool: dbPool, contents: ask.contents, redo: mine, day: day)
            } catch {
                exportLog.error("reprocess \(day, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let ids = await packRedoDay(input, dbPool: dbPool, root: root) else { continue }
            let real = input.pending.eventIntervals.map(\.id).filter { !$0.hasPrefix(redoIntervalPrefix) }
            PremiumRemote.updateState(root) { s in
                for id in ids {
                    s.uploads.append(.init(bundleId: id, trigger: PremiumExchange.triggerRedo, chains: input.chains,
                                           createdAt: PremiumExchange.isoNow(), status: PremiumRemote.statusPendingUpload,
                                           intervals: real, redo: "\(redo.id)/\(day)"))
                }
                s.lastExport = .init(bundleId: ids[ids.count - 1], at: PremiumExchange.isoNow(), outcome: "reprocess \(day)")
            }
            exportLog.notice("packed reprocess of \(day, privacy: .public) (\(keep.joined(separator: ", "), privacy: .public)): \(ids.joined(separator: ", "), privacy: .public)")
            await report(redo, day, .init(sent: true, empty: false, skipped: skipped))
            all += ids
        }
        return all
    }

    /// 本地日的偏移(性格日台账里钉死的,没有就按那天中午本机时区)和 [00:00, 24:00) 的 UTC ms。
    private static func redoDayWindow(_ store: EventIntervalStore, _ day: String) throws -> (Int, (start: Int64, end: Int64)) {
        let guess = IntervalSegmenter.dayWindow(day, tzOffsetMin: IntervalSegmenter.currentOffsetMin())
        let noon = Date(timeIntervalSince1970: Double((guess?.start ?? 0) + 43_200_000) / 1000)
        let off = try store.personalityDay(day)?.tzOffsetMin ?? IntervalSegmenter.currentOffsetMin(at: noon)
        guard let w = IntervalSegmenter.dayWindow(day, tzOffsetMin: off) else {
            throw NSError(domain: "PremiumExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad day \(day)"])
        }
        return (off, w)
    }

    /// 那天有没有帧(没有就不发重跑包,只回报)。
    static func redoDayHasFrames(dbPool: DatabasePool, day: String) throws -> Bool {
        let (_, w) = try redoDayWindow(EventIntervalStore(dbPool: dbPool), day)
        return try dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM frames WHERE timestamp_ms >= :s AND timestamp_ms < :e)",
                              arguments: ["s": w.start, "e": w.end]) ?? false
        }
    }

    /// 区间台账开始(origin)之前的日子没有区间,重跑时临时拼的区间 id 前缀(Premium 不回写台账)。
    static let redoIntervalPrefix = "redo:"

    /// 重跑某个本地日的输入。chains 有 event / impact 时带上碰到这天的全部已封区间(event 置 pending 重新聚类、连打分;
    /// 只有 impact 时 event 保持 complete、只把 impact 置 pending),这天落在区间台账开始之前的那段拼成一个
    /// `redo:<起点>` 区间;有 personality 时带上这天的性格日。portrait 搬到 Premium 时,重新聚类后接着蒸馏。
    @MainActor
    static func gatherRedoInput(dbPool: DatabasePool, contents: [String], redo: PremiumRemote.Redo,
                                day: String) throws -> Input {
        let store = EventIntervalStore(dbPool: dbPool)
        let (off, w) = try redoDayWindow(store, day)
        let ev = redo.chains.contains("event"), pers = redo.chains.contains("personality")
        let rescore = ev || redo.chains.contains("impact")
        let pending = ProcessingStatus.pending.rawValue
        let event = ev ? pending : ProcessingStatus.complete.rawValue
        var ivs: [PremiumIntervalEntry] = []
        if rescore {
            ivs = try store.all().filter { $0.startMs < w.end && $0.endMs > w.start }.map {
                var e = PremiumIntervalEntry($0)
                e.eventStatus = event
                e.impactStatus = pending
                e.retryCount = 0
                return e
            }
            let t0 = try store.origin() ?? w.end
            if w.start < t0 {
                let end = min(w.end, t0)
                let (n, maxId) = try dbPool.read { db -> (Int, Int64) in
                    let r = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS n, MAX(id) AS max_id FROM frames
                        WHERE \(EventIntervalStore.eventFrameFilter) AND timestamp_ms >= :s AND timestamp_ms < :e
                        """, arguments: ["s": w.start, "e": end])
                    return (Int((r?["n"] as Int64?) ?? 0), (r?["max_id"] as Int64?) ?? 0)
                }
                ivs.insert(PremiumIntervalEntry(
                    id: "\(redoIntervalPrefix)\(w.start)", startMs: w.start, endMs: end, tzOffsetMin: off,
                    trigger: PremiumExchange.triggerRedo, eventStatus: event, impactStatus: pending, retryCount: 0,
                    frameCount: n, afterFrameId: 0, maxFrameId: maxId), at: 0)
            }
        }
        let pday = PremiumPersonalityDayEntry(day: day, tzOffsetMin: off, status: pending, retryCount: 0)
        let p = PremiumPending(
            eventIntervals: ivs, personalityDays: pers ? [day] : [], distillPending: false, classifyPending: ev,
            writingStyleEnabled: false, writingRecordsUnprocessed: 0, personalityLog: pers ? [pday] : [])
        let portrait = ev && ConfigStore.shared.current.scheduler.portrait.isOffloaded
        let chains = PremiumPending.chainOrder.filter {
            ($0 == "event" && rescore) || ($0 == "portrait" && portrait) || ($0 == "personality" && pers)
        }
        let store2 = ProcessingLogStore()
        let da = store2.row(for: ProcessingLogStore.distillAnchorDate)?.distill ?? .idle
        let ca = store2.row(for: ProcessingLogStore.classifyAnchorDate)?.classify ?? .idle
        var input = makeInput(trigger: PremiumExchange.triggerRedo, chains: chains, contents: contents, pending: p,
                              distill: da.rawValue, classify: ca.rawValue)
        input.redo = [PremiumRedoEntry(id: redo.id, day: day, chains: redo.chains, intervals: ivs.map(\.id))]
        return input
    }

    /// 一天的重跑包:整天先打一个,超了上限按 `packWithinCap` 把区间对半分,剩下的区间接着打下一个包;
    /// 性格日只放在最后一个包里,每个包的 `redo` 只列它带的区间。有一个没打成就全部作废(nil,下一次检查再来)。
    @MainActor
    static func packRedoDay(_ input: Input, dbPool: DatabasePool, root: URL) async -> [String]? {
        guard let entry = input.redo?.first else { return nil }
        func make(_ ivs: [PremiumIntervalEntry], last: Bool) -> Input {
            var x = input
            x.pending.eventIntervals = ivs
            if !last {
                x.pending.personalityDays = []
                x.pending.personalityLog = []
            }
            x.redo = [PremiumRedoEntry(id: entry.id, day: entry.day, chains: entry.chains, intervals: ivs.map(\.id))]
            return x
        }
        func package(_ x: Input) async -> ExportResult {
            await Task.detached(priority: .utility) {
                do {
                    return try packageForUpload(input: x, root: root, dbPool: dbPool)
                } catch {
                    exportLog.error("reprocess export failed: \(error.localizedDescription, privacy: .public)")
                    return .skipped("export failed: \(error.localizedDescription)")
                }
            }.value
        }
        var rest = input.pending.eventIntervals
        var ids: [String] = []
        repeat {
            let now = rest
            let packed = await packWithinCap(make(now, last: true),
                                             regather: { make(Array(now.prefix($0)), last: $0 >= now.count) },
                                             package: package)
            guard case .exported = packed.result else {
                for id in ids { try? FileManager.default.removeItem(at: PremiumRemote.archiveURL(root, id)) }
                return nil
            }
            ids += packed.ids
            rest.removeFirst(min(packed.input.pending.eventIntervals.count, rest.count))
        } while !rest.isEmpty
        return ids
    }

    // MARK: - 取输入(主线程)

    /// 真实 pending。已经在路上(发出了、结果还没导入)的区间不再发;性格日就绪的判断把它们算作已有着落。
    @MainActor
    static func pendingNow(dbPool: DatabasePool, maxIntervals: Int = .max) -> PremiumPending {
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
            writingUnprocessed: { (try? WritingStyleStore(dbPool: dbPool).unprocessedCount()) ?? 0 },
            maxIntervals: maxIntervals)
    }

    /// `chains` = 有待处理工作的链,pending 只留这些链;都没活 → nil。`maxIntervals`:包最多带几个区间。
    @MainActor
    static func gatherInput(dbPool: DatabasePool, contents: [String], maxIntervals: Int = .max) -> Input? {
        let all = pendingNow(dbPool: dbPool, maxIntervals: maxIntervals)
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
        return makeInput(trigger: PremiumExchange.triggerNightly, chains: chains, contents: contents,
                         pending: all.only(chains), distill: da.rawValue, classify: ca.rawValue)
    }

    /// dry-run 测试包:把 [fromMs, toMs) 当作一个未处理的区间(帧不按 id 截断),四条链都
    /// 视为搬到 Premium;personality 带上完全落在这段里的本地日;distill / classify 视为
    /// pending;`chains` = event / portrait / personality,writing style 频率不是 off 时
    /// 再加 writing_style。包内容 = 这个版本能放的全部(`supportedContents`)。不读写台账,树镜像原样。
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
                         contents: PremiumRemote.supportedContents.sorted(), pending: pending, distill: ProcessingStatus.pending.rawValue,
                         classify: ProcessingStatus.pending.rawValue)
    }

    @MainActor
    private static func makeInput(trigger: String, chains: [String], contents: [String], pending: PremiumPending,
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
        return Input(trigger: trigger, chains: chains, contents: contents, pending: pending, processingLog: log,
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
                               writingUnprocessed: () -> Int,
                               maxIntervals: Int = .max) -> PremiumPending {
        func on(_ key: String, _ c: SchedulerConfig) -> Bool { c.isOffloaded && c.frequency != .off }
        let eventOn = on("event", s.event)
        let wsOn = on("writing_style", s.writingStyle)
        let ivs = eventOn ? oneDayOfIntervals(eventIntervals(), limit: maxIntervals) : []
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

    private static func isOversized(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) > maxBundleBytes
    }

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
    /// 按 `input.contents` 放内容(manifest `contents` 照记),区间(分片时只取分片那段)的:
    /// - `ocr`:帧带 OCR 文字(不要时写空串);
    /// - `event_session`:区间帧再带焦点(`focused` / `focus_state` / `visible_app`)、OCR 词框(`ocr_words_json`)和画面
    ///   (`video` + `offset_ms` 指向 `video/` 里的 MP4 块,还没压成 MP4 的 `image` 指向 `images/` 里的 JPG),外加
    ///   `keystrokes/` `mouse/` `typing/<interval_id>.jsonl`(击键、鼠标、打字记录);
    /// - `audio`:`audio/<interval_id>.jsonl`(语音转写,带说话人名字)。
    /// 性格日的帧文件只看 `ocr`。manifest 的 `files` 记树以外全部文件的 sha256。
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
        let ocr = input.contents.contains("ocr")
        let session = input.contents.contains("event_session")
        for iv in input.pending.eventIntervals {
            try writeIntervalFrames(iv, to: framesDir.appendingPathComponent("\(iv.id).jsonl"), ocr: ocr,
                                    mediaInto: session ? tmp : nil, dbPool: dbPool)
            let (s, e) = intervalRange(iv)
            func rows(_ dir: String, _ sql: String) throws {
                try writeJSONLines(sql: sql, arguments: ["s": s, "e": e],
                                   to: tmp.appendingPathComponent("\(dir)/\(iv.id).jsonl"), dbPool: dbPool)
            }
            if session {
                try rows("keystrokes", """
                    SELECT id, ts_ms, bundle_id, char, is_backspace, modifiers, input_source FROM keystroke_log
                    WHERE ts_ms >= :s AND ts_ms < :e ORDER BY ts_ms, id
                    """)
                try rows("mouse", """
                    SELECT id, ts_ms, bundle_id, kind, target_pid, target_bundle_id, x, y, screen_w, screen_h,
                           click_count, modifiers FROM mouse_log
                    WHERE ts_ms >= :s AND ts_ms < :e ORDER BY ts_ms, id
                    """)
                try rows("typing", """
                    SELECT id, bundle_id, element_hash, started_at, ended_at, text, edit_log, total_chars,
                           session_start, end_value, stripped, url FROM typing_events
                    WHERE started_at >= :s AND started_at < :e ORDER BY started_at, id
                    """)
            }
            if input.contents.contains("audio") {
                try rows("audio", """
                    SELECT t.id, CAST(c.recorded_at_ms + t.start_s * 1000 AS INTEGER) AS start_ms,
                           CAST(c.recorded_at_ms + t.end_s * 1000 AS INTEGER) AS end_ms,
                           t.text, sp.name AS speaker, c.is_input, t.engine
                    FROM audio_transcriptions t JOIN audio_chunks c ON c.id = t.audio_chunk_id
                    LEFT JOIN speakers sp ON sp.id = t.speaker_id
                    WHERE c.recorded_at_ms + t.start_s * 1000 >= :s AND c.recorded_at_ms + t.start_s * 1000 < :e
                    ORDER BY start_ms, t.id
                    """)
            }
        }
        for p in input.pending.personalityLog {
            try writeDayFrames(p, to: framesDir.appendingPathComponent("pday_\(p.day).jsonl"), ocr: ocr, dbPool: dbPool)
        }

        // writing_records.jsonl
        if input.pending.writingStyleEnabled {
            try writeWritingRecords(to: tmp.appendingPathComponent("writing_records.jsonl"),
                                    limit: input.params.writingStyleBatch, dbPool: dbPool)
        }

        // 树以外的全部文件(此时包里只有它们)。
        var files: [String: String] = [:]
        let base = tmp.standardizedFileURL.path + "/"
        for case let f as URL in fm.enumerator(at: tmp, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects ?? []
        where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files[String(f.standardizedFileURL.path.dropFirst(base.count))] = PremiumExchange.fileSHA(f)
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

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let manifest = PremiumBundleManifest(
            bundleId: bundleId, exportedAtMs: nowMs, macNowMs: nowMs,
            appVersion: input.appVersion, trigger: input.trigger, chains: input.chains, contents: input.contents,
            pending: input.pending, processingLog: input.processingLog,
            personalityLog: input.pending.personalityLog, aboutUserBlock: input.aboutUserBlock,
            params: input.params, trees: trees, files: files, redo: input.redo)
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

    private static func lineEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    /// 区间(分片时是分片那段)的 [起, 止) UTC ms。
    static func intervalRange(_ iv: PremiumIntervalEntry) -> (Int64, Int64) {
        (max(iv.startMs ?? 0, iv.partFromMs ?? Int64.min), min(iv.endMs ?? 0, iv.partToMs ?? Int64.max))
    }

    /// 区间内全部帧(`EventIntervalStore.intervalFrameSQL`,不设上限),按时间升序。`ocr` false = OCR 文字写空串;
    /// `mediaInto` 非 nil(event_session)= 再带焦点、OCR 词框,画面复制进这个包目录。
    static func writeIntervalFrames(_ iv: PremiumIntervalEntry, to url: URL, ocr: Bool, mediaInto: URL?,
                                    dbPool: DatabasePool) throws {
        let (start, end) = intervalRange(iv)
        let args: StatementArguments = [
            "iv_start": start, "iv_end": end,
            "iv_after": iv.afterFrameId ?? 0, "iv_max": iv.maxFrameId ?? Int64.max,
        ]
        let media = try mediaInto.map {
            try copyFrameMedia(where: EventIntervalStore.intervalFrameSQL, arguments: args, into: $0, dbPool: dbPool)
        }
        try writeFrameLines(where: EventIntervalStore.intervalFrameSQL, arguments: args, to: url, ocr: ocr,
                            media: media, dbPool: dbPool)
    }

    /// 某本地日 [00:00, 24:00) 的全部帧(不过滤、不设上限),按时间升序。
    static func writeDayFrames(_ p: PremiumPersonalityDayEntry, to url: URL, ocr: Bool, dbPool: DatabasePool) throws {
        let (s, e) = try dayBounds(p)
        try writeFrameLines(where: "timestamp_ms >= :start AND timestamp_ms < :end",
                            arguments: ["start": s, "end": e], to: url, ocr: ocr, media: nil, dbPool: dbPool)
    }

    /// `media` 非 nil(event_session)时每行再带焦点、OCR 词框和 `media[帧 id]` 的画面字段。
    private static func writeFrameLines(where cond: String, arguments: StatementArguments, to url: URL, ocr: Bool,
                                        media: [Int64: [String: Any]]?, dbPool: DatabasePool) throws {
        let text = ocr ? "COALESCE(ocr_backfill_text, full_text, '')" : "''"
        let session = media == nil ? ""
            : ", focused, focus_state, visible_app, COALESCE(ocr_backfill_words, ocr_words_json) AS ocr_words_json"
        try writeJSONLines(sql: """
            SELECT id, timestamp_ms, COALESCE(app_name, '') AS app_name, COALESCE(window_name, '') AS window_name,
                   browser_url, \(text) AS ocr\(session)
            FROM frames
            WHERE \(cond)
            ORDER BY timestamp_ms ASC, id ASC
            """, arguments: arguments, to: url, dbPool: dbPool,
            extra: media.map { m in { r in m[r["id"]] ?? noMedia } })
    }

    private static var noMedia: [String: Any] { ["video": NSNull(), "offset_ms": NSNull(), "image": NSNull()] }

    /// 帧的画面复制进包目录:压好的帧 → `video/<块文件名>`(行里 `video` + `offset_ms`),还没压的 → `images/<文件名>`
    /// (`image`),文件不在 → 都是 null。JPG 正好被后台压缩删掉时再读一次这一帧,改用它的 MP4 块。
    /// 返回 帧 id → 行里补的字段。
    private static func copyFrameMedia(where cond: String, arguments: StatementArguments, into dir: URL,
                                       dbPool: DatabasePool) throws -> [Int64: [String: Any]] {
        let fm = FileManager.default
        var placed: [String: String?] = [:]   // 库里的相对路径 → 包内路径(nil = 文件不在)
        func place(_ raw: String?, _ sub: String) -> String? {
            guard let raw else { return nil }
            if let hit = placed[raw] { return hit }
            var rel: String?
            if let src = AssetPath.resolve(raw) {
                let r = "\(sub)/\((raw as NSString).lastPathComponent)"
                let dst = dir.appendingPathComponent(r)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) || (try? fm.copyItem(atPath: src, toPath: dst.path)) != nil { rel = r }
            }
            placed[raw] = rel
            return rel
        }
        /// nil = JPG 刚被删,要重读。
        func fields(_ r: Row) -> [String: Any]? {
            if let chunk: String = r["chunk"] {
                return ["video": place(chunk, "video") ?? NSNull(), "offset_ms": (r["offset_ms"] as Int64?) ?? NSNull(),
                        "image": NSNull()]
            }
            guard let snap: String = r["snapshot_path"] else { return noMedia }
            guard let img = place(snap, "images") else { return nil }
            return ["video": NSNull(), "offset_ms": NSNull(), "image": img]
        }
        let pick = """
            SELECT id, offset_ms, snapshot_path,
                   (SELECT file_path FROM video_chunks v WHERE v.id = frames.video_chunk_id) AS chunk
            FROM frames
            """
        var out: [Int64: [String: Any]] = [:]
        var retry: [Int64] = []
        try dbPool.read { db in
            let rows = try Row.fetchCursor(db, sql: "\(pick) WHERE \(cond)", arguments: arguments)
            while let r = try rows.next() {
                let id: Int64 = r["id"]
                if let f = fields(r) { out[id] = f } else { retry.append(id) }
            }
        }
        for id in retry {
            let r = try dbPool.read { db in try Row.fetchOne(db, sql: "\(pick) WHERE id = :id", arguments: ["id": id]) }
            out[id] = r.flatMap(fields) ?? noMedia
        }
        return out
    }

    /// 查询结果一行一个 JSON 对象写到 `url`(键 = 列名,NULL 写 null,BLOB 不写),边查边写;`extra` 给每行补字段。
    private static func writeJSONLines(sql: String, arguments: StatementArguments, to url: URL, dbPool: DatabasePool,
                                       extra: ((Row) -> [String: Any])? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "PremiumExport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.lastPathComponent)"])
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var buf = Data()
        try dbPool.read { db in
            let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let r = try rows.next() {
                try autoreleasepool {   // 一天的帧连词框有几百 MB,临时对象逐行放掉
                    var obj: [String: Any] = [:]
                    for (col, v) in r {
                        switch v.storage {
                        case .null: obj[col] = NSNull()
                        case .int64(let i): obj[col] = i
                        case .double(let d): obj[col] = d
                        case .string(let t): obj[col] = t
                        case .blob: break
                        }
                    }
                    if let extra { obj.merge(extra(r)) { $1 } }
                    buf.append(try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]))
                    buf.append(0x0A)
                }
                if buf.count >= 4 << 20 {
                    try out.write(contentsOf: buf)
                    buf.removeAll(keepingCapacity: true)
                }
            }
        }
        try out.write(contentsOf: buf)
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
