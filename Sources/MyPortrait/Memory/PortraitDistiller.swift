import Foundation

/// Distils event-layer files into portrait-layer entries.
///
/// Input:
///   - All non-archived events under ~/.portrait/events/<day>/*.md
///   - Existing portrait files under ~/.portrait/portrait/<cat>/*.md
///     (so the LLM can UPDATE an existing portrait entry instead of
///     duplicating it)
///
/// Output: writes / updates portrait files under
///         ~/.portrait/portrait/<category>/<slug>.md
///
/// Each portrait file represents a "fact about the user":
///   skills/swift_ui_development.md
///   habits/late_night_coding.md
///   interests/personal_ai_memory_research.md
///
/// MVP characteristics:
///   - Manual trigger from the Memories UI button
///   - One LLM call per category (6 calls per full run, see PortraitPaths.distillCategories)
///   - LLM gets the events relevant to a category (by category field) +
///     the existing portrait files in that category
///   - LLM returns: list of {action: "create"|"update"|"noop",
///                            slug, title, body, derived_from_event_ids}
@MainActor
final class PortraitDistiller {
    struct Progress {
        let categoryIndex: Int
        let categoryCount: Int
        let category: String
        let written: Int
    }

    struct Result {
        let categoriesProcessed: Int
        let portraitFilesWritten: Int
        let portraitFilesUpdated: Int
        let llmFailedCategories: Int
        let archivedCount: Int
        let elapsed: TimeInterval
        /// 第一个失败 category 的具体原因("habits: LLM error: …")。
        /// 调度器用它记 failure kind,让 attention / 通知显示真因而不是
        /// 笼统的 "distill step reported failure"。nil = 没有失败。
        var firstFailureReason: String? = nil
    }

