import Foundation
import GRDB
import os.log

private let importLog = Logger(subsystem: "com.myportrait.memory", category: "premium-import")

/// 把 Premium 的结果包落回数据根:三方合并三棵树、应用 db_ops、写可回滚快照。不审批,导入即生效。
/// 结果包从收件服务下载(`PremiumRemote`):按台账逐个查状态,done 的下载、核对 sha256、解到
/// `.staging/premium_download/<bundle_id>/`,导入成功后向服务端确认(ack)并删掉下载的文件;
/// 服务端处理失败(failed)的通知一次、从台账删掉,下一次封区间检查按台账重新导出。
///
/// 三方合并(逐文件):base = 结果包 `base_trees`,premium = `result_trees`,
/// mac = 当前文件哈希。
///   - mac == premium                → 已一致,不动
///   - mac 不存在 / mac == base     → 写 premium 版
///   - premium == base               → 保留 mac
///   - 其余                         → 冲突:保留 mac,premium 版存 `.staging/premium_conflicts/<id>/`
///   - deleted:mac == base 才删,否则记冲突
/// 结果里没有的文件一律不动。
/// 只导完整的结果包(`PremiumExchange.resultReady`);已经 complete 的区间 / 本地日不被结果改回别的状态。
///
/// 快照在 `.staging/premium_import_backup/<id>/`(三棵树 + 被改的 processing_log /
/// event_intervals / personality_days 行 + db_ops.json),只留最近 3 份;
/// `--premium-rollback <id>` 用它还原。
enum PremiumExchangeImporter {

    static let backupKeep = 3

    struct Report: Sendable {
        var bundleId: String
        var status: String
        var written = 0
        var kept = 0
        var deleted = 0
        var conflicts: [String] = []
        var summary: [String: Int] = [:]

        var line: String {
            var parts = ["\(written) file(s) updated"]
            if deleted > 0 { parts.append("\(deleted) removed") }
            if !conflicts.isEmpty { parts.append("\(conflicts.count) conflict(s) kept local") }
            let s = summary.sorted { $0.key < $1.key }.filter { $0.value > 0 }
                .map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \($0.value)" }
            return (parts + s).joined(separator: " · ")
        }
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 调度器 / CLI 入口

    /// 按台账查 Premium 上的包,把 done 的逐个下载、导入、确认。调度器只在有链搬到 Premium 时调;
    /// CLI 传 `notify=false`,并且重试导入失败过的包(`retryFailed`)。`failed` = 导入抛错的包数。
    /// 网络部分不持锁;导入时才拿交换锁 + 调度锁。
    @MainActor
    static func runIfNeeded(dbPool: DatabasePool, notify: Bool = true, lockWait: TimeInterval = 0,
                            retryFailed: Bool = false) async -> (reports: [Report], failed: Int) {
        let cfg = ConfigStore.shared.current.premium
        let root = Storage.rootURL
        // 与 tick 同规则:有手动 run 待审 / AI 编辑 draft 挂起 → 不导入。
        guard !MemoryStaging.hasPending(.events, root: root),
              !MemoryStaging.hasPending(.portrait, root: root),
              !MemoryStaging.hasPending(.personality, root: root),
              !EditDraft.hasAnyPending() else {
            importLog.info("import: staging / edit draft pending — skip")
            return ([], 0)
        }
        guard PremiumRemote.transport(cfg) != nil else { return ([], 0) }
        if retryFailed {
            PremiumRemote.updateState(root) { s in
                for i in s.uploads.indices where s.uploads[i].status == PremiumRemote.statusImportFailed {
                    s.uploads[i].status = "done"
                }
            }
        }
        let ready = await collectResults(root: root, cfg: cfg, notify: notify)
        guard !ready.isEmpty else { return ([], 0) }

        // 交换锁跨进程:helper 的封区间 / 导出和 app 的导入不会同时读写树。
        guard let lock = await PremiumExchange.FileLock.acquire(wait: lockWait) else {
            importLog.info("import: exchange lock busy — retry next tick")
            return ([], 0)
        }
        let scheduler = MemoryScheduler.shared
        guard scheduler.acquireAllLocks() else {
            lock.release()
            importLog.info("import: scheduler busy — retry next tick")
            return ([], 0)
        }

        var reports: [Report] = []
        var imported: [String] = []
        var failed = 0
        for (id, dir) in ready {
            let r: Result<Report, Error> = await Task.detached(priority: .utility) {
                Result { try importBundle(id: id, dir: dir, root: root, dbPool: dbPool, defaults: .standard) }
            }.value
            try? FileManager.default.removeItem(at: dir)
            switch r {
            case .success(let rep):
                reports.append(rep)
                imported.append(id)
                guard notify else { continue }
                NotificationCenterService.shared.post(.schedulerRun(
                    pipeline: "My Portrait Premium", success: rep.status != "failed",
                    summary: rep.status == "complete" ? rep.line : "\(rep.status) · \(rep.line)"))
            case .failure(let err):
                failed += 1
                PremiumRemote.updateState(root) { s in
                    if let i = s.uploads.firstIndex(where: { $0.bundleId == id }) {
                        s.uploads[i].status = PremiumRemote.statusImportFailed
                    }
                }
                importLog.error("import \(id, privacy: .public) failed: \(err.localizedDescription, privacy: .public)")
                print("[premium-import] \(id) failed: \(err.localizedDescription)")
                guard notify else { continue }
                NotificationCenterService.shared.post(.pipelineNeedsFix(
                    pipeline: "My Portrait Premium", kindLabel: "Import failed",
                    userMessage: err.localizedDescription))
            }
        }
        scheduler.releaseAllLocks()
        lock.release()

        await acknowledge(imported, root: root, cfg: cfg)
        return (reports, failed)
    }

