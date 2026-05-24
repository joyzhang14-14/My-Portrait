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
    func runUnprocessedDays() async throws -> [WritingCaptureDayRunSummary] {
        let days = try await Task.detached(priority: .userInitiated) { [store] in
            try store.unprocessedDays()
        }.value

        workerLog.info("found \(days.count, privacy: .public) unprocessed days")

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

        // 4. 算法层 pre-merge —— 按 (app, url) 整天合并(不限时间窗)。
        // Pass 2 一天 hundreds of sessions 会撑爆 context;按 app 合并后
        // 一般 < 30 个 mega-session。
        // trade-off:LLM 看不到一天里同 app 的多个写作 session 的边界
        // (例如上午写文章 / 下午又来改),输出一条 record 覆盖整段。
        // 对风格分析够,对「精确还原一次写作 session」会模糊。
        let mergedByApp = Self.mergeRawSessionsByApp(step0.rawSessions)
        workerLog.info("pre-merge by app: \(step0.rawSessions.count) → \(mergedByApp.count) mega-sessions")
        let merged = mergedByApp

        // 5. Pass 2 —— 多源融合(mega-sessions + 每个自己一组的 trivial candidates)
        let trivialCandidates = merged.map { [$0.id] }
        let pass2Out = try await pass2.run(
            contextTimeline: pass1Out.timeline,
            rawSessions: merged,
            mergeCandidates: trivialCandidates
        )
        workerLog.info("pass2: \(pass2Out.records.count) records, \(pass2Out.discarded.count) discarded")

        // 5. 落 staged
        let promptId = Self.promptIdHash(
            pass1: pass1Out.prompt, pass2: pass2Out.prompt
        )
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.insertStaged(
                date: date,
                runId: runId,
                promptId: promptId,
                records: pass2Out.records,
                rawPass1Output: pass1Out.rawResponse,
                rawPass2Output: pass2Out.rawResponse
            )
        }.value

        // 6. 标 pending_review
        try await Task.detached(priority: .userInitiated) { [store] in
            try store.upsertRunStatus(
                date: date, status: .pendingReview,
                completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                discardedCount: pass2Out.discarded.count,
                recordsCount: pass2Out.records.count
            )
        }.value

        return WritingCaptureDayRunSummary(
            date: date, runId: runId, status: .pendingReview,
            recordsCount: pass2Out.records.count,
            discardedCount: pass2Out.discarded.count,
            errorMessage: nil
        )
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

    /// 按 (app, url) 整天合并 raw_sessions。Pre-Pass-2 算法层优化,
    /// 防止 600+ session 撑爆 LLM context。
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
