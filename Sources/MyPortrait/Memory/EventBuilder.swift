import Foundation

/// LLM-driven event clustering — the semantic layer between raw Tier 1
/// sessions and the persistent event-level PortraitFiles.
///
/// Per-event protocol (2026-05-19 rewrite):
///   - The LLM no longer emits a per-session decision. It emits a per-EVENT
///     clustering: a list of events, each owning a non-empty `session_ids`
///     list, plus a top-level `skipped` list.
///   - Every input session id MUST appear exactly once — in some event's
///     `session_ids` or in `skipped`. The parser enforces this; incomplete
///     coverage throws and the whole day is rejected (no half-written data).
///   - There is no "decision without content" shape, so empty-shell events
///     (the old "App — Window" bug) are structurally impossible.
///
/// An "event" is what the USER subjectively did, not which app was open.
/// Events span apps within a day. Multiple sessions of the same activity
/// (e.g. opening WeChat 18× to chat) are ONE event.
@MainActor
final class EventBuilder {
    /// A facet of the user's portrait that an event reflects.
    struct PortraitFacet: Equatable, Hashable {
        let facet: String
        let value: String
    }

    /// A Tier 1 session enriched with OCR/transcript context, ready for LLM.
    struct EnrichedSession {
        let session: Tier1Merger.MergedEvent
        let ocrSnippet: String
        let transcriptSnippet: String
    }

    /// Reference to an event the LLM may want to continue across days.
    /// Backfill builds this from existing PortraitFiles in `events/`.
    struct ActiveEvent {
        let id: String                  // stable id (relative path under events/)
        let title: String
        let summary: String
        let type: String
        let tags: [String]
        let lastOccurredOn: Date
    }

    /// One semantic event clustered from 1+ sessions.
    struct ClusteredEvent {
        let title: String
        let summary: String
        let type: String                // "experience" / "emotion"
        let portraitFacets: [PortraitFacet]
        let tags: [String]
        let sessionIndices: [Int]        // 1-based indices into the day's session list
        let joinExisting: String?        // id of an ActiveEvent, or nil
    }

    /// Result of clustering one day.
    struct DayClustering {
        let events: [ClusteredEvent]
        let skippedIndices: [Int]
    }