    /// 网络部分(不持锁):按服务端刷新台账;服务端处理失败的通知一次、删掉(下一次封区间检查按台账
    /// 重新导出);done 的下载、核对 sha256、解到 `.staging/premium_download/<id>/`。下载失败的下次再试。
    static func collectResults(root: URL, cfg: PremiumConfig, notify: Bool) async -> [(id: String, dir: URL)] {
        guard let transport = PremiumRemote.transport(cfg) else { return [] }
        await PremiumRemote.refresh(root: root, cfg: cfg)
        for u in PremiumRemote.readState(root).uploads where u.status == "failed" {
            importLog.error("Premium failed \(u.bundleId, privacy: .public): \(u.summary ?? "", privacy: .public)")
            PremiumRemote.updateState(root) { s in
                s.drop(u.bundleId)
                s.lastImport = .init(bundleId: u.bundleId, at: PremiumExchange.isoNow(), outcome: "failed on Premium")
            }
            if notify {
                await MainActor.run {
                    NotificationCenterService.shared.post(.pipelineNeedsFix(
                        pipeline: "My Portrait Premium", kindLabel: "Processing failed", userMessage: u.summary ?? u.bundleId))
                }
            }
        }
        var ready: [(id: String, dir: URL)] = []
        for u in PremiumRemote.readState(root).uploads where u.status == "done" {
            let archive = PremiumRemote.downloadDir(root).appendingPathComponent("\(u.bundleId).tar.gz")
            let dir = PremiumRemote.downloadDir(root).appendingPathComponent(u.bundleId, isDirectory: true)
            do {
                let header = try await transport.download(bundleId: u.bundleId, to: archive)
                let sha = PremiumExchange.fileSHA(archive) ?? ""
                guard header.isEmpty || sha == header, u.resultSha256.map({ $0 == sha }) ?? true else {
                    throw ImportError(message: "\(u.bundleId): downloaded result does not match its sha256")
                }
                try PremiumRemote.unpack(archive, into: dir)
                ready.append((u.bundleId, dir))
            } catch {
                importLog.info("download \(u.bundleId, privacy: .public): \(error.localizedDescription, privacy: .public) — retry next tick")
            }
            try? FileManager.default.removeItem(at: archive)
        }
        return ready
    }

