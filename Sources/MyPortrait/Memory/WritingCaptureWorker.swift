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
            let summary = try await PiAgentRegistry.$owner.withValue(PipelineOwner.writingCapture) {
                try await runDayCore(date: date, runId: runId)
            }
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

        // Pass 2(LLM):精准切 session(LLM 判 return 还是时间边界)+ 路由(ax/ocr)。
        // 不丢 event。chat app 真内容在 AX → ax 路;真 canvas(AX 乱码/空)→ ocr 路。
        let refinedSessions = await Self.applyPass2(
            step0.rawSessions, concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent(provider: pass3Provider, model: pass3Model) })
        workerLog.info("pass2: \(step0.rawSessions.count) sessions → \(refinedSessions.count) units")

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
            makeCleanup: { @MainActor in WritingCaptureAxCleanupAgent(provider: pass3Provider, model: pass3Model) },
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
                WritingCapturePass4Builders.buildInput(recordId: "g\(gi)_r\(ri)", record: rec, keys: raw.keys)
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
            try store.clearAllStaged()   // 清整张表(含 day-mode 孤儿),防残留卡 review
            try store.upsertRunStatus(
                date: Self.backlogDateKey, status: .processing,
                runId: runId, startedAt: startedAtMs
            )
        }.value

        let napGuard = AppNapGuard.acquire(reason: "Writing capture backlog")
        defer { napGuard.release() }
        do {
            // App Nap 防护:backlog 跑全历史时间窗,LLM fanout 可能跑几分钟。
            let summary = try await PiAgentRegistry.$owner.withValue(PipelineOwner.writingCapture) {
                try await runBacklogCore(
                    runId: runId, startMs: startMs, endMs: endMs,
                    includeAxText: includeAxText
                )
            }
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
        // Pass 2(LLM):精准切 session(LLM 判 return 还是时间边界)+ 路由(ax/ocr),
        // 不丢 event。chat app 真内容在 AX → ax;真 canvas(AX 乱码/空)→ ocr。
        ui.stage = "Pass 2"
        ui.statusMessage = "Pass 2: segment + route \(step0.rawSessions.count) sessions…"
        let refinedSessions = await Self.applyPass2(
            step0.rawSessions, concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent(provider: pass3Provider, model: pass3Model) })
        workerLog.info("pass2: \(step0.rawSessions.count) sessions → \(refinedSessions.count) units")

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
            makeCleanup: { @MainActor in WritingCaptureAxCleanupAgent(provider: pass3Provider, model: pass3Model) },
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
                WritingCapturePass4Builders.buildInput(recordId: "g\(gi)_r\(ri)", record: rec, keys: raw.keys)
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
            try store.clearAllStaged()   // 含 day-mode 孤儿,根除残留
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
        // Pass 2 = 确定性路由(根据 AX,不用 LLM、不硬编码 app):
        //   AX 有料(session 有 typing_events)→ ax 路 → 走确定性构造
        //   AX 空(真 canvas,如 Google Docs:AX 失灵,内容只在屏幕)→ 保留 Step 0
        //     的 route(默认 ocr)→ 走 CanvasAgent OCR 重建。
        // 之前用 LLM 判,把有干净 AX prompt 的 Claude Desktop 误判成 ocr →
        // ensureOcrPrepped 清掉 typingEvents → 用户 prompt 直接消失。chat/Electron
        // app 的输入在 AX,绝不该为了 OCR 丢掉它。
        let needJudge = sessions.enumerated().filter { !$0.element.typingEvents.isEmpty }
        @Sendable func judge(_ idx: Int) async -> (Int, [WritingCaptureRawSession]) {
            let s = sessions[idx]
            // 路由确定性(不用 LLM、不硬编码 app):
            //   AX 接住了字 → ax 路,整 session 原样给 Pass 3。**不在 Pass 2 切**
            //     ——LLM 切分会把一条连续消息拆成十几条(My Meeting 草稿);消息边界
            //     在 buildAxRecordsDeterministic 里按 submit(发送)切。
            //   AX 失灵(用户狂敲键但 typing_event 只有零宽残渣,如 Google Docs
            //     自绘编辑器只给 "​Wi​")→ 真内容只在屏幕 OCR → ocr 重建,不采信坏 AX。
            if Self.isAxBroken(s) {
                return (idx, [Self.ensureOcrPrepped(s)])
            }
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
        // **canvas 文档是 (app, url) 级实体,不是单时间 session**。一篇 Google Docs
        // 随笔跨整天、被 idle>5min 切成多个 session:只有打字密集那段触发 isAxBroken
        // 走 ocr,稀疏续写 / 滚动 review 段会被判 ax 而割裂,整篇塌成局部(GDoc 丢
        // 标题+尾)。修法:任一 session 被判坏 AX canvas → 该 (app,url) 整篇都是
        // canvas,所有同 url session(含稀疏、含无输入 review)一律并入 ocr,帧合并
        // 重建。判据仍是确定性的 isAxBroken,不硬编码 app/语言。
        func urlKey(_ s: WritingCaptureRawSession) -> String { s.app + "\u{1}" + (s.url ?? "") }
        var canvasUrls = Set<String>()
        for (i, r) in refinedByIdx where r.first?.route == "ocr" {
            canvasUrls.insert(urlKey(sessions[i]))
        }
        // 无 typing_events 的 session 怎么处理(数据驱动,不写 app 名):
        //  - 属于 canvas url(同篇文档的 review 帧)→ 保留走 ocr。
        //  - 该 app 本次出现过 typing_events(= AX 对它有效)→ 纯阅读 / AI 回复 /
        //    收到的消息(用户输入早已由它的 ax session 捕获)→ 丢。
        //  - 该 app 从不产 typing_events(AX 对它失灵)且有实打击键 → ocr 重建。
        let axWorkingApps = Set(sessions.filter { !$0.typingEvents.isEmpty }.map { $0.app })
        var out: [WritingCaptureRawSession] = []
        for (i, s) in sessions.enumerated() {
            let isCanvasUrl = canvasUrls.contains(urlKey(s))
            if let r = refinedByIdx[i] {
                if isCanvasUrl {
                    out.append(Self.ensureOcrPrepped(s))   // 同篇文档的稀疏段也并入 canvas
                } else {
                    out.append(contentsOf: r)
                }
            } else if isCanvasUrl {
                out.append(Self.ensureOcrPrepped(s))        // 同篇文档的 review 帧 → ocr
            } else if !axWorkingApps.contains(s.app),
                      s.keystrokes.reduce(0, { acc, k in
                          (k.isBackspace == 0 && (k.modifiers & 0x07) == 0
                              && (k.char?.isEmpty == false)) ? acc + 1 : acc
                      }) >= 120 {
                // 真 canvas 写作 → ocr。门槛对齐 isAxBroken(≥120 有效击键、同一套
                // meaningfulKeys 定义):AX 对这 app 失灵(从不产 typing_event)**且用户
                // 确实大量手打** = 在写文档。旧门槛 10 太低,把"Spotify 等前台时顺手打
                // 几个字"的纯屏 OCR 误当文档(36 个环境击键 ≥ 10 就进 canvas,LLM 把屏上
                // 歌词/别处窗口文字拼成假记录)。
                out.append(s)
            }
            // else: AX 有效 app 的无输入 session(AI 回复/阅读)或 击键不足 → 丢
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

    /// AX 对这个 session 是否失灵 —— 确定性判定,**无 app/语言硬编码**。
    /// 自绘文本编辑器(如 Google Docs)对 Accessibility 失灵:用户狂敲键写了
    /// 整篇文章,可 typing_event 只接住 "​Wi​" 这种零宽残渣。这种 session 真内容
    /// 只在屏幕 OCR 里,必须走 ocr 重建,绝不能采信坏 AX(否则整篇塌成几个字)。
    ///
    /// 判据(三者同时):
    ///   1. meaningfulKeys ≥ 120 —— 用户确实大量手打(canvas 写作)。
    ///      短聊天消息(击键少)永远不触发,保护 chat app 的 AX 输入不被误丢。
    ///   2. AX **整 session 累计**接住的有效字符(去零宽/空白,逐 typing_event
    ///      求和)≤ 击键量的 1/20 —— AX 几乎没接住字。健康 AX(含中文 IME)累计
    ///      字数与击键同数量级,远超此比。**必须求和不能取单条最大**:聊天 app
    ///      一个 session 发几十条短消息、每条发完输入框就清空,单条 endValue 只
    ///      几个字,但累计内容很多 → 取 max 会把聊天误判成坏 AX(Discord 26 条
    ///      消息被整组吞进 canvas)。求和后 Discord ~200 字 vs Google Docs ~20 字
    ///      零宽残渣,干净分开。
    ///   3. 有足够 OCR 内容可重建(maxFrame ≥ 200 字)。
    nonisolated static func isAxBroken(_ s: WritingCaptureRawSession) -> Bool {
        let minKeys = 120, keyRatio = 20
        let meaningfulKeys = s.keystrokes.reduce(0) { acc, k in
            (k.isBackspace == 0 && (k.modifiers & 0x07) == 0
                && (k.char?.isEmpty == false)) ? acc + 1 : acc
        }
        guard meaningfulKeys >= minKeys else { return false }
        let zeroWidth: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]
        func realChars(_ str: String) -> Int {
            str.reduce(0) { c, ch in
                if ch.isWhitespace { return c }
                if ch.unicodeScalars.allSatisfy({ zeroWidth.contains($0.value) }) { return c }
                return c + 1
            }
        }
        struct E: Decodable { let kind: String?; let text: String? }
        // AX 实际接住多少字:每个 event 取「末值/净增量」和「edit_log commit 流水」里
        // 更大的那个。聊天(Discord 等)发送后输入框清空、净值归零,但真消息全在 commit
        // 流水里 —— 只看末值会把聊天误判成"AX 坏掉的文档"而错走 OCR(把整段对话含对方
        // 消息重建)。真坏 AX 的 canvas(Google Docs 自绘编辑器)commit 是零宽残渣,
        // 过滤后仍≈0,照常判坏、走 OCR 重建。
        let axCaptured = s.typingEvents.reduce(0) { total, e -> Int in
            let fromValue = realChars(e.endValue.isEmpty ? e.text : e.endValue)
            var fromCommits = 0
            if let data = e.editLog.data(using: .utf8),
               let arr = try? JSONDecoder().decode([E].self, from: data) {
                fromCommits = arr.filter { $0.kind == "commit" }.compactMap { $0.text }
                    .reduce(0) { $0 + realChars($1) }
            }
            return total + max(fromValue, fromCommits)
        }
        let ocrChars = s.ocrFrames.map { $0.text.count }.max() ?? 0
        return axCaptured <= meaningfulKeys / keyRatio && ocrChars >= 200
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
    /// AX 路确定性记录构造:**一个 unit-session(Pass 2 LLM 切的一条消息)= 一条
    /// record**,反映 LLM 的 return/time 切分。text = 该 unit 各 typing_event.text 按
    /// 时间拼(单 event 时即它本身)。record 集由算法定死,不靠 LLM 增删。
    nonisolated static func buildAxRecordsDeterministic(
        group g: WritingCaptureGroup,
        contextTimeline: [WritingCaptureContextSegment]
    ) -> WritingCapturePass3Agent.Output {
        var records: [WritingCaptureRecord] = []
        for s in g.sessions {
            let evs = s.typingEvents.filter { $0.id != nil }
                .sorted { $0.startedAt < $1.startedAt }
            guard !evs.isEmpty else { continue }
            let text = evs.map { $0.text }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startTs = evs.first!.startedAt, endTs = evs.last!.endedAt
            let ctx = contextTimeline.first {
                $0.app == g.app && $0.startTs <= endTs && $0.endTs >= startTs
            }?.summary
            records.append(WritingCaptureRecord(
                text: text, editLog: [],
                kind: text.count >= 140 ? "long_form" : "short_form",
                source: "ax_cleaned", confidence: 1.0, contextSummary: ctx,
                app: g.app, url: g.url, startTs: startTs, endTs: endTs,
                referenceTypingEventIds: evs.compactMap { $0.id }, referenceFrameIds: [],
                referenceKeystrokeRange: WritingCaptureRecord.KeystrokeRange(start: nil, end: nil)))
        }
        return WritingCapturePass3Agent.Output(
            prompt: "(deterministic ax record set)", rawResponse: "(deterministic)",
            records: records, discarded: [])
    }

    /// AX 路混合:确定性 record 集 + LLM 文字润色。每条确定性 record(单
    /// typing_event id)去 LLM 输出里找引用了该 id 的 record,用其清洗后的 text;
    /// 找不到 / LLM 没出 → 保留确定性原文。**record 集永远是确定性的,绝不增删。**
    nonisolated static func mergeAxCleanup(
        deterministic: [WritingCaptureRecord], llm: [WritingCaptureRecord]?
    ) -> [WritingCaptureRecord] {
        guard let llm, !llm.isEmpty else { return deterministic }
        func nonEmpty(_ r: WritingCaptureRecord) -> Bool {
            !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return deterministic.map { det in
            // 1) 按 typing_event id 精确匹配
            if let id = det.referenceTypingEventIds.first,
               let m = llm.first(where: { $0.referenceTypingEventIds.contains(id) }), nonEmpty(m) {
                return Self.withTextAndEditLog(det, m.text, det.editLog)
            }
            // 2) 兜底:LLM 重切分导致 id 对不上 → 按文字高度重叠匹配(共同子串
            //    ≥ 原文一半)。让 "这是一家什么dian" 对上清洗后的 "这是一家什么店"。
            let dt = det.text
            let need = max(4, dt.count / 2)
            if let m = llm.first(where: {
                nonEmpty($0) && Self.hasCommonSubstring($0.text, dt, minLen: need)
            }) {
                return Self.withTextAndEditLog(det, m.text, det.editLog)
            }
            return det   // 找不到清洗版 → 保留确定性原文
        }
    }

    /// typing_event 的 edit_log 里有没有 submit(按回车 + 输入框清空)。**消息边界用**
    /// —— 区分同 session 连发的不同消息(如"修好了"/"修了一晚上")。注意:它**不代表
    /// "已发送"**(回车未必真发出、app 会假清空),所以前缀合并的 hasSend 不看它。
    nonisolated static func editLogHasSubmit(_ editLogJSON: String) -> Bool {
        editLogJSON.contains("\"kind\":\"submit\"")
    }

    /// 解析 edit_log,返回最长的一条**用户敲出来的**(commit/delete,排除 paste)
    /// entry text。发送清空时整条消息作为一条 delete 落进 edit_log → 用它取回原文;
    /// **排除 paste** —— paste 是突然贴上来、零击键的(占位符 / autofill / 收到内容),
    /// 不是用户打的,绝不能当成消息原文。
    /// `excluding`(可选):排除掉等于此文本(trim 后)的 entry —— 用来剔除占位符。
    /// 发送后输入框回到占位符,占位符会作为 commit/delete 落进 edit_log,且常比真消息
    /// 还长(如 "Write a message…\n" 16字 > "用人脑来复制人的意识难度有多高" 13字),
    /// 不排除就会被当成最长原文。传 sessionStart 进来即可剔掉它(占位符 == 开局值)。
    nonisolated static func longestEditLogText(_ editLogJSON: String, excluding: String = "") -> String? {
        struct E: Decodable { let kind: String?; let text: String? }
        guard let data = editLogJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([E].self, from: data) else { return nil }
        let ex = excluding.trimmingCharacters(in: .whitespacesAndNewlines)
        return arr.filter {
            $0.kind != "paste"
                && (ex.isEmpty || ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != ex)
        }.compactMap { $0.text }
            .max(by: { $0.count < $1.count })
    }

    /// 这个 event 的 endValue 是不是"贴上来的"(== edit_log 里某条 paste 文本)。
    /// 输入框清空后显示的占位符("Write a message…" / "请输入文本")就是这样作为一条
    /// paste 冒出来、变成 endValue 的 —— 零击键、不是用户打的字。**跟输入法无关**
    /// (只看 paste 标记,不比对击键内容,所以拼音/五笔/双拼都不影响)。
    nonisolated static func isPastedValue(_ ev: TypingEvent) -> Bool {
        let v = ev.endValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return false }
        struct E: Decodable { let kind: String?; let text: String? }
        guard let data = ev.editLog.data(using: .utf8),
              let arr = try? JSONDecoder().decode([E].self, from: data) else { return false }
        func trim(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        // (1) 占位符作为 paste 冒出来:endValue == 某条 paste 文本。
        if arr.contains(where: { $0.kind == "paste" && trim($0.text) == v }) { return true }
        // (2) 占位符作为 commit 回填(claudefordesktop 发送后字段回到 "Write a message…",
        //     不是 paste)。endValue **既匹配 commit 又匹配 delete** = 字段反复回填/清掉的
        //     占位符,零击键、非用户草稿 —— 跟 extractSentMessages 的占位符判据一致。
        return arr.contains(where: { $0.kind == "commit" && trim($0.text) == v })
            && arr.contains(where: { $0.kind == "delete" && trim($0.text) == v })
    }

    /// 这个 event 是不是"发送清空":聊天 app(如 ChatGPT)发送后输入框清空,
    /// TypingObserver 把整框内容作为一条 delete 记下、endValue 变空。它**不带
    /// submit 标记**(不同于 Discord/微信的回车),所以单独识别,同样当消息边界。
    /// **排除自撤销**:同一 event 里刚 commit 又 delete 掉同一段(用户打了"ba"
    /// 又删掉,净零)不是发送 —— 只有删掉的是**累积内容**(本 event 没 commit 过的)
    /// 才算发送清空。否则 IME 残渣的自撤销会被误判成发送、切出幽灵半成品。
    nonisolated static func isSendClear(_ ev: TypingEvent) -> Bool {
        guard ev.endValue.isEmpty else { return false }
        struct E: Decodable { let kind: String?; let text: String? }
        guard let data = ev.editLog.data(using: .utf8),
              let arr = try? JSONDecoder().decode([E].self, from: data) else { return false }
        let commits = Set(arr.filter { $0.kind == "commit" }.compactMap { $0.text })
        return arr.contains { e in
            guard e.kind == "delete", let raw = e.text else { return false }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count >= 2 && !commits.contains(raw)   // 删的不是自己刚打的
        }
    }

    /// 取一条消息组里**最完整**的文本。常态取末事件 endValue(累积全文);但两种
    /// 情况 endValue 不是用户的字:
    ///   1. 发送清空 → endValue 空(ChatGPT 等);
    ///   2. 发送后输入框显示**占位符**("Write a message…" / "请输入文本")→ endValue
    ///      是贴上来的占位符(isPastedValue),零击键、不是用户打的。
    /// 这两种都改用 edit_log 里**用户敲出来**的最长那条(发送时被整条 delete 的原文,
    /// longestEditLogText 已排除 paste);再不行退回组里最后一个**非占位符**的非空 endValue。
    nonisolated static func bestGroupText(_ grp: [TypingEvent]) -> String {
        guard let last = grp.last else { return "" }
        // 字段「回到开局」(endValue == sessionStart)= 发送/清空后回到初始态(占位符 or
        // 原内容),endValue 不是这次写的字 —— 别用它。claudefordesktop 发送后回到
        // "Write a message…":开局占位符、结尾又是占位符,return 后蹦出来的就是它。
        func backToStart(_ e: TypingEvent) -> Bool {
            let s = e.sessionStart.trimmingCharacters(in: .whitespacesAndNewlines)
            return !s.isEmpty
                && e.endValue.trimmingCharacters(in: .whitespacesAndNewlines) == s
        }
        if !last.endValue.isEmpty, !Self.isPastedValue(last), !backToStart(last) {
            return last.endValue
        }
        // 取打字内容:排除 paste + 排除占位符(== sessionStart)的最长 commit/delete。
        if let t = Self.longestEditLogText(last.editLog, excluding: last.sessionStart), !t.isEmpty {
            return t
        }
        if let prev = grp.last(where: {
            !$0.endValue.isEmpty && !Self.isPastedValue($0) && !backToStart($0)
        }) {
            return prev.endValue
        }
        // 没有任何打字内容 = 纯剪切板粘贴 / 占位符 / autofill → **一律丢**(返回空)。
        // (用户决定:纯粘贴不留。根治"Write a message…"这类占位符泄漏 —— 它跟真短
        // 粘贴在算法层分不开,唯一区别是匹不匹配剪贴板,而那信号没存进 typing_event。)
        return ""
    }

    /// 去零宽(0x200B/C/D + 0xFEFF)再去首尾空白;只剩零宽/空白 → 空串。
    /// `trimmingCharacters(.whitespacesAndNewlines)` **不**去零宽,Discord 发送后
    /// 残留的 "﻿\n" 会 trim 成 "﻿"(非空)→ 不挡掉会生出只含零宽的垃圾记录。
    nonisolated static func cleanVisible(_ s: String) -> String {
        let zw: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]
        let stripped = String(String.UnicodeScalarView(s.unicodeScalars.filter { !zw.contains($0.value) }))
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从一个 typing_event 的 edit_log 里拆出**每一条发出去的消息**。
    /// 聊天里连发多条会挤进同一个 typing_event:发送后输入框留下零宽残留
    /// (如 Discord 的 "﻿\n"),不被当成 flush 边界,于是 N 条消息共用一个 event,
    /// bestGroupText 只取得到一条、其余全丢 —— 这正是用户早指出的"同框第二条 invalid"。
    /// 救法:每次发送 = 一条把**整框内容整条删掉**的 delete,且其**相邻项只剩零宽/空白**
    /// (发送后那一瞬的字段态)。纠正型删除(改字、退格)旁边没有这种空标记 → 排除。
    nonisolated static func extractSentMessages(
        _ editLogJSON: String, sessionStart: String, endValue: String
    ) -> [String] {
        struct E: Decodable { let kind: String?; let text: String? }
        guard let data = editLogJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([E].self, from: data) else { return [] }
        let zw: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]   // 零宽空格/连接符/BOM
        func effEmpty(_ s: String) -> Bool {
            s.unicodeScalars.allSatisfy { $0.properties.isWhitespace || zw.contains($0.value) }
        }
        func stripZW(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.filter { !zw.contains($0.value) }))
        }
        func norm(_ s: String) -> String { stripZW(s).trimmingCharacters(in: .whitespacesAndNewlines) }
        // 占位符识别:有些 app(如 claudefordesktop)发送后输入框**不清空、而是回填占位符**
        // ("Write a message…"),不是空/零宽,于是「相邻 effEmpty = 发送」判据失效、消息全丢。
        // 占位符特征:它是字段静止态 endValue,且在 edit_log 里**既作为 commit 出现(字段回到它)
        // 又作为 delete 出现(打字时被清掉)**。认出后把它跟零宽一样当**清空/发送标记**:相邻的
        // delete = 一条发出的消息,占位符本身不抓。Discord 清成空/零宽 → endValue 空 → 不触发。
        let endN = norm(endValue)
        let endIsPlaceholder = !endN.isEmpty
            && arr.contains { $0.kind == "commit" && norm($0.text ?? "") == endN }
            && arr.contains { $0.kind == "delete" && norm($0.text ?? "") == endN }
        func isMarker(_ s: String) -> Bool { effEmpty(s) || (endIsPlaceholder && norm(s) == endN) }
        // 基线 = session 开始时字段里已有的内容。只记**用户这次打出来的新字**:删掉「本来
        // 就在基线里」的文字 = 在编辑器里删除预先存在的内容(如改 AI 写的 release note 草稿),
        // 那是删除、不是发送。聊天里 sessionStart 是空/占位符,发出去的消息绝不会是它的子串。
        let baseline = stripZW(sessionStart)
        var msgs: [String] = []
        for (i, e) in arr.enumerated() where e.kind == "delete" {
            guard let raw = e.text, !isMarker(raw) else { continue }   // 占位符/空 本身是标记,不抓
            let prevMarker = i > 0 && (arr[i - 1].text.map(isMarker) ?? false)
            let nextMarker = i + 1 < arr.count && (arr[i + 1].text.map(isMarker) ?? false)
            guard prevMarker || nextMarker else { continue }     // 旁边没有清空标记 = 普通纠正删除
            let t = norm(raw)
            guard t.count >= 2 else { continue }
            if !baseline.isEmpty && baseline.contains(t) { continue }   // 预先存在的内容,非这次所写
            msgs.append(t)
        }
        return msgs
    }

    // MARK: - 统一提取(字段状态时间线模型)
    //
    // 替掉散落互相打架的 6 个启发式。核心一句话:维护「当前跨事件草稿 cur」,字段每次
    // reset(空/零宽/占位符)就把 cur 吐成一条消息;末尾没 reset 的是草稿。reset 用
    // 「下一个事件起点是不是 reset 态」判 —— **绝不用前缀比对**(CJK 拼音↔汉字、中途改字
    // 会把前缀判炸成逐字爆炸,那次 194 条就是这么来的)。event 内连发由 withinEventSends
    // 拆。占位符按 run 级「整段跳变复现」识别,不认 app/语言/长度。

    /// 字段是不是「reset 态」:空/纯空白/零宽,或 run 级识别出的占位符。
    nonisolated static func isResetState(_ s: String, placeholders: Set<String>) -> Bool {
        let zw: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]
        if s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || zw.contains($0.value) }) { return true }
        return placeholders.contains(Self.cleanVisible(s))
    }

    /// run 级占位符识别:某 endValue **作为单条 commit/paste 一次性跳变出现**(app 注入、
    /// 非逐字打出)且复现 ≥3 次。逐字堆出来的真草稿没有「整段=单条目」,不会误判;
    /// 不限长度、不认 app/语言。所有待处理事件扫一遍,只算一次。
    nonisolated static func collectPlaceholders(_ groups: [WritingCaptureGroup]) -> Set<String> {
        struct E: Decodable { let kind: String?; let text: String? }
        var counts: [String: Int] = [:]
        for g in groups {
            for s in g.sessions {
                for ev in s.typingEvents {
                    let evn = Self.cleanVisible(ev.endValue)
                    guard !evn.isEmpty,
                          let data = ev.editLog.data(using: .utf8),
                          let arr = try? JSONDecoder().decode([E].self, from: data) else { continue }
                    if arr.contains(where: {
                        ($0.kind == "commit" || $0.kind == "paste") && Self.cleanVisible($0.text ?? "") == evn
                    }) { counts[evn, default: 0] += 1 }
                }
            }
        }
        return Set(counts.filter { $0.value >= 3 }.keys)
    }

    /// event **内部**连发(挤进一个 event,如 Discord):整框 delete 紧挨 reset 态 = 一条发出。
    nonisolated static func withinEventSends(_ ev: TypingEvent, placeholders: Set<String>) -> [String] {
        struct E: Decodable { let kind: String?; let text: String? }
        guard let data = ev.editLog.data(using: .utf8),
              let arr = try? JSONDecoder().decode([E].self, from: data) else { return [] }
        func marker(_ s: String) -> Bool { Self.isResetState(s, placeholders: placeholders) }
        var out: [String] = []
        for (i, e) in arr.enumerated() where e.kind == "delete" {
            guard let raw = e.text, !marker(raw) else { continue }
            let pm = i > 0 && (arr[i - 1].text.map(marker) ?? false)
            let nm = i + 1 < arr.count && (arr[i + 1].text.map(marker) ?? false)
            guard pm || nm else { continue }
            let t = Self.cleanVisible(raw)
            if t.count >= 2 { out.append(t) }
        }
        return out
    }

    /// 一个 session 的事件序列 → 用户发出的每条消息(+末尾草稿)。
    nonisolated static func unifiedExtract(_ evs: [TypingEvent], placeholders: Set<String>) -> [String] {
        var msgs: [String] = []
        var cur: String? = nil
        for (k, e) in evs.enumerated() {
            let we = Self.withinEventSends(e, placeholders: placeholders)
            msgs.append(contentsOf: we)
            let ev = Self.cleanVisible(e.endValue)
            let evReset = Self.isResetState(e.endValue, placeholders: placeholders)
            if !evReset && !ev.isEmpty { cur = ev }     // 非 reset = 当前草稿的最新内容
            let nextReset = (k + 1 < evs.count)
                && Self.isResetState(evs[k + 1].sessionStart, placeholders: placeholders)
            if nextReset {                               // 两事件间字段 reset → 本条发出去了
                if let c = cur { msgs.append(c); cur = nil }
            } else if evReset {                          // 本事件末尾 reset(发送)
                if let c = cur, we.isEmpty { msgs.append(c) }   // within 抓到就用它,否则 cur 兜
                cur = nil
            }
        }
        if let c = cur { msgs.append(c) }                // 末尾未发送草稿
        var seen = Set<String>()
        return msgs.filter { !$0.isEmpty && seen.insert($0).inserted }   // 去重保序
    }

    /// 确定性前缀合并(原 Pass2 LLM 切分里的"草稿增长合并",改算法层实现)。
    /// 同 (app,url) 组内,一条**未发送草稿**(其引用的 typing_events 里没有任何
    /// 发送 = send-clear 输入框清空)的文字若是更晚某条 record 的前缀 → 它只是那条
    /// 草稿的早期快照,丢掉。**发送过的不丢**:先发"好的"再发"好的开始吧"是两条
    /// 独立消息,即使前者是后者前缀。
    nonisolated static func mergePrefixDrafts(
        _ records: [WritingCaptureRecord], rawTyping: [TypingEvent]
    ) -> [WritingCaptureRecord] {
        guard records.count > 1 else { return records }
        let evById = Dictionary(rawTyping.compactMap { e in e.id.map { ($0, e) } },
                                uniquingKeysWith: { a, _ in a })
        // "已发送"只认 isSendClear(输入框**真清空**)。submit 标记**不算已发送**:
        // 回车未必真发出、app 会假清空(claudefordesktop:989"那个图…"带 submit 但
        // 990 仍带该前缀=没真发),这种假 submit 不该挡住前缀合并把早期草稿并进后续。
        func hasSend(_ r: WritingCaptureRecord) -> Bool {
            r.referenceTypingEventIds.contains { id in
                guard let e = evById[id] else { return false }
                return Self.isSendClear(e)
            }
        }
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var drop = Set<Int>()
        for (i, r) in records.enumerated() {
            guard !hasSend(r) else { continue }          // 只合"未发送草稿"
            let a = norm(r.text)
            guard !a.isEmpty else { continue }
            // 有没有更晚的、严格以 a 为前缀的更完整 record
            let isStaleDraft = records.enumerated().contains { (j, o) in
                j != i && o.startTs >= r.startTs && norm(o.text) != a && norm(o.text).hasPrefix(a)
            }
            if isStaleDraft { drop.insert(i) }
        }
        guard !drop.isEmpty else { return records }
        return records.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }

    /// 一条消息的置信度 = 输入干净度:commit 字符 / (commit + delete 字符)。
    /// 干净直打(删得少)→ ~0.95+;反复改 / IME 多次重组 → 0.8 左右。自然浮动,
    /// 不再是死的 1.00。
    nonisolated static func axConfidence(_ events: [TypingEvent]) -> Double {
        struct E: Decodable { let kind: String?; let text: String? }
        var commit = 0, del = 0
        for ev in events {
            guard let data = ev.editLog.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([E].self, from: data) else { continue }
            for e in arr {
                let n = (e.text ?? "").count
                if e.kind == "commit" { commit += n } else if e.kind == "delete" { del += n }
            }
        }
        guard commit + del > 0 else { return 0.9 }
        // ratio∈[0,1] → conf∈[0.80,0.99]。中文 IME 组词天然多删,不该把正常中文
        // 拉到 0.5;映射到高位区间,浮动但不显假。干净直打≈0.99,反复改≈0.85。
        let ratio = Double(commit) / Double(commit + del)
        return ((0.80 + 0.19 * ratio) * 100).rounded() / 100
    }

    static func runPass3Concurrently(
        contextTimeline: [WritingCaptureContextSegment],
        groups: [WritingCaptureGroup],
        concurrency: Int,
        makePass3: @escaping @MainActor @Sendable () -> WritingCapturePass3Agent,
        makeCanvas: @escaping @MainActor @Sendable () -> WritingCaptureCanvasAgent,
        makeCleanup: @escaping @MainActor @Sendable () -> WritingCaptureAxCleanupAgent,
        includeAxText: Bool = true,
        userLanguages: [String] = [],
        userRejections: [UserRejectionRow] = []
    ) async -> [Pass3GroupResult] {
        // 单组执行:canvas 组(有 chromeTokens 的 AX 稀疏文档)走 window 切分
        // fanout;普通组走 Pass 3 单调用。LLM 偶发 socket 断/超时常见,失败退避
        // 重试最多 3 次(吸收瞬时错误);重试还失败才算 group failure。
        // run 级占位符:所有待处理事件扫一遍算一次,各组共享(单组事件少时也能认出占位符)。
        let placeholders = Self.collectPlaceholders(groups)
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
                // AX 路:record 集确定性(一 unit-session = 一条,反映 Pass 2 的
                // return/time 切分)+ 专职 LLM **只补 AX 小瑕疵**(dian→店)。补齐按
                // record id 精确回填;LLM 漏某条/失败 → 保留确定性原文,绝不增删。
                var records: [WritingCaptureRecord] = []
                var items: [WritingCaptureAxCleanupAgent.Item] = []
                for s in g.sessions {
                    let evs = s.typingEvents.filter { $0.id != nil }
                        .sorted { $0.startedAt < $1.startedAt }
                    guard !evs.isEmpty else { continue }
                    // **统一提取(字段状态时间线)**:维护跨事件草稿 cur,字段一 reset(空/
                    // 零宽/占位符)就把 cur 吐成一条;reset 用「下一个事件起点是否 reset 态」判,
                    // 不用前缀比对(CJK 拼音/改字会把它判炸成逐字爆炸)。event 内连发由
                    // withinEventSends 拆。占位符按 run 级「整段跳变复现」识别,不认 app/语言。
                    let messages = Self.unifiedExtract(evs, placeholders: placeholders)
                    guard !messages.isEmpty else { continue }
                    let startTs = evs.first!.startedAt, endTs = evs.last!.endedAt
                    let pad: Int64 = 10_000
                    let grpKeys = s.keystrokes.filter { $0.tsMs >= startTs - pad && $0.tsMs <= endTs + pad }
                    // 组级击键 gate:消息总量远超击键 = 编辑预先存在内容/纯粘贴 → 整组丢
                    // (中文拼音击键 ≥ 字数,真打的永远过;短粘贴混大量打字也过)。
                    let kc = grpKeys.filter { ($0.modifiers & 0x07) == 0 }.count
                    let totalLen = messages.reduce(0) { $0 + $1.count }
                    if totalLen > 20 && kc < totalLen / 4 { continue }
                    let ks = await WritingCapturePass2Agent.assembleKeystrokeText(grpKeys)
                    // slash 命令(/play 等):keystroke 起头 "/" → 整组丢(chat app 通用约定)。
                    let ksTrim = ks.replacingOccurrences(of: "<CR>", with: "")
                        .replacingOccurrences(of: "<BS>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if ksTrim.hasPrefix("/") { continue }
                    let ctx = contextTimeline.first {
                        $0.app == g.app && $0.startTs <= endTs && $0.endTs >= startTs
                    }?.summary
                    for text in messages {
                        // conf 默认 0.9;下面 AxCleanup(LLM)给真实判定覆盖。漏/失败 → 0.9。
                        let rid = "r\(records.count)"
                        records.append(WritingCaptureRecord(
                            text: text, editLog: [],
                            kind: text.count >= 140 ? "long_form" : "short_form",
                            source: "ax_cleaned", confidence: 0.9, contextSummary: ctx,
                            app: g.app, url: g.url, startTs: startTs, endTs: endTs,
                            referenceTypingEventIds: evs.compactMap { $0.id }, referenceFrameIds: [],
                            referenceKeystrokeRange: WritingCaptureRecord.KeystrokeRange(start: nil, end: nil)))
                        items.append(WritingCaptureAxCleanupAgent.Item(id: rid, text: text, keystroke: ks))
                    }
                }
                let fixes = await makeCleanup().run(items: items)
                let cleaned = records.enumerated().map { i, rec -> WritingCaptureRecord in
                    // LLM(补齐 agent)给的 text + confidence 覆盖默认值;漏/失败/给空 → 原文+默认。
                    // 给空守卫:小模型清不动带 IME 残渣的碎片(如「你得抓住mei」)时会返回空,
                    // 没这道守卫就把确定性原文覆盖成空、整条静默丢失(对齐 mergeAxCleanup 的 nonEmpty)。
                    guard let fix = fixes["r\(i)"],
                          !fix.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return rec }
                    return WritingCaptureRecord(
                        text: fix.text, editLog: rec.editLog, kind: rec.kind, source: rec.source,
                        confidence: fix.confidence, contextSummary: rec.contextSummary,
                        app: rec.app, url: rec.url, startTs: rec.startTs, endTs: rec.endTs,
                        referenceTypingEventIds: rec.referenceTypingEventIds,
                        referenceFrameIds: rec.referenceFrameIds,
                        referenceKeystrokeRange: rec.referenceKeystrokeRange)
                }
                // 确定性前缀合并:跨 session(切走 app 又回来接着打同一条草稿,
                // Step0 按 app 切成两条)的草稿增长在这并回去。
                let merged = Self.mergePrefixDrafts(
                    cleaned, rawTyping: g.sessions.flatMap { $0.typingEvents })
                return WritingCapturePass3Agent.Output(
                    prompt: "(ax cleanup)", rawResponse: "", records: merged, discarded: [])
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
                // 6a:ax_cleaned 的 edit_log 从 typing_events 重建(准确编辑历史)。
                // 不在此丢任何 record —— AI回复/阅读的过滤交给 Pass 3(keystroke 重建)
                // + Pass 4(最终审核)。text 保留 Pass 3(LLM)清洗后的结果。
                var editLog = rec.editLog
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
                }
                keptGroup.append(Self.withEditLog(rec, editLog))
            }
            _ = keys
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
        // 窗口两侧放宽 60s:打字常发生在 AX value-change 之前一段时间(Electron 等
        // 合成后才一次性 fire,typing_event 窗口很窄)。放宽以覆盖真实击键期;
        // 读笔记/AI回复/收到消息 附近本就 0 击键,放宽也照样毙,不误伤。
        let pad: Int64 = 60_000
        let typed = keys.lazy.filter {
            $0.tsMs >= startTs - pad && $0.tsMs <= endTs + pad
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
