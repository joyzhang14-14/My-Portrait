import Foundation
import CryptoKit
import Combine
import os.log

private let workerLog = Logger(subsystem: "com.myportrait.memory", category: "writing-worker")

// MARK: - 单日 Run 结果摘要

struct WritingCaptureDayRunSummary: Sendable {
    let date: String                 // 'YYYY-MM-DD' UTC
    let runId: String
    let status: WritingCaptureRunStatus
    let recordsCount: Int
    let discardedCount: Int
    let errorMessage: String?
}

// MARK: - UI 状态(跨 view 持久化,不随 sidebar 切换销毁)

/// 全局单例。Worker 跑 backlog/runDay 时更新这里,view 订阅。
/// 切换 sidebar 时 view 被销毁,但 state 在这里活着,回来时直接读。
@MainActor
final class WritingCaptureUIState: ObservableObject {
    static let shared = WritingCaptureUIState()
    @Published var isRunning: Bool = false
    @Published var stage: String = ""              // "Step 0" / "Pass 1" / "Pass 3 (3/5)" / "Saving"
    @Published var statusMessage: String = ""      // 给用户看的一行
    @Published var lastSummary: WritingCaptureDayRunSummary? = nil
    @Published var lastError: String? = nil
    /// 跑 backlog 的 Task 句柄 —— Stop 按钮 cancel 用。挂在单例上,view 切走
    /// 再回来 Stop 按钮仍可点(原本 @State 在 view 里,view 销毁后 task 句柄丢)。
    var task: Task<Void, Never>? = nil
    private init() {}
}

// MARK: - WritingCaptureWorker

/// 写作采集主 worker —— 串起 Step 0 / Pass 1 / Pass 3 / DB。
///
/// 测试期由 Settings → Scheduler 的 "Run now" 按钮调,跑「未处理的天」。
/// 输出落 `writing_records_staged`,等用户 Approve/Reject。
///
/// 详见 `canvas-editor-capture-design-final.md` §3.3 + §7。
@MainActor
final class WritingCaptureWorker {

    /// 全局单例,Services init 时填上。UI(MemorySettingsView)用这个引用。
    /// 同 MemoryScheduler.shared 模式,但延迟到 Services 初始化时才赋值
    /// (因为 worker 需要外部 DatabasePool)。
    static var shared: WritingCaptureWorker?

    let store: WritingCaptureStore
    /// pass1/pass3 在每次 runDay 重新构造 —— 这样用户在 Settings 改 provider
    /// 后下一次跑就用新的(写作采集用 LIGHT 模型档,跟 cluster 一档)。
    /// init 传入的 override 仍然优先(测试用)。
    private let pass1Override: WritingCapturePass1Agent?
    private let pass3Override: WritingCapturePass3Agent?

    init(
        store: WritingCaptureStore,
        pass1: WritingCapturePass1Agent? = nil,
        pass3: WritingCapturePass3Agent? = nil
    ) {
        self.store = store
        self.pass1Override = pass1
        self.pass3Override = pass3
    }

    private var pass1: WritingCapturePass1Agent {
        if let o = pass1Override { return o }
        let cfg = ConfigStore.shared.current.memory
        return WritingCapturePass1Agent(provider: cfg.resolvedProvider, model: cfg.resolvedModelLight)
    }
    private var pass3: WritingCapturePass3Agent {
        if let o = pass3Override { return o }
        let cfg = ConfigStore.shared.current.memory
        return WritingCapturePass3Agent(provider: cfg.resolvedProvider, model: cfg.resolvedModelLight)
    }

