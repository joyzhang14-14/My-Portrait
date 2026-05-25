import Foundation
import os.log

private let ssLog = Logger(subsystem: "com.myportrait.memory", category: "speech-style")

/// speech_style 提炼链路的 orchestrator —— 两个入口:
///   - `runManual()` —— UI Run 按钮触发。LLM 决策落 speech_style_staged,
///                      run.status = pending_review。用户在 UI Approve 后
///                      才落 portrait/speech_style/ 文件 + 标 records completed。
///   - `runAuto()`   —— scheduler 自动。LLM 决策直接落 portrait/speech_style/
///                      文件 + 标 records completed,run.status = auto_committed。
///
/// 两条路径共用 `prepareAndCallLLM()`:拉未处理 records → 截断到上限 →
/// 读现存 portrait/speech_style/ 摘要 → 调 Agent → 解析。
@MainActor
final class SpeechStyleDistiller {

    /// 全局单例,Services init 时填上。UI(MemorySettingsView)+ scheduler 用。
    /// 同 WritingCaptureWorker.shared 模式。
    static var shared: SpeechStyleDistiller?

    /// 单次 LLM 调用最多喂多少 record —— 防止上下文爆。可经 env
    /// MYPORTRAIT_SPEECH_STYLE_BATCH 覆盖(测试用)。剩下的下一次 run 接着跑。
    static let defaultBatchCap: Int = {
        if let s = ProcessInfo.processInfo.environment["MYPORTRAIT_SPEECH_STYLE_BATCH"],
           let v = Int(s), v > 0 {
            return v
        }
        return 600
    }()

    let store: SpeechStyleStore
    let agentProvider: () -> SpeechStyleAgent
    let batchCap: Int

    init(
        store: SpeechStyleStore,
        batchCap: Int = SpeechStyleDistiller.defaultBatchCap,
        agentProvider: (() -> SpeechStyleAgent)? = nil
    ) {
        self.store = store
        self.batchCap = batchCap
        if let p = agentProvider {
            self.agentProvider = p
        } else {
            self.agentProvider = {
                let cfg = ConfigStore.shared.current.memory
                return SpeechStyleAgent(provider: cfg.resolvedProvider,
                                        model: cfg.resolvedModelLight)
            }
        }
    }

    // MARK: - Manual

    /// 手动跑:LLM 决策落 speech_style_staged。返回 RunSummary 给 UI / CLI。
    @discardableResult
    func runManual() async throws -> SpeechStyleRunSummary {
        try await runCore(mode: .manual)
    }

    // MARK: - Auto

    /// 自动跑:LLM 决策直接落 portrait/speech_style/ 文件 + 标 records
    /// completed,run.status = auto_committed。
    @discardableResult
    func runAuto() async throws -> SpeechStyleRunSummary {
        try await runCore(mode: .auto)
    }

    // MARK: - 共用核心

