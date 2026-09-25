import Foundation
import GRDB

/// `--interval-selftest`:本机 event 链按区间跑 + personality 按本地日的集成自检。
///
/// 只在临时数据根上跑:必须设 `CFFIXED_USER_HOME` 指到一个空的临时目录(数据根 =
/// `$CFFIXED_USER_HOME/.portrait`),否则拒绝执行。目录别放在 /tmp、/var 下:那两处是
/// 符号链接,扫事件树得到的路径和数据根对不上,join 找不到已有事件。聚类换成确定性的
/// 假聚类,不调 LLM。
/// 覆盖:区间跨两个本地日时事件分到两个日期目录、同一日期目录第二个区间照常写入
/// (文件名去重)、join 记被 join 那几个 session 的本地日、失败区间不留文件且不动其他
/// 区间的事件(LLM 失败 / 失败回滚 / 崩溃恢复 / 落盘中途出错)、impact 评分范围找回、
/// personality 每个本地日只跑一次、OCR 闸按本地日窗口计数、区间取帧不设上限、
/// 时间轴按日历日期显示、本机运行时机(封区间不触发运行,time_of_day 到点处理全部待处理
/// 区间,其余时刻只重试失败过且退避到期的区间 / 本地日,Retry now / Run now 立即处理)、
/// 事件目录分同日 / 往日、与 portrait_offload 共用的测试向量(V-A、V-B、V-G、V-W、V-M、V-O)、
/// 解析时替换邮箱、写作风格双层转义不写、OCR 闸分母(当天有字帧数)。
///
///   CFFIXED_USER_HOME=$(mktemp -d .build/ivhome.XXXX) .build/debug/MyPortrait --interval-selftest
@MainActor
enum IntervalSelfTest {

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    static func run() {
        Task { @MainActor in
            do {
                try await runImpl()
                print(failures == 0 ? "[interval-selftest] ALL PASS" : "[interval-selftest] \(failures) FAILURE(S)")
                exit(failures == 0 ? 0 : 1)
            } catch {
                fputs("[interval-selftest] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// 数据根必须在 CFFIXED_USER_HOME 下,且不是本机用户真实的 ~/.portrait。
    private static func tempRootOK() -> Bool {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else { return false }
        let root = Storage.rootURL.standardizedFileURL.path
        let fixed = URL(fileURLWithPath: home).standardizedFileURL.path
        guard root.hasPrefix(fixed + "/") else { return false }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let real = URL(fileURLWithPath: String(cString: dir)).appendingPathComponent(".portrait").standardizedFileURL.path
            if root == real { return false }
        }
        return true
    }

    // MARK: - 夹具

    private static let tz = -420   // PDT
    private static let m: Int64 = 60_000
    private static let h: Int64 = 3_600_000

    /// 本地时间 "yyyy-MM-dd HH:mm"(钉死 PDT)→ UTC ms。
    private static func local(_ s: String) -> Int64 {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: tz * 60)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return Int64(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }

    /// 一个 session 的帧:同一 app / window,[from, to] 每 `every` 一帧,OCR 文本够 60 字。
    private static func addSession(_ pool: DatabasePool, window: String, app: String,
                                   from: Int64, to: Int64, every: Int64) throws {
        let text = "Working in \(window) with enough on-screen text\nSecond line about the \(window) topic and details"
        try pool.write { db in
            for t in stride(from: from, through: to, by: Int(every)) {
                try db.execute(sql: """
                    INSERT INTO frames (timestamp_ms, app_name, window_name, snapshot_path, capture_trigger,
                                        full_text, created_at_ms)
                    VALUES (:t, :app, :win, 'x.jpg', 'click', :text, :t)
                    """, arguments: ["t": t, "app": app, "win": window, "text": text])
            }
        }
    }

    private static func interval(_ id: String, _ start: Int64, _ end: Int64) -> EventInterval {
        EventInterval(id: id, startMs: start, endMs: end, tzOffsetMin: tz, sealedAtMs: end,
                      trigger: EventIntervalStore.triggerGap, frameCount: 0, afterFrameId: 0,
                      maxFrameId: Int64.max, event: .pending, impact: .idle, retryCount: 0, updatedAtMs: 0)
    }

    private static func insertLedger(_ pool: DatabasePool, _ ivs: [EventInterval], origin: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO event_intervals (id, start_ms, end_ms, tz_offset_min, sealed_at_ms, trigger,
                  frame_count, after_frame_id, max_frame_id, event_status, impact_status, retry_count, updated_at_ms)
                VALUES (:id, :t, :t, :tz, :t, 'origin', 0, 0, 0, 'complete', 'complete', 0, 0)
                """, arguments: ["id": EventIntervalStore.originId, "t": origin, "tz": Int64(tz)])
            for iv in ivs {
                try db.execute(sql: """
                    INSERT INTO event_intervals (id, start_ms, end_ms, tz_offset_min, sealed_at_ms, trigger,
                      frame_count, after_frame_id, max_frame_id, event_status, impact_status, retry_count, updated_at_ms)
                    VALUES (:id, :s, :e, :tz, :e, 'gap', 0, 0, :max, 'pending', 'idle', 0, 0)
                    """, arguments: ["id": iv.id, "s": iv.startMs, "e": iv.endMs, "tz": Int64(tz),
                                     "max": iv.maxFrameId])
            }
        }
    }

    /// 假聚类最近一次收到的 EARLIER TODAY / PAST DAYS 事件 id。
    private static var seenEarlierToday: [String] = []
    private static var seenActive: [String] = []

    /// 假聚类:按 session 的 window 名查计划(title, join);没在计划里的 session 进 skipped。
    private static func clusterer(_ plan: [String: (title: String, join: String?)],
                                  fail: Bool = false) -> Backfill.Clusterer {
        { _, sessions, earlierToday, active in
            seenEarlierToday = earlierToday.map(\.id)
            seenActive = active.map(\.id)
            if fail { throw NSError(domain: "IntervalSelfTest", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "simulated LLM failure"]) }
            var events: [EventBuilder.ClusteredEvent] = []
            var skipped: [Int] = []
            for (i, s) in sessions.enumerated() {
                guard let p = plan[s.session.windowName] else { skipped.append(i + 1); continue }
                events.append(EventBuilder.ClusteredEvent(
                    title: p.title, summary: "\(p.title) summary", type: "experience",
                    portraitFacets: [], tags: ["selftest"], sessionIndices: [i + 1], joinExisting: p.join))
            }
            return EventBuilder.DayClustering(events: events, skippedIndices: skipped)
        }
    }

    private static func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }
    private static func i64(_ v: Any?) -> Int64 { (v as! NSNumber).int64Value }

    /// 只带 app 名和帧 id 的 session(排名、错并闸只看这两样)。
    private static func session(app: String, frames: Int) -> EventBuilder.EnrichedSession {
        let t = Date(timeIntervalSince1970: 0)
        return EventBuilder.EnrichedSession(
            session: Tier1Merger.MergedEvent(appName: app, windowName: "w", browserURL: nil, firstSeen: t,
                                             lastSeen: t, occurrences: [], sourceFrameIds: (0..<frames).map(Int64.init)),
            ocrSnippet: "", transcriptSnippet: "")
    }

    private static func events(_ rel: String) -> URL { Storage.eventsDir.appendingPathComponent(rel) }
    private static func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: events(rel).path) }
    private static func day(_ s: String) -> Date { ProcessingLogStore.day(from: s)! }

    /// 整个 events/ 树(相对路径 → 内容)。
    private static func tree() -> [String: Data] {
        var out: [String: Data] = [:]
        let root = Storage.eventsDir
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            out[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try? Data(contentsOf: url)
        }
        return out
    }

    // MARK: - 用例

    private static func runImpl() async throws {
        guard tempRootOK() else {
            fputs("[interval-selftest] refusing to run: set CFFIXED_USER_HOME to a temp directory\n", stderr)
            exit(2)
        }
        let fm = FileManager.default
        print("[interval-selftest] data root: \(Storage.rootURL.path)")
        guard !fm.fileExists(atPath: Storage.portraitDBPath) else {
            fputs("[interval-selftest] refusing to run: the data root is not empty, use a fresh temp directory\n", stderr)
            exit(2)
        }
        sharedVectors()
        let dbImpl = try PortraitDBImpl()
        let pool = dbImpl.dbPool

        // 写作风格 update 的正文多了一层转义 → 这次不写。
        let wsDir = PortraitPaths.categoryDir("writing_style")
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
        let wsURL = wsDir.appendingPathComponent("selftest_entry.md")
        let wsDraft = WritingStyleDraft(action: .create, slug: "selftest_entry", title: "Entry",
                                        body: "line one\nline two", sourceRecordIds: [1], existingSlug: nil)
        let wsNew = WritingStyleDistiller.writeNew(at: wsURL, draft: wsDraft)
        let wsBefore = try Data(contentsOf: wsURL)
        let wsSkip = WritingStyleDistiller.writeUpdate(
            at: wsURL, draft: WritingStyleDraft(action: .update, slug: "selftest_entry", title: "Entry 2",
                                                body: #"line one\nline two plus"#, sourceRecordIds: [2],
                                                existingSlug: "selftest_entry"),
            slug: "selftest_entry")
        let wsAfter = try Data(contentsOf: wsURL)
        check(wsNew && wsSkip && wsAfter == wsBefore,
              "writing style: update with a doubly escaped body returns true and leaves the file unchanged")
        try fm.removeItem(at: wsURL)
        MemoryScheduler.useLedgerPool(pool)
        let sched = MemoryScheduler.shared

        // 区间(PDT):A = 09-21 00:00 → 09-22 06:00,B = 09-22 06:00 → 18:00,
        // C = 09-22 18:00 → 09-23 06:00,E = 09-23 06:00 → 12:00。
        let t0 = local("2026-09-21 00:00")
        let ivA = interval("iv:\(t0)", t0, t0 + 30 * h)
        let ivB = interval("iv:\(t0 + 30 * h)", t0 + 30 * h, t0 + 42 * h)
        let ivC = interval("iv:\(t0 + 42 * h)", t0 + 42 * h, t0 + 54 * h)
        let ivE = interval("iv:\(t0 + 54 * h)", t0 + 54 * h, t0 + 60 * h)

        try addSession(pool, window: "alpha-win", app: "Editor",
                       from: local("2026-09-21 22:00"), to: local("2026-09-21 23:00"), every: m)
        // 跨午夜的 session:23:40–00:20,午夜前 20 帧、午夜后 21 帧 → 归 09-22。
        try addSession(pool, window: "span-win", app: "Terminal",
                       from: local("2026-09-21 23:40"), to: local("2026-09-22 00:20"), every: m)
        try addSession(pool, window: "beta-win", app: "Browser",
                       from: local("2026-09-22 00:30"), to: local("2026-09-22 01:30"), every: m)
        try addSession(pool, window: "gamma-win", app: "Notes",
                       from: local("2026-09-22 10:00"), to: local("2026-09-22 11:00"), every: m)
        try addSession(pool, window: "alpha-win", app: "Editor",
                       from: local("2026-09-22 14:00"), to: local("2026-09-22 14:30"), every: m)
        try addSession(pool, window: "beta2-win", app: "Mail",
                       from: local("2026-09-22 15:00"), to: local("2026-09-22 15:10"), every: m)
        try addSession(pool, window: "beta3-win", app: "Chat",
                       from: local("2026-09-22 16:00"), to: local("2026-09-22 16:10"), every: m)
        try addSession(pool, window: "delta-win", app: "Figma",
                       from: local("2026-09-22 20:00"), to: local("2026-09-22 20:30"), every: m)
        try addSession(pool, window: "beta-win", app: "Browser",
                       from: local("2026-09-22 21:00"), to: local("2026-09-22 21:10"), every: m)
        // E:6000 帧,每秒一帧,同一 session。
        try addSession(pool, window: "bulk-win", app: "Video",
                       from: local("2026-09-23 07:00"), to: local("2026-09-23 07:00") + 5999 * 1000, every: 1000)
        try insertLedger(pool, [ivA, ivB, ivC, ivE], origin: t0)

        check(sched.pendingIntervals().map(\.id) == [ivA.id, ivB.id, ivC.id, ivE.id],
              "scheduler: pending intervals come from the ledger, oldest first")

        // —— A:跨两个本地日 ——
        print("[interval-selftest] interval spanning two local days")
        let rA = try await Backfill.runInterval(ivA, clusterer: clusterer([
            "alpha-win": ("Alpha", nil), "span-win": ("Span", nil), "beta-win": ("Beta", nil),
        ]))
        check(!rA.llmFailed && rA.newEventCount == 3 && !exists("2026-09-21/2026-09-21_alpha.md"),
              "A: three new events planned, nothing on disk before commit")
        try rA.overlay.commit(intervalId: ivA.id)
        check(exists("2026-09-21/2026-09-21_alpha.md") && exists("2026-09-22/2026-09-22_beta.md"),
              "A: events land in two local-day directories (09-21 alpha, 09-22 beta)")
        check(exists("2026-09-22/2026-09-22_span.md") && !exists("2026-09-21/2026-09-21_span.md"),
              "A: a session across midnight goes to the local day with more frames")
        check(rA.days == ["2026-09-21", "2026-09-22"], "A: event days = {09-21, 09-22}")
        let alpha0 = try PortraitFileIO.read(from: events("2026-09-21/2026-09-21_alpha.md"))
        check(alpha0.created == day("2026-09-21") && alpha0.occurrences == [day("2026-09-21")]
              && alpha0.memberFrameIds.count == 61 && alpha0.impactSource == "unscored",
              "A: alpha created / occurrences = local day, 61 member frames, unscored")
        check(fm.fileExists(atPath: EventOverlay.journalURL(intervalId: ivA.id).path),
              "A: undo journal written with the commit")
        let aId = ivA.id
        try await pool.write { db in
            try db.execute(sql: "UPDATE event_intervals SET event_status = 'complete' WHERE id = :id",
                           arguments: ["id": aId])
        }
        sched.recoverStaleLocks()
        check(!fm.fileExists(atPath: EventOverlay.journalURL(intervalId: ivA.id).path),
              "A: journal dropped once the interval's event step is complete")
        let touchedA = await Backfill.eventFiles(withAnyFrameIn: Set(alpha0.memberFrameIds))
        check(touchedA.map(\.lastPathComponent) == ["2026-09-21_alpha.md"],
              "impact retry scope: events found back by the interval's frame ids")

        // —— B:同一日期目录第二个区间 ——
        print("[interval-selftest] second interval into the same date directory")
        let alphaRel = "2026-09-21/2026-09-21_alpha.md"
        let rB = try await Backfill.runInterval(ivB, clusterer: clusterer([
            "gamma-win": ("Gamma", nil), "alpha-win": ("Alpha again", alphaRel),
            "beta2-win": ("Beta", nil), "beta3-win": ("Beta", nil),
        ]))
        check(seenEarlierToday == ["2026-09-22/2026-09-22_beta.md", "2026-09-22/2026-09-22_span.md"],
              "B: EARLIER TODAY = interval A's 09-22 events (latest occurrence desc, then path)")
        check(seenActive.contains(alphaRel) && Set(seenActive).isDisjoint(with: seenEarlierToday),
              "B: PAST DAYS has the 09-21 event and none of the same-day events")
        try rB.overlay.commit(intervalId: ivB.id)
        EventOverlay.clearJournal(intervalId: ivB.id)
        check(exists("2026-09-22/2026-09-22_gamma.md") && exists("2026-09-22/2026-09-22_beta.md"),
              "B: new event written next to interval A's events in 09-22/")
        check(exists("2026-09-22/2026-09-22_beta_2.md") && exists("2026-09-22/2026-09-22_beta_3.md"),
              "B: same-title events dedupe against disk and within the interval (_2, _3)")
        let alpha1 = try PortraitFileIO.read(from: events(alphaRel))
        check(alpha1.occurrences == [day("2026-09-21"), day("2026-09-22")] && alpha1.memberFrameIds.count == 92
              && alpha1.eventTitle == "Alpha" && rB.joinedSessionCount == 1,
              "B: join records the joined session's local day (09-22), appends frames, keeps the title")
        check(Set(rB.touched.map(\.lastPathComponent)) == ["2026-09-22_gamma.md", "2026-09-21_alpha.md",
                                                             "2026-09-22_beta_2.md", "2026-09-22_beta_3.md"],
              "B: impact scope = this interval's new and joined events")

        // —— C:失败区间 ——
        print("[interval-selftest] failed interval leaves no files and keeps other intervals' events")
        let before = tree()
        let planC: [String: (title: String, join: String?)] = [
            "delta-win": ("Delta", nil), "beta-win": ("Beta again", "2026-09-22/2026-09-22_beta.md"),
        ]
        let rC0 = try await Backfill.runInterval(ivC, clusterer: clusterer(planC, fail: true))
        check(rC0.llmFailed && rC0.overlay.isEmpty && tree() == before, "C: LLM failure → nothing written")

        // 落盘后步骤记为失败 → 按撤销清单撤掉(applyOutcome 的回滚)。
        let rC1 = try await Backfill.runInterval(ivC, clusterer: clusterer(planC))
        try rC1.overlay.commit(intervalId: ivC.id)
        check(exists("2026-09-22/2026-09-22_delta.md") && tree() != before, "C: committed (delta new, beta joined)")
        await sched.runInjectedStep(date: ivC.id, stage: .event, result: .failure)
        check(tree() == before, "C: failed step undoes only this interval (delta removed, beta restored, others untouched)")
        let c1 = try EventIntervalStore(dbPool: pool).interval(id: ivC.id)
        check(c1?.event == .failed && c1?.retryCount == 1, "C: ledger row failed, retry 1")

        // 落盘后进程死掉(心跳过期)→ 恢复时按清单撤销。
        let rC2 = try await Backfill.runInterval(ivC, clusterer: clusterer(planC))
        try rC2.overlay.commit(intervalId: ivC.id)
        let staleAt = EventIntervalStore.nowMs() - 2 * h, cId = ivC.id
        try await pool.write { db in
            try db.execute(sql: "UPDATE event_intervals SET event_status = 'in_progress', updated_at_ms = :t WHERE id = :id",
                           arguments: ["t": staleAt, "id": cId])
        }
        sched.recoverStaleLocks()
        let c2 = try EventIntervalStore(dbPool: pool).interval(id: ivC.id)
        check(tree() == before && c2?.event == .failed && c2?.retryCount == 2,
              "C: stale in-progress interval → recovery undoes its writes, failed, retry 2")
        check(sched.attentionDays().contains { $0.date == ivC.id }, "C: failed interval shows in Needs attention")
        sched.resetDay(ivC.id)
        let c3 = try EventIntervalStore(dbPool: pool).interval(id: ivC.id)
        check(c3?.event == .pending && c3?.retryCount == 2
              && sched.pendingIntervals(scope: .retryOnly).map(\.id) == [ivC.id],
              "C: Retry now → pending, retry kept, picked up by the next tick's retry run")

        // 落盘中途出错 → 当场撤销。
        let blocker = events("2026-09-24")
        try Data("x".utf8).write(to: blocker)
        var ov = EventOverlay()
        var beta = try PortraitFileIO.read(from: events("2026-09-22/2026-09-22_beta.md"))
        beta.memberFrameIds.append(999_999)
        ov.put(beta, at: events("2026-09-22/2026-09-22_beta.md"))
        ov.put(beta, at: blocker.appendingPathComponent("2026-09-24_new.md"), isNew: true)
        check((try? ov.commit(intervalId: "iv:selftest")) == nil && tree() == before
              && !fm.fileExists(atPath: EventOverlay.journalURL(intervalId: "iv:selftest").path),
              "commit error midway → earlier writes restored, journal removed")
        try fm.removeItem(at: blocker)

        // —— E:不设帧上限 ——
        print("[interval-selftest] no frame cap")
        let rows = TimelineDB().frames(fromMs: ivE.startMs, toMs: ivE.endMs, afterId: 0, maxId: Int64.max)
        let rE = try await Backfill.runInterval(ivE, clusterer: clusterer([:]))
        check(rows.count == 6000 && rE.rawFrameCount == 6000 && rE.skippedSessionCount == 1 && rE.overlay.isEmpty,
              "E: interval with 6000 frames is read whole (no 5000 cap)")

        // —— personality:本地日、每天一次 ——
        print("[interval-selftest] personality by local day")
        let store = EventIntervalStore(dbPool: pool)
        for iv in [ivA, ivB] {
            try store.setStatus(id: iv.id, stage: .event, status: .complete)
            try store.setStatus(id: iv.id, stage: .impact, status: .complete)
        }
        check(sched.pendingPersonalityDays(cap: 7).map(\.day) == ["2026-09-21"],
              "personality: 09-21 ready (only A overlaps); 09-22 waits for C")
        try store.setPersonalityStatus(day: "2026-09-21", tzOffsetMin: tz, status: .pending)
        await sched.runInjectedStep(date: MemoryScheduler.pdayKey("2026-09-21"), stage: .personality, result: .success)
        let p21 = try store.personalityDay("2026-09-21")
        check(p21?.status == .complete && p21?.tzOffsetMin == tz, "personality: step result lands in personality_days")
        for iv in [ivC] {
            try store.setStatus(id: iv.id, stage: .event, status: .complete)
            try store.setStatus(id: iv.id, stage: .impact, status: .complete)
        }
        check(sched.pendingPersonalityDays(cap: 7).map(\.day) == ["2026-09-22"],
              "personality: each local day runs once (09-21 not again, 09-22 now ready)")
        let w22 = IntervalSegmenter.dayWindow("2026-09-22", tzOffsetMin: tz)!
        let w21 = IntervalSegmenter.dayWindow("2026-09-21", tzOffsetMin: tz)!
        let tl = TimelineDB()
        check(tl.frameCount(fromMs: w22.start, toMs: w22.end, keywords: ["gamma-win"]) == 61
              && tl.frameCount(fromMs: w21.start, toMs: w21.end, keywords: ["gamma-win"]) == 0
              && tl.frameCount(fromMs: w21.start, toMs: w21.end, keywords: ["span-win"]) == 20,
              "OCR gate counts frames inside the local day window")
        check(tl.ocrFrameCount(fromMs: w22.start, toMs: w22.end) == 238,
              "OCR gate denominator: 238 frames with text on 09-22 (21+61+61+31+11+11+31+11)")
        check(sched.stagesComplete(date: ivA.id, stages: [.raw, .event, .impact])
              && !sched.stagesComplete(date: ivE.id, stages: [.raw, .event, .impact]),
              "staged-run check reads interval rows")

        // —— 本机运行时机 ——
        print("[interval-selftest] local run timing")
        let cal0 = Calendar.current
        func at(_ hh: Int, _ mm: Int) -> Date { cal0.date(bySettingHour: hh, minute: mm, second: 0, of: Date())! }
        let daily = SchedulerConfig(frequency: .daily, timeOfDay: "03:00", dayOfWeek: 0, dayOfMonth: 1)
        typealias MS = MemoryScheduler
        // 12:00 之后又用了一小时电脑,14:00 起离开 2.5h → 这次检查封出一个空档区间 F。
        try addSession(pool, window: "zeta-win", app: "Editor",
                       from: local("2026-09-23 13:00"), to: local("2026-09-23 14:00"), every: m)
        let sealedF = try store.sealCheck(now: Date(timeIntervalSince1970: Double(local("2026-09-23 16:30")) / 1000),
                                          tzOffsetMin: tz)
        let ivF = sealedF.first
        check(sealedF.count == 1 && ivF?.trigger == "gap" && ivF?.startMs == ivE.endMs
              && ivF?.endMs == local("2026-09-23 14:00") + 1 && ivF?.frameCount == 61,
              "timing: seal check closes F at the 2h gap after 14:00")
        let fId = ivF?.id ?? ""
        check(sched.pendingIntervals().map(\.id) == [ivE.id, fId] && sched.pendingIntervals(scope: .retryOnly).isEmpty,
              "timing: E and F wait in the ledger, neither is a retry")
        check(MS.localRunScope(config: daily, now: at(14, 0), ranToday: true, hasRetry: false) == nil,
              "timing: after today's scheduled run, a newly sealed interval starts no local run")
        check(MS.localRunScope(config: daily, now: at(2, 59), ranToday: false, hasRetry: false) == nil
              && MS.localRunScope(config: daily, now: at(3, 0), ranToday: false, hasRetry: false) == .all
              && MS.localRunScope(config: daily, now: at(9, 0), ranToday: false, hasRetry: false) == .all,
              "timing: time_of_day 03:00 (or the first tick after waking past it) runs all pending intervals")
        check(sched.eventRunNowHasWork() && sched.pendingIntervals().map(\.id).contains(fId),
              "timing: Run now takes E and F right away (scope .all)")

        // folder 分类失败 → Retry now 翻回 pending(锚行 retry 归零)→ 下个 tick 的重试运行。
        let plog = ProcessingLogStore(), classifyKey = ProcessingLogStore.classifyAnchorDate
        _ = plog.ensureRow(for: classifyKey)
        plog.setStatus(date: classifyKey, stage: .classify, status: .failed)
        plog.setRetryCount(date: classifyKey, count: 1)
        check(!sched.eventNeedsRetry(), "timing: failed folder classify inside its backoff → no retry yet")
        sched.resetDay(classifyKey)
        check(plog.row(for: classifyKey)?.classify == .pending && sched.eventNeedsRetry(),
              "timing: Retry now on folder classify → pending, retried on the next tick")
        plog.setStatus(date: classifyKey, stage: .classify, status: .complete)

        // F 失败一次 → 10 分钟退避;到期后只有 F 进重试运行,E(retry 0)仍等 time_of_day。
        let nowT = EventIntervalStore.nowMs()
        try store.setStatus(id: fId, stage: .event, status: .failed, nowMs: nowT)
        try store.bumpRetry(id: fId, nowMs: nowT)
        check(sched.pendingIntervals(scope: .retryOnly).isEmpty, "timing: failed F inside its 10 min backoff → no retry yet")
        try store.setRetryCount(id: fId, count: 1, nowMs: nowT - 11 * m)
        let retryIds = sched.pendingIntervals(scope: .retryOnly).map(\.id)
        check(retryIds == [fId]
              && MS.localRunScope(config: daily, now: at(14, 0), ranToday: true, hasRetry: !retryIds.isEmpty) == .retryOnly,
              "timing: backoff over → retry run takes only F (retry_count > 0), not E")
        let off = SchedulerConfig(frequency: .off, timeOfDay: "03:00", dayOfWeek: 0, dayOfMonth: 1)
        check(MS.localRunScope(config: off, now: at(14, 0), ranToday: false, hasRetry: true) == nil,
              "timing: frequency off → no scheduled or retry run")

        // 退出中断(paused → failed)和撞额度(budget_deferred)都不计 retry,仍按退避重试;
        // Retry now 翻回 pending 后下个 tick 就跑。
        try store.setStatus(id: ivE.id, stage: .event, status: .inProgress)
        sched.pauseInProgressJobs()
        sched.recoverStaleLocks()
        let e1 = try store.interval(id: ivE.id)
        check(e1?.event == .failed && e1?.retryCount == 0
              && sched.pendingIntervals(scope: .retryOnly).map(\.id) == [ivE.id, fId],
              "timing: interval interrupted by quit (paused → failed, retry 0) is retried on the next tick")
        await sched.runInjectedStep(date: ivE.id, stage: .event, result: .budget)
        let e2 = try store.interval(id: ivE.id)
        check(e2?.event == .budgetDeferred && e2?.retryCount == 0
              && sched.pendingIntervals(scope: .retryOnly).map(\.id) == [ivE.id, fId],
              "timing: budget_deferred interval (retry 0) is retried on the next tick")
        sched.resetDay(ivE.id)
        let e3 = try store.interval(id: ivE.id)
        check(e3?.event == .pending && sched.pendingIntervals(scope: .retryOnly).map(\.id) == [ivE.id, fId]
              && !sched.attentionDays().contains { $0.date == ivE.id },
              "timing: Retry now on a retry-0 interval → pending, picked up by the next tick's retry run")

        // personality:就绪日等调度时刻(或 event 接力),失败日按退避重试。
        check(sched.pendingPersonalityDays(cap: 7).map(\.day) == ["2026-09-22"]
              && sched.pendingPersonalityDays(cap: 7, scope: .retryOnly).isEmpty,
              "timing: ready personality day is not a retry — runs at the scheduled time or after event")
        try store.setPersonalityStatus(day: "2026-09-22", tzOffsetMin: tz, status: .failed, nowMs: nowT)
        try store.bumpPersonalityRetry(day: "2026-09-22", nowMs: nowT)
        check(sched.pendingPersonalityDays(cap: 7, scope: .retryOnly).isEmpty,
              "timing: failed personality day inside its backoff → no retry yet")
        try store.setPersonalityRetryCount(day: "2026-09-22", count: 1, nowMs: nowT - 11 * m)
        check(sched.pendingPersonalityDays(cap: 7, scope: .retryOnly).map(\.day) == ["2026-09-22"],
              "timing: failed personality day retried once its backoff is over")
        let p22 = MemoryScheduler.pdayKey("2026-09-22")
        try store.setPersonalityRetryCount(day: "2026-09-22", count: 0)
        await sched.runInjectedStep(date: p22, stage: .personality, result: .budget)
        let pd1 = try store.personalityDay("2026-09-22")
        check(pd1?.status == .budgetDeferred && pd1?.retryCount == 0
              && sched.pendingPersonalityDays(cap: 7, scope: .retryOnly).map(\.day) == ["2026-09-22"],
              "timing: budget_deferred personality day (retry 0) is retried on the next tick")
        sched.resetDay(p22)
        check(try store.personalityDay("2026-09-22")?.status == .pending
              && sched.pendingPersonalityDays(cap: 7, scope: .retryOnly).map(\.day) == ["2026-09-22"],
              "timing: Retry now on a retry-0 personality day → pending, picked up by the next tick's retry run")

        // —— UI:日历日期 ——
        let cal = Calendar(identifier: .gregorian)
        let shown = EventTimeline.calendarDay(day("2026-09-22"))
        check(cal.component(.day, from: shown) == 22 && cal.component(.hour, from: shown) == 0,
              "timeline shows 2026-09-22 as the 22nd in the local calendar")
    }

    // MARK: - 两端共用测试向量(与 portrait_offload 的 pytest 内嵌同一段 JSON)

    private static func sharedVectors() {
        print("[interval-selftest] shared vectors")
        // V-A:同日 / 往日划分。
        let va = json(vectorA) as! [String: Any]
        var catalog: [EventBuilder.ActiveEvent] = []
        var occ: [String: [Date]] = [:]
        for c in va["catalog"] as! [[String: Any]] {
            let id = c["id"] as! String, days = (c["occ"] as! [String]).map(day)
            catalog.append(.init(id: id, title: "t", summary: "", type: "experience", tags: [],
                                 lastOccurredOn: days.max()!))
            occ[id] = days
        }
        for c in va["cases"] as! [[String: Any]] {
            let r = EventBuilder.splitCatalog(catalog, occurrences: occ, firstMs: i64(c["first_ms"]),
                                              lastMs: i64(c["last_ms"]), tzOffsetMin: va["tz_offset_min"] as! Int)
            check(r.sameDay.map(\.id) == c["same_day"] as! [String] && r.past.map(\.id) == c["past"] as! [String],
                  "V-A splitCatalog: \(c["note"] as! String)")
        }

        // V-B:PAST DAYS 排名与目录顺序。
        let vb = json(vectorB) as! [String: Any]
        let evs = (vb["events"] as! [[String: Any]]).map { e in
            (name: e["name"] as! String,
             ev: EventBuilder.ActiveEvent(id: e["id"] as! String, title: "t", summary: "", type: "experience",
                                          tags: e["tags"] as! [String], lastOccurredOn: day(e["last"] as! String)))
        }
        let nameOf = Dictionary(uniqueKeysWithValues: evs.map { ($0.ev.id, $0.name) })
        let batch = (vb["batch_apps"] as! [String]).map { session(app: $0, frames: 1) }
        check(EventBuilder.rankActive(evs.map(\.ev), for: batch).map { nameOf[$0.id]! } == vb["rank"] as! [String],
              "V-B rankActive: score desc, then latest occurrence desc, then path")
        check(evs.map(\.ev).sorted(by: EventBuilder.catalogOrder).map { nameOf[$0.id]! } == vb["catalog_order"] as! [String],
              "V-B catalog order: latest occurrence desc, then path")

        // V-G:错并闸。一个簇 = 只含 session 1 的并入,帧数 = 并入帧。
        let vg = json(vectorG) as! [String: Any]
        func gate(_ target: String, add: Int, _ framesNow: inout [String: Int]) -> Bool {
            let ev = EventBuilder.ClusteredEvent(title: "t", summary: "s", type: "experience", portraitFacets: [],
                                                 tags: [], sessionIndices: [1], joinExisting: target)
            let r = EventBuilder.gateJoins([ev], sessions: [session(app: "App", frames: add)], framesNow: &framesNow)
            return r.rejected == 1 && r.events.first?.joinExisting == nil && r.events.first?.title == "t"
        }
        var cur: [String: Int] = [:], rejected: [Int] = []
        for row in vg["rows"] as! [[Any]] {
            let n = row[0] as! Int, t = row[1] as! String, add = row[3] as! Int
            let now = cur[t] ?? row[2] as! Int
            if row[4] as! String == "P" {
                var fn = [t: now]
                if gate(t, add: add, &fn) { rejected.append(n) } else { cur[t] = fn[t]! }
            } else {
                cur[t] = now + add
            }
        }
        check(rejected == vg["rejected"] as! [Int], "V-G auditB replay: gate rejects only #31, #39")
        let single = (vg["single"] as! [[Any]]).allSatisfy { v in
            var fn = ["T": v[0] as! Int]
            return gate("T", add: v[1] as! Int, &fn) == v[2] as! Bool
        }
        check(single, "V-G single joins: reject iff add ≥ 10 and add > 3 × current frames")
        let seq = vg["sequence"] as! [String: Any]
        var fn = ["T": seq["start"] as! Int]
        let seqRejected = (seq["adds"] as! [Int]).map { gate("T", add: $0, &fn) }
        check(seqRejected == seq["rejected"] as! [Bool] && fn["T"] == (seq["end"] as! Int),
              "V-G sequence: passed joins add up on the target")
        var none: [String: Int] = [:]
        check(!gate("_b1", add: 500, &none), "join gate: targets outside framesNow (same-day, _bN) pass")

        // V-W:写作风格已有条目给全文(去掉溯源行),转义成一行。
        for (i, v) in (json(vectorW) as! [[String: String]]).enumerated() {
            let prose = WritingStyleDistiller.proseOf(v["body"]!)
            let pl = WritingStyleAgent.buildPrompt(
                records: [], existing: [.init(slug: "s\(i)", title: "T", body: prose)]).components(separatedBy: "\n")
            let hi = pl.firstIndex { $0.hasPrefix("EXISTING ENTRIES") } ?? pl.count - 2
            let si = pl.firstIndex(of: "[slug=s\(i)] T") ?? pl.count - 1
            check(prose == v["prose"]! && pl[hi + 1] == PortraitDistiller.escapedBodyNote && pl[si + 1] == v["line"]!
                  && !pl.contains { $0.contains("Derived from writing records") },
                  "V-W writing style entry \(i + 1): full prose without the trailer, escaped on one line")
        }

        // V-M:邮箱换成 [email];四条链的解析都过这一步。
        let vm = json(vectorM) as! [[String]]
        let vmBad = vm.filter { EventBuilder.scrubEmails($0[0]) != $0[1] }.map { $0[0] }
        check(vmBad.isEmpty, "V-M scrubEmails: all \(vm.count) vectors\(vmBad.isEmpty ? "" : " — wrong: \(vmBad)")")
        let pc = try? EventBuilder.parseClustering(from: #"""
            {"events": [{"title": "Mail alice@example.com", "summary": "Wrote to bob@example.org about x",
              "type": "experience", "tags": ["mail"], "portrait_facets": [{"facet": "social", "value": "contact carol@example.net"}],
              "session_ids": [1]},
             {"title": "Joined", "summary": "s", "session_ids": [2], "join_existing": "2026-09-21/a.md"}], "skipped": []}
            """#)
        check(pc?.events.first?.title == "Mail [email]" && pc?.events.first?.summary == "Wrote to [email] about x"
              && pc?.events.first?.portraitFacets == [.init(facet: "social", value: "contact [email]")]
              && pc?.events.last?.joinExisting == "2026-09-21/a.md" && pc?.events.last?.sessionIndices == [2],
              "emails: parseClustering scrubs title, summary and facet values; joins parse as before")
        let ws = try? WritingStyleAgent.parse(from: #"""
            [{"action": "create", "slug": "sign_off", "title": "Signs off as alice@example.com",
              "body": "Short lines.\nReplies to bob@example.org fast.", "source_record_ids": [1]}]
            """#)
        check(ws?.first?.title == "Signs off as [email]" && ws?.first?.body == "Short lines.\nReplies to [email] fast.",
              "emails: WritingStyleAgent.parse scrubs title and body")
        let snap = try? PersonalityAgent.parseSnapshot(from: #"""
            {"date": "", "tags": [{"name": "writes to alice@example.com", "evidence": ["2026-09-22/x.md", "mailed bob@example.org"],
              "ocr_keywords": ["alice@example.com", "placeholder"]}]}
            """#, fallbackDate: "2026-09-22")
        check(snap?.date == "2026-09-22" && snap?.tags.first?.name == "writes to [email]"
              && snap?.tags.first?.evidence == ["2026-09-22/x.md", "mailed [email]"]
              && snap?.tags.first?.ocrKeywords == ["alice@example.com", "placeholder"],
              "emails: parseSnapshot scrubs tag names and evidence, keeps ocr_keywords")
        let cl = PersonalityCluster(head: "outreach",
                                    members: [PersonalityTagCandidate(tag: "outreach", source: .events, evidence: [])])
        let acts = try? PersonalityMerger.parseActions(
            from: #"[{"action": "createNew", "head": "outreach", "description": "  Emails dave@example.com often.  "}]"#,
            clusters: [cl])
        check(acts == [.createNew(cluster: cl, description: "Emails [email] often.")],
              "emails: parseActions trims then scrubs the description")

        // V-O:性格 OCR 闸的证据关键词与低帧日。
        let vo = json(vectorO) as! [String: Any]
        let hits = vo["hits"] as! [String: Int]
        check(PersonalityRefresh.evidenceKeywords(vo["keywords"] as! [String], total: vo["total"] as! Int) { hits[$0]! }
              == vo["evidence"] as! [String],
              "V-O evidenceKeywords: keywords above 30% of the day's text frames are not evidence")
        check((vo["sparse"] as! [[Any]]).allSatisfy { PersonalityRefresh.ocrDayTooSparse($0[0] as! Int) == $0[1] as! Bool },
              "V-O ocrDayTooSparse: fewer than 50 text frames is a valid empty day")
    }

    private static let vectorA = #"""
{"tz_offset_min": -420,
 "catalog": [
  {"id": "2026-09-19/q.md", "occ": ["2026-09-19"]},
  {"id": "2026-09-22/b.md", "occ": ["2026-09-22"]},
  {"id": "2026-09-21/y.md", "occ": ["2026-09-21"]},
  {"id": "2026-09-23/c.md", "occ": ["2026-09-23"]},
  {"id": "2026-09-10/p.md", "occ": ["2026-09-10", "2026-09-21"]},
  {"id": "2026-09-22/a.md", "occ": ["2026-09-22"]},
  {"id": "2026-09-20/x.md", "occ": ["2026-09-20", "2026-09-22"]}],
 "cases": [
  {"note": "本地 09-22 23:30 至 09-23 00:40",
   "first_ms": 1790145000000, "last_ms": 1790149200000,
   "same_day": ["2026-09-23/c.md", "2026-09-20/x.md", "2026-09-22/a.md", "2026-09-22/b.md"],
   "past": ["2026-09-10/p.md", "2026-09-21/y.md", "2026-09-19/q.md"]},
  {"note": "本地 09-21 10:00 至 09-21 23:59:59.999",
   "first_ms": 1790010000000, "last_ms": 1790060399999,
   "same_day": ["2026-09-10/p.md", "2026-09-21/y.md"],
   "past": ["2026-09-23/c.md", "2026-09-20/x.md", "2026-09-22/a.md", "2026-09-22/b.md", "2026-09-19/q.md"]},
  {"note": "本地 09-21 22:00 至 09-22 00:00（最后一帧恰在零点）",
   "first_ms": 1790053200000, "last_ms": 1790060400000,
   "same_day": ["2026-09-20/x.md", "2026-09-22/a.md", "2026-09-22/b.md", "2026-09-10/p.md", "2026-09-21/y.md"],
   "past": ["2026-09-23/c.md", "2026-09-19/q.md"]}]}
"""#

    private static let vectorG = #"""
{"rows": [
  [1, "T1", 14, 1, "S", 0], [2, "T2", 7, 17, "P", 0], [3, "T3", 261, 27, "S", 0], [4, "T4", 20, 16, "S", 0],
  [5, "T5", 1, 6, "S", 0], [6, "T6", 1833, 7, "S", 0], [7, "T7", 4, 3, "S", 0], [8, "T4", 20, 42, "S", 0],
  [9, "T8", 11, 24, "S", 0], [10, "T1", 14, 4, "S", 0], [11, "T1", 14, 12, "S", 1], [12, "T2", 7, 3, "S", 0],
  [13, "T6", 1833, 4, "S", 0], [14, "T9", 243, 15, "S", 0], [15, "T6", 1833, 2, "S", 0], [16, "T8", 11, 6, "S", 0],
  [17, "T3", 261, 7, "S", 0], [18, "T10", 131, 10, "S", 0], [19, "T11", 62, 3, "P", 0], [20, "T4", 20, 4, "S", 0],
  [21, "T6", 1833, 1, "S", 0], [22, "T12", 26, 4, "S", 0], [23, "T13", 9, 12, "S", 0], [24, "T6", 1833, 3, "S", 0],
  [25, "T12", 26, 4, "S", 0], [26, "T14", 3, 2, "P", 0], [27, "T13", 9, 4, "S", 0], [28, "T15", 35149, 2, "P", 0],
  [29, "T13", 9, 2, "S", 0], [30, "T12", 26, 2, "S", 0], [31, "T5", 1, 34, "P", 1], [32, "T16", 708, 19, "P", 0],
  [33, "T6", 1833, 2, "P", 0], [34, "T17", 68, 3, "P", 0], [35, "T13", 9, 5, "P", 0], [36, "T15", 35149, 1, "P", 0],
  [37, "T6", 1833, 4, "P", 0], [38, "T10", 131, 61, "P", 0], [39, "T5", 1, 78, "P", 1], [40, "T3", 261, 18, "P", 1],
  [41, "T18", 601, 7, "P", 0], [42, "T15", 35149, 18, "S", 0]],
 "rejected": [31, 39],
 "single": [[7, 34, true], [1, 6, false], [7, 17, false], [3, 9, false], [3, 10, true], [4, 12, false], [4, 13, true]],
 "sequence": {"start": 5, "adds": [12, 40], "rejected": [false, false], "end": 57}}
"""#

    private static let vectorW = #"""
[{"body": "Line one.\nLine two with \\ backslash.\n\n**Derived from writing records:** [[wr:1]], [[wr:2]]",
  "prose": "Line one.\nLine two with \\ backslash.",
  "line": "Line one.\\nLine two with \\\\ backslash."},
 {"body": "No trailer here.\nSecond line.",
  "prose": "No trailer here.\nSecond line.",
  "line": "No trailer here.\\nSecond line."}]
"""#

    private static let vectorM = #"""
[["contact alice.w+tag@example.edu.", "contact [email]."],
 ["邮箱a_b@gmail.com，谢谢", "邮箱[email]，谢谢"],
 ["mailto:x@y.co.uk", "mailto:[email]"],
 ["A@B.COM", "[email]"],
 ["a@b-c.io", "[email]"],
 ["Email: a@b.com: done", "Email: [email]: done"],
 ["https://u:p@h.example.com/x", "https://u:[email]/x"],
 ["😀a@b.com", "😀[email]"],
 ["@Alice hi", "@Alice hi"],
 ["@MainActor", "@MainActor"],
 ["icon@2x.png", "icon@2x.png"],
 ["react@18.3.1", "react@18.3.1"],
 ["node@22", "node@22"],
 ["root@192.0.2.10", "root@192.0.2.10"],
 ["user@host", "user@host"],
 ["a@b.c", "a@b.c"],
 ["x@y.com2", "x@y.com2"],
 ["/tmp/a@b.log", "/tmp/a@b.log"],
 ["C:\\Users\\a@b.txt", "C:\\Users\\a@b.txt"],
 ["git@github.com:owner/repo.git", "git@github.com:owner/repo.git"],
 ["ssh alice@host.example.com:22", "ssh alice@host.example.com:22"],
 ["git@gitlab.example.com:group/repo.git", "git@gitlab.example.com:group/repo.git"]]
"""#

    private static let vectorO = #"""
{"total": 100,
 "keywords": ["nftables", "port", "claude"],
 "hits": {"nftables": 30, "port": 80, "claude": 31},
 "evidence": ["nftables"],
 "sparse": [[0, true], [49, true], [50, false]]}
"""#

    private static let vectorB = #"""
{"batch_apps": ["Editor"],
 "events": [
  {"name": "E1", "id": "2026-09-21/b.md", "last": "2026-09-21", "tags": ["notes"]},
  {"name": "E2", "id": "2026-09-21/a.md", "last": "2026-09-21", "tags": []},
  {"name": "E3", "id": "2026-09-20/z.md", "last": "2026-09-20", "tags": ["browser"]},
  {"name": "E4", "id": "2026-09-10/x.md", "last": "2026-09-10", "tags": ["Editor"]}],
 "rank": ["E4", "E2", "E1", "E3"],
 "catalog_order": ["E2", "E1", "E3", "E4"]}
"""#
}
