import Foundation
import CryptoKit
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

        do {
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
        let userBlacklist = ConfigStore.shared.privacy.typingBlacklistBundleIds
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
        let allOcrFrames = step0.rawSessions.flatMap { $0.ocrFrames }
            .sorted(by: { $0.startTs < $1.startTs })
        // DEBUG: 转储 prompt 给 /tmp 看实际大小
        let probePrompt = WritingCapturePass1Agent.buildPrompt(ocrFrames: allOcrFrames)
        try? probePrompt.write(
            toFile: "/tmp/writing-capture-pass1-prompt.txt",
            atomically: false, encoding: .utf8)
        workerLog.info("pass1 prompt: \(probePrompt.count, privacy: .public) chars, dumped /tmp/writing-capture-pass1-prompt.txt")
        let pass1Out = try await pass1.run(ocrFrames: allOcrFrames)
        workerLog.info("pass1: \(pass1Out.timeline.count) context segments")

        // 4. 按 (app, url) 分组(不真合,LLM 在组内决定怎么分 record)
        let groups = Self.groupRawSessionsByApp(step0.rawSessions)
        workerLog.info("grouped by app+url: \(step0.rawSessions.count) sessions → \(groups.count) groups")

        // 5. **每组一个 subagent 并发跑 Pass 2**(sonnet[1m])。
        // 失败 group 单独标错,不阻塞其他 group。最多 5 并发,防止 Anthropic
        // 限流 + 本机 CPU 打爆。每个并发任务都创建一个全新的 Pass2Agent,
        // 不复用(每 agent 有 subprocess 状态)。
        let pass2Results = await Self.runPass2Concurrently(
            contextTimeline: pass1Out.timeline,
            groups: groups,
            concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent() }
        )

        // 6. 合并所有 group 输出
        var allRecords: [WritingCaptureRecord] = []
        var allDiscarded: [WritingCaptureDiscarded] = []
        var failedGroups = 0
        var rawResponses: [String] = []
        var firstPrompt: String?
        for r in pass2Results {
            switch r {
            case .success(let out):
                allRecords.append(contentsOf: out.records)
                allDiscarded.append(contentsOf: out.discarded)
                rawResponses.append(out.rawResponse)
                if firstPrompt == nil { firstPrompt = out.prompt }
            case .failure(let err):
                failedGroups += 1
                workerLog.warning("pass2 group failed: \(String(describing: err), privacy: .public)")
            }
        }
        workerLog.info("pass2 fanout: \(allRecords.count) records, \(allDiscarded.count) discarded, \(failedGroups) failed groups")

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
    func runBacklog() async throws -> WritingCaptureDayRunSummary {
        let runId = UUID().uuidString
        let startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

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
        // 跑之前先清 staged(避免上次 pending_review 没 approve/reject 残留)
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.clearStaged(date: Self.backlogDateKey)
            try store.upsertRunStatus(
                date: Self.backlogDateKey, status: .processing,
                runId: runId, startedAt: startedAtMs
            )
        }.value

        do {
            let summary = try await runBacklogCore(
                runId: runId, startMs: startMs, endMs: endMs
            )
            return summary
        } catch {
            let msg = error.localizedDescription
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
        runId: String, startMs: Int64, endMs: Int64
    ) async throws -> WritingCaptureDayRunSummary {
        let date = Self.backlogDateKey
        let userBlacklist = ConfigStore.shared.privacy.typingBlacklistBundleIds
        let hardcoded = TypingPrivacyFilter.defaultBlacklist
        let blacklist = Set(hardcoded).union(userBlacklist)

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
        let probePrompt = WritingCapturePass1Agent.buildPrompt(ocrFrames: allOcrFrames)
        try? probePrompt.write(
            toFile: "/tmp/writing-capture-pass1-prompt.txt",
            atomically: false, encoding: .utf8)
        workerLog.info("pass1 prompt: \(probePrompt.count, privacy: .public) chars")
        let pass1Out = try await pass1.run(ocrFrames: allOcrFrames)
        workerLog.info("pass1: \(pass1Out.timeline.count) context segments")

        // 4. group + 5. Pass 2 并发
        let groups = Self.groupRawSessionsByApp(step0.rawSessions)
        workerLog.info("grouped by app+url: \(step0.rawSessions.count) sessions → \(groups.count) groups")
        let pass2Results = await Self.runPass2Concurrently(
            contextTimeline: pass1Out.timeline, groups: groups, concurrency: 5,
            makePass2: { @MainActor in WritingCapturePass2Agent() }
        )

        // 6. 合并
        var allRecords: [WritingCaptureRecord] = []
        var allDiscarded: [WritingCaptureDiscarded] = []
        var failedGroups = 0
        var rawResponses: [String] = []
        var firstPrompt: String?
        for r in pass2Results {
            switch r {
            case .success(let out):
                allRecords.append(contentsOf: out.records)
                allDiscarded.append(contentsOf: out.discarded)
                rawResponses.append(out.rawResponse)
                if firstPrompt == nil { firstPrompt = out.prompt }
            case .failure(let err):
                failedGroups += 1
                workerLog.warning("pass2 group failed: \(String(describing: err), privacy: .public)")
            }
        }
        workerLog.info("pass2 fanout: \(allRecords.count) records, \(allDiscarded.count) discarded, \(failedGroups) failed groups")

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

    /// 并发跑多 group 的 Pass 2 —— sonnet[1m] subagent 一组一个。
    /// 限流 `concurrency` 道闸,防止瞬间 spawn 30 个 claude 子进程。
    enum Pass2GroupResult {
        case success(WritingCapturePass2Agent.Output)
        case failure(Error)
    }
    static func runPass2Concurrently(
        contextTimeline: [WritingCaptureContextSegment],
        groups: [WritingCaptureGroup],
        concurrency: Int,
        makePass2: @escaping @MainActor @Sendable () -> WritingCapturePass2Agent
    ) async -> [Pass2GroupResult] {
        await withTaskGroup(of: (Int, Pass2GroupResult).self) { taskGroup in
            var inFlight = 0
            var nextIdx = 0
            var results: [Int: Pass2GroupResult] = [:]
            // 启动初始批
            while inFlight < concurrency && nextIdx < groups.count {
                let idx = nextIdx; nextIdx += 1
                let g = groups[idx]
                taskGroup.addTask {
                    do {
                        let agent = await makePass2()
                        let out = try await agent.run(
                            contextTimeline: contextTimeline,
                            groupApp: g.app, groupUrl: g.url,
                            rawSessions: g.sessions
                        )
                        return (idx, .success(out))
                    } catch {
                        return (idx, .failure(error))
                    }
                }
                inFlight += 1
            }
            // 收一个 → 补一个
            while let (idx, res) = await taskGroup.next() {
                results[idx] = res
                inFlight -= 1
                if nextIdx < groups.count {
                    let nidx = nextIdx; nextIdx += 1
                    let g = groups[nidx]
                    taskGroup.addTask {
                        do {
                            let agent = await makePass2()
                            let out = try await agent.run(
                                contextTimeline: contextTimeline,
                                groupApp: g.app, groupUrl: g.url,
                                rawSessions: g.sessions
                            )
                            return (nidx, .success(out))
                        } catch {
                            return (nidx, .failure(error))
                        }
                    }
                    inFlight += 1
                }
            }
            return (0..<groups.count).map { results[$0] ?? .failure(Pass2GroupError.missing) }
        }
    }

    enum Pass2GroupError: Error { case missing }

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
                maxContentChars: members.map(\.maxContentChars).max() ?? 0
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