    private func runCore(mode: SpeechStyleMode) async throws -> SpeechStyleRunSummary {
        let runId = UUID().uuidString
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try store.insertRun(runId: runId, mode: mode, startedAt: startedAt)

        do {
            // 1. 拉一批未处理 records(截断到 batchCap)
            let records = try await Task.detached(priority: .userInitiated) { [store, batchCap] in
                try store.unprocessedRecords(limit: batchCap)
            }.value

            if records.isEmpty {
                ssLog.info("runCore(\(mode.rawValue, privacy: .public)): no unprocessed records — noop")
                let status: SpeechStyleRunStatus = (mode == .auto) ? .autoCommitted : .approved
                try store.updateRun(
                    runId: runId, status: status,
                    completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    recordsCount: 0, draftsCount: 0
                )
                return SpeechStyleRunSummary(
                    runId: runId, mode: mode, status: status,
                    recordsCount: 0, draftsCount: 0, errorMessage: nil
                )
            }

            // 2. 读现存 portrait/speech_style/ 摘要
            let existing = Self.loadExistingEntries()
            ssLog.info("runCore(\(mode.rawValue, privacy: .public)): records=\(records.count) existing=\(existing.count)")

            // 3. 调 LLM
            let agent = agentProvider()
            let out = try await agent.run(records: records, existing: existing)
            ssLog.info("runCore(\(mode.rawValue, privacy: .public)): LLM returned \(out.drafts.count) drafts")

            // 4. 分模式落地
            let recordIds = records.map { $0.id }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            switch mode {
            case .manual:
                // staged + pending_review。**不**标 records completed —— 等 Approve。
                try store.insertStaged(runId: runId, drafts: out.drafts)
                try store.updateRun(
                    runId: runId, status: .pendingReview,
                    completedAt: nowMs,
                    recordsCount: records.count,
                    draftsCount: out.drafts.count
                )
                return SpeechStyleRunSummary(
                    runId: runId, mode: mode, status: .pendingReview,
                    recordsCount: records.count, draftsCount: out.drafts.count,
                    errorMessage: nil
                )

            case .auto:
                // 直接落盘 + 标 records completed。
                Self.applyDrafts(out.drafts)
                try store.markRecordsProcessed(ids: recordIds, at: nowMs)
                try store.updateRun(
                    runId: runId, status: .autoCommitted,
                    completedAt: nowMs,
                    recordsCount: records.count,
                    draftsCount: out.drafts.count
                )
                return SpeechStyleRunSummary(
                    runId: runId, mode: mode, status: .autoCommitted,
                    recordsCount: records.count, draftsCount: out.drafts.count,
                    errorMessage: nil
                )
            }
        } catch {
            let msg = error.localizedDescription
            ssLog.error("runCore(\(mode.rawValue, privacy: .public)) failed: \(msg, privacy: .public)")
            try? store.updateRun(
                runId: runId, status: .failed,
                completedAt: Int64(Date().timeIntervalSince1970 * 1000),
                errorMessage: msg
            )
            throw error
        }
    }

    // MARK: - Approve(manual)

    /// UI Approve 一个 pending_review run:把 staged drafts 落 portrait/
    /// speech_style/ 文件 + 标 records completed + run.status = approved。
    @discardableResult
    func approveStaged(runId: String) throws -> Int {
        guard let _ = try store.fetchRun(runId: runId) else { return 0 }
        let staged = try store.fetchStaged(runId: runId)
        // 落盘
        let drafts = staged.map {
            SpeechStyleDraft(
                action: $0.action, slug: $0.slug,
                title: $0.title, body: $0.body,
                sourceRecordIds: $0.sourceRecordIds,
                existingSlug: $0.existingSlug
            )
        }
        Self.applyDrafts(drafts)
        // 标 records completed —— union 所有 source_record_ids
        let allIds = Array(Set(staged.flatMap { $0.sourceRecordIds }))
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !allIds.isEmpty {
            try store.markRecordsProcessed(ids: allIds, at: nowMs)
        }
        try store.approveRunMeta(runId: runId)
        return drafts.count
    }

    /// UI Reject 一个 pending_review run:清 staged,run.status =
    /// rejected_for_rerun。**不**标 records completed —— 下次 run 重进 LLM。
    func rejectStaged(runId: String) throws {
        try store.rejectRun(runId: runId)
    }

    // MARK: - 落盘 helpers

    /// 把一批 drafts 写到 portrait/speech_style/<slug>.md。
    /// create / update 都用 PortraitFile + PortraitFileIO,noop 跳过。
    /// **slug 冲突**(create 的 slug 已存在)→ 走 update 分支。
    nonisolated static func applyDrafts(_ drafts: [SpeechStyleDraft]) {
        let dir = PortraitPaths.categoryDir("speech_style")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for d in drafts {
            switch d.action {
            case .noop:
                continue
            case .create:
                let url = dir.appendingPathComponent(d.slug + ".md")
                if FileManager.default.fileExists(atPath: url.path) {
                    // 冲突 → 当 update。把 existingSlug 临时 patch 成 slug 本身。
                    writeUpdate(at: url, draft: d, slug: d.slug)
                } else {
                    writeNew(at: url, draft: d)
                }
            case .update:
                let target = d.existingSlug ?? d.slug
                let url = dir.appendingPathComponent(target + ".md")
                if FileManager.default.fileExists(atPath: url.path) {
                    writeUpdate(at: url, draft: d, slug: target)
                } else {
                    // 目标不存在 —— 当 create 兜底
                    writeNew(at: url, draft: d)
                }
            }
        }
    }