    enum DistillError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)
        case llmError(String)        // agent .error 事件携带的 API 错误原文

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):     return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:          return "LLM did not respond within timeout"
            case .noJSONInResponse:      return "LLM response contained no JSON"
            case .malformedJSON(let m):  return "LLM JSON parse failed: \(m)"
            case .llmError(let m):       return "LLM error: \(m)"
            }
        }
    }

    private let provider: Provider
    private let model: String
    private let perCategoryTimeout: TimeInterval

    /// perCategoryTimeout 120→300:distill 的 prompt 是全 pipeline 最大的
    /// (整个 portrait 正文 + 每类 50 事件),reasoning 模型(deepseek-v4-pro
    /// 等)思考就要几分钟,120s 必超 → agentTimeout 中止整轮反复退避。
    /// 300s × 6 类最坏 30min,仍在 runStep 的 60min 看门狗内。
    init(provider: Provider = .chatgpt, model: String = "gpt-5.4", perCategoryTimeout: TimeInterval = 300) {
        self.provider = provider
        self.model = model
        self.perCategoryTimeout = perCategoryTimeout
    }

    /// Run a full distillation pass across all distill categories.
    func distill(progress: ((Progress) -> Void)? = nil) async throws -> Result {
        let napGuard = AppNapGuard.acquire(reason: "Portrait distillation")
        defer { napGuard.release() }
        return try await distillImpl(progress: progress)
    }

    private func distillImpl(progress: ((Progress) -> Void)?) async throws -> Result {
        try PortraitPaths.ensureSeedTree()
        let start = Date()

        // 入口先刷一次 weight —— 即使本轮 LLM 没动某条 entry,也按当前时间
        // 让它的 weight 随 lastModified 衰减。跟 WritingStyle 同套路。
        PortraitWeight.refreshDistillCategories()

        // 1. Group events by category from disk.
        let eventsByCategory = await collectEventsByCategory()

        // 2. Snapshot existing portrait files (for UPDATE decisions).
        let portraitByCategory = await collectPortraitByCategory()

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw DistillError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = DistillerCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        var written = 0
        var updated = 0
        var failed = 0
        var firstFailureReason: String? = nil
        // distillCategories 排除 personality —— personality 走独立的
        // PersonalityAgent / PersonalityMerger pipeline，不归通用 distiller。
        let categories = PortraitPaths.distillCategories

        for (idx, category) in categories.enumerated() {
            let events = eventsByCategory[category] ?? []
            // Skip categories with no events AND no existing portraits.
            // Nothing to distill from.
            let existing = portraitByCategory[category] ?? []
            if events.isEmpty && existing.isEmpty {
                progress?(.init(categoryIndex: idx, categoryCount: categories.count, category: category, written: 0))
                continue
            }

            do {
                let decisions = try await runCategory(
                    category: category,
                    events: events,
                    existing: existing,
                    agent: agent,
                    coordinator: coordinator
                )
                for decision in decisions {
                    switch decision.action {
                    case "create":
                        if try writeNewPortrait(category: category, decision: decision) {
                            written += 1
                        }
                    case "update":
                        if try updateExistingPortrait(category: category, decision: decision) {
                            updated += 1
                        } else {
                            // Slug not found → treat as create.
                            if try writeNewPortrait(category: category, decision: decision) {
                                written += 1
                            }
                        }
                    default:
                        break    // "noop" — nothing to do
                    }
                }
            } catch let e as BudgetExhaustedError {
                // 撞额度：中止整轮 distill，调度器据此标 budget_deferred。
                // 已写入 / 更新的分类保留（update 幂等，下次重跑覆盖）。
                throw e
            } catch DistillError.agentTimeout {
                // 超时后该 agent 的事件流已错位:turn N 的迟到响应(事件不带
                // turn id)会 resume 下一轮的 waiter,category N 的 create/update
                // 决策会写进 category N+1 的目录。不能继续复用同一 agent ——
                // 中止整轮,已写分类保留(update 幂等),调度器稍后重试。
                throw DistillError.agentTimeout
            } catch {
                // ⚠️ 别静默吞:这里曾经只 failed += 1,DeepSeek 等 API 后端
                // 单类失败(限流/解析/空响应)时用户只看到"distill step
                // reported failure",完全无从排查。落 DiagLog + 留第一条原因
                // 给 Result,让 attention/通知显示真因。
                failed += 1
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                if firstFailureReason == nil {
                    firstFailureReason = "\(category): \(reason)"
                }
                print("[Distill] category \(category) FAILED — \(reason)")
                DiagLog.warn("distill.category.failed", ctx: [
                    "category": category, "error": reason,
                ])
            }

            progress?(.init(categoryIndex: idx + 1, categoryCount: categories.count, category: category, written: written))
        }

        // 蒸馏后扫一遍 portrait/ 归档（程序化、无 LLM）。放在 distill 之后
        // 是因为归档动的就是 portrait 文件、distill 刚更新完它们；用 Settings
        // 配置的阈值（archive_max_weight / archive_min_days_idle）。
        let archive = try Archiver.run(rule: .fromConfig)

        return Result(
            categoriesProcessed: categories.count,
            portraitFilesWritten: written,
            portraitFilesUpdated: updated,
            llmFailedCategories: failed,
            archivedCount: archive.archivedCount,
            elapsed: Date().timeIntervalSince(start),
            firstFailureReason: firstFailureReason
        )
    }

    // MARK: - One category round-trip

    private struct ParsedDecision {
        let action: String          // create | update | noop
        let slug: String            // file basename, no extension
        let title: String
        let body: String
        let derivedFromEventIds: [String]
    }

    private func runCategory(
        category: String,
        events: [EventEntry],
        existing: [PortraitEntry],
        agent: any ChatAgent,
        coordinator: DistillerCoordinator
    ) async throws -> [ParsedDecision] {
        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)

        let prompt = Self.buildPrompt(
            category: category,
            events: events,
            existing: existing,
            evidenceThreshold: ConfigStore.shared.current.memory.distillEvidenceThreshold,
            personal: ConfigStore.shared.current.personalInfo
        )

        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw DistillError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perCategoryTimeout * 1_000_000_000))
                    throw DistillError.agentTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw DistillError.agentTimeout
        }

        // 撞额度优先于解析失败：抛 BudgetExhaustedError 让上层走 budget_deferred。
        // 其它 .error(限流 / 余额 / 认证 / 网络)也显式抛原文 —— 否则 buffer
        // 是空的,落到 parseDecisions 抛 noJSONInResponse,真因被掩盖。
        if let err = await coordinator.consumeError() {
            if BudgetSignal.isExhausted(err) {
                throw BudgetExhaustedError(processor: "PortraitDistiller", message: err)
            }
            if collected.isEmpty {
                throw DistillError.llmError(err)
            }
        }

        return try Self.parseDecisions(from: collected, category: category)
    }

    // MARK: - Prompt

    nonisolated private static func buildPrompt(
        category: String,
        events: [EventEntry],
        existing: [PortraitEntry],
        evidenceThreshold: Int,
        personal: PersonalInfoConfig
    ) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(personal)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(MemoryPrompts.distillIntro)
        lines.append("Target portrait category: **\(category)**")
        lines.append("")
        lines.append("Definitions:")
        lines.append(MemoryPrompts.distillDefinition(for: category))
        lines.append("")

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"

        // Existing entries — FULL body (weighted merge needs the whole text,
        // not an excerpt) + last-updated date so the LLM can tell which source
        // events post-date the settled entry.
        if existing.isEmpty {
            lines.append("Existing portrait entries in this category: (none)")
        } else {
            lines.append("Existing portrait entries you may UPDATE — these are SETTLED knowledge (slug | title | last updated):")
            for p in existing {
                // 喂 LLM 的是纯正文（去掉 `# 标题` 行和 derived 尾块）——
                // 否则 LLM 合并时会把渲染产物原样抄回，renderBody 再前置标题
                // 就出现重复标题。
                let prose = Self.proseOf(p.body)
                let full = prose.count > 1200 ? String(prose.prefix(1200)) + "…" : prose
                lines.append("  - \(p.slug) | \(p.title) | last updated \(dayFmt.string(from: p.lastUpdated))")
                lines.append("    body: \(full.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("")

        // Source events — impact + weight + created date. `created` lets the
        // LLM judge which events are NEW relative to a settled entry.
        if events.isEmpty {
            lines.append("No new events tagged with this category were captured.")
        } else {
            lines.append("Source events (id | title | impact | weight | created | day-occurrences):")
            for e in events {
                let summary = e.summary.isEmpty ? "(no summary)" : e.summary
                let trim = summary.count > 180 ? String(summary.prefix(180)) + "…" : summary
                lines.append("  - [\(e.id)] \(e.title)  | impact=\(String(format: "%.1f", e.impact)), weight=\(String(format: "%.2f", e.weight)), created=\(dayFmt.string(from: e.created)), days=\(e.occurrenceDays)")
                lines.append("    summary: \(trim.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("")

        // Output spec.
        lines.append(MemoryPrompts.distillOutputSpec(evidenceThreshold: evidenceThreshold))
        return lines.joined(separator: "\n")
    }

    // MARK: - Response parsing

    /// 解析失败时把 LLM 原始响应落盘(~/.portrait/llm_dump/),修复逻辑跟不上
    /// 模型格式新花样时,直接看原文排查。best-effort,失败静默。
    nonisolated private static func dumpParseFailure(response: String, category: String) {
        let dir = Storage.rootURL.appendingPathComponent("llm_dump", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("distill_parsefail_\(category)_\(ms).txt")
        try? response.write(to: url, atomically: true, encoding: .utf8)
        print("[Distill] \(category): parse failure raw response dumped → \(url.lastPathComponent)")
    }

    nonisolated private static func parseDecisions(from response: String, category: String) throws -> [ParsedDecision] {
        // 用 LLMJSON 抽 balanced array(去 fence + 尊重字符串内的 bracket),
        // 比原来的 first/last bracket 抽法稳一档:模型在数组前后的散文 / fence /
        // 字符串字面量里出现 `]` 都不会被错抽。
        let jsonStr: String
        do {
            jsonStr = try LLMJSON.extract(response, expecting: .array)
        } catch {
            Self.dumpParseFailure(response: response, category: category)
            throw DistillError.noJSONInResponse
        }
        guard let data = jsonStr.data(using: .utf8) else {
            throw DistillError.malformedJSON("could not encode response as UTF-8")
        }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) }
        catch {
            // DeepSeek 等 reasoning 模型常给"几乎是 JSON":长 markdown body
            // 字符串里裸换行、尾逗号(strict JSON 不允许)。机械修复后重试,
            // .json5Allowed 顺带兜注释/单引号;仍失败才放弃,dump 原文到
            // llm_dump 便于排查格式新花样。
            let repaired = LLMJSON.repair(jsonStr)
            guard let rdata = repaired.data(using: .utf8),
                  let robj = try? JSONSerialization.jsonObject(with: rdata, options: [.json5Allowed])
            else {
                Self.dumpParseFailure(response: response, category: category)
                throw DistillError.malformedJSON(error.localizedDescription)
            }
            print("[Distill] \(category): strict JSON parse failed, repaired parse succeeded")
            obj = robj
        }
        guard let arr = obj as? [[String: Any]] else {
            throw DistillError.malformedJSON("top-level was not an array of objects")
        }

        var out: [ParsedDecision] = []
        for (idx, entry) in arr.enumerated() {
            let action = (entry["action"] as? String) ?? "noop"
            let rawSlug = (entry["slug"] as? String) ?? ""
            // 写盘前消毒:LLM 偶发照抄目录化路径("skills/swift_ui")或带遍历
            // 成分("../")—— 不消毒的话文件落进嵌套子目录(甚至画像树外),
            // update 按 categoryDir+slug 拼路径永远 miss,同一概念反复 create
            // 分叉。详见 PortraitPaths.sanitizeSlug。
            let slug = PortraitPaths.sanitizeSlug(rawSlug) ?? ""
            if !rawSlug.isEmpty, slug != rawSlug {
                print("[PortraitDistiller] sanitized LLM slug '\(rawSlug)' → '\(slug)'")
            }
            let title = (entry["title"] as? String) ?? ""
            let body = (entry["body"] as? String) ?? ""
            let derived = (entry["derived_from"] as? [String]) ?? []
            guard !slug.isEmpty else {
                if action == "noop" {
                    out.append(ParsedDecision(action: "noop", slug: "", title: "", body: "", derivedFromEventIds: []))
                    continue
                }
                throw DistillError.malformedJSON("entry \(idx + 1) action=\(action) missing slug")
            }
            // derivedFromEventIds 引用回查 —— LLM 可能编造 id(EventBuilder 有
            // defendJoins 机制做同样事,这里给 distill 路径补上)。把不存在的
            // 剔除 + log,避免在 portrait 文件 body 里渲染死链。
            let (kept, dropped) = Self.validateDerivedIds(derived)
            if !dropped.isEmpty {
                print("[PortraitDistiller] decision \(slug): dropped \(dropped.count) hallucinated event id(s): \(dropped.prefix(5).joined(separator: ", "))\(dropped.count > 5 ? "…" : "")")
            }
            // 取证:create/update 决策的 derived 落空持久化进 DiagLog —— 否则只在
            // stdout,事后排查无据。llm_gave=0 → 模型一个 id 都没给;llm_gave>0
            // 且 kept=0 → 给的全是编造 / 对不上、被回查剔光。写盘闸据此跳过空壳。
            if action != "noop", kept.isEmpty {
                DiagLog.warn("distill.derived.empty", ctx: [
                    "category": category, "slug": slug, "action": action,
                    "llm_gave": derived.count, "dropped": dropped.count,
                ])
            }
            out.append(ParsedDecision(
                action: action,
                slug: slug,
                title: title,
                body: body,
                derivedFromEventIds: kept
            ))
        }
        return out
    }

    /// 把 LLM 给出的 event id 数组逐个回查 events/ 下是否真存在,丢掉编造的。
    /// id 形式跟 markEventsDistilled 一致:相对 Storage.eventsDir 的 path
    /// (e.g. "2026-05-16/cluster-foo.md")。
    nonisolated private static func validateDerivedIds(_ ids: [String]) -> (kept: [String], dropped: [String]) {
        let fm = FileManager.default
        var kept: [String] = []
        var dropped: [String] = []
        for id in ids {
            let url = Storage.eventsDir.appendingPathComponent(id)
            if fm.fileExists(atPath: url.path) {
                kept.append(id)
            } else {
                dropped.append(id)
            }
        }
        return (kept, dropped)
    }

    // MARK: - Disk writes

    /// 返回 true = 真写了一个新文件;false = 跳过(空溯源)或委托给 update。
    private func writeNewPortrait(category: String, decision: ParsedDecision) throws -> Bool {
        let dir = PortraitPaths.categoryDir(category)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(decision.slug + ".md")
        // If slug collides with existing file, fall through to update.
        if FileManager.default.fileExists(atPath: url.path) {
            return try updateExistingPortrait(category: category, decision: decision)
        }
        // 不变量:全新 portrait 条目必须有 event 溯源。derived 为空 = 没有任何
        // 来源事件 → 不能凭空创建(否则 weight = ref_count × decay = 0,落出一个
        // 零溯源空壳条目)。跳过不写;事件没被标 distilled → 下轮 distill 重新
        // 看到它,模型这次引用对了就能正常落地。
        guard !decision.derivedFromEventIds.isEmpty else {
            DiagLog.warn("distill.create.skipped_no_evidence", ctx: [
                "category": category, "slug": decision.slug, "title": decision.title,
            ])
            return false
        }
        // Portrait files use `category` as the routing label (kept for human
        // readability inside the file). For type, "experiences" / "emotions"
        // map back to the underlying event types; other categories are
        // facet-driven portrait entries (treated as `experience` by default).
        let portraitType: String = (category == "emotions") ? "emotion" : "experience"
        var file = PortraitFile(
            created: Date(),
            // impact: 不传 —— portrait 不持有 impact（event-only 字段）。
            body: renderBody(decision: decision, derivedIds: decision.derivedFromEventIds),
            source: "distilled",
            tags: [category, "portrait"],
            firstOccurrence: Date(),
            eventTitle: decision.title,
            eventSummary: decision.body,
            eventType: portraitType,
            portraitFacets: [],
            category: category,
            memberFrameIds: []
        )
        // weight = ref_count × exp(-Δt / τ);ref_count 跟 body 渲染保持一致
        // 封顶在 20(renderBody 用 derivedIds.prefix(20)),防止单条超热 facet
        // 把 weight 拉爆。
        file.weight = PortraitWeight.compute(
            refCount: min(decision.derivedFromEventIds.count, 20),
            lastModified: file.created, now: file.created
        )
        // portrait-layer 字段：所有 portrait 文件都要带 mergeCount + lastModified
        // （EMA 衰减锚点）。primaryLabel / aliases / evidenceEventIds 留 nil ——
        // 那几个是 personality concept 专属。
        file.mergeCount = 1
        file.lastModified = file.created
        try PortraitFileIO.write(file, to: url)
        // 回写每个被消费的事件,标记"我已被蒸馏进 <category>/<slug>"。下次
        // distill 通过 distilledInto 按 category 跳过它们,LLM 只看新事件。
        Self.markEventsDistilled(eventIds: decision.derivedFromEventIds,
                                 into: decision.slug, category: category)
        return true
    }

    /// Returns true if file existed and was updated; false if not found.
    @discardableResult
    private func updateExistingPortrait(category: String, decision: ParsedDecision) throws -> Bool {
        let url = PortraitPaths.categoryDir(category).appendingPathComponent(decision.slug + ".md")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var file = try PortraitFileIO.read(from: url)
        // 旧 portrait 文件可能残留 3 个 event-only 字段(早期未做镜像清理)。
        // 写回前清掉,序列化时整行 skip,文件就只剩真正的 portrait 字段。
        file.rawImpact = nil
        file.rebalanceCount = nil
        file.impactSource = nil
        let oldBody = file.body
        // 合并 derived 溯源：旧 body 里已有的 `[[id]]` 与本轮 LLM 引用的
        // 并集（旧的在前、保序），否则 update 会把历史溯源链接抹掉。
        let oldDerived = Self.extractDerivedIds(from: file.body)
        var mergedDerived = oldDerived
        for id in decision.derivedFromEventIds where !mergedDerived.contains(id) {
            mergedDerived.append(id)
        }
        file.eventTitle = decision.title
        file.eventSummary = decision.body
        let newBody = renderBody(decision: decision, derivedIds: mergedDerived)
        file.body = newBody
        file.recordOccurrence(on: Date())    // mark as "still relevant today"
        // body 改了 → 刷新 EMA 锚点 + merge 计数(老文件可能 nil,兜 1)。
        file.mergeCount = (file.mergeCount ?? 1) + 1
        let now = Date()
        file.lastModified = now
        // weight 用合并后的 ref 数(同样封顶 20,跟 render 一致)。
        file.weight = PortraitWeight.compute(
            refCount: min(mergedDerived.count, 20),
            lastModified: now, now: now
        )
        try PortraitFileIO.write(file, to: url)
        // 回写每个被消费的事件,标记"我已被蒸馏进 <category>/<slug>"。
        Self.markEventsDistilled(eventIds: decision.derivedFromEventIds,
                                 into: decision.slug, category: category)

        // 审计日志：body 实际变化才记一条 distill_changelog，供 debug / 回滚。
        if oldBody != newBody {
            let rel = url.path
                .replacingOccurrences(of: Storage.portraitDir.path + "/", with: "")
            let trigger = decision.derivedFromEventIds.isEmpty
                ? nil : decision.derivedFromEventIds.joined(separator: ",")
            ProcessingLogStore().appendChangelog(
                entityId: rel,
                before: oldBody,
                after: newBody,
                triggeredByEventId: trigger,
                reasoning: nil    // distill 输出未含 reasoning 字段
            )
        }
        return true
    }

    /// 从已渲染的 portrait body 抽出纯正文：去掉开头 `# 标题` 行 + 结尾的
    /// `**Derived from events:**` 块。LLM 合并的对象是正文，不是渲染产物。
    nonisolated private static func proseOf(_ body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
        if let idx = lines.firstIndex(where: { $0.hasPrefix("**Derived from events:**") }) {
            lines = Array(lines[..<idx])
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从已渲染 body 的 `**Derived from events:**` 块抽出 `[[id]]` 列表。
    nonisolated private static func extractDerivedIds(from body: String) -> [String] {
        var out: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- [[") && line.hasSuffix("]]") else { continue }
            let inner = line.dropFirst(4).dropLast(2)
            if !inner.isEmpty { out.append(String(inner)) }
        }
        return out
    }

    /// **不再前置 `# 标题`** —— 标题已在 frontmatter event_title 中,UI 顶部
    /// 已渲染 H1,正文里再放就重复。derived 块保留(用户审计 + UI 溯源)。
    /// proseOf() 仍能正确剥老文件残留的 `# title` 行(向后兼容)。
    private func renderBody(decision: ParsedDecision, derivedIds: [String]) -> String {
        var lines: [String] = []
        lines.append(decision.body)
        if !derivedIds.isEmpty {
            lines.append("")
            lines.append("**Derived from events:**")
            for eid in derivedIds.prefix(20) {
                lines.append("- [[\(eid)]]")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - On-disk inventory

    /// One event we'll show to the LLM.
    private struct EventEntry: Sendable {
        let id: String                  // relative path under events/
        let title: String
        let summary: String
        let impact: Double
        let weight: Double              // decayed importance — recency-aware
        let created: Date               // 用于让 LLM 判断"新证据"
        let occurrenceDays: Int
    }

    private struct PortraitEntry: Sendable {
        let slug: String
        let title: String
        let body: String                // 完整 body（加权合并需要看全文，不是摘要）
        let lastUpdated: Date           // 上次蒸馏更新 —— 判定"此后的新事件"基准
        let category: String
    }

    nonisolated private func collectEventsByCategory() async -> [String: [EventEntry]] {
        await Task.detached(priority: .userInitiated) {
            Self.scanEventsSync()
        }.value
    }

    nonisolated private func collectPortraitByCategory() async -> [String: [PortraitEntry]] {
        await Task.detached(priority: .userInitiated) {
            Self.scanPortraitsSync()
        }.value
    }

    /// 把 "<category>/<slug>" 追加到给定 event 文件的 distilledInto。已存在就跳。
    /// **按 (event, category) 记录消费** —— 同一事件可路由进多个 category
    /// (type 路由 + 每个 facet 一份),只记事件级布尔的话,某 category 先消费、
    /// 后续 category 的 LLM 调用失败,重跑时事件会被全局跳过,该 facet 的信号
    /// 永久丢失。失败默默忽略 —— 单个事件回写失败不该让整个 distill 跑废。
    nonisolated private static func markEventsDistilled(eventIds: [String],
                                                        into portraitSlug: String,
                                                        category: String) {
        let fm = FileManager.default
        let mark = category + "/" + portraitSlug
        for id in eventIds {
            let url = Storage.eventsDir.appendingPathComponent(id)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                var f = try PortraitFileIO.read(from: url)
                if !f.distilledInto.contains(mark) {
                    f.distilledInto.append(mark)
                    try PortraitFileIO.write(f, to: url)
                }
            } catch { continue }
        }
    }

    nonisolated private static func scanEventsSync() -> [String: [EventEntry]] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.eventsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var out: [String: [EventEntry]] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            if f.eventTitle.isEmpty && f.eventSummary.isEmpty { continue }
            // 增量 distill:**按 (event, category) 跳过**已消费的事件。
            // distilledInto 存 "<category>/<slug>";老格式纯 slug 无法定位
            // category,维持旧行为视为全局已消费。Backfill join-existing 会
            // 清空 distilledInto,让"事件又活了"的文件重新进入 distill 视野。
            var consumedCategories: Set<String> = []
            var legacyConsumed = false
            for mark in f.distilledInto {
                if let slash = mark.firstIndex(of: "/") {
                    consumedCategories.insert(String(mark[..<slash]))
                } else {
                    legacyConsumed = true
                }
            }
            if legacyConsumed { continue }
            let rel = url.path
                .replacingOccurrences(of: Storage.eventsDir.path + "/", with: "")
            let entry = EventEntry(
                id: rel,
                title: f.eventTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : f.eventTitle,
                summary: f.eventSummary,
                impact: f.impact ?? 0,   // event 必有 impact，?? 0 防御不触发
                weight: f.weight,
                created: f.created,
                occurrenceDays: f.occurrences.count
            )

            // New routing:
            //   - type=experience → portrait/experiences/
            //   - type=emotion    → portrait/emotions/
            //   - every facet     → portrait/<facet name>/
            // (Same event can feed multiple portrait categories.)
            switch f.eventType.lowercased() {
            case "emotion":
                if !consumedCategories.contains("emotions") {
                    out["emotions", default: []].append(entry)
                }
            default:
                if !consumedCategories.contains("experiences") {
                    out["experiences", default: []].append(entry)
                }
            }
            for facet in f.portraitFacets {
                let name = facet.facet.lowercased()
                // Defensive — skip facets that look like routes already
                // handled by type, or facets outside the 9 known buckets.
                guard name != "experiences", name != "emotions" else { continue }
                guard !consumedCategories.contains(name) else { continue }
                out[name, default: []].append(entry)
            }
        }
        // Sort each category's events by impact desc; cap to prevent context bloat.
        for (k, v) in out {
            out[k] = Array(v.sorted { $0.impact > $1.impact }.prefix(50))
        }
        return out
    }

    nonisolated private static func scanPortraitsSync() -> [String: [PortraitEntry]] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Storage.portraitDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var out: [String: [PortraitEntry]] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            let slug = url.deletingPathExtension().lastPathComponent
            let title = f.eventTitle.isEmpty ? slug : f.eventTitle
            let entry = PortraitEntry(
                slug: slug,
                title: title,
                body: f.body,
                lastUpdated: f.lastOccurrence ?? f.created,
                category: f.category
            )
            out[f.category, default: []].append(entry)
        }
        return out
    }
}

// MARK: - Coordinator (mirrors EventBuilder's pattern)

private actor DistillerCoordinator {
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

    /// 被取消(如超时子任务触发 cancelAll)→ 用已收到的部分 buffer resume 等待者,
    /// 让 task group 能 drain、调用方抛错/返回,defer 里的 agent.stop() 才真去杀
    /// 卡住的子进程。否则 awaitTurn 的 continuation 永不 resume → 整条 pipeline
    /// 永久 hang(同 EventBuilder.ResponseCoordinator 的既有修法)。
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