    /// 导入成功的向服务端确认(删掉服务端的结果),再从台账删掉;确认没成功的下次重下重导(导入幂等)。
    static func acknowledge(_ ids: [String], root: URL, cfg: PremiumConfig) async {
        guard !ids.isEmpty, let transport = PremiumRemote.transport(cfg) else { return }
        for id in ids {
            do {
                try await transport.ack(bundleId: id)
                PremiumRemote.updateState(root) { s in s.drop(id) }
            } catch {
                importLog.info("ack \(id, privacy: .public): \(error.localizedDescription, privacy: .public) — retry next tick")
            }
        }
    }

    // MARK: - 导入一个结果包

    /// `dir` = 解开的结果包。成功 / 失败都记进台账的 `last_import`。
    static func importBundle(id: String, dir: URL, root: URL,
                             dbPool: DatabasePool, defaults: UserDefaults) throws -> Report {
        do {
            let r = try importBundleUnrecorded(id: id, dir: dir, root: root, dbPool: dbPool, defaults: defaults)
            PremiumRemote.updateState(root) { $0.lastImport = .init(bundleId: id, at: PremiumExchange.isoNow(), outcome: r.status) }
            return r
        } catch {
            PremiumRemote.updateState(root) { $0.lastImport = .init(bundleId: id, at: PremiumExchange.isoNow(), outcome: "failed") }
            throw error
        }
    }

    private static func importBundleUnrecorded(id: String, dir: URL, root: URL,
                                               dbPool: DatabasePool, defaults: UserDefaults) throws -> Report {
        let fm = FileManager.default
        guard PremiumExchange.resultReady(dir) else {
            throw ImportError(message: "\(id): DONE, db_ops.json or result files missing")
        }
        let manifest = try JSONDecoder().decode(
            PremiumResultManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        guard manifest.bundleId == id else { throw ImportError(message: "\(id): manifest bundle_id mismatch") }
        let opsURL = dir.appendingPathComponent("db_ops.json")
        let ops = try JSONDecoder().decode(PremiumDbOps.self, from: Data(contentsOf: opsURL))

        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        let backup = staging.appendingPathComponent("premium_import_backup/\(id)", isDirectory: true)
        let ledger = staging.appendingPathComponent("premium_imported.json")
        let alreadyImported = readLedger(ledger).contains(id)

        // 1. 快照。同一个包重导时保留首次导入前那份(给 rollback),另拍一份临时的
        //    只给本次失败还原用。
        let safety = alreadyImported
            ? backup.deletingLastPathComponent().appendingPathComponent(".\(id).reimport", isDirectory: true)
            : backup
        try makeBackup(at: safety, root: root, ops: ops, opsURL: opsURL, dbPool: dbPool)
        pruneBackups(in: backup.deletingLastPathComponent(), keep: backupKeep)
        defer { if alreadyImported { try? fm.removeItem(at: safety) } }

        var report = Report(bundleId: id, status: manifest.status, summary: manifest.summary ?? [:])
        do {
            // 2. 三方合并。
            try merge(manifest: manifest, bundleDir: dir, root: root,
                      conflictsDir: staging.appendingPathComponent("premium_conflicts/\(id)", isDirectory: true),
                      report: &report)
            // 3. db_ops(一个事务)。
            try applyDbOps(ops, dbPool: dbPool, recordRuns: !alreadyImported)
        } catch {
            try? restoreTrees(from: safety, root: root)
            throw error
        }

        // 4. 事务外的附带写入(失败只记日志)。
        if !alreadyImported {
            for (day, text) in ops.journalAppend ?? [:] {
                appendJournal(day: day, text: text, root: root)
            }
        }
        applyLastRunDays(ops.lastRunDays, defaults: defaults)
        for (name, text) in ops.llmDumps ?? [:] {
            let safe = (name as NSString).lastPathComponent
            guard !safe.isEmpty, !safe.hasPrefix(".") else { continue }
            let url = root.appendingPathComponent("llm_dump/\(safe)")
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
        if !alreadyImported { writeLedger(ledger, adding: id) }
        importLog.notice("imported \(id, privacy: .public): \(report.line, privacy: .public)")
        return report
    }

    // MARK: - 三方合并

    /// 相对路径必须落在三棵树里、不含 `..`、不在排除列表。
    private static func validRel(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, let first = parts.first,
              PremiumExchange.treeNames.contains(String(first)),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return false }
        return !PremiumExchange.isExcluded(rel)
    }

    private static func merge(manifest: PremiumResultManifest, bundleDir: URL, root: URL,
                              conflictsDir: URL, report: inout Report) throws {
        let fm = FileManager.default
        var conflicts: [String] = []
        for (rel, premium) in manifest.resultTrees.sorted(by: { $0.key < $1.key }) {
            guard validRel(rel) else { continue }
            let base = manifest.baseTrees[rel]
            let dst = root.appendingPathComponent(rel)
            let mac = PremiumExchange.fileSHA(dst)
            if mac == premium { continue }
            if mac == nil || mac == base {
                let src = bundleDir.appendingPathComponent(rel)
                let data = try Data(contentsOf: src)
                guard PremiumExchange.sha256Hex(data) == premium else {
                    throw ImportError(message: "\(rel): content does not match result_trees hash")
                }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dst, options: .atomic)
                report.written += 1
            } else if premium == base {
                report.kept += 1
            } else {
                let keep = conflictsDir.appendingPathComponent(rel)
                try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: keep)
                try fm.copyItem(at: bundleDir.appendingPathComponent(rel), to: keep)
                conflicts.append(rel)
            }
        }
        for rel in manifest.deleted ?? [] {
            guard validRel(rel) else { continue }
            let dst = root.appendingPathComponent(rel)
            guard let mac = PremiumExchange.fileSHA(dst) else { continue }
            if mac == manifest.baseTrees[rel] {
                try fm.removeItem(at: dst)
                report.deleted += 1
            } else {
                conflicts.append(rel + " (deleted on Premium)")
            }
        }
        if !conflicts.isEmpty {
            try fm.createDirectory(at: conflictsDir, withIntermediateDirectories: true)
            try Data((conflicts.joined(separator: "\n") + "\n").utf8)
                .write(to: conflictsDir.appendingPathComponent("conflicts.txt"))
        }
        report.conflicts = conflicts
    }

