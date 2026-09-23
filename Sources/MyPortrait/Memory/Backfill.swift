import Foundation

/// event 链的 event 步:把一个区间(`EventInterval`)的帧聚成事件。
///
///   1. 取区间全部帧(`TimelineDB.frames(fromMs:toMs:afterId:maxId:)`,不设上限)。
///   2. Tier 1 合并(app + window + 5 min,规则)→ session。
///   3. 每个 session 配 OCR;OCR 不足 60 字的丢掉。
///   4. EventBuilder(LLM)聚类:事件列表(每个 ≥ 1 个 session)+ skipped。
///      提示词里的日期与活跃窗口的参照日 = 整个区间帧的 attribute_day。
///   5. 落到 overlay(还不写盘):
///      - join_existing → 在已有事件上记一次出现(那几个 session 的 attribute_day)、
///        追加帧 id、清空 distilledInto;title / summary / facets 不动。
///      - 新事件 → `events/<本地日>/<本地日>_<slug>.md`,本地日 = 成员帧的 attribute_day
///        (区间钉死的 tz_offset_min);同一日期目录可以被多个区间写入。
///   调用方确认成功后 `overlay.commit`,失败什么都不写。weight pass 由调用方在
///   整个 job 末尾跑一次。
///
/// 覆盖率在 EventBuilder 内保证 —— LLM 漏掉的 session 进 skipped,聚类抛错则整个
/// 区间算失败。
@MainActor
enum Backfill {
    /// 一个区间 event 步的结果。写入攒在 `overlay` 里,还没落盘。
    struct IntervalRun {
        var rawFrameCount = 0
        var tier1SessionCount = 0
        var emptySessionCount = 0   // OCR 不足被丢的
        var llmFailed = false
        var newEventCount = 0
        var joinedSessionCount = 0
        var skippedSessionCount = 0
        /// 本区间新建与被 join 的事件文件(impact 的评分范围),去重保序。
        var touched: [URL] = []
        /// 这些事件归到的本地日。
        var days: Set<String> = []
        var overlay = EventOverlay()
    }

    struct Progress {
        let phase: String
        /// 进度条单元信号(nil = 该阶段无单元粒度,只有 phase 文案)。
        var unit: Unit? = nil

        enum Unit: Equatable {
            case llmBatch(index: Int, count: Int)      // 1-based,batch 开始前发
            case materialise(index: Int, count: Int)   // 1-based,每写完一个 cluster 发
        }
    }

    /// 聚类这一步(默认 = EventBuilder.clusterDay;自检换成确定性的假聚类)。
    typealias Clusterer = (_ date: Date, _ sessions: [EventBuilder.EnrichedSession],
                           _ active: [EventBuilder.ActiveEvent]) async throws -> EventBuilder.DayClustering

