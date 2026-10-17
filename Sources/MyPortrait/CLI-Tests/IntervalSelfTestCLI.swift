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
/// 时间轴按日历日期显示。
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

    /// 假聚类:按 session 的 window 名查计划(title, join);没在计划里的 session 进 skipped。
    private static func clusterer(_ plan: [String: (title: String, join: String?)],
                                  fail: Bool = false) -> Backfill.Clusterer {
        { _, sessions, _ in
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
        let dbImpl = try PortraitDBImpl()
        let pool = dbImpl.dbPool
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

        check(sched.pendingIntervals(cap: 7).map(\.id) == [ivA.id, ivB.id, ivC.id, ivE.id],
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
        check(c3?.event == .pending && c3?.retryCount == 0, "C: Retry now → pending, retry 0")

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
        check(sched.stagesComplete(date: ivA.id, stages: [.raw, .event, .impact])
              && !sched.stagesComplete(date: ivE.id, stages: [.raw, .event, .impact]),
              "staged-run check reads interval rows")

        // —— UI:日历日期 ——
        let cal = Calendar(identifier: .gregorian)
        let shown = EventTimeline.calendarDay(day("2026-09-22"))
        check(cal.component(.day, from: shown) == 22 && cal.component(.hour, from: shown) == 0,
              "timeline shows 2026-09-22 as the 22nd in the local calendar")
    }
}