    /// 新建 portrait/speech_style/<slug>.md。复刻 PortraitDistiller.writeNewPortrait
    /// 的极简版:不持有 impact / weight 的 event-only 字段,只填 portrait 那套。
    nonisolated static func writeNew(at url: URL, draft: SpeechStyleDraft) {
        let now = Date()
        var file = PortraitFile(
            created: now,
            body: renderBody(title: draft.title, body: draft.body,
                             sourceIds: draft.sourceRecordIds),
            source: "speech_style",
            tags: ["speech_style", "portrait"],
            firstOccurrence: now,
            eventTitle: draft.title,
            eventSummary: draft.body,
            eventType: "experience",
            portraitFacets: [],
            category: "speech_style",
            memberFrameIds: []
        )
        file.weight = 1.0
        file.mergeCount = 1
        file.lastModified = now
        do { try PortraitFileIO.write(file, to: url) }
        catch { ssLog.error("writeNew failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    /// 更新现有 portrait/speech_style/<slug>.md。body 用 LLM 返回的合并后正文
    /// (prompt 已要求 LLM 返回 final state),溯源 ids 累积。
    nonisolated static func writeUpdate(at url: URL, draft: SpeechStyleDraft, slug: String) {
        do {
            var file = try PortraitFileIO.read(from: url)
            // 清掉旧文件可能残留的 event-only 字段
            file.rawImpact = nil
            file.rebalanceCount = nil
            file.impactSource = nil
            // 合并 derived ids:从旧 body 抽 + 这次的 union
            let oldIds = extractDerivedIds(from: file.body)
            var merged = oldIds
            for id in draft.sourceRecordIds where !merged.contains(id) {
                merged.append(id)
            }
            file.eventTitle = draft.title
            file.eventSummary = draft.body
            file.body = renderBody(title: draft.title, body: draft.body, sourceIds: merged)
            file.recordOccurrence(on: Date())
            file.mergeCount = (file.mergeCount ?? 1) + 1
            file.lastModified = Date()
            try PortraitFileIO.write(file, to: url)
        } catch {
            ssLog.error("writeUpdate failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// body 渲染:`# 标题` + 一空行 + body + 一空行 + Derived from writing records 行。
    nonisolated static func renderBody(title: String, body: String, sourceIds: [Int64]) -> String {
        var out = "# \(title)\n\n\(body)"
        if !sourceIds.isEmpty {
            let links = sourceIds.map { "[[wr:\($0)]]" }.joined(separator: ", ")
            out += "\n\n**Derived from writing records:** \(links)"
        }
        return out
    }

    /// 从 body 抽出 `[[wr:<id>]]` 形态的引用 —— update 合并溯源用。
    nonisolated static func extractDerivedIds(from body: String) -> [Int64] {
        var out: [Int64] = []
        var seen = Set<Int64>()
        let pattern = #"\[\[wr:(\d+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        for m in matches where m.numberOfRanges >= 2 {
            let s = ns.substring(with: m.range(at: 1))
            if let id = Int64(s), !seen.contains(id) {
                seen.insert(id)
                out.append(id)
            }
        }
        return out
    }

    /// 读 portrait/speech_style/*.md → ExistingEntry。出错 / 没目录返回 []。
    nonisolated static func loadExistingEntries() -> [SpeechStyleAgent.ExistingEntry] {
        let dir = PortraitPaths.categoryDir("speech_style")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [SpeechStyleAgent.ExistingEntry] = []
        for name in items where name.hasSuffix(".md") && name != "INDEX.md" {
            let url = dir.appendingPathComponent(name)
            guard let file = try? PortraitFileIO.read(from: url) else { continue }
            let slug = String(name.dropLast(3))   // .md
            let excerpt = String(file.body.prefix(SpeechStyleAgent.existingBodyExcerptChars))
            out.append(SpeechStyleAgent.ExistingEntry(
                slug: slug,
                title: file.eventTitle.isEmpty ? slug : file.eventTitle,
                bodyExcerpt: excerpt
            ))
        }
        out.sort { $0.slug < $1.slug }
        return out
    }
}