    static func runInterval(
        _ iv: EventInterval,
        activeWindowDays: Int = 14,
        clusterer: Clusterer? = nil,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> IntervalRun {
        let napGuard = AppNapGuard.acquire(reason: "Backfill / event clustering")
        defer { napGuard.release() }
        return try await runIntervalImpl(iv, activeWindowDays: activeWindowDays,
                                         clusterer: clusterer, progress: progress)
    }

    private static func runIntervalImpl(
        _ iv: EventInterval, activeWindowDays: Int, clusterer: Clusterer?,
        progress: ((Progress) -> Void)?
    ) async throws -> IntervalRun {
        try PortraitPaths.ensureSeedTree()

        let db = TimelineDB()
        guard db.exists else {
            throw NSError(
                domain: "Backfill", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timeline DB not found at \(db.dbPath)"]
            )
        }

        var r = IntervalRun()
        let off = iv.tzOffsetMin
        progress?(.init(phase: "reading frames"))
        let frames = db.frames(fromMs: iv.startMs, toMs: iv.endMs,
                               afterId: iv.afterFrameId, maxId: iv.maxFrameId)
        r.rawFrameCount = frames.count
        if frames.isEmpty {
            DiagLog.event("backfill.interval.skipped", ctx: ["interval": iv.id, "reason": "no frames"])
            return r
        }

        // Tier 1 merge.
        let rawEvents = frames.map { f in
            Tier1Merger.RawEvent(
                timestamp: f.timestamp,
                appName: f.appName,
                windowName: f.windowName,
                browserURL: f.browserUrl,
                frameId: f.id
            )
        }
        let sessions = Tier1Merger.merge(rawEvents)
        r.tier1SessionCount = sessions.count
        if sessions.isEmpty { return r }

        var tsById: [Int64: Int64] = [:]
        for f in frames { tsById[f.id] = ms(f.timestamp) }
        func span(_ s: Tier1Merger.MergedEvent) -> (start: Int64, end: Int64) {
            (ms(s.firstSeen), ms(s.lastSeen))
        }
        // 提示词里的日期、活跃窗口的参照日 = 整个区间帧的 attribute_day。
        guard let ivDay = IntervalSegmenter.attributeDay(frameTs: frames.map { ms($0.timestamp) },
                                                         spans: sessions.map(span), tzOffsetMin: off),
              let day = ProcessingLogStore.day(from: ivDay) else { return r }

        // Enrich + drop OCR-poor sessions (no OCR → nothing to summarise).
        // maxOcrChars 2000→600:每个 session 的 OCR 前 ~600 字才有聚类信号(app
        // 名 / 任务上下文),尾巴是重复噪音。session 主导 prompt,砍它直接把
        // reasoning 模型在大 prompt 上的思考时间 + 额度都压下来(event 步太慢的
        // 主因)。质量影响要跑几天对比 event 数 / dropped 率(下面那行日志)确认。
        let minOcrChars = 60
        let maxOcrChars = 600
        var enriched: [EventBuilder.EnrichedSession] = []
        for s in sessions {
            let ocr = db.ocrText(forFrameIds: s.sourceFrameIds, maxChars: maxOcrChars)
            if ocr.count < minOcrChars {
                r.emptySessionCount += 1
                continue
            }
            enriched.append(EventBuilder.EnrichedSession(
                session: s, ocrSnippet: ocr, transcriptSnippet: ""
            ))
        }
        let dropped = sessions.count - enriched.count
        print("Interval \(iv.id) (\(ivDay)): \(frames.count) frames, \(sessions.count) sessions, \(enriched.count) enriched (OCR ≥ 60), \(dropped) dropped")
        DiagLog.event("backfill.interval.sessions", ctx: [
            "interval": iv.id, "day": ivDay, "frames": frames.count,
            "sessions": sessions.count, "enriched": enriched.count, "dropped": dropped,
        ])
        if enriched.isEmpty { return r }

        // Active-events catalogue from the in-memory cache.
        var fileCache = await loadAllFiles()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let activeCutoff = cal.date(byAdding: .day, value: -activeWindowDays, to: day) ?? day
        let active: [EventBuilder.ActiveEvent] = fileCache.values.compactMap { entry in
            guard !entry.file.eventTitle.isEmpty,
                  let last = entry.file.occurrences.max(),
                  last >= activeCutoff else { return nil }
            return EventBuilder.ActiveEvent(
                id: entry.relativePath,
                title: entry.file.eventTitle,
                summary: entry.file.eventSummary,
                type: entry.file.eventType.isEmpty ? "experience" : entry.file.eventType,
                tags: entry.file.tags,
                lastOccurredOn: last
            )
        }

        // LLM per-event clustering.
        progress?(.init(phase: "LLM clustering \(enriched.count) sessions"))
        let clustering: EventBuilder.DayClustering
        do {
            if let clusterer {
                clustering = try await clusterer(day, enriched, active)
            } else {
                // 从 Events Processor pipeline 的 config 读 provider/model,Settings 改完
                // 下一次就用上。
                let evCfg = ConfigStore.shared.current.scheduler.event
                clustering = try await EventBuilder(provider: evCfg.resolvedProvider, model: evCfg.resolvedModel)
                    .clusterDay(date: day, tzOffsetMin: off, sessions: enriched, activeEvents: active, onBatch: { i, n in
                        progress?(.init(phase: "LLM clustering batch \(i)/\(n)",
                                        unit: .llmBatch(index: i, count: n)))
                    })
            }
        } catch let e as BudgetExhaustedError {
            // 撞额度不是"失败"——上抛让调度器标 budget_deferred 而非 failed，
            // 不计入 retry_count。
            throw e
        } catch {
            r.llmFailed = true
            print("Interval \(iv.id): LLM clustering FAILED — \(error.localizedDescription) — nothing written")
            // 真实原因只 print 到 stdout 的话,scheduler 只会记一条笼统的
            // "event step reported failure",事后完全无从排查。
            DiagLog.warn("backfill.interval.llm_failed", ctx: [
                "interval": iv.id, "error": error.localizedDescription,
            ])
            progress?(.init(phase: "LLM failed: \(error.localizedDescription)"))
            return r
        }

        // Materialise into the overlay. `sessionIndices` are 1-based into `enriched`.
        let clusterCount = clustering.events.count
        for (ci, ev) in clustering.events.enumerated() {
            progress?(.init(phase: "writing event \(ci + 1)/\(clusterCount)",
                            unit: .materialise(index: ci + 1, count: clusterCount)))
            let members = ev.sessionIndices.compactMap { idx -> EventBuilder.EnrichedSession? in
                let i = idx - 1
                guard i >= 0, i < enriched.count else { return nil }
                return enriched[i]
            }
            if members.isEmpty { continue }
            let frameIds = members.flatMap { $0.session.sourceFrameIds }
            // 事件日期 = 成员帧的 attribute_day(区间钉死的偏移)。
            guard let ds = IntervalSegmenter.attributeDay(
                    frameTs: frameIds.compactMap { tsById[$0] },
                    spans: members.map { span($0.session) }, tzOffsetMin: off),
                  let eday = ProcessingLogStore.day(from: ds) else { continue }

            let url: URL
            if let je = ev.joinExisting, let entry = fileCache[je] {
                // Re-run safety: frames already accounted for.
                if !frameIds.isEmpty,
                   entry.file.memberFrameIds.contains(where: frameIds.contains) {
                    r.skippedSessionCount += 1
                    continue
                }
                // Join: +1 occurrence(这几个 session 的本地日), append frames.
                // Title / summary / facets stay frozen at first creation.
                var updated = entry.file
                updated.recordOccurrence(on: eday)
                updated.memberFrameIds.append(contentsOf: frameIds)
                // 事件又活了 → 清空 distilledInto,让下次 distill 重新看到
                // 它(增量 distill 的"改过"通道)。
                updated.distilledInto = []
                r.overlay.put(updated, at: entry.url)
                fileCache[je] = .init(url: entry.url,
                                      relativePath: entry.relativePath,
                                      file: updated)
                r.joinedSessionCount += 1
                url = entry.url
            } else {
                url = createNewEvent(cluster: ev, frameIds: frameIds, day: eday,
                                     overlay: &r.overlay, cache: &fileCache)
                r.newEventCount += 1
            }
            if !r.touched.contains(url) { r.touched.append(url) }
            r.days.insert(ds)
        }
        r.skippedSessionCount += clustering.skippedIndices.count

        // 归档不在这里跑 —— 它动的是 portrait/ 文件，挪到了
        // PortraitDistiller.distill 之后。
        return r
    }

    /// 成员帧与 `frameIds` 相交的事件文件(按路径排序)。event 步早已成功、只剩 impact
    /// 要重试时,用它找回本区间新建与被 join 的事件。
    static func eventFiles(withAnyFrameIn frameIds: Set<Int64>) async -> [URL] {
        guard !frameIds.isEmpty else { return [] }
        return await loadAllFiles().values
            .filter { $0.file.memberFrameIds.contains(where: frameIds.contains) }
            .map(\.url)
            .sorted { $0.path < $1.path }
    }

    nonisolated private static func ms(_ d: Date) -> Int64 {
        Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - File materialisation

    private struct Entry {
        let url: URL
        let relativePath: String
        var file: PortraitFile
    }

    /// Build a new PortraitFile from a clustered event into the overlay; returns its URL.
    private static func createNewEvent(
        cluster: EventBuilder.ClusteredEvent,
        frameIds: [Int64],
        day: Date,
        overlay: inout EventOverlay,
        cache: inout [String: Entry]
    ) -> URL {
        let filename = makeFilename(title: cluster.title, day: day)
        // Events live under events/<yyyy-MM-dd>/. Routing into portrait
        // subdirs is the Distiller's job, based on type + portraitFacets.
        let url = PortraitPaths.eventsDayDir(for: day).appendingPathComponent(filename)
        let finalURL = uniqueURL(url, overlay: overlay)

        // `created` = the event's local day(按 UTC 零点存,文件里写 yyyy-MM-dd),
        // aligned with `occurrences`.
        //
        // No placeholder impact — a new event is `unscored` until the LLM
        // (ImpactScorer) gives it a real score. impact starts at the 0.0
        // floor so an unscored event never outranks a scored one (scored
        // pointless 也能压到 0.0-0.9,占位必须贴地板)。
        var file = PortraitFile(
            created: PortraitFile.truncateToDay(day),
            impact: 0.0,
            body: renderBody(title: cluster.title, summary: cluster.summary),
            source: "timeline:event",
            tags: cluster.tags,
            firstOccurrence: day,
            eventTitle: cluster.title,
            eventSummary: cluster.summary,
            eventType: cluster.type,
            portraitFacets: cluster.portraitFacets,
            memberFrameIds: frameIds
        )
        file.occurrences = [PortraitFile.truncateToDay(day)]
        file.impactSource = "unscored"

        overlay.put(file, at: finalURL, isNew: true)
        let rel = finalURL.path
            .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
        cache[rel] = Entry(url: finalURL, relativePath: rel, file: file)
        return finalURL
    }

    // MARK: - Title/file helpers

    private static func makeFilename(title: String, day: Date) -> String {
        let stamp = isoDay(day)
        let slug = slugify(title)
        return "\(stamp)_\(slug).md"
    }

    /// `isoDay` 一天每次 backfill 都会调,DateFormatter 构造昂贵,缓存住。
    /// 跟 EventBuilder.dayFmt 同样的 Sendable 静态实例模式。
    private static let isoDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func isoDay(_ day: Date) -> String {
        isoDayFmt.string(from: day)
    }

    private static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var lastWasSep = false
        for scalar in lower.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasSep = false
            } else if !lastWasSep {
                out.append("_")
                lastWasSep = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if trimmed.count > 60 { return String(trimmed.prefix(60)) }
        return trimmed.isEmpty ? "event" : trimmed
    }

    /// 盘上已有或本区间 overlay 里已占用的路径都算重名。
    private static func uniqueURL(_ url: URL, overlay: EventOverlay) -> URL {
        func taken(_ u: URL) -> Bool {
            overlay.contains(u) || FileManager.default.fileExists(atPath: u.path)
        }
        if !taken(url) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...100 {
            let candidate = dir.appendingPathComponent("\(base)_\(n).\(ext)")
            if !taken(candidate) { return candidate }
        }
        return url    // give up; will overwrite
    }

    private static func renderBody(title: String, summary: String) -> String {
        "# \(title)\n\n\(summary)\n"
    }

    // MARK: - Tree I/O

    nonisolated private static func loadAllFiles() async -> [String: Entry] {
        await Task.detached(priority: .userInitiated) {
            scanAllFilesSync()
        }.value
    }

    nonisolated private static func scanAllFilesSync() -> [String: Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.eventsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var out: [String: Entry] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            let rel = url.path
                .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
            out[rel] = Entry(url: url, relativePath: rel, file: f)
        }
        return out
    }

