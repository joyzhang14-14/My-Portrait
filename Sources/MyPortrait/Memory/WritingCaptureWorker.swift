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
    @Published var stage: String = ""              // "Step 0" / "Pass 1" / "Pass 2 (3/5)" / "Saving"
    @Published var statusMessage: String = ""      // 给用户看的一行
    @Published var lastSummary: WritingCaptureDayRunSummary? = nil
    @Published var lastError: String? = nil
    /// 跑 backlog 的 Task 句柄 —— Stop 按钮 cancel 用。挂在单例上,view 切走
    /// 再回来 Stop 按钮仍可点(原本 @State 在 view 里,view 销毁后 task 句柄丢)。
    var task: Task<Void, Never>? = nil
    private init() {}
}

// MARK: - WritingCaptureWorker

/// 写作采集主 worker —— 串起 Step 0 / Pass 1 / Pass 2 / DB。
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
    /// pass1/pass2 在每次 runDay 重新构造 —— 这样用户在 Settings 改 provider
    /// 后下一次跑就用新的(写作采集用 LIGHT 模型档,跟 cluster 一档)。
    /// init 传入的 override 仍然优先(测试用)。
    private let pass1Override: WritingCapturePass1Agent?
    private let pass2Override: WritingCapturePass2Agent?

    init(
        store: WritingCaptureStore,
        pass1: WritingCapturePass1Agent? = nil,
        pass2: WritingCapturePass2Agent? = nil
    ) {
        self.store = store
        self.pass1Override = pass1
        self.pass2Override = pass2
    }

    private var pass1: WritingCapturePass1Agent {
        if let o = pass1Override { return o }
        let cfg = ConfigStore.shared.current.memory
        return WritingCapturePass1Agent(provider: cfg.resolvedProvider, model: cfg.resolvedModelLight)
    }
    private var pass2: WritingCapturePass2Agent {
        if let o = pass2Override { return o }
        let cfg = ConfigStore.shared.current.memory
        return WritingCapturePass2Agent(provider: cfg.resolvedProvider, model: cfg.resolvedModelLight)
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
            // App Nap 防护:Pass 1 + Pass 2 fanout 长任务,后台跑能拖到 10x。
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

        let pass2Cfg = ConfigStore.shared.current.memory
        let pass2Provider = pass2Cfg.resolvedProvider
        let pass2Model = pass2Cfg.resolvedModelLight

        // 3.5 Pass 4 —— 切割 + AX 真伪(非 canvas session)。判断活,轻量模型。
        let refinedSessions = await Self.applyPass4(
            step0.rawSessions, concurrency: 5,
            makePass4: { @MainActor in WritingCapturePass4Agent(provider: pass2Provider, model: pass2Model) })
        workerLog.info("pass4: \(step0.rawSessions.count) sessions → \(refinedSessions.count) units")

        // 4. 按 (app, url) 分组(不真合,LLM 在组内决定怎么分 record)
        let groups = Self.groupRawSessionsByApp(refinedSessions)
        workerLog.info("grouped by app+url: \(refinedSessions.count) sessions → \(groups.count) groups")

        // 5. **每组一个 subagent 并发跑 Pass 2**(默认 sonnet)。
        // 失败 group 单独标错,不阻塞其他 group。最多 5 并发,防止 Anthropic
        // 限流 + 本机 CPU 打爆。每个并发任务都创建一个全新的 Pass2Agent,
        // 不复用(每 agent 有 subprocess 状态)。
        let userLanguages = ConfigStore.shared.current.personalInfo.languages
        let userRejections = (try? await Task.detached(priority: .userInitiated) { [store] in
            try store.fetchRecentUserRejections()
        }.value) ?? []
        let pass2Results = await Self.runPass2Concurrently(
            contextTimeline: pass1Out.timeline,
            groups: groups,
            concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent(provider: pass2Provider, model: pass2Model) },
            makeCanvas: { @MainActor in WritingCaptureCanvasAgent(provider: pass2Provider, model: pass2Model) },
            userLanguages: userLanguages,
            userRejections: userRejections
        )

        // 6. 收集 Pass 2 输出(按 group 索引保留分组),给 Pass 3 用
        var recordsByGroupIdx: [[WritingCaptureRecord]] = []
        var failedGroups = 0
        var rawResponses: [String] = []
        var firstPrompt: String?
        for r in pass2Results {
            switch r {
            case .success(let out):
                recordsByGroupIdx.append(out.records)
                rawResponses.append(out.rawResponse)
                if firstPrompt == nil { firstPrompt = out.prompt }
            case .failure(let err):
                recordsByGroupIdx.append([])
                failedGroups += 1
                workerLog.warning("pass2 group failed: \(String(describing: err), privacy: .public)")
            }
        }
        let pass2Total = recordsByGroupIdx.reduce(0) { $0 + $1.count }
        workerLog.info("pass2 fanout: \(pass2Total) records, \(failedGroups) failed groups")

        // 6b. Pass 3 —— keystroke 支撑度过滤(每组一次,跟 Pass 2 同 provider/model)
        let pass3Inputs = recordsByGroupIdx.enumerated().map { (gi, recs) in
            recs.enumerated().map { (ri, rec) in
                WritingCapturePass3Builders.buildInput(
                    recordId: "g\(gi)_r\(ri)",
                    record: rec, typing: raw.typing, keys: raw.keys
                )
            }
        }
        let pass3Results = await WritingCapturePass3Builders.runConcurrently(
            inputsByGroupIdx: pass3Inputs,
            concurrency: 5,
            makePass3: { @MainActor in WritingCapturePass3Agent(provider: pass2Provider, model: pass2Model) }
        )
        var allRecords: [WritingCaptureRecord] = []
        var allDiscarded: [WritingCaptureDiscarded] = []
        var pass3RawResponses: [String] = []
        var pass3FailedGroups = 0
        for (gi, recs) in recordsByGroupIdx.enumerated() {
            switch pass3Results[gi] {
            case .success(let out):
                pass3RawResponses.append(out.rawResponse)
                for (ri, rec) in recs.enumerated() {
                    let id = "g\(gi)_r\(ri)"
                    if out.kept.contains(id) { allRecords.append(rec) }
                }
                for d in out.discarded {
                    allDiscarded.append(WritingCaptureDiscarded(
                        reason: "pass3: \(d.reason)",
                        sessionIds: [],
                        preview: d.preview
                    ))
                }
            case .failure(let err):
                pass3FailedGroups += 1
                workerLog.warning("pass3 group failed: \(String(describing: err), privacy: .public) — keeping all records for this group")
                allRecords.append(contentsOf: recs)
            }
        }
        workerLog.info("pass3 fanout: \(allRecords.count) kept, \(allDiscarded.count) discarded, \(pass3FailedGroups) failed groups")

        // 7. 落 staged + discarded
        let promptId = Self.promptIdHash(
            pass1: pass1Out.prompt, pass2: firstPrompt ?? ""
        )
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.insertStaged(
                date: date,
                runId: runId,
                promptId: promptId,
                records: allRecords,
                rawPass1Output: pass1Out.rawResponse,
                rawPass2Output: rawResponses.joined(separator: "\n---\n")
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
        var errorDescription: String? {
            switch self {
            case .pendingReviewExists(let n):
                return "Backlog already has \(n) record(s) pending review. " +
                       "Approve or reject them first before running again."
            case .alreadyProcessing:
                return "Backlog run already in progress. Wait for it to finish."
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

        let pass2Cfg = ConfigStore.shared.current.memory
        let pass2Provider = pass2Cfg.resolvedProvider
        let pass2Model = pass2Cfg.resolvedModelLight

        // 3.5 Pass 4 —— 切割 + AX 真伪(非 canvas session)。判断活,轻量模型。
        ui.stage = "Pass 4"
        ui.statusMessage = "Pass 4: judging \(step0.rawSessions.count) sessions (cut + AX validity)…"
        let refinedSessions = await Self.applyPass4(
            step0.rawSessions, concurrency: 5,
            makePass4: { @MainActor in WritingCapturePass4Agent(provider: pass2Provider, model: pass2Model) })
        workerLog.info("pass4: \(step0.rawSessions.count) sessions → \(refinedSessions.count) units")

        // 4. group + 5. Pass 2 并发
        let groups = Self.groupRawSessionsByApp(refinedSessions)
        ui.stage = "Pass 2"
        ui.statusMessage = "Pass 2: \(groups.count) (app, url) groups — running concurrently (max 5)…"
        workerLog.info("grouped by app+url: \(refinedSessions.count) sessions → \(groups.count) groups")
        let userLanguages = ConfigStore.shared.current.personalInfo.languages
        let userRejections = (try? await Task.detached(priority: .userInitiated) { [store] in
            try store.fetchRecentUserRejections()
        }.value) ?? []
        if !userRejections.isEmpty {
            workerLog.info("user_rejections: \(userRejections.count) examples fed to Pass 2")
        }
        let pass2Results = await Self.runPass2Concurrently(
            contextTimeline: pass1Out.timeline, groups: groups, concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent(provider: pass2Provider, model: pass2Model) },
            makeCanvas: { @MainActor in WritingCaptureCanvasAgent(provider: pass2Provider, model: pass2Model) },
            includeAxText: includeAxText,
            userLanguages: userLanguages,
            userRejections: userRejections
        )

        // 6. 收集 Pass 2 输出(按 group 索引保留)
        var recordsByGroupIdx: [[WritingCaptureRecord]] = []
        var failedGroups = 0
        var rawResponses: [String] = []
        var firstPrompt: String?
        for r in pass2Results {
            switch r {
            case .success(let out):
                recordsByGroupIdx.append(out.records)
                rawResponses.append(out.rawResponse)
                if firstPrompt == nil { firstPrompt = out.prompt }
            case .failure(let err):
                recordsByGroupIdx.append([])
                failedGroups += 1
                workerLog.warning("pass2 group failed: \(String(describing: err), privacy: .public)")
            }
        }
        let pass2Total = recordsByGroupIdx.reduce(0) { $0 + $1.count }
        workerLog.info("pass2 fanout: \(pass2Total) records, \(failedGroups) failed groups")

        // 6b. Pass 3
        ui.stage = "Pass 3"
        ui.statusMessage = "Pass 3: validating \(pass2Total) candidate record(s)…"
        let pass3Inputs = recordsByGroupIdx.enumerated().map { (gi, recs) in
            recs.enumerated().map { (ri, rec) in
                WritingCapturePass3Builders.buildInput(
                    recordId: "g\(gi)_r\(ri)",
                    record: rec, typing: raw.typing, keys: raw.keys
                )
            }
        }
        let pass3Results = await WritingCapturePass3Builders.runConcurrently(
            inputsByGroupIdx: pass3Inputs,
            concurrency: 5,
            makePass3: { @MainActor in WritingCapturePass3Agent(provider: pass2Provider, model: pass2Model) }
        )
        var allRecords: [WritingCaptureRecord] = []
        var allDiscarded: [WritingCaptureDiscarded] = []
        var pass3FailedGroups = 0
        for (gi, recs) in recordsByGroupIdx.enumerated() {
            switch pass3Results[gi] {
            case .success(let out):
                for (ri, rec) in recs.enumerated() {
                    let id = "g\(gi)_r\(ri)"
                    if out.kept.contains(id) { allRecords.append(rec) }
                }
                for d in out.discarded {
                    allDiscarded.append(WritingCaptureDiscarded(
                        reason: "pass3: \(d.reason)",
                        sessionIds: [],
                        preview: d.preview
                    ))
                }
            case .failure(let err):
                pass3FailedGroups += 1
                workerLog.warning("pass3 group failed: \(String(describing: err), privacy: .public) — keeping all records for this group")
                allRecords.append(contentsOf: recs)
            }
        }
        workerLog.info("pass3 fanout: \(allRecords.count) kept, \(allDiscarded.count) discarded, \(pass3FailedGroups) failed groups")
        ui.stage = "saving"
        ui.statusMessage = "Saving \(allRecords.count) record(s), \(allDiscarded.count) discarded…"

        // 7. stage
        let promptId = Self.promptIdHash(pass1: pass1Out.prompt, pass2: firstPrompt ?? "")
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.insertStaged(
                date: date, runId: runId, promptId: promptId,
                records: allRecords,
                rawPass1Output: pass1Out.rawResponse,
                rawPass2Output: rawResponses.joined(separator: "\n---\n")
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

    /// 按 (app, url) **分组**(不合)。Pass 2 LLM 在 group 内自己决定切多少 record。
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

    /// Pass 4 —— 切割 + AX 真伪判断,把非 canvas session 重建成"一单元一 session"。
    /// canvas session(chromeTokens 非空)/ 无 typing_events 的 → 原样直通。
    /// 并发限 `concurrency`。LLM 失败 fallback:该 session 原样保留。
    static func applyPass4(
        _ sessions: [WritingCaptureRawSession],
        concurrency: Int,
        makePass4: @escaping @MainActor @Sendable () -> WritingCapturePass4Agent
    ) async -> [WritingCaptureRawSession] {
        // 需要判的:有 typing_events 的 session(无论 Step 0 有没有 canvas 标记)。
        // —— Pass 4 用三源做 session 级判断:真内容在 AX(ax,按消息切)还是 OCR
        // (ocr,整 session 走重建)。这取代 Step 0 死检测的路由作用。
        let needJudge = sessions.enumerated().filter { !$0.element.typingEvents.isEmpty }
        @Sendable func judge(_ idx: Int) async -> (Int, [WritingCaptureRawSession]) {
            let s = sessions[idx]
            let agent = await makePass4()
            let result = (try? await agent.run(session: s))
                ?? WritingCapturePass4Agent.Result(
                    primarySource: "ax",
                    units: s.typingEvents.compactMap { $0.id }.map { [$0] }, dropped: [])
            if result.primarySource == "ocr" {
                // 真内容在 OCR:整 session 走 CanvasAgent。确保带 chromeTokens +
                // 粗快照(Step 0 若没 canvas-prep 过,这里补)。
                let ocrSession = Self.ensureOcrPrepped(s)
                return (idx, [ocrSession])
            }
            // primary=ax:按单元重建(chromeTokens 清空 → 走 Pass2Agent);
            // dropped 的 event(autofill/垃圾)不进任何单元;全空 = 整 session 丢。
            let rebuilt = result.units.compactMap { rebuildUnitSession(from: s, eventIds: $0) }
            return (idx, rebuilt)
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

    /// 用 Pass 4 给的一组 event_ids 从原 session 重建一个 mini-session
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

    /// 并发跑多 group 的 Pass 2 —— 默认 sonnet subagent 一组一个。
    /// 限流 `concurrency` 道闸,防止瞬间 spawn 30 个 claude 子进程。
    enum Pass2GroupResult {
        case success(WritingCapturePass2Agent.Output)
        case failure(Error)
    }
    static func runPass2Concurrently(
        contextTimeline: [WritingCaptureContextSegment],
        groups: [WritingCaptureGroup],
        concurrency: Int,
        makePass2: @escaping @MainActor @Sendable () -> WritingCapturePass2Agent,
        makeCanvas: @escaping @MainActor @Sendable () -> WritingCaptureCanvasAgent,
        includeAxText: Bool = true,
        userLanguages: [String] = [],
        userRejections: [UserRejectionRow] = []
    ) async -> [Pass2GroupResult] {
        // 单组执行:canvas 组(有 chromeTokens 的 AX 稀疏文档)走 window 切分
        // fanout;普通组走 Pass 2 单调用。
        @Sendable func runOne(_ idx: Int) async -> (Int, Pass2GroupResult) {
            let g = groups[idx]
            let isCanvas = g.sessions.contains { $0.route == "ocr" }
            do {
                if isCanvas {
                    let merged = Self.mergeCanvasSessions(g.sessions)
                    let ctx = contextTimeline.first {
                        $0.app == g.app && $0.startTs <= merged.endTs && $0.endTs >= merged.startTs
                    }?.summary
                    let agent = await makeCanvas()
                    let out = try await agent.run(
                        groupApp: g.app, groupUrl: g.url,
                        session: merged, contextSummary: ctx)
                    return (idx, .success(out))
                } else {
                    let agent = await makePass2()
                    let out = try await agent.run(
                        contextTimeline: contextTimeline,
                        groupApp: g.app, groupUrl: g.url,
                        rawSessions: g.sessions,
                        includeAxText: includeAxText,
                        userLanguages: userLanguages,
                        userRejections: userRejections
                    )
                    return (idx, .success(out))
                }
            } catch {
                return (idx, .failure(error))
            }
        }

        return await withTaskGroup(of: (Int, Pass2GroupResult).self) { taskGroup in
            var inFlight = 0
            var nextIdx = 0
            var results: [Int: Pass2GroupResult] = [:]
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
            return (0..<groups.count).map { results[$0] ?? .failure(Pass2GroupError.missing) }
        }
    }

    enum Pass2GroupError: Error { case missing }

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

    /// `prompt_id = sha256(pass1_prompt + pass2_prompt)[..16]` hex string。
    /// prompt 迭代时阶段三能筛同版本训练对。
    static func promptIdHash(pass1: String, pass2: String) -> String {
        let combined = pass1 + "\u{1F}" + pass2  // 单元分隔符
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