    enum BuilderError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):     return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:          return "LLM did not respond within timeout"
            case .noJSONInResponse:      return "LLM response contained no JSON"
            case .malformedJSON(let m):  return "LLM JSON parse failed: \(m)"
            }
        }
    }

    private let model: String
    private let perBatchTimeout: TimeInterval
    /// Sessions ≤ this run in a single LLM call. Above it, batched.
    /// Kept small (40) so the LLM rarely drops a session from a big day.
    private let batchSize: Int
    /// Retries per batch on a malformed-JSON / timeout response.
    private let maxAttempts: Int

    private let provider: Provider

    init(provider: Provider = .chatgpt,
         model: String = "gpt-5.4",
         perBatchTimeout: TimeInterval = 180,
         batchSize: Int = 40,
         maxAttempts: Int = 3) {
        self.provider = provider
        self.model = model
        self.perBatchTimeout = perBatchTimeout
        self.batchSize = batchSize
        self.maxAttempts = maxAttempts
    }

    /// Cluster one day's sessions into semantic events.
    /// `onBatch(index, count)`(1-based)在每个 LLM batch 开始前回调 ——
    /// 给上游进度条按 batch 推进用。单批日也回调一次 (1, 1)。
    /// `tzOffsetMin` = 区间钉死的 UTC 偏移;提示词里的 session 时刻按它显示成本地时刻。
    /// `earlierToday` = 同日事件(进 EARLIER TODAY,全部不截断);`activeEvents` = 往日事件
    /// (进 PAST DAYS)。两者由 `splitCatalog` 在区间开始时划分。
    func clusterDay(
        date: Date,
        tzOffsetMin: Int,
        sessions: [EnrichedSession],
        earlierToday: [ActiveEvent],
        activeEvents: [ActiveEvent],
        onBatch: ((Int, Int) -> Void)? = nil
    ) async throws -> DayClustering {
        guard !sessions.isEmpty else {
            return DayClustering(events: [], skippedIndices: [])
        }
        if sessions.count <= batchSize {
            onBatch?(1, 1)
            return try await clusterOneBatch(
                date: date,
                tzOffsetMin: tzOffsetMin,
                sessions: sessions,
                globalOffset: 0,
                earlierToday: earlierToday,
                activeEvents: activeEvents
            )
        }
        return try await clusterBatched(
            date: date, tzOffsetMin: tzOffsetMin, sessions: sessions,
            earlierToday: earlierToday, activeEvents: activeEvents,
            onBatch: onBatch
        )
    }

    // MARK: - Single batch

    /// Cluster one batch. `globalOffset` shifts the 1-based session ids the
    /// LLM sees so they stay unique across batches.
    /// `earlierToday` 是同日事件 + 本区间前面批次新建的 temp events(强 join
    /// 候选),`activeEvents` 是往日事件(弱 join 候选)。两者在 prompt 里分两段
    /// 呈现,LLM 优先 join earlierToday。
    private func clusterOneBatch(
        date: Date,
        tzOffsetMin: Int,
        sessions: [EnrichedSession],
        globalOffset: Int,
        earlierToday: [ActiveEvent],
        activeEvents: [ActiveEvent]
    ) async throws -> DayClustering {
        let lo = globalOffset + 1
        let hi = globalOffset + sessions.count
        let validActiveIds = Set((earlierToday + activeEvents).map { $0.id })
        // 在 MainActor 拿 personal info snapshot,传给 nonisolated buildPrompt。
        let personal = ConfigStore.shared.current.personalInfo
        let prompt = Self.buildPrompt(
            date: date,
            tzOffsetMin: tzOffsetMin,
            sessions: sessions,
            globalOffset: globalOffset,
            earlierToday: earlierToday,
            activeEvents: activeEvents,
            personal: personal
        )

        // The LLM occasionally returns malformed JSON or times out. A failed
        // batch loses the whole day, so retry a few times before giving up.
        var lastError: Error = BuilderError.noJSONInResponse
        for attempt in 1...maxAttempts {
            do {
                let raw = try await runLLM(prompt: prompt)
                var parsed = try Self.parseClustering(from: raw)
                parsed = Self.defendJoins(parsed, validActiveIds: validActiveIds)
                // Sessions the LLM forgot are moved to `skipped` rather than
                // failing the whole day. A skipped session produces no file,
                // so it cannot create a shell event — the original reason
                // for the strict check disappeared with the join fallback.
                parsed = Self.coverGaps(parsed, lo: lo, hi: hi)
                return parsed
            } catch let e as BudgetExhaustedError {
                // 撞额度重试无意义（额度不会几秒内恢复）—— 立即上抛。
                throw e
            } catch {
                lastError = error
                print("EventBuilder: batch attempt \(attempt)/\(maxAttempts) failed — \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// One LLM round-trip: spawn agent, send prompt, collect the response.
    private func runLLM(prompt: String) async throws -> String {
        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw BuilderError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = ResponseCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)
        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw BuilderError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perBatchTimeout * 1_000_000_000))
                    throw BuilderError.agentTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw BuilderError.agentTimeout
        }

        // 撞额度优先于解析失败：抛 BudgetExhaustedError 让上层走 budget_deferred。
        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "EventBuilder", message: err)
        }
        return collected
    }

    // MARK: - Batched (fallback for > batchSize sessions)

    /// Cluster a large day in chunks. Each chunk gets the same-day events plus
    /// prior chunks' new events (temp ids prefixed `_b`) as EARLIER TODAY join
    /// candidates. Cross-batch joins to a temp id are merged in memory; joins to
    /// a real id (same-day or past event) are left for Backfill. Session ids
    /// stay globally unique via offsets.
    private func clusterBatched(
        date: Date,
        tzOffsetMin: Int,
        sessions: [EnrichedSession],
        earlierToday: [ActiveEvent],
        activeEvents: [ActiveEvent],
        onBatch: ((Int, Int) -> Void)? = nil
    ) async throws -> DayClustering {
        let chunks = stride(from: 0, to: sessions.count, by: batchSize).map {
            Array(sessions[$0..<min($0 + batchSize, sessions.count)])
        }

        // Temp-id → cluster, preserving insertion order.
        var tempOrder: [String] = []
        var tempClusters: [String: ClusteredEvent] = [:]
        var historicalJoinEvents: [ClusteredEvent] = []
        var allSkipped: [Int] = []
        var tempSeq = 0

        for (ci, chunk) in chunks.enumerated() {
            onBatch?(ci + 1, chunks.count)
            let offset = ci * batchSize

            // EARLIER TODAY = 同日事件 + 前批新事件,全部不截断。
            let carry: [ActiveEvent] = earlierToday + tempOrder.map { tid in
                let c = tempClusters[tid]!
                return ActiveEvent(id: tid, title: c.title, summary: c.summary,
                                   type: c.type, tags: c.tags, lastOccurredOn: date)
            }
            // 往日事件按本批 app 打分排序,取前 20。
            let historicalRanked = Self.rankActive(activeEvents, for: chunk).prefix(20)

            let batch = try await clusterOneBatch(
                date: date, tzOffsetMin: tzOffsetMin, sessions: chunk, globalOffset: offset,
                earlierToday: carry,
                activeEvents: Array(historicalRanked)
            )
            allSkipped.append(contentsOf: batch.skippedIndices)

            for ev in batch.events {
                if let je = ev.joinExisting, je.hasPrefix("_b"),
                   var target = tempClusters[je] {
                    // Cross-batch join to an in-flight temp event → merge.
                    target = ClusteredEvent(
                        title: target.title, summary: target.summary,
                        type: target.type, portraitFacets: target.portraitFacets,
                        tags: target.tags,
                        sessionIndices: target.sessionIndices + ev.sessionIndices,
                        joinExisting: target.joinExisting
                    )
                    tempClusters[je] = target
                } else if let je = ev.joinExisting, !je.hasPrefix("_b") {
                    // Join to a real historical event — Backfill handles it.
                    historicalJoinEvents.append(ev)
                } else {
                    // New event — register a temp id for later chunks.
                    tempSeq += 1
                    let tid = "_b\(tempSeq)"
                    tempOrder.append(tid)
                    tempClusters[tid] = ev
                }
            }
        }

        let merged = tempOrder.compactMap { tempClusters[$0] } + historicalJoinEvents
        return DayClustering(events: merged, skippedIndices: allSkipped)
    }

    /// 事件目录顺序:最近出现倒序,再按路径(UTF-8 字节序)升序。全序,不依赖排序是否稳定。
    nonisolated static func catalogOrder(_ a: ActiveEvent, _ b: ActiveEvent) -> Bool {
        if a.lastOccurredOn != b.lastOccurredOn { return a.lastOccurredOn > b.lastOccurredOn }
        return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
    }

    /// 目录按 (最近出现倒序, 路径升序) 排;有出现日落在区间帧碰到的本地日里的是同日事件,其余是往日事件。
    nonisolated static func splitCatalog(_ catalog: [ActiveEvent], occurrences: [String: [Date]],
                                         firstMs: Int64, lastMs: Int64,
                                         tzOffsetMin: Int) -> (sameDay: [ActiveEvent], past: [ActiveEvent]) {
        let days = Set(IntervalSegmenter.touchedDays(startMs: firstMs, endMs: lastMs + 1, tzOffsetMin: tzOffsetMin))
        let cat = catalog.sorted(by: catalogOrder)
        let same = Set(cat.filter { a in (occurrences[a.id] ?? []).contains { days.contains(isoDay($0)) } }.map(\.id))
        return (cat.filter { same.contains($0.id) }, cat.filter { !same.contains($0.id) })
    }

    /// Rank active events by app overlap with the batch (most-overlapping
    /// first) so the top-20 cut keeps the most relevant join candidates.
    /// 同分按 `catalogOrder`。
    nonisolated static func rankActive(_ active: [ActiveEvent], for batch: [EnrichedSession]) -> [ActiveEvent] {
        let apps = Set(batch.map { $0.session.appName.lowercased() })
        func score(_ e: ActiveEvent) -> Int { Set(e.tags.map { $0.lowercased() }).intersection(apps).count }
        return active.sorted { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : catalogOrder(a, b)
        }
    }

    // MARK: - Join defence + coverage

    /// Drop joins that point at a non-existent active id. The offending
    /// event's sessions are moved to `skipped` rather than written as a shell.
    private static func defendJoins(
        _ clustering: DayClustering,
        validActiveIds: Set<String>
    ) -> DayClustering {
        var keptEvents: [ClusteredEvent] = []
        var skipped = clustering.skippedIndices
        for ev in clustering.events {
            if let je = ev.joinExisting, !validActiveIds.contains(je) {
                // Hallucinated / stale join target — demote to skipped.
                skipped.append(contentsOf: ev.sessionIndices)
            } else {
                keptEvents.append(ev)
            }
        }
        return DayClustering(events: keptEvents, skippedIndices: skipped)
    }

    /// Sessions the LLM left out of every event AND out of `skipped` are
    /// appended to `skipped`. Logged but non-fatal — a forgotten session
    /// produces no file, so it cannot create a shell event.
    private static func coverGaps(
        _ clustering: DayClustering, lo: Int, hi: Int
    ) -> DayClustering {
        var seen = Set<Int>()
        for ev in clustering.events { seen.formUnion(ev.sessionIndices) }
        seen.formUnion(clustering.skippedIndices)
        let missing = (lo...hi).filter { !seen.contains($0) }
        if missing.isEmpty { return clustering }
        print("EventBuilder: \(missing.count) session(s) uncovered by LLM → moved to skipped")
        return DayClustering(
            events: clustering.events,
            skippedIndices: clustering.skippedIndices + missing
        )
    }

    // MARK: - Prompt construction

    nonisolated private static func buildPrompt(
        date: Date,
        tzOffsetMin: Int,
        sessions: [EnrichedSession],
        globalOffset: Int,
        earlierToday: [ActiveEvent],
        activeEvents: [ActiveEvent],
        personal: PersonalInfoConfig
    ) -> String {
        let dayStr = isoDay(date)

        // 两段:earlier today (强 join 候选) 在前 + 跨日 active (弱候选) 在后。
        // LLM 看到 earlier today + 同主题 → 必须 join,不要起新 event。
        var blocks: [String] = []
        if !earlierToday.isEmpty {
            var rows: [String] = ["EARLIER TODAY (already created in this same day — PREFER joining over creating a new event when the subject overlaps):"]
            for e in earlierToday {
                let tagStr = e.tags.isEmpty ? "—" : e.tags.joined(separator: ",")
                rows.append("  [\(e.id)] \(e.title) | tags=[\(tagStr)]")
            }
            blocks.append(rows.joined(separator: "\n"))
        }
        if activeEvents.isEmpty {
            blocks.append("PAST DAYS (active events from earlier days — join if the new sessions continue the same thread across days): (none)")
        } else {
            var rows: [String] = ["PAST DAYS (active events from earlier days — join if the new sessions continue the same thread across days):"]
            for e in activeEvents {
                let last = relativeDay(from: e.lastOccurredOn, on: date)
                let tagStr = e.tags.isEmpty ? "—" : e.tags.joined(separator: ",")
                rows.append("  [\(e.id)] \(e.title) | tags=[\(tagStr)] | last=\(last)")
            }
            blocks.append(rows.joined(separator: "\n"))
        }
        let activeBlock = blocks.joined(separator: "\n\n")

        var sessionRows: [String] = ["SESSIONS TO CLUSTER (use the id shown):"]
        for (i, item) in sessions.enumerated() {
            let id = globalOffset + i + 1
            let s = item.session
            // 区间可能跨多天,起点统一带 MM-dd。
            let timeRange = "\(localTime(s.firstSeen, tzOffsetMin: tzOffsetMin, withDay: true))–"
                + localTime(s.lastSeen, tzOffsetMin: tzOffsetMin, withDay: false)
            let durMin = max(1, Int((s.lastSeen.timeIntervalSince(s.firstSeen) / 60).rounded()))
            var line = "\(id). [\(timeRange), \(durMin)min] \(s.appName)"
            if !s.windowName.isEmpty { line += " — \(s.windowName)" }
            if let u = s.browserURL, !u.isEmpty { line += " (url: \(u))" }
            sessionRows.append(line)
            if !item.ocrSnippet.isEmpty {
                let snippet = item.ocrSnippet.replacingOccurrences(of: "\n", with: " ⏎ ")
                sessionRows.append("    ocr: \(snippet)")
            }
            if !item.transcriptSnippet.isEmpty {
                sessionRows.append("    audio: \(item.transcriptSnippet)")
            }
        }
        let sessionBlock = sessionRows.joined(separator: "\n")

        let about = MemoryPrompts.aboutUserBlock(personal)
        let prefix = about.isEmpty ? "" : about + "\n\n"
        return prefix
            + MemoryPrompts.eventClustering
            + "\n\nDate being processed: " + dayStr
            + "\n\n" + activeBlock
            + "\n\n" + sessionBlock
    }

    // MARK: - Response parsing

    nonisolated private static func parseClustering(
        from response: String
    ) throws -> DayClustering {
        guard let firstBrace = response.firstIndex(of: "{"),
              let lastBrace = response.lastIndex(of: "}") else {
            throw BuilderError.noJSONInResponse
        }
        let jsonStr = String(response[firstBrace...lastBrace])
        guard let data = jsonStr.data(using: .utf8) else {
            throw BuilderError.malformedJSON("could not encode response as UTF-8")
        }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) }
        catch { throw BuilderError.malformedJSON(error.localizedDescription) }
        guard let root = obj as? [String: Any] else {
            throw BuilderError.malformedJSON("top-level was not a JSON object")
        }

        let rawEvents = (root["events"] as? [[String: Any]]) ?? []
        var events: [ClusteredEvent] = []
        events.reserveCapacity(rawEvents.count)
        for (idx, e) in rawEvents.enumerated() {
            let title = (e["title"] as? String) ?? ""
            let summary = (e["summary"] as? String) ?? ""
            let rawType = ((e["type"] as? String) ?? "experience").lowercased()
            let type = (rawType == "emotion") ? "emotion" : "experience"
            let tags = (e["tags"] as? [String]) ?? []
            let facets: [PortraitFacet] = ((e["portrait_facets"] as? [[String: Any]]) ?? []).compactMap { f in
                guard let facet = f["facet"] as? String, !facet.isEmpty,
                      let value = f["value"] as? String, !value.isEmpty else { return nil }
                return PortraitFacet(facet: facet.lowercased(), value: value)
            }
            let sessionIDs = (e["session_ids"] as? [Int]) ?? []
            if sessionIDs.isEmpty {
                throw BuilderError.malformedJSON("event \(idx + 1) has empty session_ids")
            }
            if title.isEmpty || summary.isEmpty {
                throw BuilderError.malformedJSON("event \(idx + 1) missing title or summary")
            }
            let join = (e["join_existing"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            events.append(ClusteredEvent(
                title: title, summary: summary, type: type,
                portraitFacets: facets, tags: tags,
                sessionIndices: sessionIDs, joinExisting: join
            ))
        }
        let skipped = (root["skipped"] as? [Int]) ?? []
        return DayClustering(events: events, skippedIndices: skipped)
    }

    // MARK: - Formatters

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    nonisolated(unsafe) private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()
    nonisolated(unsafe) private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
    nonisolated private static func isoDay(_ d: Date) -> String { dayFmt.string(from: d) }
    /// 本地时刻:按 tz_offset_min 平移后用 UTC formatter 读。
    nonisolated private static func localTime(_ d: Date, tzOffsetMin: Int, withDay: Bool) -> String {
        (withDay ? stampFmt : timeFmt).string(from: d.addingTimeInterval(TimeInterval(tzOffsetMin * 60)))
    }

    nonisolated private static func relativeDay(from past: Date, on reference: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let pastDay = cal.startOfDay(for: past)
        let refDay = cal.startOfDay(for: reference)
        let days = cal.dateComponents([.day], from: pastDay, to: refDay).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}

// MARK: - Coordinator

/// LLM agent 事件流协调器:开 turn、收 chunk 拼最终回答、捕获 error 行。
/// 原本是 `private actor`,改成模块内可见以供 EventClassifier 复用(同一套
/// agent 协议、避免复制粘贴 60 行)。
actor ResponseCoordinator {
    private var buffer: String = ""
    private var currentID: String?
    private var pending: CheckedContinuation<String, Never>?
    private var lastError: String?

    func startTurn(id: String) {
        buffer = ""
        currentID = id
        pending = nil
        lastError = nil
    }

    func awaitTurn() async -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                pending = cont
            }
        } onCancel: {
            Task { await self.cancelTurn() }
        }
    }

    /// 被取消(如 per-batch 超时子任务触发)→ 用已收到的部分 buffer resume 等待者,
    /// 让 task group 能 drain、调用方抛错/返回,defer 里的 agent.stop() 才真去杀
    /// 卡住的子进程。否则 awaitTurn 的 continuation 永不 resume → 整轮永久 hang。
    func cancelTurn() {
        if let p = pending {
            pending = nil
            p.resume(returning: buffer)
        }
    }

    /// 本轮 LLM `.error` 事件携带的错误文本（无错误返回 nil）。
    func consumeError() -> String? { lastError }

    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d):
            buffer.append(d)
        case .assistantFinalText(let t):
            if buffer.isEmpty { buffer = t }
        case .agentEnd:
            if let p = pending {
                pending = nil
                p.resume(returning: buffer)
            }
        case .error(let msg):
            lastError = msg
            if let p = pending {
                pending = nil
                p.resume(returning: buffer)
            }
        default:
            break
        }
    }
}