    /// MemoryScheduler.runEventJob 在所有区间跑完后调一次(跟 rebalance 同模式)。
    nonisolated static func weightPass() async {
        await Task.detached(priority: .userInitiated) {
            weightPassSync()
        }.value
    }

    /// Sync helper — NSEnumerator iteration isn't usable from `async` bodies
    /// under Swift 6 strict concurrency, so isolate it here.
    nonisolated private static func weightPassSync() {
        // 只对 events/ 跑 WeightCalculator —— portrait 不再走 event 的
        // impact×decay 公式。portrait 的 weight 由 P5 EMA 写入路径管理；
        // P5 接入前 portrait weight 保持 P3 迁移后的 1.0 不被覆盖。
        weightPassDir(Storage.eventsDir)
    }

    nonisolated private static func weightPassDir(_ root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                let oldWeight = f.weight
                WeightCalculator.recompute(&f)
                // 浮点容差 1e-6,对齐 PortraitWeight.refresh —— 值没变就不
                // 写盘,避免全树文件被无条件改写(I/O + mtime 跳动)。
                if abs(f.weight - oldWeight) < 1e-6 { continue }
                try PortraitFileIO.write(f, to: url)
            } catch {
                continue
            }
        }
    }
}

/// 一个区间 event 步的写入:先攒在内存里,成功才落盘。落盘前先写撤销清单(新建了
/// 哪些文件、被 join 的文件原文),落盘中途出错当场撤销;进程在落盘后、台账记
/// complete 前死掉,恢复时按清单撤销。只动本区间碰过的文件。
struct EventOverlay {
    private(set) var order: [URL] = []
    private var files: [URL: PortraitFile] = [:]
    private var created: Set<URL> = []