    /// 跑所有「未处理的天」。返回每天的执行摘要。
    /// 串行处理,一天一天跑 —— LLM 调用本来就慢,并发没意义。
    /// **过滤**:跳过当天 typing_events 为 0 的天 —— 纯 OCR 重建不可靠,
    /// 浪费 LLM token + 出来的多是幻觉。
    func runUnprocessedDays() async throws -> [WritingCaptureDayRunSummary] {
        let candidate = try await Task.detached(priority: .userInitiated) { [store] in
            try store.unprocessedDays()
        }.value
        let days = try await Task.detached(priority: .userInitiated) { [store] in
            candidate.filter { d in
                (try? store.hasTypingEvents(date: d)) == true
            }
        }.value
        let skipped = candidate.count - days.count

        workerLog.info("found \(candidate.count, privacy: .public) unprocessed days, \(days.count, privacy: .public) with typing (\(skipped, privacy: .public) skipped: no typing)")

        var summaries: [WritingCaptureDayRunSummary] = []
        for day in days {
            do {
                let s = try await runDay(date: day)
                summaries.append(s)
            } catch {
                workerLog.error("day \(day, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                summaries.append(WritingCaptureDayRunSummary(
                    date: day, runId: "", status: .failed,
                    recordsCount: 0, discardedCount: 0,
                    errorMessage: error.localizedDescription
                ))
            }
        }
        return summaries
    }

    /// 跑某一天。
    /// 失败时:writing_capture_runs.status = failed,raw 不删,下次重跑。
    func runDay(date: String) async throws -> WritingCaptureDayRunSummary {
        let runId = UUID().uuidString
        let startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

        try await Task.detached(priority: .userInitiated) { [store] in
            try store.upsertRunStatus(
                date: date, status: .processing,
                runId: runId, startedAt: startedAtMs
            )
        }.value

        let napGuard = AppNapGuard.acquire(reason: "Writing capture day run")
        defer { napGuard.release() }
        do {
            // App Nap 防护:Pass 1 + Pass 3 fanout 长任务,后台跑能拖到 10x。
            let summary = try await runDayCore(date: date, runId: runId)
            return summary
        } catch {
            let msg = error.localizedDescription
            try? await Task.detached(priority: .userInitiated) { [store] in
                try store.upsertRunStatus(
                    date: date, status: .failed,
                    completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    errorMessage: msg
                )
            }.value
            throw error
        }
    }

    /// 真实业务流程 —— 出错 throw 给上层标 failed。
    private func runDayCore(date: String, runId: String) async throws -> WritingCaptureDayRunSummary {
        // 黑名单 snapshot(同步打字采集那套配置)
        // keystroke_log 表行没 URL,只能按 bundle_id 屏蔽 —— 从 entries 里抽
        // 整 app 屏蔽的(urlPrefix 空)。URL-level entries 已在 TypingRecordWriter
        // 写入时拦住,typing_events 表里直接就没那些行。
        let entries = ConfigStore.shared.privacy.typingBlacklistEntries
        let userBlacklist = entries.compactMap { $0.urlPrefix.isEmpty ? $0.bundleId : nil }
        let hardcoded = TypingPrivacyFilter.defaultBlacklist
        let blacklist = Set(hardcoded).union(userBlacklist)

        // 1. 读 raw(后台)
        let raw = try await Task.detached(priority: .userInitiated) { [store] in
            let typing = try store.typingEventsForDay(date)
            let keys = try store.keystrokesForDay(date, excludeBundleIds: blacklist)
            let frames = try store.framesForDay(date)
            return (typing: typing, keys: keys, frames: frames)
        }.value

        workerLog.info("date=\(date, privacy: .public) raw: typing=\(raw.typing.count) keys=\(raw.keys.count) frames=\(raw.frames.count)")

        // 2. Step 0 算法预压缩
        let step0 = WritingCaptureStep0.preprocess(
            typingEvents: raw.typing,
            keystrokes: raw.keys,
            rawOcrFrames: raw.frames
        )
        workerLog.info("step0: \(step0.rawSessions.count) sessions, \(step0.throwawaySessions.count) throwaway")

        // 没 sessions → 整天 noop(直接标 approved 空数据,避免下次重跑)
        if step0.rawSessions.isEmpty {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.upsertRunStatus(
                    date: date, status: .approved,
                    completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    discardedCount: step0.throwawaySessions.count,
                    recordsCount: 0
                )
            }.value
            return WritingCaptureDayRunSummary(
                date: date, runId: runId, status: .approved,
                recordsCount: 0, discardedCount: step0.throwawaySessions.count,
                errorMessage: nil
            )
        }

        // 3. Pass 1 —— 整天 OCR 抽 context timeline
        // 单帧 cap 决策 per session:AX 数 *10 < typing event 数 时,该 session
        // OCR 不截字(AX 对该 session 几乎没拿到数据,OCR 是唯一来源)。
        let pass1OcrFrames = step0.rawSessions.flatMap { s -> [WritingCaptureOcrFrame] in
            let unlimited = s.axFrameCount * 10 < s.typingEvents.count
            let cap = unlimited ? Int.max : WritingCapturePass1Agent.pass1OcrTextMaxChars
            return s.ocrFrames.map { f in
                guard f.text.count > cap else { return f }
                return WritingCaptureOcrFrame(
                    frameId: f.frameId,
                    startTs: f.startTs, endTs: f.endTs,
                    app: f.app, url: f.url, windowTitle: f.windowTitle,
                    text: String(f.text.prefix(cap))
                )
            }
        }.sorted(by: { $0.startTs < $1.startTs })
        // Pass 1 也喂 raw.typing + raw.keys 当 cross-signal,帮 LLM 区分
        // "用户在打字" vs "用户在看东西"
        let probePrompt = WritingCapturePass1Agent.buildPrompt(
            ocrFrames: pass1OcrFrames,
            typingEvents: raw.typing,
            keystrokes: raw.keys
        )
        try? probePrompt.write(
            toFile: "/tmp/writing-capture-pass1-prompt.txt",
            atomically: false, encoding: .utf8)
        workerLog.info("pass1 prompt: \(probePrompt.count, privacy: .public) chars, dumped /tmp/writing-capture-pass1-prompt.txt")
        let pass1Out = try await pass1.run(
            ocrFrames: pass1OcrFrames,
            typingEvents: raw.typing,
            keystrokes: raw.keys
        )
        workerLog.info("pass1: \(pass1Out.timeline.count) context segments")

        let pass3Cfg = ConfigStore.shared.current.memory
        let pass3Provider = pass3Cfg.resolvedProvider
        let pass3Model = pass3Cfg.resolvedModelLight

        // 3.5 Pass 2 —— 路由(AX vs OCR)+ 切割 + AX 真伪。判断活,轻量模型。
        // 关键作用:chat app(Discord/微信等)真内容在 AX/keystroke,Pass 2 把它们
        // 留在 AX 路,不让 Step 0 粗启发式误送进 OCR canvas → 避免 OCR 整屏桌面垃圾。
        let routedSessions = await Self.applyPass2(
            step0.rawSessions, concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent(provider: pass3Provider, model: pass3Model) })
        // pass2-2:确定性消息切分(按 typing_event,不用 LLM、不丢 event)。
        let refinedSessions = Self.applyPass2Segment(routedSessions)
        workerLog.info("pass2: \(step0.rawSessions.count) sessions → route \(routedSessions.count) → segment \(refinedSessions.count) units")

        // 4. 按 (app, url) 分组(不真合,LLM 在组内决定怎么分 record)
        let groups = Self.groupRawSessionsByApp(refinedSessions)
        workerLog.info("grouped by app+url: \(refinedSessions.count) sessions → \(groups.count) groups")

        // 5. **每组一个 subagent 并发跑 Pass 3**(默认 sonnet)。
        // 失败 group 单独标错,不阻塞其他 group。最多 5 并发,防止 Anthropic
        // 限流 + 本机 CPU 打爆。每个并发任务都创建一个全新的 Pass3Agent,
        // 不复用(每 agent 有 subprocess 状态)。
        let userLanguages = ConfigStore.shared.current.personalInfo.languages
        let userRejections = (try? await Task.detached(priority: .userInitiated) { [store] in
            try store.fetchRecentUserRejections()
        }.value) ?? []
        let pass3Results = await Self.runPass3Concurrently(
            contextTimeline: pass1Out.timeline,
            groups: groups,
            concurrency: 5,
            makePass3: { @MainActor in WritingCapturePass3Agent(provider: pass3Provider, model: pass3Model) },
            makeCanvas: { @MainActor in WritingCaptureCanvasAgent(provider: pass3Provider, model: pass3Model) },
            userLanguages: userLanguages,
            userRejections: userRejections
        )

        // 6. 收集 Pass 3 输出(按 group 索引保留分组),给 Pass 4 用
        var recordsByGroupIdx: [[WritingCaptureRecord]] = []
        var failedGroups = 0
        var firstError: String?
        var rawResponses: [String] = []
        var firstPrompt: String?
        for r in pass3Results {
            switch r {
            case .success(let out):
                recordsByGroupIdx.append(out.records)
                rawResponses.append(out.rawResponse)
                if firstPrompt == nil { firstPrompt = out.prompt }
            case .failure(let err):
                recordsByGroupIdx.append([])
                failedGroups += 1
                let desc = (err as? LocalizedError)?.errorDescription ?? String(describing: err)
                if firstError == nil { firstError = desc }
                workerLog.warning("pass3 group failed: \(desc, privacy: .public)")
            }
        }
        let pass3Total = recordsByGroupIdx.reduce(0) { $0 + $1.count }
        workerLog.info("pass3 fanout: \(pass3Total) records, \(failedGroups) failed groups")

        // Pass 3 group 失败 = 那个 (app,url) 时间窗的写作数据被吞空。若放任,
        // 这天照常进 pending_review → approve 后标 'approved' → unprocessedDays
        // 不再返回这天(store:80) → 这段 raw 永不重跑 = 永久丢。故失败即整次 abort:
        // catch 标 'failed'('failed' 会被 unprocessedDays 重新捞起,raw 不删,下次重跑)。
        // Pass 4 / Pass 2 失败是 fail-open(保留记录),不在此列。
        if failedGroups > 0 {
            throw BacklogError.pass3GroupsFailed(count: failedGroups, sample: firstError ?? "unknown")
        }

        // 6a. edit_log 重建 + authoring 过滤(确定性):ax edit_log 从 typing_events
        // 补全;没有 commit/delete 的(粘贴/OCR/AI)直接丢。
        let editLogFilter = Self.refineAndFilterByEditLog(recordsByGroupIdx, typing: raw.typing, keys: raw.keys)
        recordsByGroupIdx = editLogFilter.records
        let editLogDropped = editLogFilter.dropped
        workerLog.info("editlog filter: dropped \(editLogDropped.count) non-authored records")

        // 6b. Pass 4 —— keystroke 支撑度过滤(每组一次,跟 Pass 3 同 provider/model)
        let pass4Inputs = recordsByGroupIdx.enumerated().map { (gi, recs) in
            recs.enumerated().map { (ri, rec) in
                WritingCapturePass4Builders.buildInput(recordId: "g\(gi)_r\(ri)", record: rec)
            }
        }
        let pass4Results = await WritingCapturePass4Builders.runConcurrently(
            inputsByGroupIdx: pass4Inputs,
            concurrency: 5,
            userRejections: userRejections,
            makePass4: { @MainActor in WritingCapturePass4Agent(provider: pass3Provider, model: pass3Model) }
        )
        var allRecords: [WritingCaptureRecord] = []
        var allDiscarded: [WritingCaptureDiscarded] = editLogDropped
        var pass4RawResponses: [String] = []
        var pass4FailedGroups = 0
        for (gi, recs) in recordsByGroupIdx.enumerated() {
            switch pass4Results[gi] {
            case .success(let out):
                pass4RawResponses.append(out.rawResponse)
                for (ri, rec) in recs.enumerated() {
                    let id = "g\(gi)_r\(ri)"
                    if out.kept.contains(id) { allRecords.append(rec) }
                }
                for d in out.discarded {
                    allDiscarded.append(WritingCaptureDiscarded(
                        reason: "pass4: \(d.reason)",
                        sessionIds: [],
                        preview: d.preview
                    ))
                }
            case .failure(let err):
                pass4FailedGroups += 1
                workerLog.warning("pass4 group failed: \(String(describing: err), privacy: .public) — keeping all records for this group")
                allRecords.append(contentsOf: recs)
            }
        }
        workerLog.info("pass4 fanout: \(allRecords.count) kept, \(allDiscarded.count) discarded, \(pass4FailedGroups) failed groups")

        // 7. 落 staged + discarded
        let promptId = Self.promptIdHash(
            pass1: pass1Out.prompt, pass3: firstPrompt ?? ""
        )
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.insertStaged(
                date: date,
                runId: runId,
                promptId: promptId,
                records: allRecords,
                rawPass1Output: pass1Out.rawResponse,
                rawPass3Output: rawResponses.joined(separator: "\n---\n")
            )
            try store.insertStagedDiscarded(
                date: date, runId: runId, discarded: allDiscarded
            )
        }.value

        // 8. 标 pending_review
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.upsertRunStatus(
                date: date, status: .pendingReview,
                completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                discardedCount: allDiscarded.count,
                recordsCount: allRecords.count
            )
        }.value

        return WritingCaptureDayRunSummary(
            date: date, runId: runId, status: .pendingReview,
            recordsCount: allRecords.count,
            discardedCount: allDiscarded.count,
            errorMessage: nil
        )
    }

    // MARK: - Backlog mode(v27) —— 不按天分,从 cursor 跑到现在

    /// backlog 模式的固定 date_utc key —— 复用 writing_capture_runs 表 schema,
    /// 不用 'YYYY-MM-DD' 而是常量 'all'。staged / discarded / runs 全用这个 key。
    nonisolated static let backlogDateKey = "all"

    /// 跑一次 backlog:cursor → now。
    /// approve 后 cursor 推进,reject 不动 cursor。
    /// **防重复**:已有 pending_review 或 processing 状态时拒绝重跑,要求先
    /// approve/reject。避免用户忘了 review 又点一次 → 上次 LLM 输出被清重跑。
    enum BacklogError: LocalizedError {
        case pendingReviewExists(records: Int)
        case alreadyProcessing
        case pass3GroupsFailed(count: Int, sample: String)
        var errorDescription: String? {
            switch self {
            case .pendingReviewExists(let n):
                return "Backlog already has \(n) record(s) pending review. " +
                       "Approve or reject them first before running again."
            case .alreadyProcessing:
                return "Backlog run already in progress. Wait for it to finish."
            case .pass3GroupsFailed(let n, let sample):
                return "\(n) Pass 3 group(s) failed: \(sample). " +
                       "Run aborted so no data window is skipped — try again."
            }
        }
    }

    /// backlog 现在有没有活 —— cursor 之后有没有未处理的 typing_event。
    /// UI 拿来灰 Run 按钮。
    func backlogHasWork() async -> Bool {
        await Task.detached(priority: .userInitiated) { [store] in
            let cursor = (try? store.getCursor()) ?? 0
            return (try? store.hasTypingEventsAfter(cursor: cursor)) ?? false
        }.value
    }

    func runBacklog(includeAxText: Bool = true) async throws -> WritingCaptureDayRunSummary {
        let runId = UUID().uuidString
        let startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ui = WritingCaptureUIState.shared
        ui.isRunning = true
        ui.stage = "starting"
        ui.statusMessage = "Backlog run starting…"
        ui.lastError = nil
        defer {
            ui.isRunning = false
            ui.stage = ""
        }

        // 防重复触发:当前状态如果是 pending_review / processing,拒绝重跑
        let existing = try await Task.detached(priority: .userInitiated) { [store] in
            try store.fetchRun(date: Self.backlogDateKey)
        }.value
        if let r = existing {
            switch r.status {
            case WritingCaptureRunStatus.pendingReview.rawValue:
                throw BacklogError.pendingReviewExists(records: r.recordsCount ?? 0)
            case WritingCaptureRunStatus.processing.rawValue:
                throw BacklogError.alreadyProcessing
            default:
                break  // approved / rejected / failed → 允许重跑
            }
        }

        // cursor:上次 approve 处理到的 max ts(exclusive)。
        // 首次跑(cursor=0)从**第一条 typing_event 的 ts** 开始 —— 没 typing 的
        // 历史天纯 OCR 重建意义不大,白烧 token。
        let (cursor, startMs) = try await Task.detached(priority: .userInitiated) { [store] in
            let c = try store.getCursor()
            if c > 0 { return (c, c) }
            let first = (try? store.firstTypingEventTs()) ?? nil
            return (c, first ?? 0)
        }.value
        let endMs = Int64(Date().timeIntervalSince1970 * 1000)
        workerLog.info("backlog: cursor=\(cursor, privacy: .public), startMs=\(startMs, privacy: .public)")
        // 跑之前清 staged(approved / failed / rejected 状态下的残留),
        // 上一步 gate 已经挡掉 pending_review,这里安全。
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.clearStaged(date: Self.backlogDateKey)
            try store.upsertRunStatus(
                date: Self.backlogDateKey, status: .processing,
                runId: runId, startedAt: startedAtMs
            )
        }.value

        let napGuard = AppNapGuard.acquire(reason: "Writing capture backlog")
        defer { napGuard.release() }
        do {
            // App Nap 防护:backlog 跑全历史时间窗,LLM fanout 可能跑几分钟。
            let summary = try await runBacklogCore(
                runId: runId, startMs: startMs, endMs: endMs,
                includeAxText: includeAxText
            )
            ui.lastSummary = summary
            ui.stage = "done"
            ui.statusMessage = summary.status == .pendingReview
                ? "Done — \(summary.recordsCount) record(s) staged, \(summary.discardedCount) discarded. Review below."
                : "Status: \(summary.status.rawValue)"
            return summary
        } catch {
            let msg = error.localizedDescription
            ui.lastError = msg
            ui.statusMessage = "Failed: \(msg)"
            try? await Task.detached(priority: .userInitiated) { [store] in
                try store.upsertRunStatus(
                    date: Self.backlogDateKey, status: .failed,
                    completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    errorMessage: msg
                )
            }.value
            throw error
        }
    }

    private func runBacklogCore(
        runId: String, startMs: Int64, endMs: Int64,
        includeAxText: Bool = true
    ) async throws -> WritingCaptureDayRunSummary {
        let date = Self.backlogDateKey
        let ui = WritingCaptureUIState.shared
        // keystroke_log 表行没 URL,只能按 bundle_id 屏蔽 —— 从 entries 里抽
        // 整 app 屏蔽的(urlPrefix 空)。URL-level entries 已在 TypingRecordWriter
        // 写入时拦住,typing_events 表里直接就没那些行。
        let entries = ConfigStore.shared.privacy.typingBlacklistEntries
        let userBlacklist = entries.compactMap { $0.urlPrefix.isEmpty ? $0.bundleId : nil }
        let hardcoded = TypingPrivacyFilter.defaultBlacklist
        let blacklist = Set(hardcoded).union(userBlacklist)

        ui.stage = "reading raw"
        ui.statusMessage = "Reading typing / keystrokes / OCR frames…"
        // 1. 读 raw —— 全范围(startMs, endMs)
        let raw = try await Task.detached(priority: .userInitiated) { [store] in
            let typing = try store.typingEventsInRange(startMs: startMs, endMs: endMs)
            let keys = try store.keystrokesInRange(
                startMs: startMs, endMs: endMs, excludeBundleIds: blacklist
            )
            let frames = try store.framesInRange(startMs: startMs, endMs: endMs)
            return (typing: typing, keys: keys, frames: frames)
        }.value
        workerLog.info("backlog range=[\(startMs, privacy: .public), \(endMs, privacy: .public)) raw: typing=\(raw.typing.count) keys=\(raw.keys.count) frames=\(raw.frames.count)")

        ui.stage = "Step 0"
        ui.statusMessage = "Step 0: segmenting sessions and dedup OCR…"
        // 2. Step 0
        let step0 = WritingCaptureStep0.preprocess(
            typingEvents: raw.typing, keystrokes: raw.keys, rawOcrFrames: raw.frames
        )
        workerLog.info("step0: \(step0.rawSessions.count) sessions, \(step0.throwawaySessions.count) throwaway")

        // 没 sessions → 没东西可 review,直接标 approved 空 + 推进 cursor
        if step0.rawSessions.isEmpty {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.setCursor(endMs)
                try store.upsertRunStatus(
                    date: date, status: .approved,
                    completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    discardedCount: step0.throwawaySessions.count, recordsCount: 0
                )
            }.value
            return WritingCaptureDayRunSummary(
                date: date, runId: runId, status: .approved,
                recordsCount: 0, discardedCount: step0.throwawaySessions.count,
                errorMessage: nil
            )
        }

        // 3. Pass 1
        let allOcrFrames = step0.rawSessions.flatMap { $0.ocrFrames }
            .sorted(by: { $0.startTs < $1.startTs })
        // per-session ocrFrames 数 + 总和(诊断"OCR 喂量"用)
        let perSessionFrames = step0.rawSessions.map { $0.ocrFrames.count }
        let frameSum = perSessionFrames.reduce(0, +)
        let frameMax = perSessionFrames.max() ?? 0
        let frameDist = perSessionFrames.sorted(by: >).prefix(5).map(String.init).joined(separator: ",")
        workerLog.info("ocr/session: sum=\(frameSum, privacy: .public) max=\(frameMax, privacy: .public) top5=[\(frameDist, privacy: .public)] sessions=\(step0.rawSessions.count, privacy: .public)")
        let probePrompt = WritingCapturePass1Agent.buildPrompt(
            ocrFrames: allOcrFrames,
            typingEvents: raw.typing,
            keystrokes: raw.keys
        )
        try? probePrompt.write(
            toFile: "/tmp/writing-capture-pass1-prompt.txt",
            atomically: false, encoding: .utf8)
        workerLog.info("pass1 prompt: \(probePrompt.count, privacy: .public) chars")
        ui.stage = "Pass 1"
        ui.statusMessage = "Pass 1: extracting context timeline (\(allOcrFrames.count) OCR frames)…"
        let pass1Out = try await pass1.run(
            ocrFrames: allOcrFrames,
            typingEvents: raw.typing,
            keystrokes: raw.keys
        )
        workerLog.info("pass1: \(pass1Out.timeline.count) context segments")

        let pass3Cfg = ConfigStore.shared.current.memory
        let pass3Provider = pass3Cfg.resolvedProvider
        let pass3Model = pass3Cfg.resolvedModelLight

        // 3.5 Pass 2 —— 路由(AX vs OCR)+ 切割 + AX 真伪。判断活,轻量模型。
        // chat app(Discord/微信等)短消息真内容在 AX/keystroke,Pass 2 把它们留在
        // AX 路并按消息切,不让 Step 0 粗启发式误送进 OCR canvas(否则 OCR 整屏桌面)。
        ui.stage = "Pass 2"
        ui.statusMessage = "Pass 2: routing \(step0.rawSessions.count) sessions (AX vs OCR)…"
        let routedSessions = await Self.applyPass2(
            step0.rawSessions, concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent(provider: pass3Provider, model: pass3Model) })
        // pass2-2:确定性消息切分(按 typing_event,不用 LLM、不丢 event)。
        let refinedSessions = Self.applyPass2Segment(routedSessions)
        workerLog.info("pass2: \(step0.rawSessions.count) sessions → route \(routedSessions.count) → segment \(refinedSessions.count) units")

        // 4. group + 5. Pass 3 并发
        let groups = Self.groupRawSessionsByApp(refinedSessions)
        ui.stage = "Pass 3"
        ui.statusMessage = "Pass 3: \(groups.count) (app, url) groups — running concurrently (max 5)…"
        workerLog.info("grouped by app+url: \(refinedSessions.count) sessions → \(groups.count) groups")
        let userLanguages = ConfigStore.shared.current.personalInfo.languages
        let userRejections = (try? await Task.detached(priority: .userInitiated) { [store] in
            try store.fetchRecentUserRejections()
        }.value) ?? []
        if !userRejections.isEmpty {
            workerLog.info("user_rejections: \(userRejections.count) examples fed to Pass 3")
        }
        let pass3Results = await Self.runPass3Concurrently(
            contextTimeline: pass1Out.timeline, groups: groups, concurrency: 5,
            makePass3: { @MainActor in WritingCapturePass3Agent(provider: pass3Provider, model: pass3Model) },
            makeCanvas: { @MainActor in WritingCaptureCanvasAgent(provider: pass3Provider, model: pass3Model) },
            includeAxText: includeAxText,
            userLanguages: userLanguages,
            userRejections: userRejections
        )

        // 6. 收集 Pass 3 输出(按 group 索引保留)
        var recordsByGroupIdx: [[WritingCaptureRecord]] = []
        var failedGroups = 0
        var firstError: String?
        var rawResponses: [String] = []
        var firstPrompt: String?
        for r in pass3Results {
            switch r {
            case .success(let out):
                recordsByGroupIdx.append(out.records)
                rawResponses.append(out.rawResponse)
                if firstPrompt == nil { firstPrompt = out.prompt }
            case .failure(let err):
                recordsByGroupIdx.append([])
                failedGroups += 1
                let desc = (err as? LocalizedError)?.errorDescription ?? String(describing: err)
                if firstError == nil { firstError = desc }
                workerLog.warning("pass3 group failed: \(desc, privacy: .public)")
            }
        }
        let pass3Total = recordsByGroupIdx.reduce(0) { $0 + $1.count }
        workerLog.info("pass3 fanout: \(pass3Total) records, \(failedGroups) failed groups")

        // Pass 3 group 失败 = 那个 (app,url) 时间窗的写作数据被吞空。若放任,
        // approve 会无条件把 cursor 推过整个窗(approveBacklog setCursor) → 这段 raw
        // 永不重跑 = 永久丢。故失败即整次 abort:catch 标 'failed'、不进 pending_review、
        // cursor 不动,下次同范围重跑(raw 不删)。Pass 4 / Pass 2 失败 fail-open,不在此列。
        if failedGroups > 0 {
            throw BacklogError.pass3GroupsFailed(count: failedGroups, sample: firstError ?? "unknown")
        }

        // 6a. edit_log 重建 + authoring 过滤(确定性)
        let editLogFilter = Self.refineAndFilterByEditLog(recordsByGroupIdx, typing: raw.typing, keys: raw.keys)
        recordsByGroupIdx = editLogFilter.records
        let editLogDropped = editLogFilter.dropped
        workerLog.info("editlog filter: dropped \(editLogDropped.count) non-authored records")

        // 6b. Pass 4
        ui.stage = "Pass 4"
        ui.statusMessage = "Pass 4: validating \(pass3Total) candidate record(s)…"
        let pass4Inputs = recordsByGroupIdx.enumerated().map { (gi, recs) in
            recs.enumerated().map { (ri, rec) in
                WritingCapturePass4Builders.buildInput(recordId: "g\(gi)_r\(ri)", record: rec)
            }
        }
        let pass4Results = await WritingCapturePass4Builders.runConcurrently(
            inputsByGroupIdx: pass4Inputs,
            concurrency: 5,
            userRejections: userRejections,
            makePass4: { @MainActor in WritingCapturePass4Agent(provider: pass3Provider, model: pass3Model) }
        )
        var allRecords: [WritingCaptureRecord] = []
        var allDiscarded: [WritingCaptureDiscarded] = editLogDropped
        var pass4FailedGroups = 0
        for (gi, recs) in recordsByGroupIdx.enumerated() {
            switch pass4Results[gi] {
            case .success(let out):
                for (ri, rec) in recs.enumerated() {
                    let id = "g\(gi)_r\(ri)"
                    if out.kept.contains(id) { allRecords.append(rec) }
                }
                for d in out.discarded {
                    allDiscarded.append(WritingCaptureDiscarded(
                        reason: "pass4: \(d.reason)",
                        sessionIds: [],
                        preview: d.preview
                    ))
                }
            case .failure(let err):
                pass4FailedGroups += 1
                workerLog.warning("pass4 group failed: \(String(describing: err), privacy: .public) — keeping all records for this group")
                allRecords.append(contentsOf: recs)
            }
        }
        workerLog.info("pass4 fanout: \(allRecords.count) kept, \(allDiscarded.count) discarded, \(pass4FailedGroups) failed groups")
        ui.stage = "saving"
        ui.statusMessage = "Saving \(allRecords.count) record(s), \(allDiscarded.count) discarded…"

        // 7. stage
        let promptId = Self.promptIdHash(pass1: pass1Out.prompt, pass3: firstPrompt ?? "")
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.insertStaged(
                date: date, runId: runId, promptId: promptId,
                records: allRecords,
                rawPass1Output: pass1Out.rawResponse,
                rawPass3Output: rawResponses.joined(separator: "\n---\n")
            )
            try store.insertStagedDiscarded(date: date, runId: runId, discarded: allDiscarded)
        }.value

        // 8. pending_review。**完成时刻 = endMs**,approve 时把 cursor 推进到这。
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.upsertRunStatus(
                date: date, status: .pendingReview,
                completedAt: endMs,   // 复用 completed_at 编码 range_end
                discardedCount: allDiscarded.count, recordsCount: allRecords.count
            )
        }.value

        return WritingCaptureDayRunSummary(
            date: date, runId: runId, status: .pendingReview,
            recordsCount: allRecords.count, discardedCount: allDiscarded.count,
            errorMessage: nil
        )
    }

    /// approve backlog:拷 staged → writing_records,推进 cursor,清 staged。
    func approveBacklog() async throws -> Int {
        return try await Task.detached(priority: .userInitiated) { [store] in
            // cursor 推进到本次 run 的 endMs(存在 runs.completed_at)
            let endMs = (try? store.fetchRunCompletedAt(date: Self.backlogDateKey)) ?? Int64(Date().timeIntervalSince1970 * 1000)
            let copied = try store.approveStaged(date: Self.backlogDateKey)
            try store.setCursor(endMs)
            return copied
        }.value
    }

    /// reject backlog:清 staged,cursor 不动(下次 run 同样范围重跑)。
    func rejectBacklog() async throws {
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.clearStaged(date: Self.backlogDateKey)
            try store.upsertRunStatus(
                date: Self.backlogDateKey, status: .rejectedForRerun,
                completedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }.value
    }

    // MARK: - Approve / Reject

    /// 用户在 Pending review 里点 Approve。
    /// staged → writing_records,该天 runs.status = approved。
    func approveDay(date: String) async throws -> Int {
        return try await Task.detached(priority: .userInitiated) { [store] in
            try store.approveStaged(date: date)
        }.value
    }

    /// 用户在 Pending review 里点 Reject。
    /// 清 staged,该天 runs.status = rejected_for_rerun(下次 Run 重跑)。
    func rejectDay(date: String) async throws {
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.clearStaged(date: date)
            try store.upsertRunStatus(
                date: date, status: .rejectedForRerun,
                completedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }.value
    }

    // MARK: - prompt id

    /// 按 (app, url) **分组**(不合)。Pass 3 LLM 在 group 内自己决定切多少 record。
    /// 跟 mergeRawSessionsByApp 的区别:这里保留每个 session 独立结构,LLM 可以
    /// 把 session 拆成多个 short_form record(聊天连发多条)。
    struct WritingCaptureGroup: Sendable {
        let app: String
        let url: String?
        let sessions: [WritingCaptureRawSession]
    }

    static func groupRawSessionsByApp(
        _ sessions: [WritingCaptureRawSession]
    ) -> [WritingCaptureGroup] {
        struct Key: Hashable { let app: String; let url: String }
        var groups: [Key: [WritingCaptureRawSession]] = [:]
        var keyOrder: [Key] = []
        for s in sessions {
            let k = Key(app: s.app, url: s.url ?? "")
            if groups[k] == nil { keyOrder.append(k) }
            groups[k, default: []].append(s)
        }
        return keyOrder.compactMap { k in
            guard let members = groups[k] else { return nil }
            return WritingCaptureGroup(
                app: k.app,
                url: k.url.isEmpty ? nil : k.url,
                sessions: members.sorted(by: { $0.startTs < $1.startTs })
            )
        }
    }

    /// Pass 2 —— 切割 + AX 真伪判断,把非 canvas session 重建成"一单元一 session"。
    /// canvas session(chromeTokens 非空)/ 无 typing_events 的 → 原样直通。
    /// 并发限 `concurrency`。LLM 失败 fallback:该 session 原样保留。
    static func applyPass2(
        _ sessions: [WritingCaptureRawSession],
        concurrency: Int,
        makePass2: @escaping @MainActor @Sendable () -> WritingCapturePass2Agent
    ) async -> [WritingCaptureRawSession] {
        // 需要判的:有 typing_events 的 session(无论 Step 0 有没有 canvas 标记)。
        // —— Pass 2 用三源做 session 级判断:真内容在 AX(ax,按消息切)还是 OCR
        // (ocr,整 session 走重建)。这取代 Step 0 死检测的路由作用。
        let needJudge = sessions.enumerated().filter { !$0.element.typingEvents.isEmpty }
        @Sendable func judge(_ idx: Int) async -> (Int, [WritingCaptureRawSession]) {
            let s = sessions[idx]
            let agent = await makePass2()
            let result = (try? await agent.run(session: s))
                ?? WritingCapturePass2Agent.Result(
                    primarySource: "ax",
                    units: s.typingEvents.compactMap { $0.id }.map { [$0] }, dropped: [])
            if result.primarySource == "ocr" {
                // 真内容在 OCR:整 session 走 CanvasAgent。确保带 chromeTokens +
                // 粗快照(Step 0 若没 canvas-prep 过,这里补)。
                let ocrSession = Self.ensureOcrPrepped(s)
                return (idx, [ocrSession])
            }
            // primary=ax:Pass 2 只做路由 —— 整 session 原样交给 Pass 3(route=ax,
            // chromeTokens 清空 → 走 Pass3Agent)。**不切单元、不丢 event**:切分/
            // 过滤交给 Pass 3 + 算法层闸门(之前在这里丢 event 把 Discord 短消息丢了)。
            return (idx, [Self.ensureAxRoute(s)])
        }
        var refinedByIdx: [Int: [WritingCaptureRawSession]] = [:]
        await withTaskGroup(of: (Int, [WritingCaptureRawSession]).self) { tg in
            var inFlight = 0, next = 0
            while inFlight < concurrency && next < needJudge.count {
                let idx = needJudge[next].offset; next += 1
                tg.addTask { await judge(idx) }; inFlight += 1
            }
            while let (idx, r) = await tg.next() {
                refinedByIdx[idx] = r; inFlight -= 1
                if next < needJudge.count {
                    let idx2 = needJudge[next].offset; next += 1
                    tg.addTask { await judge(idx2) }; inFlight += 1
                }
            }
        }
        // 重组:被判过的 session 替换成它的单元;其余原样。保持原顺序。
        var out: [WritingCaptureRawSession] = []
        for (i, s) in sessions.enumerated() {
            if let r = refinedByIdx[i] { out.append(contentsOf: r) } else { out.append(s) }
        }
        return out
    }

    /// 用 Pass 2 给的一组 event_ids 从原 session 重建一个 mini-session
    /// (保留这些 typing_events + 其合并时间窗 ±10s 内的 keystrokes / frames)。
    nonisolated static func rebuildUnitSession(
        from s: WritingCaptureRawSession, eventIds: [Int64]
    ) -> WritingCaptureRawSession? {
        let kept = s.typingEvents.filter { e in e.id.map { eventIds.contains($0) } ?? false }
        guard !kept.isEmpty else { return nil }
        let pad: Int64 = 10_000
        let lo = (kept.map(\.startedAt).min() ?? s.startTs) - pad
        let hi = (kept.map(\.endedAt).max() ?? s.endTs) + pad
        let keys = s.keystrokes.filter { $0.tsMs >= lo && $0.tsMs <= hi }
        let frames = s.ocrFrames.filter { $0.startTs >= lo && $0.endTs <= hi }
        let startTs = kept.map(\.startedAt).min() ?? s.startTs
        return WritingCaptureRawSession(
            id: makeUnitSessionId(startTs: startTs, app: s.app),
            app: s.app, url: s.url,
            startTs: startTs, endTs: kept.map(\.endedAt).max() ?? s.endTs,
            typingEvents: kept, keystrokes: keys, ocrFrames: frames,
            maxContentChars: max(kept.map { $0.text.count }.reduce(0, +),
                                 frames.map { $0.text.count }.max() ?? 0),
            axFrameCount: 0, chromeTokens: []
        )
    }

    /// pass2-2 —— 确定性消息切分(不用 LLM)。Pass 2 路由后,把 ax 路 session
    /// 按 typing_event(一条 = 一次 send/clear = 一条消息)切成多个单元,每个单元
    /// 带其 ±10s 内的 keystrokes/frames。**不丢任何 event**:每个 typing_event 都
    /// 进一个单元。ocr 路(canvas)整篇不切。无 typing_event 的 ax session 原样留
    /// (Pass 3 凭 keystroke/OCR 处理)。
    nonisolated static func applyPass2Segment(
        _ sessions: [WritingCaptureRawSession]
    ) -> [WritingCaptureRawSession] {
        var out: [WritingCaptureRawSession] = []
        // 按 typing_event id 全局去重 —— Step 0 偶发把同一段消息切进多个重叠
        // session,同一个 typing_event 会被切成多份。一个 event 只产一个单元。
        var seenEventIds = Set<Int64>()
        for s in sessions {
            if s.route == "ocr" || s.typingEvents.isEmpty {
                out.append(s)
                continue
            }
            var units: [WritingCaptureRawSession] = []
            for ev in s.typingEvents {
                guard let id = ev.id, !seenEventIds.contains(id) else { continue }
                seenEventIds.insert(id)
                if let unit = Self.rebuildUnitSession(from: s, eventIds: [id]) {
                    units.append(unit)
                }
            }
            // 整 session 的 event 都已在别处出过 → 这个 session 不再重复产单元。
            if units.isEmpty, s.typingEvents.allSatisfy({ $0.id == nil }) {
                out.append(s)
            } else {
                out.append(contentsOf: units)
            }
        }
        return out
    }

    /// 把一个 session 标成走 AX 路径(route="ax" → dispatch 去 Pass3Agent)。
    /// 整 session 原样保留(typingEvents/keystrokes/ocrFrames 都给 Pass 3),
    /// 只清 chromeTokens(canvas hint)并定 route=ax。Pass 2 路由用。
    nonisolated static func ensureAxRoute(
        _ s: WritingCaptureRawSession
    ) -> WritingCaptureRawSession {
        WritingCaptureRawSession(
            id: s.id, app: s.app, url: s.url, startTs: s.startTs, endTs: s.endTs,
            typingEvents: s.typingEvents, keystrokes: s.keystrokes, ocrFrames: s.ocrFrames,
            maxContentChars: s.maxContentChars, axFrameCount: s.axFrameCount,
            chromeTokens: [], route: "ax")
    }

    /// 把一个 session 标成走 OCR 路径(route="ocr" → dispatch 去 CanvasAgent)。
    /// chromeTokens 仅作 hint:已有则留,没有则从帧补算(自适应频率,非写死)。
    /// typingEvents 清空(OCR 路径不用 AX)。
    nonisolated static func ensureOcrPrepped(
        _ s: WritingCaptureRawSession
    ) -> WritingCaptureRawSession {
        let tokens = s.chromeTokens.isEmpty
            ? CanvasFrameCleaner.chromeTokens(s.ocrFrames.map { f in
                WritingCaptureRawOcr(id: f.frameId, tsMs: f.startTs, app: f.app, url: f.url,
                                     windowTitle: f.windowTitle, text: f.text, textSource: "ocr") })
            : s.chromeTokens
        return WritingCaptureRawSession(
            id: s.id, app: s.app, url: s.url, startTs: s.startTs, endTs: s.endTs,
            typingEvents: [], keystrokes: s.keystrokes, ocrFrames: s.ocrFrames,
            maxContentChars: s.maxContentChars, axFrameCount: s.axFrameCount,
            chromeTokens: tokens, route: "ocr")
    }

    nonisolated static func makeUnitSessionId(startTs: Int64, app: String) -> String {
        "unit_" + String(format: "%llx", UInt64(bitPattern: startTs &* 31 &+ Int64(app.hashValue & 0xffff)))
    }

    /// 并发跑多 group 的 Pass 3 —— 默认 sonnet subagent 一组一个。
    /// 限流 `concurrency` 道闸,防止瞬间 spawn 30 个 claude 子进程。
    enum Pass3GroupResult {
        case success(WritingCapturePass3Agent.Output)
        case failure(Error)
    }
    static func runPass3Concurrently(
        contextTimeline: [WritingCaptureContextSegment],
        groups: [WritingCaptureGroup],
        concurrency: Int,
        makePass3: @escaping @MainActor @Sendable () -> WritingCapturePass3Agent,
        makeCanvas: @escaping @MainActor @Sendable () -> WritingCaptureCanvasAgent,
        includeAxText: Bool = true,
        userLanguages: [String] = [],
        userRejections: [UserRejectionRow] = []
    ) async -> [Pass3GroupResult] {
        // 单组执行:canvas 组(有 chromeTokens 的 AX 稀疏文档)走 window 切分
        // fanout;普通组走 Pass 3 单调用。LLM 偶发 socket 断/超时常见,失败退避
        // 重试最多 3 次(吸收瞬时错误);重试还失败才算 group failure。
        @Sendable func runOnce(_ g: WritingCaptureGroup) async throws -> WritingCapturePass3Agent.Output {
            let isCanvas = g.sessions.contains { $0.route == "ocr" }
            if isCanvas {
                let merged = Self.mergeCanvasSessions(g.sessions)
                let ctx = contextTimeline.first {
                    $0.app == g.app && $0.startTs <= merged.endTs && $0.endTs >= merged.startTs
                }?.summary
                let agent = await makeCanvas()
                return try await agent.run(
                    groupApp: g.app, groupUrl: g.url, session: merged, contextSummary: ctx)
            } else {
                let agent = await makePass3()
                return try await agent.run(
                    contextTimeline: contextTimeline,
                    groupApp: g.app, groupUrl: g.url,
                    rawSessions: g.sessions,
                    includeAxText: includeAxText,
                    userLanguages: userLanguages,
                    userRejections: userRejections)
            }
        }
        @Sendable func runOne(_ idx: Int) async -> (Int, Pass3GroupResult) {
            let g = groups[idx]
            var lastErr: Error = Pass3GroupError.missing
            for attempt in 0..<3 {
                do { return (idx, .success(try await runOnce(g))) }
                catch let e as BudgetExhaustedError {
                    // 预算耗尽重试无意义,直接失败(保留真实错误供 UI 展示)
                    return (idx, .failure(e))
                }
                catch {
                    lastErr = error
                    if attempt < 2 {
                        // 退避 1s / 3s 再试,给瞬时网络/限流恢复
                        try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 2 - 1) * 1_000_000_000)
                    }
                }
            }
            return (idx, .failure(lastErr))
        }

        return await withTaskGroup(of: (Int, Pass3GroupResult).self) { taskGroup in
            var inFlight = 0
            var nextIdx = 0
            var results: [Int: Pass3GroupResult] = [:]
            while inFlight < concurrency && nextIdx < groups.count {
                let idx = nextIdx; nextIdx += 1
                taskGroup.addTask { await runOne(idx) }
                inFlight += 1
            }
            while let (idx, res) = await taskGroup.next() {
                results[idx] = res
                inFlight -= 1
                if nextIdx < groups.count {
                    let nidx = nextIdx; nextIdx += 1
                    taskGroup.addTask { await runOne(nidx) }
                    inFlight += 1
                }
            }
            return (0..<groups.count).map { results[$0] ?? .failure(Pass3GroupError.missing) }
        }
    }

    enum Pass3GroupError: Error { case missing }

    /// edit_log 重建 + authoring 过滤(确定性,不靠 LLM)。
    /// 1. ax_cleaned record:edit_log 从源 typing_events.editLog 直接取(haiku 经常
    ///    输出空 edit_log,这里补全 —— 真实反映编辑过程)。
    /// 2. 过滤:edit_log 里没有任何 commit/delete(逐字编辑)= 不是用户敲出来的
    ///    (粘贴 / OCR / AI 内容)→ 丢。Google Docs 逐字写的(canvas 抓到 commit/
    ///    delete)留;纯粘贴一坨(paste-only / 空)→ 丢。
    nonisolated static func refineAndFilterByEditLog(
        _ recordsByGroupIdx: [[WritingCaptureRecord]],
        typing: [TypingEvent],
        keys: [KeystrokeEntry]
    ) -> (records: [[WritingCaptureRecord]], dropped: [WritingCaptureDiscarded]) {
        struct RawEntry: Decodable { let ts: Int64?; let kind: String?; let text: String? }
        let byId = Dictionary(typing.compactMap { e in e.id.map { ($0, e) } },
                              uniquingKeysWith: { a, _ in a })
        var outRecs: [[WritingCaptureRecord]] = []
        var dropped: [WritingCaptureDiscarded] = []
        for group in recordsByGroupIdx {
            var keptGroup: [WritingCaptureRecord] = []
            for rec in group {
                var editLog = rec.editLog
                var text = rec.text
                if rec.source == "ax_cleaned", !rec.referenceTypingEventIds.isEmpty {
                    var entries: [EditEntry] = []
                    for tid in rec.referenceTypingEventIds {
                        guard let ev = byId[tid], let data = ev.editLog.data(using: .utf8),
                              let raw = try? JSONDecoder().decode([RawEntry].self, from: data)
                        else { continue }
                        for r in raw {
                            entries.append(EditEntry(ts: r.ts ?? 0, kind: r.kind ?? "", text: r.text ?? ""))
                        }
                    }
                    if !entries.isEmpty { editLog = entries.sorted { $0.ts < $1.ts } }
                    // 根治:text = 用户真打的 commit 增量拼接(ts 序),丢弃整篇 AX
                    // 快照。`typing_event.text` 存的是整个字段的值 —— 在已有大文档里
                    // 只打一句,也会把整篇当成 text。改成只留真打的那几段。
                    // 读笔记 / 打开文档 = 0 commit → text 空 → 下面被毙。
                    text = editLog.filter { $0.kind == "commit" }.map(\.text).joined()
                }

                // 确定性击键覆盖闸门(K=1.0):字数须有等量真实击键撑得起(用上面
                // 重建后的 text)。读笔记/AI回复/收到消息/OCR幻觉/程序写入 ≈ 0 击键
                // → 全在此算法层毙掉,不靠 LLM 自觉。对 CJK 同样成立(比击键数量)。
                if !Self.keystrokeCovered(startTs: rec.startTs, endTs: rec.endTs, app: rec.app,
                                          textLen: text.count, keys: keys, k: Self.keystrokeCoverageK) {
                    dropped.append(WritingCaptureDiscarded(
                        reason: "keystroke coverage below \(Self.keystrokeCoverageK)× text length "
                            + "(reading / received / pasted / hallucinated — not typed by user)",
                        sessionIds: [], preview: String(text.prefix(200))))
                    continue
                }

                let hasAuthoring = editLog.contains { $0.kind == "commit" || $0.kind == "delete" }
                // canvas(OCR 重建)record:keystroke 跟 text 必须有对应(零对应兜底)。
                let canvasOrphan = (rec.source == "canvas_fusion" || rec.source == "merged")
                    && Self.keystrokeOrphan(rec: rec, keys: keys)
                if hasAuthoring && !canvasOrphan {
                    keptGroup.append(Self.withTextAndEditLog(rec, text, editLog))
                } else {
                    dropped.append(WritingCaptureDiscarded(
                        reason: canvasOrphan
                            ? "canvas OCR text has no keystroke correspondence (unrelated on-screen text)"
                            : "no authoring edits in edit_log (pasted / OCR / AI content, not typed)",
                        sessionIds: [], preview: String(text.prefix(200))))
                }
            }
            outRecs.append(keptGroup)
        }
        return (outRecs, dropped)
    }

    /// 击键覆盖闸门系数:窗口内真实击键数须 ≥ K × record 字数,否则毙。
    /// K=1.0 = 最严(不豁免粘贴):中文拼音 ~2 击键/字、英文 ~1 击键/字,真打字
    /// 远超;读/AI回复/幻觉 ≈ 0 击键 → 必毙。调这个数即可整体收紧/放松。
    nonisolated static let keystrokeCoverageK: Double = 1.0

    /// textLen 是否有足够真实击键撑得起(窗口内、同 app、非 cmd/opt/ctrl 快捷键
    /// 的物理按键;shift/退格/空格/回车都算打字)。textLen=0 直接判不通过。
    nonisolated static func keystrokeCovered(
        startTs: Int64, endTs: Int64, app: String, textLen: Int,
        keys: [KeystrokeEntry], k: Double
    ) -> Bool {
        guard textLen > 0 else { return false }
        let typed = keys.lazy.filter {
            $0.tsMs >= startTs && $0.tsMs <= endTs
                && $0.bundleId == app && ($0.modifiers & 0x07) == 0
        }.count
        return Double(typed) >= k * Double(textLen)
    }

    /// canvas record 的窗口击键跟 record.text 是否"完全对不上"(零对应)。
    /// 保守:只在极端情形返回 true —— 窗口里有击键(≥5)、但击键串与 text 没有
    /// 任何 ≥3 长公共子串,且非中文 IME 情形(text 含 CJK + 击键含 ascii 字母 →
    /// 放过,拼音对汉字字符层面本就不重叠)。
    nonisolated static func keystrokeOrphan(
        rec: WritingCaptureRecord, keys: [KeystrokeEntry]
    ) -> Bool {
        let windowKeys = keys.filter {
            $0.tsMs >= rec.startTs && $0.tsMs <= rec.endTs && $0.bundleId == rec.app
                && ($0.modifiers & 0x7) == 0 && $0.isBackspace == 0
        }
        guard windowKeys.count >= 5 else { return false }   // 击键太少不判(可能 IME/吞键)
        let kText = windowKeys.sorted { $0.tsMs < $1.tsMs }
            .compactMap { $0.char }.joined().lowercased()
        guard kText.count >= 5 else { return false }
        let text = rec.text.lowercased()
        // 中文 IME 放过:text 含 CJK 且击键含 ascii 字母(拼音)
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasAsciiLetter = kText.contains { $0.isASCII && $0.isLetter }
        if hasCJK && hasAsciiLetter { return false }
        // 有任何 ≥3 长公共子串就算"有对应",不是 orphan
        return !Self.hasCommonSubstring(kText, text, minLen: 3)
    }

    /// a、b 是否存在长度 ≥ minLen 的公共子串(滑窗,a 通常短)。
    nonisolated static func hasCommonSubstring(_ a: String, _ b: String, minLen: Int) -> Bool {
        let ac = Array(a), bc = Array(b)
        guard ac.count >= minLen, bc.count >= minLen else { return false }
        let bSet = b
        var i = 0
        while i + minLen <= ac.count {
            let sub = String(ac[i..<i+minLen])
            if bSet.contains(sub) { return true }
            i += 1
        }
        return false
    }

    /// 用新 editLog 重建一条 record(其余字段不变)。
    nonisolated static func withEditLog(
        _ r: WritingCaptureRecord, _ editLog: [EditEntry]
    ) -> WritingCaptureRecord {
        withTextAndEditLog(r, r.text, editLog)
    }

    /// 同时替换 text + editLog(ax_cleaned 把 text 改成真打的 commit 增量时用)。
    nonisolated static func withTextAndEditLog(
        _ r: WritingCaptureRecord, _ text: String, _ editLog: [EditEntry]
    ) -> WritingCaptureRecord {
        WritingCaptureRecord(
            text: text, editLog: editLog, kind: r.kind, source: r.source,
            confidence: r.confidence, contextSummary: r.contextSummary,
            app: r.app, url: r.url, startTs: r.startTs, endTs: r.endTs,
            referenceTypingEventIds: r.referenceTypingEventIds,
            referenceFrameIds: r.referenceFrameIds,
            referenceKeystrokeRange: r.referenceKeystrokeRange)
    }

    /// 把一个 canvas group 的多 session 并成一条(整篇文档跨天)——
    /// ocrFrames 按 ts 拼,chromeTokens 取并集。
    nonisolated static func mergeCanvasSessions(
        _ sessions: [WritingCaptureRawSession]
    ) -> WritingCaptureRawSession {
        let first = sessions[0]
        if sessions.count == 1 { return first }
        let frames = sessions.flatMap { $0.ocrFrames }.sorted { $0.startTs < $1.startTs }
        return WritingCaptureRawSession(
            id: first.id, app: first.app, url: first.url,
            startTs: sessions.map(\.startTs).min() ?? first.startTs,
            endTs: sessions.map(\.endTs).max() ?? first.endTs,
            typingEvents: sessions.flatMap { $0.typingEvents },
            keystrokes: sessions.flatMap { $0.keystrokes },
            ocrFrames: frames,
            maxContentChars: sessions.map(\.maxContentChars).max() ?? 0,
            axFrameCount: sessions.map(\.axFrameCount).reduce(0, +),
            chromeTokens: Array(Set(sessions.flatMap(\.chromeTokens))).sorted()
        )
    }

    /// 按 (app, url) 整天合并 raw_sessions(已弃用,留向后兼容)。
    /// Pre-Pass-2 算法层优化的早期方案,现在改成 group + 并发 subagent。
    static func mergeRawSessionsByApp(
        _ sessions: [WritingCaptureRawSession]
    ) -> [WritingCaptureRawSession] {
        struct Key: Hashable { let app: String; let url: String }
        var groups: [Key: [WritingCaptureRawSession]] = [:]
        var keyOrder: [Key] = []
        for s in sessions {
            let k = Key(app: s.app, url: s.url ?? "")
            if groups[k] == nil { keyOrder.append(k) }
            groups[k, default: []].append(s)
        }
        return keyOrder.compactMap { k -> WritingCaptureRawSession? in
            guard let members = groups[k] else { return nil }
            if members.count == 1 { return members[0] }
            let typing = members.flatMap { $0.typingEvents }
                .sorted(by: { $0.startedAt < $1.startedAt })
            let keys = members.flatMap { $0.keystrokes }
                .sorted(by: { $0.tsMs < $1.tsMs })
            let frames = members.flatMap { $0.ocrFrames }
                .sorted(by: { $0.startTs < $1.startTs })
            let first = members[0]
            return WritingCaptureRawSession(
                id: first.id,
                app: first.app,
                url: first.url,
                startTs: members.map(\.startTs).min() ?? first.startTs,
                endTs: members.map(\.endTs).max() ?? first.endTs,
                typingEvents: typing,
                keystrokes: keys,
                ocrFrames: frames,
                maxContentChars: members.map(\.maxContentChars).max() ?? 0,
                axFrameCount: members.map(\.axFrameCount).reduce(0, +),
                chromeTokens: Array(Set(members.flatMap(\.chromeTokens))).sorted(),
                route: members.contains { $0.route == "ocr" } ? "ocr" : "ax"
            )
        }
    }

    /// `prompt_id = sha256(pass1_prompt + pass3_prompt)[..16]` hex string。
    /// prompt 迭代时阶段三能筛同版本训练对。
    static func promptIdHash(pass1: String, pass3: String) -> String {
        let combined = pass1 + "\u{1F}" + pass3  // 单元分隔符
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