    // MARK: - db_ops

    private static func statusColumns(_ e: PremiumProcessingLogEntry) -> [(String?, String)] {
        [(e.rawStatus, "raw_status"), (e.eventStatus, "event_status"),
         (e.impactStatus, "impact_status"), (e.personalityStatus, "personality_status"),
         (e.distillStatus, "distill_status"), (e.classifyStatus, "classify_status")]
    }

    private static func applyDbOps(_ ops: PremiumDbOps, dbPool: DatabasePool, recordRuns: Bool) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            // processing_log:按列覆盖,不碰 active_processor / heartbeat_ms;值没变不写。
            for e in ops.processingLog ?? [] {
                var sets: [String] = []
                var diffs: [String] = []
                var args: [String: (any DatabaseValueConvertible)?] = ["date": e.date, "now": now]
                for (val, col) in statusColumns(e) {
                    guard let v = val else { continue }
                    guard ProcessingStatus(rawValue: v) != nil else {
                        throw ImportError(message: "processing_log \(e.date): bad \(col) '\(v)'")
                    }
                    sets.append("\(col) = :\(col)")
                    diffs.append("\(col) IS NOT :\(col)")
                    args[col] = v
                }
                if let rc = e.retryCount {
                    sets.append("retry_count = :retry_count")
                    diffs.append("retry_count IS NOT :retry_count")
                    args["retry_count"] = Int64(rc)
                }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO processing_log (date, updated_at_ms) VALUES (:date, :now)",
                    arguments: ["date": e.date, "now": now])
                guard !sets.isEmpty else { continue }
                try db.execute(sql: """
                    UPDATE processing_log SET \(sets.joined(separator: ", ")), updated_at_ms = :now
                    WHERE date = :date AND (\(diffs.joined(separator: " OR ")))
                    """, arguments: StatementArguments(args))
            }

            // event_intervals:按 id 覆盖状态列;Mac 上没有这一行(不该发生)时,带齐
            // start_ms / end_ms 才插入,否则整个导入失败。Mac 上已经 complete 的阶段不改回
            // 别的状态,event 与 impact 都 complete 的行整行不动(重复处理的结果不回退台账)。
            let done = ProcessingStatus.complete.rawValue
            for e in ops.eventIntervals ?? [] {
                let cur = try Row.fetchOne(db, sql: """
                    SELECT event_status, impact_status FROM event_intervals WHERE id = :id
                    """, arguments: ["id": e.id])
                let curEvent = cur?["event_status"] as String?
                let curImpact = cur?["impact_status"] as String?
                if curEvent == done && curImpact == done { continue }
                if cur == nil {
                    guard let start = e.startMs, let end = e.endMs else {
                        throw ImportError(message: "event_intervals \(e.id): unknown interval")
                    }
                    try db.execute(sql: """
                        INSERT INTO event_intervals (id, start_ms, end_ms, tz_offset_min, sealed_at_ms,
                          trigger, frame_count, after_frame_id, max_frame_id, updated_at_ms)
                        VALUES (:id, :s, :e, :tz, :now, :trig, :n, :after, :max, :now)
                        """, arguments: [
                            "id": e.id, "s": start, "e": end, "tz": Int64(e.tzOffsetMin ?? 0), "now": now,
                            "trig": e.trigger ?? EventIntervalStore.triggerGap,
                            "n": Int64(e.frameCount ?? 0), "after": e.afterFrameId ?? 0,
                            "max": e.maxFrameId ?? 0,
                        ])
                }
                var sets: [String] = []
                var diffs: [String] = []
                var args: [String: (any DatabaseValueConvertible)?] = ["id": e.id, "now": now]
                for (val, col, was) in [(e.eventStatus, "event_status", curEvent),
                                        (e.impactStatus, "impact_status", curImpact)] {
                    guard let v = val else { continue }
                    guard ProcessingStatus(rawValue: v) != nil else {
                        throw ImportError(message: "event_intervals \(e.id): bad \(col) '\(v)'")
                    }
                    if was == done && v != done { continue }
                    sets.append("\(col) = :\(col)")
                    diffs.append("\(col) IS NOT :\(col)")
                    args[col] = v
                }
                if let rc = e.retryCount {
                    sets.append("retry_count = :retry_count")
                    diffs.append("retry_count IS NOT :retry_count")
                    args["retry_count"] = Int64(rc)
                }
                guard !sets.isEmpty else { continue }
                try db.execute(sql: """
                    UPDATE event_intervals SET \(sets.joined(separator: ", ")), updated_at_ms = :now
                    WHERE id = :id AND (\(diffs.joined(separator: " OR ")))
                    """, arguments: StatementArguments(args))
            }

            // personality_days:按本地日 upsert;Mac 上已经 complete 的日子不动。
            for p in ops.personalityDays ?? [] {
                guard ProcessingLogStore.day(from: p.day) != nil else {
                    throw ImportError(message: "personality_days: bad day '\(p.day)'")
                }
                if let v = p.status, ProcessingStatus(rawValue: v) == nil {
                    throw ImportError(message: "personality_days \(p.day): bad status '\(v)'")
                }
                if try String.fetchOne(db, sql: "SELECT status FROM personality_days WHERE day = :d",
                                       arguments: ["d": p.day]) == done {
                    continue
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO personality_days (day, tz_offset_min, status, retry_count, updated_at_ms)
                    VALUES (:d, :tz, :s, :rc, :now)
                    """, arguments: [
                        "d": p.day, "tz": Int64(p.tzOffsetMin ?? IntervalSegmenter.currentOffsetMin()),
                        "s": p.status ?? ProcessingStatus.pending.rawValue,
                        "rc": Int64(p.retryCount ?? 0), "now": now,
                    ])
                try db.execute(sql: """
                    UPDATE personality_days
                    SET status = COALESCE(:s, status), retry_count = COALESCE(:rc, retry_count), updated_at_ms = :now
                    WHERE day = :d AND (status IS NOT COALESCE(:s, status)
                                        OR retry_count IS NOT COALESCE(:rc, retry_count))
                    """, arguments: ["d": p.day, "s": p.status, "rc": p.retryCount.map { Int64($0) }, "now": now])
            }

            for c in ops.distillChangelog ?? [] {
                try db.execute(sql: """
                    INSERT INTO distill_changelog
                      (entity_id, field_name, before, after, triggered_by_event_id, llm_reasoning, timestamp_ms)
                    SELECT :entity, :field, :before, :after, :trig, NULL, :ts
                    WHERE NOT EXISTS (SELECT 1 FROM distill_changelog
                                      WHERE entity_id = :entity AND timestamp_ms = :ts AND after IS :after)
                    """, arguments: [
                        "entity": c.entityId, "field": c.fieldName ?? "body", "before": c.before,
                        "after": c.after, "trig": c.triggeredByEventId, "ts": c.timestampMs,
                    ])
            }

            if let ws = ops.writingStyle {
                if let run = ws.run {
                    let ids = String(data: try JSONEncoder().encode(run.inputRecordIds ?? []),
                                     encoding: .utf8) ?? "[]"
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO writing_style_runs
                          (run_id, mode, status, started_at, completed_at, error_message,
                           records_count, drafts_count, input_record_ids)
                        VALUES (:rid, :mode, :status, :started, :completed, :err, :rec, :dft, :ids)
                        """, arguments: [
                            "rid": run.runId, "mode": run.mode, "status": run.status,
                            "started": run.startedAt, "completed": run.completedAt,
                            "err": run.errorMessage,
                            "rec": run.recordsCount.map { Int64($0) },
                            "dft": run.draftsCount.map { Int64($0) }, "ids": ids,
                        ])
                }
                let ids = ws.processedRecordIds ?? []
                let ts = ws.processedAtMs ?? now
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let ph = chunk.map { _ in "?" }.joined(separator: ",")
                    var a: [DatabaseValueConvertible] = [ts]
                    a.append(contentsOf: chunk.map { $0 as DatabaseValueConvertible })
                    try db.execute(sql: """
                        UPDATE writing_records SET writing_style_processed_at = ?
                        WHERE id IN (\(ph)) AND writing_style_processed_at IS NULL
                        """, arguments: StatementArguments(a))
                }
            }

            if recordRuns, let runs = ops.pipelineRuns, !runs.isEmpty {
                for r in runs {
                    try db.execute(sql: """
                        INSERT INTO pipeline_runs (timestamp_ms, trigger, pipeline, outcome, reason)
                        VALUES (:ts, 'premium', :p, :o, :r)
                        """, arguments: ["ts": now, "p": r.pipeline, "o": r.outcome, "r": r.detail])
                }
                try db.execute(sql: """
                    DELETE FROM pipeline_runs WHERE id NOT IN
                      (SELECT id FROM pipeline_runs ORDER BY timestamp_ms DESC LIMIT 50)
                    """)
            }
        }
    }

    private static func appendJournal(day: String, text: String, root: URL) {
        guard ProcessingLogStore.day(from: day) != nil, !text.isEmpty else { return }
        let url = root.appendingPathComponent("journal/\(day).md")
        // 新建 journal 时先写标题行,与 MemoryBudget / Archiver 的写法一致。
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# 记忆维护日志 \(day)\n"
        guard !existing.contains(text) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data((existing + text).utf8).write(to: url, options: .atomic)
        } catch {
            importLog.error("journal append \(day, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Premium 给的是它那边的 UTC 日;lastRun 键存的是 Mac 本地日期,按导入时刻写。
    private static func applyLastRunDays(_ m: [String: String]?, defaults: UserDefaults) {
        guard let m, !m.isEmpty else { return }
        let keys = ["event": "scheduler.lastEventRun", "portrait": "scheduler.lastPortraitRun",
                    "personality": "scheduler.lastPersonalityRun",
                    "writing_style": "scheduler.lastWritingStyleRun"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        for k in m.keys { if let key = keys[k] { defaults.set(today, forKey: key) } }
    }

    // MARK: - 快照 / 回滚

    private struct LogBackup: Codable {
        var rows: [PremiumProcessingLogEntry]
        var absent: [String]
        var intervals: [PremiumIntervalEntry]?
        var intervalsAbsent: [String]?
        var personality: [PremiumPersonalityDayEntry]?
        var personalityAbsent: [String]?
    }

    private static func makeBackup(at backup: URL, root: URL, ops: PremiumDbOps,
                                   opsURL: URL, dbPool: DatabasePool) throws {
        let fm = FileManager.default
        let tmp = backup.deletingLastPathComponent()
            .appendingPathComponent(".\(backup.lastPathComponent).partial", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for t in PremiumExchange.treeNames {
            let src = root.appendingPathComponent(t, isDirectory: true)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: tmp.appendingPathComponent(t, isDirectory: true))
            }
        }
        // 会被覆盖的 processing_log 行。
        let dates = (ops.processingLog ?? []).map(\.date)
        var rows: [PremiumProcessingLogEntry] = []
        if !dates.isEmpty {
            let ph = dates.map { _ in "?" }.joined(separator: ",")
            rows = try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT date, raw_status, event_status, impact_status, personality_status,
                           distill_status, classify_status, retry_count
                    FROM processing_log WHERE date IN (\(ph))
                    """, arguments: StatementArguments(dates.map { $0 as DatabaseValueConvertible }))
                .map {
                    PremiumProcessingLogEntry(
                        date: $0["date"], rawStatus: $0["raw_status"], eventStatus: $0["event_status"],
                        impactStatus: $0["impact_status"], personalityStatus: $0["personality_status"],
                        distillStatus: $0["distill_status"], classifyStatus: $0["classify_status"],
                        retryCount: Int(($0["retry_count"] as Int64?) ?? 0))
                }
            }
        }
        let present = Set(rows.map(\.date))
        // 会被覆盖的 event_intervals / personality_days 行。
        let ivIds = (ops.eventIntervals ?? []).map(\.id)
        let days = (ops.personalityDays ?? []).map(\.day)
        let (ivRows, dayRows) = try dbPool.read { db -> ([PremiumIntervalEntry], [PremiumPersonalityDayEntry]) in
            var ivs: [PremiumIntervalEntry] = []
            for id in ivIds {
                if let r = try Row.fetchOne(db, sql: """
                    SELECT event_status, impact_status, retry_count FROM event_intervals WHERE id = :id
                    """, arguments: ["id": id]) {
                    ivs.append(PremiumIntervalEntry(id: id, eventStatus: r["event_status"],
                                                  impactStatus: r["impact_status"],
                                                  retryCount: Int((r["retry_count"] as Int64?) ?? 0)))
                }
            }
            var ds: [PremiumPersonalityDayEntry] = []
            for d in days {
                if let r = try Row.fetchOne(db, sql: """
                    SELECT tz_offset_min, status, retry_count FROM personality_days WHERE day = :d
                    """, arguments: ["d": d]) {
                    ds.append(PremiumPersonalityDayEntry(day: d, tzOffsetMin: Int((r["tz_offset_min"] as Int64?) ?? 0),
                                                       status: r["status"],
                                                       retryCount: Int((r["retry_count"] as Int64?) ?? 0)))
                }
            }
            return (ivs, ds)
        }
        let ivPresent = Set(ivRows.map(\.id)), dayPresent = Set(dayRows.map(\.day))
        try PremiumExchange.encoder().encode(LogBackup(
            rows: rows, absent: dates.filter { !present.contains($0) },
            intervals: ivRows, intervalsAbsent: ivIds.filter { !ivPresent.contains($0) },
            personality: dayRows, personalityAbsent: days.filter { !dayPresent.contains($0) }))
            .write(to: tmp.appendingPathComponent("processing_log.json"))
        if fm.fileExists(atPath: opsURL.path) {
            try fm.copyItem(at: opsURL, to: tmp.appendingPathComponent("db_ops.json"))
        }
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: tmp, to: backup)
    }

    private static func pruneBackups(in dir: URL, keep: Int) {
        let ids = PremiumExchange.bundleIds(in: dir)
        guard ids.count > keep else { return }
        for id in ids.prefix(ids.count - keep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
        }
    }

    /// 三棵树整树换回快照。
    private static func restoreTrees(from backup: URL, root: URL) throws {
        let fm = FileManager.default
        for t in PremiumExchange.treeNames {
            let src = backup.appendingPathComponent(t, isDirectory: true)
            let dst = root.appendingPathComponent(t, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
    }

    /// `--premium-rollback`:还原三棵树 + processing_log / event_intervals / personality_days
    /// 行 + writing style 的 run / 已处理标记。distill_changelog / pipeline_runs / journal
    /// 是历史记录,不回滚。
    static func rollback(bundleId: String, root: URL, dbPool: DatabasePool) throws {
        let backup = root.appendingPathComponent(".staging/premium_import_backup/\(bundleId)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw ImportError(message: "no backup for \(bundleId)")
        }
        try restoreTrees(from: backup, root: root)
        let log = try JSONDecoder().decode(
            LogBackup.self, from: Data(contentsOf: backup.appendingPathComponent("processing_log.json")))
        let opsURL = backup.appendingPathComponent("db_ops.json")
        let ops = (try? JSONDecoder().decode(PremiumDbOps.self, from: Data(contentsOf: opsURL))) ?? PremiumDbOps()
        try dbPool.write { db in
            for r in log.rows {
                try db.execute(sql: """
                    UPDATE processing_log SET raw_status = :raw, event_status = :ev,
                      impact_status = :imp, personality_status = :per, distill_status = :dis,
                      classify_status = :cls, retry_count = :rc, updated_at_ms = :now
                    WHERE date = :date
                    """, arguments: [
                        "raw": r.rawStatus ?? "idle", "ev": r.eventStatus ?? "idle",
                        "imp": r.impactStatus ?? "idle", "per": r.personalityStatus ?? "idle",
                        "dis": r.distillStatus ?? "idle", "cls": r.classifyStatus ?? "idle",
                        "rc": Int64(r.retryCount ?? 0),
                        "now": Int64(Date().timeIntervalSince1970 * 1000), "date": r.date,
                    ])
            }
            for d in log.absent {
                try db.execute(sql: "DELETE FROM processing_log WHERE date = :date", arguments: ["date": d])
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for r in log.intervals ?? [] {
                try db.execute(sql: """
                    UPDATE event_intervals SET event_status = :ev, impact_status = :imp,
                      retry_count = :rc, updated_at_ms = :now
                    WHERE id = :id
                    """, arguments: [
                        "ev": r.eventStatus ?? "pending", "imp": r.impactStatus ?? "idle",
                        "rc": Int64(r.retryCount ?? 0), "now": now, "id": r.id,
                    ])
            }
            for id in log.intervalsAbsent ?? [] {
                try db.execute(sql: "DELETE FROM event_intervals WHERE id = :id", arguments: ["id": id])
            }
            for r in log.personality ?? [] {
                try db.execute(sql: """
                    UPDATE personality_days SET status = :s, retry_count = :rc, updated_at_ms = :now
                    WHERE day = :d
                    """, arguments: ["s": r.status ?? "pending", "rc": Int64(r.retryCount ?? 0),
                                     "now": now, "d": r.day])
            }
            for d in log.personalityAbsent ?? [] {
                try db.execute(sql: "DELETE FROM personality_days WHERE day = :d", arguments: ["d": d])
            }
            if let ws = ops.writingStyle {
                if let run = ws.run {
                    try db.execute(sql: "DELETE FROM writing_style_runs WHERE run_id = :rid",
                                   arguments: ["rid": run.runId])
                }
                let ids = ws.processedRecordIds ?? []
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let ph = chunk.map { _ in "?" }.joined(separator: ",")
                    var a: [DatabaseValueConvertible] = []
                    a.append(contentsOf: chunk.map { $0 as DatabaseValueConvertible })
                    var cond = ""
                    if let ts = ws.processedAtMs {
                        cond = " AND writing_style_processed_at = ?"
                        a.append(ts)
                    }
                    try db.execute(sql: """
                        UPDATE writing_records SET writing_style_processed_at = NULL
                        WHERE id IN (\(ph))\(cond)
                        """, arguments: StatementArguments(a))
                }
            }
        }
    }

    // MARK: - 已导入账本(让 pipeline_runs / journal 在重导时不重复)

    private static func readLedger(_ url: URL) -> [String] {
        guard let d = try? Data(contentsOf: url),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return a
    }

    private static func writeLedger(_ url: URL, adding id: String) {
        var a = readLedger(url)
        guard !a.contains(id) else { return }
        a.append(id)
        if a.count > 50 { a.removeFirst(a.count - 50) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(a).write(to: url, options: .atomic)
    }
}