    var isEmpty: Bool { order.isEmpty }
    func contains(_ url: URL) -> Bool { files[url] != nil }

    mutating func put(_ file: PortraitFile, at url: URL, isNew: Bool = false) {
        if files[url] == nil { order.append(url) }
        files[url] = file
        if isNew { created.insert(url) }
    }

    /// 撤销清单(绝对路径)。
    private struct Journal: Codable {
        var created: [String]
        var originals: [String: Data]
    }

    static func journalURL(intervalId: String) -> URL {
        Storage.rootURL.appendingPathComponent(".staging/event_intervals", isDirectory: true)
            .appendingPathComponent(intervalId.replacingOccurrences(of: ":", with: "_") + ".json")
    }

    /// 写撤销清单 → 逐个落盘;中途出错按清单撤销后抛出。
    func commit(intervalId: String) throws {
        guard !order.isEmpty else { return }
        var j = Journal(created: [], originals: [:])
        for url in order {
            if created.contains(url) { j.created.append(url.path) }
            else { j.originals[url.path] = try Data(contentsOf: url) }
        }
        let ju = Self.journalURL(intervalId: intervalId)
        try FileManager.default.createDirectory(at: ju.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(j).write(to: ju, options: .atomic)
        do {
            for url in order {
                guard let f = files[url] else { continue }
                try PortraitFileIO.write(f, to: url)
            }
        } catch {
            Self.undo(intervalId: intervalId)
            throw error
        }
    }

    /// 按撤销清单还原本区间的写入(新建的删、被 join 的恢复原文),再删清单。
    /// 没有清单 → 什么都不动。
    static func undo(intervalId: String) {
        let ju = journalURL(intervalId: intervalId)
        guard let data = try? Data(contentsOf: ju),
              let j = try? JSONDecoder().decode(Journal.self, from: data) else { return }
        let fm = FileManager.default
        for p in j.created {
            try? fm.removeItem(at: URL(fileURLWithPath: p))
        }
        for (p, original) in j.originals {
            try? original.write(to: URL(fileURLWithPath: p), options: .atomic)
        }
        try? fm.removeItem(at: ju)
        print("[Backfill] undo \(intervalId): removed \(j.created.count) new event(s), restored \(j.originals.count) joined event(s)")
    }

    /// 本区间 event 步已记为 complete:清单作废。
    static func clearJournal(intervalId: String) {
        try? FileManager.default.removeItem(at: journalURL(intervalId: intervalId))
    }
}
