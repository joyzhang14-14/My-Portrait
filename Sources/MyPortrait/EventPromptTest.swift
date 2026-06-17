import Foundation

/// `--event-prompt-test <yyyy-MM-dd>` — DEV-ONLY diagnostic entry point.
///
/// Validates the proposed "方案 D" per-event clustering prompt WITHOUT
/// touching EventBuilder / Backfill. Reads one day's frames, runs Tier 1
/// merge, enriches with OCR, sends batched per-event prompts to the LLM,
/// validates the schema, and dumps everything to stdout. Writes nothing.
///
/// Disposable: delete this file + the App.swift flag once the prompt is
/// validated and the real EventBuilder rewrite lands.
enum EventPromptTestCLI {

    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(day dayStr: String) {
        let state = State()
        Task.detached {
            do {
                try await runAsync(day: dayStr)
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }

    // MARK: - Test session model

    /// One Tier-1 session, globally numbered 1..N across the whole day.
    struct TestSession {
        let globalId: Int
        let merged: Tier1Merger.MergedEvent
        let ocr: String
    }

    /// Cross-batch carry — events produced by earlier batches become
    /// join_existing candidates for later batches.
    struct CarryEvent {
        let id: String              // evt_01 ...
        let title: String
        let tags: [String]
        let apps: Set<String>       // apps of the sessions it covers
    }

    private static let batchSize = 40
    private static let ocrBudget = 800

    // MARK: - Main

    static func runAsync(day dayStr: String) async throws {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let day = fmt.date(from: dayStr) else {
            throw NSError(domain: "EventPromptTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad date: \(dayStr)"])
        }

        print("=== event-prompt-test \(dayStr) ===\n")

        // 1. Frames.
        let db = TimelineDB()
        guard db.exists else {
            throw NSError(domain: "EventPromptTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "timeline DB not found at \(db.dbPath)"])
        }
        let frames = db.frames(on: day, limit: 5000)
        print("frames on \(dayStr): \(frames.count)")

        // 2. Tier 1 merge.
        let rawEvents = frames.map { f in
            Tier1Merger.RawEvent(
                timestamp: f.timestamp,
                appName: f.appName,
                windowName: f.windowName,
                browserURL: f.browserUrl,
                frameId: f.id
            )
        }
        let merged = Tier1Merger.merge(rawEvents)
        print("Tier 1 sessions: \(merged.count)")

        // 3. Enrich with OCR; drop sessions with < 60 chars of OCR (same
        //    filter Backfill uses).
        var sessions: [TestSession] = []
        var gid = 0
        var droppedNoOCR = 0
        for m in merged {
            let ocr = db.ocrText(forFrameIds: m.sourceFrameIds, maxChars: ocrBudget)
            if ocr.count < 60 {
                droppedNoOCR += 1
                continue
            }
            gid += 1
            sessions.append(TestSession(globalId: gid, merged: m, ocr: ocr))
        }
        print("enriched sessions (OCR ≥ 60 chars): \(sessions.count)  (dropped no-OCR: \(droppedNoOCR))")

        if sessions.isEmpty {
            print("\nnothing to cluster — no OCR-bearing sessions.")
            return
        }

        // 4. Batch.
        let batches = stride(from: 0, to: sessions.count, by: batchSize).map {
            Array(sessions[$0..<min($0 + batchSize, sessions.count)])
        }
        print("batches: \(batches.count)  (≤ \(batchSize) sessions each)\n")

        // 5. Process each batch.
        var carry: [CarryEvent] = []
        var carrySeq = 0
        var totalEvents = 0
        var allCovered = Set<Int>()
        var allSkipped = Set<Int>()
        var wechatEventCount = 0

        for (bi, batch) in batches.enumerated() {
            print(String(repeating: "─", count: 70))
            print("BATCH \(bi + 1)/\(batches.count) — \(batch.count) sessions (ids \(batch.first!.globalId)..\(batch.last!.globalId))")
            print(String(repeating: "─", count: 70))

            // Active candidates: rank carry by app + tag overlap with this
            // batch, keep top 20.
            let batchApps = Set(batch.map { $0.merged.appName })
            let active = rankCarry(carry, batchApps: batchApps).prefix(20)

            let prompt = buildPrompt(batch: batch, active: Array(active))
            let inTokens = estTokens(prompt)
            print("input tokens (est): \(inTokens)")

            let (raw, usageIn, usageOut) = try await callLLM(prompt: prompt)
            let outTokens = estTokens(raw)
            print("output tokens (est): \(outTokens)   reported usage: in=\(usageIn) out=\(usageOut)")
            print("\n--- RAW LLM OUTPUT (batch \(bi + 1)) ---")
            print(raw)
            print("--- END RAW (batch \(bi + 1)) ---\n")

            // Parse + schema validate.
            let parsed = try parseOutput(raw)
            print("parsed events: \(parsed.events.count)  skipped: \(parsed.skipped.count)")

            // Coverage check against this batch's global ids.
            let batchIds = Set(batch.map { $0.globalId })
            var coveredThisBatch = Set<Int>()
            for ev in parsed.events { coveredThisBatch.formUnion(ev.sessionIds) }
            coveredThisBatch.formUnion(parsed.skipped)
            let missing = batchIds.subtracting(coveredThisBatch)
            let foreign = coveredThisBatch.subtracting(batchIds)
            if !missing.isEmpty {
                print("⚠️  SCHEMA FAIL: sessions not covered nor skipped: \(missing.sorted())")
            }
            if !foreign.isEmpty {
                print("⚠️  SCHEMA WARN: output referenced ids outside this batch: \(foreign.sorted())")
            }
            if missing.isEmpty && foreign.isEmpty {
                print("✅ coverage OK — every session covered or skipped")
            }

            allCovered.formUnion(coveredThisBatch.intersection(batchIds))
            allSkipped.formUnion(parsed.skipped)
            totalEvents += parsed.events.count

            // Print event list for this batch.
            for ev in parsed.events {
                wechatEventCount += isWeChatEvent(ev, batch: batch) ? 1 : 0
                let join = ev.joinExisting.map { " [join→\($0)]" } ?? ""
                print("  • \(ev.title)\(join)  sessions=\(ev.sessionIds.sorted())")
            }

            // Accumulate carry from NEW events (not joins).
            for ev in parsed.events where ev.joinExisting == nil {
                carrySeq += 1
                let apps = Set(ev.sessionIds.compactMap { sid in
                    batch.first { $0.globalId == sid }?.merged.appName
                })
                carry.append(CarryEvent(
                    id: String(format: "evt_%02d", carrySeq),
                    title: ev.title,
                    tags: ev.tags,
                    apps: apps
                ))
            }
            print("")
        }

        // 6. Summary.
        print(String(repeating: "═", count: 70))
        print("SUMMARY")
        print(String(repeating: "═", count: 70))
        print("input sessions (enriched):    \(sessions.count)")
        print("batches:                      \(batches.count)")
        print("events generated (total):     \(totalEvents)")
        print("sessions covered:             \(allCovered.count)")
        print("sessions skipped:             \(allSkipped.count)")
        let uncovered = Set(sessions.map { $0.globalId })
            .subtracting(allCovered).subtracting(allSkipped)
        if uncovered.isEmpty {
            print("schema check:                 ✅ all sessions accounted for")
        } else {
            print("schema check:                 ⚠️ UNACCOUNTED: \(uncovered.sorted())")
        }

        // WeChat consolidation: count enriched 微信 sessions vs events touching them.
        let wechatSessions = sessions.filter { $0.merged.appName.contains("微信") }
        print("微信 sessions (input):         \(wechatSessions.count)")
        print("events containing 微信 session: \(wechatEventCount)")
    }

    // MARK: - Carry ranking

    private static func rankCarry(_ carry: [CarryEvent],
                                  batchApps: Set<String>) -> [CarryEvent] {
        carry.sorted { a, b in
            let sa = a.apps.intersection(batchApps).count
            let sb = b.apps.intersection(batchApps).count
            return sa > sb
        }
    }

    // MARK: - Prompt

    private static func buildPrompt(batch: [TestSession],
                                    active: [CarryEvent]) -> String {
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone = TimeZone(identifier: "UTC")

        // Active block.
        let activeBlock: String
        if active.isEmpty {
            activeBlock = "ACTIVE EVENTS (join candidates from earlier batches): (none)"
        } else {
            var rows = ["ACTIVE EVENTS (join candidates from earlier batches):"]
            for e in active {
                let tagStr = e.tags.isEmpty ? "—" : e.tags.joined(separator: ",")
                rows.append("  [\(e.id)] \(e.title) | tags=[\(tagStr)]")
            }
            activeBlock = rows.joined(separator: "\n")
        }

        // Session block.
        var rows = ["SESSIONS TO CLUSTER (id 1..N — use the global id shown):"]
        for s in batch {
            let m = s.merged
            let tr = "\(timeFmt.string(from: m.firstSeen))–\(timeFmt.string(from: m.lastSeen))"
            let dur = max(1, Int(m.lastSeen.timeIntervalSince(m.firstSeen) / 60))
            var line = "\(s.globalId). [\(tr), \(dur)min] \(m.appName)"
            if !m.windowName.isEmpty { line += " — \(m.windowName)" }
            if let u = m.browserURL, !u.isEmpty { line += " (url: \(u))" }
            rows.append(line)
            let snippet = s.ocr.replacingOccurrences(of: "\n", with: " ⏎ ")
            rows.append("    ocr: \(snippet)")
        }
        let sessionBlock = rows.joined(separator: "\n")

        let body = #"""
        You cluster raw activity SESSIONS into semantic EVENTS for a personal portrait system.

        An EVENT is what the USER was doing (subject + intent), NOT which app was open.
        Multiple sessions of the same activity (e.g. opening WeChat 18 times to chat
        with the same person) are ONE event. Sessions across different apps that serve
        one task (research in Safari → notes in Notes) are ONE event.

        OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
        {
          "events": [
            {
              "title": "...",
              "summary": "...",
              "type": "experience",
              "tags": ["..."],
              "portrait_facets": [],
              "session_ids": [1, 4, 9],
              "join_existing": null
            }
          ],
          "skipped": [3, 7]
        }

        HARD RULES (a violation makes the whole output invalid):
        - EVERY input session id MUST appear EXACTLY ONCE — either inside some
          event's "session_ids", or in the top-level "skipped" array.
        - "title": ≤ 60 chars, describes what the user was DOING. NEVER "App — Window".
        - "summary": REQUIRED, 3-5 sentences, MUST cite specific topics / names /
          actions visible in the OCR. NEVER write "the user used X app". If no OCR
          supports a summary, the session belongs in "skipped", not in an event.
        - THIRD PERSON always — "the user" / "they", never "you".
        - "type": "experience" (default, 99%) or "emotion" (only a clear emotional
          signal in the OCR — frustration, joy, conflict, anxiety).
        - "session_ids": non-empty list of the global ids this event covers.
        - "join_existing": if this event continues an ACTIVE EVENT listed above, put
          its id (e.g. "evt_03"); otherwise null. Only join when the subject matter
          is genuinely the same thread.
        - "skipped": sessions with no real content (idle glance, no meaningful OCR).

        portrait_facets — optional, default []. Only attach when the event reflects a
        STABLE signal about who the user is. Each facet: {"facet": "<name>", "value": "<short>"}.
          personality / background (demographic facts only) / social (named people) /
          interests / skills.

        WRITING THE SUMMARY — be concrete:
          ❌ "The user was chatting on WeChat."
          ✅ "The user discussed the AP exam schedule with a friend, confirming the
             May 12 calculus session and asking about the review sheet."
        """#

        return body
            + "\n\n" + activeBlock
            + "\n\n" + sessionBlock
    }

    // MARK: - Parse

    struct ParsedEvent {
        let title: String
        let summary: String
        let type: String
        let tags: [String]
        let facets: [(String, String)]
        let sessionIds: [Int]
        let joinExisting: String?
    }
    struct ParsedOutput {
        let events: [ParsedEvent]
        let skipped: [Int]
    }

    private static func parseOutput(_ response: String) throws -> ParsedOutput {
        guard let firstBrace = response.firstIndex(of: "{"),
              let lastBrace = response.lastIndex(of: "}") else {
            throw NSError(domain: "EventPromptTest", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "no JSON object in response"])
        }
        let jsonStr = String(response[firstBrace...lastBrace])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "EventPromptTest", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "JSON parse failed"])
        }
        let rawEvents = (obj["events"] as? [[String: Any]]) ?? []
        let events: [ParsedEvent] = rawEvents.map { e in
            let facets: [(String, String)] = ((e["portrait_facets"] as? [[String: Any]]) ?? []).compactMap { f in
                guard let n = f["facet"] as? String, let v = f["value"] as? String else { return nil }
                return (n, v)
            }
            return ParsedEvent(
                title: (e["title"] as? String) ?? "(no title)",
                summary: (e["summary"] as? String) ?? "",
                type: (e["type"] as? String) ?? "experience",
                tags: (e["tags"] as? [String]) ?? [],
                facets: facets,
                sessionIds: (e["session_ids"] as? [Int]) ?? [],
                joinExisting: e["join_existing"] as? String
            )
        }
        let skipped = (obj["skipped"] as? [Int]) ?? []
        return ParsedOutput(events: events, skipped: skipped)
    }

    private static func isWeChatEvent(_ ev: ParsedEvent, batch: [TestSession]) -> Bool {
        ev.sessionIds.contains { sid in
            batch.first { $0.globalId == sid }?.merged.appName.contains("微信") ?? false
        }
    }

    // MARK: - LLM call

    private static func callLLM(prompt: String) async throws -> (String, Int, Int) {
        let agent = try PiAgent(model: "gpt-5.4")
        try await agent.start()
        defer { agent.stop() }

        let coord = PromptTestCoordinator()
        let consumer = Task { [events = agent.events] in
            for await ev in events { await coord.handle(ev) }
        }
        defer { consumer.cancel() }

        let id = UUID().uuidString
        await coord.start()
        try agent.sendPrompt(prompt, id: id)

        let result = try await withThrowingTaskGroup(of: (String, Int, Int).self) { group in
            group.addTask { await coord.await_() }
            group.addTask {
                try await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                throw NSError(domain: "EventPromptTest", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: "LLM timeout (180s)"])
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
        return result
    }

    // MARK: - Token estimate

    /// Rough mixed CJK/Latin token estimate — CJK ≈ 1.5 tok/char, rest ≈ 0.3.
    static func estTokens(_ s: String) -> Int {
        var t = 0.0
        for u in s.unicodeScalars {
            if u.value >= 0x2E80 && u.value <= 0x9FFF { t += 1.5 }
            else { t += 0.3 }
        }
        return Int(t)
    }
}

/// `--backfill-day <yyyy-MM-dd>` — DEV-ONLY entry point that runs the real
/// `Backfill.run` restricted to a single day. Used to test the per-event
/// EventBuilder rewrite on one day's data. Disposable.
enum BackfillDayCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(day dayStr: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }
        print("=== backfill-day \(dayStr) ===")
        let state = State()
        Task.detached {
            do {
                let r = try await Backfill.run(onlyDay: day)
                print("=== backfill done ===")
                print("new events:           \(r.newEventCount)")
                print("joined (cross-day):   \(r.joinedSessionCount)")
                print("tier1 sessions:       \(r.tier1SessionCount)")
                print("dropped (no OCR):     \(r.emptySessionCount)")
                print("LLM-skipped sessions: \(r.skippedSessionCount)")
                print("LLM-failed days:      \(r.llmFailedDays)")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--rescore` — DEV-ONLY entry point that runs ImpactScorer.rescoreAll
/// over every event file. Disposable.
enum RescoreCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run() {
        print("=== rescore ===")
        let state = State()
        Task.detached {
            do {
                let scorer = await ImpactScorer()
                let r = try await scorer.rescoreAll { p in
                    print("batch \(p.batchIndex + 1)/\(p.batchCount) — scored \(p.scoredCount)/\(p.totalCount)")
                }
                print("=== rescore done ===")
                print("scored:  \(r.scoredCount)")
                print("failed:  \(r.failedCount)")
                print("elapsed: \(String(format: "%.1f", r.elapsed))s")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--backfill-days <N>` — DEV-ONLY entry point that runs the real Backfill
/// over the last N days in one process. Disposable.
enum BackfillDaysCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(daysBack: Int) {
        print("=== backfill-days \(daysBack) ===")
        let state = State()
        Task.detached {
            do {
                let r = try await Backfill.run(daysBack: daysBack)
                print("=== backfill done ===")
                print("days scanned:         \(r.daysScanned)")
                print("new events:           \(r.newEventCount)")
                print("joined (cross-day):   \(r.joinedSessionCount)")
                print("tier1 sessions:       \(r.tier1SessionCount)")
                print("dropped (no OCR):     \(r.emptySessionCount)")
                print("LLM-skipped sessions: \(r.skippedSessionCount)")
                print("LLM-failed days:      \(r.llmFailedDays)")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--wipe-personality-concepts` — DEV-ONLY 一次性迁移:备份 portrait/
/// personality/ + personality_daily/,然后清空(只留 INDEX.md)。用于
/// personality pipeline 改架构后从零重建。events/ 不动。
enum WipePersonalityCLI {
    static func run() {
        print("=== wipe-personality-concepts ===")
        let fm = FileManager.default
        let personalityDir = Storage.portraitDir.appendingPathComponent("personality")
        let dailyDir = Storage.personalityDailyDir
        // 不再备份 —— 测试期间反复 wipe 会堆一坨 personality.bak.* 占地方,
        // 用户已确认风险自担。
        var removed = 0
        for dir in [personalityDir, dailyDir] {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        print("=== done === removed \(removed) file(s)")
        exit(0)
    }
}

/// `--drop-portrait-impact-residue` — DEV-ONLY 一次性迁移:把 portrait/ 下
/// 每个非归档 / 非隔离的 .md 读出来,清掉 `rawImpact` / `rebalanceCount` /
/// `impactSource` 三个 event-only 字段(序列化器现在会 skip nil),重写。
/// 备份 portrait → portrait.bak.<date>-residue。events/ 不动。
enum DropPortraitImpactResidueCLI {
    static func run() {
        print("=== drop-portrait-impact-residue ===")
        let fm = FileManager.default
        let portraitDir = Storage.portraitDir
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let backup = portraitDir.deletingLastPathComponent()
            .appendingPathComponent("portrait.bak.\(stamp)-residue")
        do {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: portraitDir, to: backup)
            print("backup: \(backup.path)")
        } catch {
            FileHandle.standardError.write(Data("backup FAILED, 中止: \(error)\n".utf8))
            exit(1)
        }
        var migrated = 0, failed = 0
        guard let en = fm.enumerator(
            at: portraitDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { exit(1) }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_quarantine")
                || url.pathComponents.contains("_archive") { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                f.rawImpact = nil
                f.rebalanceCount = nil
                f.impactSource = nil
                try PortraitFileIO.write(f, to: url)
                migrated += 1
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("FAIL \(url.lastPathComponent): \(error)\n".utf8))
            }
        }
        print("=== done === migrated: \(migrated), failed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

/// `--drop-portrait-impact` — DEV-ONLY 一次性迁移：把 portrait/ 下每个非
/// 归档 / 非隔离的 .md 读出来、清掉 impact 字段、重写（PortraitFileIO 序列
/// 化器现在会 skip nil impact 行）。备份 ~/.portrait/portrait →
/// portrait.bak.<date>。events/ 不动。
enum DropPortraitImpactCLI {
    static func run() {
        print("=== drop-portrait-impact ===")
        let fm = FileManager.default
        let portraitDir = Storage.portraitDir

        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let backup = portraitDir.deletingLastPathComponent()
            .appendingPathComponent("portrait.bak.\(stamp)")
        do {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: portraitDir, to: backup)
            print("backup: \(backup.path)")
        } catch {
            FileHandle.standardError.write(Data("backup FAILED, 中止: \(error)\n".utf8))
            exit(1)
        }

        var migrated = 0, failed = 0
        guard let en = fm.enumerator(
            at: portraitDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { exit(1) }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_quarantine")
                || url.pathComponents.contains("_archive") { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                f.impact = nil
                try PortraitFileIO.write(f, to: url)
                migrated += 1
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("FAIL \(url.lastPathComponent): \(error)\n".utf8))
            }
        }
        print("=== done === migrated: \(migrated), failed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

/// `--migrate-portrait-ema` — DEV-ONLY 一次性迁移（Phase 3 策略 A）。
/// 先把 ~/.portrait/portrait 备份到 portrait.bak.YYYY-MM-DD，再把每个非归档 /
/// 非隔离的 portrait .md 重置为 EMA 干净起点：weight=1.0, mergeCount=1,
/// aliases=[], primaryLabel=nil, lastModified=created。body / 其它 metadata 保留。
/// 只动 portrait/ —— events/ 不在迁移范围（其字段靠读取默认值惰性补全）。
enum MigratePortraitEMACLI {
    static func run() {
        print("=== migrate-portrait-ema (策略 A：全部重置) ===")
        let fm = FileManager.default
        let portraitDir = Storage.portraitDir

        // 备份。
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let backup = portraitDir.deletingLastPathComponent()
            .appendingPathComponent("portrait.bak.\(stamp)")
        do {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: portraitDir, to: backup)
            print("backup: \(backup.path)")
        } catch {
            FileHandle.standardError.write(Data("backup FAILED, 中止: \(error)\n".utf8))
            exit(1)
        }

        var migrated = 0, failed = 0
        guard let en = fm.enumerator(
            at: portraitDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { exit(1) }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_quarantine")
                || url.pathComponents.contains("_archive") { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                f.weight = 1.0
                f.mergeCount = 1
                f.aliases = []
                f.primaryLabel = nil
                f.lastModified = f.created
                try PortraitFileIO.write(f, to: url)
                migrated += 1
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("FAIL \(url.lastPathComponent): \(error)\n".utf8))
            }
        }
        print("=== done === migrated: \(migrated), failed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

/// `--repair-portrait` — DEV-ONLY. 把 events/ 与 portrait/ 下每个 .md 读出来
/// 再写回，用更新后的 PortraitFileIO 修复格式（如旧的多行 frontmatter）。
/// 报告读取成功 / 失败数。Disposable.
enum RepairPortraitCLI {
    static func run() {
        print("=== repair-portrait ===")
        let fm = FileManager.default
        var ok = 0, failed = 0
        for root in [Storage.eventsDir, Storage.portraitDir] {
            guard let en = fm.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "md",
                      url.lastPathComponent != "INDEX.md" else { continue }
                do {
                    let f = try PortraitFileIO.read(from: url)
                    try PortraitFileIO.write(f, to: url)
                    ok += 1
                } catch {
                    failed += 1
                    let rel = url.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                    FileHandle.standardError.write(Data("FAIL \(rel): \(error)\n".utf8))
                }
            }
        }
        print("=== repair done ===")
        print("read OK + rewritten: \(ok)")
        print("failed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

/// `--personality-prompt-test <yyyy-MM-dd>` — DEV-ONLY. 对指定日期的 events
/// 跑一次 PersonalityAgent，打印 prompt + LLM 原始 JSON + parsed snapshot。
/// 不写盘。用于人工评估 trait 质量。Disposable.
enum PersonalityPromptTestCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(day dayStr: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }
        print("=== personality-prompt-test \(dayStr) ===")
        let state = State()
        Task {
            do {
                let events = await PersonalityAgent.readEvents(for: day)
                print("events for \(dayStr): \(events.count)")
                let agent = await PersonalityAgent()
                let r = try await agent.runWithRaw(date: day, events: events)
                print("\n──── PROMPT ────")
                print(r.prompt)
                print("\n──── LLM RAW ────")
                print(r.raw)
                print("\n──── PARSED SNAPSHOT ────")
                print("date: \(r.snapshot.date)")
                print("tags (\(r.snapshot.tags.count)):")
                for t in r.snapshot.tags {
                    print("  - \(t.name)  evidence=\(t.evidence)  ocr_keywords=\(t.ocrKeywords)")
                }
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--personality-merge-test <yyyy-MM-dd>` — DEV-ONLY. 对指定日期跑
/// PersonalityAgent → snapshot → PersonalityMerger.merge，打印 merge prompt +
/// LLM 原始 + 解析后的 actions。**不落盘**（review-first）。Disposable.
enum PersonalityMergeTestCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(day dayStr: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }
        print("=== personality-merge-test \(dayStr) ===")
        let state = State()
        Task {
            do {
                let events = await PersonalityAgent.readEvents(for: day)
                let snapshot = try await PersonalityAgent().generateDailySnapshot(date: day, events: events)
                print("daily snapshot — \(snapshot.tags.count) tag(s): \(snapshot.tags.map(\.name))")

                let concepts = await PersonalityMerger.readConcepts()
                print("existing personality concepts: \(concepts.count)")

                // events-only 候选(其他两源 portraits/ocr 走 --personality-refresh-apply)。
                let candidates: [PersonalityTagCandidate] = snapshot.tags.map {
                    PersonalityTagCandidate(tag: $0.name, source: .events, evidence: $0.evidence)
                }
                // 先聚类(降噪 + 收敛同义),再 merge。
                let clusters = try await PersonalityClusterAgent().cluster(candidates: candidates)
                print("clusters: \(clusters.count) (from \(candidates.count) candidate(s))")
                let r = try await PersonalityMerger().mergeWithRaw(
                    clusters: clusters, existingConcepts: concepts)
                print("\n──── MERGE PROMPT ────")
                print(r.prompt)
                print("\n──── LLM RAW ────")
                print(r.raw)
                print("\n──── PARSED ACTIONS (\(r.actions.count)) ────")
                for (i, a) in r.actions.enumerated() {
                    switch a {
                    case .mergeInto(let slug, let cluster, _):
                        print("\(i + 1). mergeInto [\(slug)]  head=\(cluster.head)  members=\(cluster.members.map(\.tag))")
                    case .createNew(let cluster, _):
                        print("\(i + 1). createNew \"\(cluster.head)\"  members=\(cluster.members.map(\.tag))")
                    case .skipCluster(let head, let reason):
                        print("\(i + 1). skipCluster [\(head)] — \(reason)")
                    }
                }
                print("\n(dry-run: nothing written to disk)")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--personality-merge-apply <yyyy-MM-dd>` — DEV-ONLY. 跟 merge-test 一样跑
/// agent → snapshot → merge，但**落盘**：applyActions 把 createNew / mergeInto
/// 写进 portrait/personality/。报告写了什么。Disposable.
enum PersonalityMergeApplyCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(day dayStr: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }
        print("=== personality-merge-apply \(dayStr) ===")
        let state = State()
        Task {
            do {
                let events = await PersonalityAgent.readEvents(for: day)
                let snapshot = try await PersonalityAgent().generateDailySnapshot(date: day, events: events)
                print("daily snapshot — \(snapshot.tags.count) tag(s): \(snapshot.tags.map(\.name))")
                let dailyURL = try PersonalityDailyStore.write(snapshot)
                print("daily snapshot written: \(dailyURL.path)")
                let concepts = await PersonalityMerger.readConcepts()
                print("existing personality concepts: \(concepts.count)")

                let candidates: [PersonalityTagCandidate] = snapshot.tags.map {
                    PersonalityTagCandidate(tag: $0.name, source: .events, evidence: $0.evidence)
                }
                let clusters = try await PersonalityClusterAgent().cluster(candidates: candidates)
                print("clusters: \(clusters.count) (from \(candidates.count) candidate(s))")
                let merger = await PersonalityMerger()
                let actions = try await merger.merge(clusters: clusters, existingConcepts: concepts)
                for (i, a) in actions.enumerated() {
                    switch a {
                    case .mergeInto(let s, let cl, _): print("\(i + 1). mergeInto [\(s)] head=\(cl.head) members=\(cl.members.map(\.tag))")
                    case .createNew(let cl, _):        print("\(i + 1). createNew \"\(cl.head)\" members=\(cl.members.map(\.tag))")
                    case .skipCluster(let h, let r):print("\(i + 1). skipCluster [\(h)] — \(r)")
                    }
                }
                let result = try await merger.applyActions(actions, on: day)
                print("\n=== applied ===")
                print("created: \(result.created), merged: \(result.merged), skipped: \(result.skipped)")
                print("written slugs: \(result.writtenSlugs)")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--distill` — DEV-ONLY entry point that runs the full PortraitDistiller
/// pass over all categories. Disposable.
enum DistillCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run() {
        print("=== distill ===")
        let state = State()
        Task.detached {
            do {
                let distiller = await PortraitDistiller()
                let r = try await distiller.distill { p in
                    print("category \(p.categoryIndex + 1)/\(p.categoryCount): \(p.category) — written so far \(p.written)")
                }
                print("=== distill done ===")
                print("categories processed: \(r.categoriesProcessed)")
                print("portrait files written: \(r.portraitFilesWritten)")
                print("portrait files updated: \(r.portraitFilesUpdated)")
                print("LLM-failed categories: \(r.llmFailedCategories)")
                print("archived: \(r.archivedCount)")
                print("elapsed: \(String(format: "%.1f", r.elapsed))s")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--distill-staged` — DEV-ONLY. 跟 `--distill` 一样跑全量 PortraitDistiller,
/// 但**进 staging**:跑前给 portrait/ 拍快照,跑完留在 Pending review,可在 app
/// 里 Reject(整树回滚)/ Approve(保留)。用来验证 distill 改动而不直接污染 live。
enum DistillStagedCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run() {
        print("=== distill (staged) ===")
        let state = State()
        Task.detached {
            do {
                try MemoryStaging.beginRun(.portrait)
                print("snapshot: portrait/ → .staging/portrait_backup/")
                let distiller = await PortraitDistiller()
                let r = try await distiller.distill { p in
                    print("category \(p.categoryIndex + 1)/\(p.categoryCount): \(p.category) — written so far \(p.written)")
                }
                try MemoryStaging.markRan(.portrait, days: [ProcessingLogStore.distillAnchorDate])
                print("=== distill done (staged for review) ===")
                print("written \(r.portraitFilesWritten) / updated \(r.portraitFilesUpdated) / archived \(r.archivedCount)")
                print("LLM-failed categories: \(r.llmFailedCategories)")
                print("→ 在 app 的 Pending review 审核;Reject 整树回滚,Approve 保留。")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}

/// `--dump-day <yyyy-MM-dd>` — DEV-ONLY. Exports one day's enriched Tier-1
/// sessions (id / time / app / window / url / OCR / frame ids) as JSON to
/// `/tmp/dump_<day>.json`. No LLM call — used to hand data to a subagent
/// when the codex quota is exhausted. Disposable.
enum DumpDayCLI {
    static func run(day dayStr: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }
        let iso = ISO8601DateFormatter()
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"
        hm.timeZone = TimeZone(identifier: "UTC")

        let db = TimelineDB()
        guard db.exists else {
            FileHandle.standardError.write(Data("timeline DB not found\n".utf8))
            exit(1)
        }
        let frames = db.frames(on: day, limit: 5000)
        let merged = Tier1Merger.merge(frames.map { f in
            Tier1Merger.RawEvent(timestamp: f.timestamp, appName: f.appName,
                                 windowName: f.windowName, browserURL: f.browserUrl,
                                 frameId: f.id)
        })

        var sessions: [[String: Any]] = []
        var gid = 0
        var dropped = 0
        for m in merged {
            let ocr = db.ocrText(forFrameIds: m.sourceFrameIds, maxChars: 800)
            if ocr.count < 60 { dropped += 1; continue }
            gid += 1
            let dur = max(1, Int(m.lastSeen.timeIntervalSince(m.firstSeen) / 60))
            sessions.append([
                "id": gid,
                "time": "\(hm.string(from: m.firstSeen))–\(hm.string(from: m.lastSeen))",
                "durMin": dur,
                "firstSeen": iso.string(from: m.firstSeen),
                "lastSeen": iso.string(from: m.lastSeen),
                "app": m.appName,
                "window": m.windowName,
                "url": m.browserURL ?? "",
                "frameIds": m.sourceFrameIds,
                "ocr": ocr,
            ])
        }
        let root: [String: Any] = [
            "day": dayStr,
            "tier1Total": merged.count,
            "enriched": sessions.count,
            "droppedNoOCR": dropped,
            "sessions": sessions,
        ]
        let outURL = URL(fileURLWithPath: "/tmp/dump_\(dayStr).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outURL)
            print("dumped \(sessions.count) sessions (\(dropped) dropped) → \(outURL.path)")
        } catch {
            FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

/// `--materialize-day <yyyy-MM-dd> <clustering.json>` — DEV-ONLY. Takes a
/// subagent-produced clustering JSON and the matching `/tmp/dump_<day>.json`,
/// and writes correct PortraitFile `.md` events to `~/.portrait/events/<day>/`.
/// Used when the codex quota is exhausted and a subagent did the clustering.
///
/// clustering JSON shape:
///   {"events":[{"title","summary","type","tags":[],"portrait_facets":["f:v"],
///               "impact":3.2,"session_ids":[1,5]}], "skipped":[...]}
enum MaterializeDayCLI {
    static func run(day dayStr: String, clusteringPath: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }

        // Load dump (sessions by id).
        guard let dumpData = FileManager.default.contents(atPath: "/tmp/dump_\(dayStr).json"),
              let dumpRoot = (try? JSONSerialization.jsonObject(with: dumpData)) as? [String: Any],
              let dumpSessions = dumpRoot["sessions"] as? [[String: Any]] else {
            FileHandle.standardError.write(Data("cannot read /tmp/dump_\(dayStr).json\n".utf8))
            exit(1)
        }
        var sessionById: [Int: [String: Any]] = [:]
        for s in dumpSessions { if let id = s["id"] as? Int { sessionById[id] = s } }

        // Load clustering.
        guard let clData = FileManager.default.contents(atPath: clusteringPath),
              let clRoot = (try? JSONSerialization.jsonObject(with: clData)) as? [String: Any],
              let events = clRoot["events"] as? [[String: Any]] else {
            FileHandle.standardError.write(Data("cannot read clustering \(clusteringPath)\n".utf8))
            exit(1)
        }

        let dayDir = PortraitPaths.eventsDayDir(for: day)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        var written = 0
        for ev in events {
            guard let title = ev["title"] as? String, !title.isEmpty,
                  let summary = ev["summary"] as? String, !summary.isEmpty,
                  let ids = ev["session_ids"] as? [Int], !ids.isEmpty else {
                FileHandle.standardError.write(Data("skipping malformed event\n".utf8))
                continue
            }
            let members = ids.compactMap { sessionById[$0] }
            if members.isEmpty { continue }
            var frameIds: [Int64] = []
            for m in members {
                if let fids = m["frameIds"] as? [Int64] { frameIds.append(contentsOf: fids) }
                else if let fids = m["frameIds"] as? [Int] { frameIds.append(contentsOf: fids.map(Int64.init)) }
            }
            frameIds.sort()
            // `created` = the event's day (UTC startOfDay), NOT a raw session
            // timestamp — a session's UTC instant can land on the next
            // calendar day and make created > occurrences.
            let createdDay = PortraitFile.truncateToDay(day)
            let type = ((ev["type"] as? String) ?? "experience").lowercased() == "emotion"
                ? "emotion" : "experience"
            let tags = (ev["tags"] as? [String]) ?? []
            let facets: [EventBuilder.PortraitFacet] = ((ev["portrait_facets"] as? [String]) ?? []).compactMap { fv in
                let parts = fv.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return EventBuilder.PortraitFacet(facet: parts[0].lowercased(), value: parts[1])
            }
            let impactRaw = (ev["impact"] as? Double) ?? Double((ev["impact"] as? Int) ?? 1)
            let impact = PortraitFile.clampImpact(impactRaw)

            var file = PortraitFile(
                created: createdDay,
                impact: impact,
                body: "# \(title)\n\n\(summary)\n",
                source: "timeline:event",
                tags: tags,
                firstOccurrence: day,
                eventTitle: title,
                eventSummary: summary,
                eventType: type,
                portraitFacets: facets,
                memberFrameIds: frameIds
            )
            file.rawImpact = impact
            file.impactSource = "llm:claude-subagent"
            file.occurrences = [PortraitFile.truncateToDay(day)]
            WeightCalculator.recompute(&file)

            let url = uniqueURL(dayDir.appendingPathComponent(makeFilename(title: title, day: dayStr)))
            do {
                try PortraitFileIO.write(file, to: url)
                written += 1
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            }
        }
        print("materialized \(written) events → \(dayDir.path)")
        exit(0)
    }

    private static func makeFilename(title: String, day: String) -> String {
        let lower = title.lowercased()
        var out = ""
        var sep = false
        for sc in lower.unicodeScalars {
            let c = Character(sc)
            if c.isLetter || c.isNumber { out.append(c); sep = false }
            else if !sep { out.append("_"); sep = true }
        }
        var slug = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.count > 60 { slug = String(slug.prefix(60)) }
        if slug.isEmpty { slug = "event" }
        return "\(day)_\(slug).md"
    }

    private static func uniqueURL(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...200 {
            let c = dir.appendingPathComponent("\(base)_\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return url
    }
}

/// `--dump-events-by-category` — DEV-ONLY. Mirrors PortraitDistiller's
/// event bucketing (type → experiences/emotions, each facet → its bucket,
/// top 50 by impact) and writes `/tmp/events_by_category.json`. No LLM.
enum DumpEventsByCategoryCLI {
    static func run() {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Storage.eventsDir,
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            FileHandle.standardError.write(Data("no events dir\n".utf8)); exit(1)
        }
        var buckets: [String: [[String: Any]]] = [:]
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            if f.eventTitle.isEmpty && f.eventSummary.isEmpty { continue }
            let rel = url.path.replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
            let entry: [String: Any] = [
                "id": rel,
                "title": f.eventTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : f.eventTitle,
                "summary": f.eventSummary,
                "impact": f.impact ?? 0,   // event 路径 dump；event 必有 impact
                "occurrenceDays": f.occurrences.count,
            ]
            if f.eventType.lowercased() == "emotion" {
                buckets["emotions", default: []].append(entry)
            } else {
                buckets["experiences", default: []].append(entry)
            }
            for facet in f.portraitFacets {
                let name = facet.facet.lowercased()
                guard name != "experiences", name != "emotions" else { continue }
                buckets[name, default: []].append(entry)
            }
        }
        for (k, v) in buckets {
            let sorted = v.sorted { (($0["impact"] as? Double) ?? 0) > (($1["impact"] as? Double) ?? 0) }
            buckets[k] = Array(sorted.prefix(50))
        }
        let outURL = URL(fileURLWithPath: "/tmp/events_by_category.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: buckets,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outURL)
            for (k, v) in buckets.sorted(by: { $0.key < $1.key }) {
                print("\(k): \(v.count) events")
            }
            print("→ \(outURL.path)")
        } catch {
            FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8)); exit(1)
        }
        exit(0)
    }
}

/// `--materialize-portrait <category> <decisions.json>` — DEV-ONLY. Takes a
/// subagent-produced distill decisions JSON and writes portrait files to
/// `~/.portrait/portrait/<category>/<slug>.md`.
///
/// decisions JSON: [{"action":"create","slug":"...","title":"...","body":"...",
///                   "derived_from":["event id",...]}]
enum MaterializePortraitCLI {
    static func run(category: String, decisionsPath: String) {
        guard let data = FileManager.default.contents(atPath: decisionsPath),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            FileHandle.standardError.write(Data("cannot read \(decisionsPath)\n".utf8)); exit(1)
        }
        let dir = PortraitPaths.categoryDir(category)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let portraitType = (category == "emotions") ? "emotion" : "experience"

        var written = 0
        for d in arr {
            let action = (d["action"] as? String) ?? "noop"
            guard action == "create" || action == "update" else { continue }
            guard let slug = d["slug"] as? String, !slug.isEmpty,
                  let title = d["title"] as? String, !title.isEmpty,
                  let body = d["body"] as? String, !body.isEmpty else {
                FileHandle.standardError.write(Data("skip malformed decision\n".utf8)); continue
            }
            let derived = (d["derived_from"] as? [String]) ?? []
            var md = "# \(title)\n\n\(body)\n"
            if !derived.isEmpty {
                md += "\n**Derived from events:**\n"
                for eid in derived.prefix(20) { md += "- [[\(eid)]]\n" }
            }
            var file = PortraitFile(
                created: Date(),
                // portrait 不持有 impact（event-only 字段）。
                body: md,
                source: "distilled",
                tags: [category, "portrait"],
                firstOccurrence: Date(),
                eventTitle: title,
                eventSummary: body,
                eventType: portraitType,
                portraitFacets: [],
                category: category,
                memberFrameIds: []
            )
            // 新 portrait baseline = EMA.afterMerge(0,0) = 1.0；不走 event 公式。
            file.weight = 1.0
            let url = dir.appendingPathComponent(slug + ".md")
            do {
                try PortraitFileIO.write(file, to: url)
                written += 1
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            }
        }
        print("materialized \(written) portrait files → \(dir.path)")
        exit(0)
    }
}

/// `--dump-events-for-scoring` — DEV-ONLY. Exports every event whose
/// impact_source is still `unscored` (id / title / summary /
/// occurrence days) to `/tmp/events_to_score.json`. No LLM.
enum DumpEventsForScoringCLI {
    static func run() {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Storage.eventsDir,
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            FileHandle.standardError.write(Data("no events dir\n".utf8)); exit(1)
        }
        var out: [[String: Any]] = []
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            guard f.impactSource == "unscored" else { continue }
            let rel = url.path.replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
            out.append([
                "id": rel,
                "title": f.eventTitle,
                "summary": f.eventSummary,
                "occurrenceDays": f.occurrences.count,
            ])
        }
        let outURL = URL(fileURLWithPath: "/tmp/events_to_score.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: out,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outURL)
            print("dumped \(out.count) events needing scores → \(outURL.path)")
        } catch {
            FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8)); exit(1)
        }
        exit(0)
    }
}

/// `--apply-scores <scores.json>` — DEV-ONLY. Reads `[{"id":"...","impact":2.3}]`
/// and writes each impact back into its event file (impact + raw_impact,
/// impact_source="llm:claude-subagent", weight recomputed).
enum ApplyScoresCLI {
    static func run(scoresPath: String) {
        guard let data = FileManager.default.contents(atPath: scoresPath),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            FileHandle.standardError.write(Data("cannot read \(scoresPath)\n".utf8)); exit(1)
        }
        var applied = 0, missing = 0
        for s in arr {
            guard let id = s["id"] as? String else { continue }
            let impactRaw = (s["impact"] as? Double) ?? Double((s["impact"] as? Int) ?? 1)
            let url = Storage.eventsDir.appendingPathComponent(id)
            guard var f = try? PortraitFileIO.read(from: url) else { missing += 1; continue }
            let c = PortraitFile.clampImpact(impactRaw)
            f.impact = c
            f.rawImpact = c
            f.rebalanceCount = 0
            f.impactSource = "llm:claude-subagent"
            WeightCalculator.recompute(&f)
            do { try PortraitFileIO.write(f, to: url); applied += 1 }
            catch { FileHandle.standardError.write(Data("write failed \(id): \(error)\n".utf8)) }
        }
        print("applied \(applied) scores (\(missing) ids not found)")
        exit(0)
    }
}

// MARK: - Coordinator

private actor PromptTestCoordinator {
    private var buffer = ""
    private var usageIn = 0
    private var usageOut = 0
    private var pending: CheckedContinuation<(String, Int, Int), Never>?

    func start() { buffer = ""; usageIn = 0; usageOut = 0; pending = nil }

    func await_() async -> (String, Int, Int) {
        await withCheckedContinuation { c in pending = c }
    }

    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d):
            buffer.append(d)
        case .assistantFinalText(let t):
            if buffer.isEmpty { buffer = t }
        case .usage(let i, let o):
            usageIn = i; usageOut = o
        case .agentEnd, .error:
            if let p = pending {
                pending = nil
                p.resume(returning: (buffer, usageIn, usageOut))
            }
        default:
            break
        }
    }
}

/// `--personality-refresh-apply <yyyy-MM-dd>` — DEV-ONLY. 跑完整的三源
/// personality 流水线(events + portraits + OCR)并落盘到
/// portrait/personality/。Disposable.
enum PersonalityRefreshApplyCLI {
    final class State: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func run(day dayStr: String) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let day = fmt.date(from: dayStr) else {
            FileHandle.standardError.write(Data("bad date: \(dayStr)\n".utf8))
            exit(1)
        }
        print("=== personality-refresh-apply \(dayStr) ===")
        let state = State()
        Task {
            do {
                let r = try await PersonalityRefresh().refresh(day: day)
                print("events on \(dayStr): \(r.eventsTotal) total → \(r.eventsAboveWeight) above weight \(PersonalityRefresh.minEventWeight)")
                print("snapshot tags: \(r.snapshotTags)")
                print("ocr validation (≥\(PersonalityRefresh.minOCRFrames) frames): kept \(r.ocrKept), dropped \(r.ocrDropped)")
                print("clusters: \(r.clusterCount) (from \(r.ocrKept * 2) candidate(s) — each kept tag emits .events + .ocr)")
                print("existing personality concepts: \(r.existingConceptCount)")
                print("\n──── ACTIONS (\(r.actions.count)) ────")
                for (i, a) in r.actions.enumerated() {
                    switch a {
                    case .mergeInto(let slug, let cluster, _):
                        print("\(i + 1). mergeInto [\(slug)]  head=\(cluster.head)  members=\(cluster.members.map(\.tag))")
                    case .createNew(let cluster, _):
                        print("\(i + 1). createNew \"\(cluster.head)\"  members=\(cluster.members.map(\.tag))")
                    case .skipCluster(let head, let reason):
                        print("\(i + 1). skipCluster [\(head)] — \(reason)")
                    }
                }
                print("\n=== applied ===")
                print("created: \(r.apply.created), merged: \(r.apply.merged), skipped: \(r.apply.skipped)")
                print("written slugs: \(r.apply.writtenSlugs)")
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                state.code = 1
            }
            state.done = true
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }
}
