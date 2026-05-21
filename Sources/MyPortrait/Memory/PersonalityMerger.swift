import Foundation
import os.log

private let pmLog = Logger(subsystem: "com.myportrait.memory", category: "personality-merger")

/// 一个 observed tag 的归属决定。LLM 对 daily snapshot 的每个 tag 产一个。
/// `evidence` = 该 tag 的 event slug，落盘时累加进 concept 的 evidenceEventIds。
enum PersonalityMergeAction: Equatable, Sendable {
    /// tag 是某现有 concept 的同义 / 近义词 → 合并：新 body + 该 tag 加入 aliases。
    case mergeInto(conceptSlug: String, mergedBody: String, newAliases: [String], evidence: [String])
    /// 全新 personality concept → 建新文件。
    case createNew(primaryLabel: String, body: String, aliases: [String], evidence: [String])
    /// 证据不足 / tag 太模糊 → 跳过。
    case skipTag(tag: String, reason: String)
}

/// 把 PersonalityDailySnapshot 的 traits 合进 portrait/personality/ 的概念文件。
///
/// `merge()` 走 LLM 出决定（[PersonalityMergeAction]）；`applyActions()` 把
/// 决定落盘 —— EMA weight + merge_count + last_modified。两步分开：决定可
/// 单独 review / 测试，落盘是另一回事。
///
/// LLM 路径复刻 ImpactScorer / PersonalityAgent：PiAgent + 私有 Coordinator +
/// budget 检测，不抽共享基类。
@MainActor
final class PersonalityMerger {

    enum MergerError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):    return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:         return "LLM did not respond within timeout"
            case .noJSONInResponse:     return "LLM response contained no JSON array"
            case .malformedJSON(let m): return "LLM JSON parse failed: \(m)"
            }
        }
    }

    struct ApplyResult: Sendable {
        var created: Int = 0
        var merged: Int = 0
        var skipped: Int = 0
        var writtenSlugs: [String] = []
    }

    private let model: String
    private let perRunTimeout: TimeInterval

    init(model: String = "gpt-5.4", perRunTimeout: TimeInterval = 90) {
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    // MARK: - 读取现有 concept

    /// 扫 portrait/personality/ 把每个概念读成 `(slug, PortraitFile)`。
    /// slug = 文件名去 `.md`，mergeInto 用它定位。
    static func readConcepts() -> [(slug: String, file: PortraitFile)] {
        let fm = FileManager.default
        let dir = PortraitPaths.categoryDir("personality")
        guard let en = fm.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(String, PortraitFile)] = []
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_quarantine")
                || url.pathComponents.contains("_archive") { continue }
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            out.append((url.deletingPathExtension().lastPathComponent, f))
        }
        return out
    }

    // MARK: - merge（LLM 决定）

    /// 测试入口：同时返回 prompt、LLM 原始、解析后的 actions。
    func mergeWithRaw(
        snapshot: PersonalityDailySnapshot,
        existingConcepts: [(slug: String, file: PortraitFile)]
    ) async throws -> (prompt: String, raw: String, actions: [PersonalityMergeAction]) {
        let prompt = Self.buildPrompt(snapshot: snapshot, concepts: existingConcepts)

        // tags 为空（snapshot skip 了）→ 无需 LLM。
        if snapshot.tags.isEmpty {
            return (prompt: prompt, raw: "(short-circuited: no tags)", actions: [])
        }

        let agent = try PiAgent(model: model)
        do { try await agent.start() }
        catch { throw MergerError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = MergerCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)
        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw MergerError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perRunTimeout * 1_000_000_000))
                    throw MergerError.agentTimeout
                }
                let r = try await group.next()!
                group.cancelAll()
                return r
            }
        } catch is CancellationError {
            throw MergerError.agentTimeout
        }

        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "PersonalityMerger", message: err)
        }

        let actions = try Self.parseActions(from: collected, tags: snapshot.tags)
        return (prompt: prompt, raw: collected, actions: actions)
    }

    /// 生产入口：跑 LLM 返回 actions。
    func merge(
        snapshot: PersonalityDailySnapshot,
        existingConcepts: [(slug: String, file: PortraitFile)]
    ) async throws -> [PersonalityMergeAction] {
        try await mergeWithRaw(snapshot: snapshot, existingConcepts: existingConcepts).actions
    }

    // MARK: - applyActions（落盘）

    /// 把 actions 落到 portrait/personality/。`on` 是 snapshot 的日期，用作
    /// last_modified。
    @discardableResult
    func applyActions(_ actions: [PersonalityMergeAction], on date: Date) throws -> ApplyResult {
        var result = ApplyResult()
        let today = PortraitFile.truncateToDay(date)
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let ema = WeightEMA(halfLifeDays: halfLife)
        let dir = PortraitPaths.categoryDir("personality")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for action in actions {
            switch action {
            case .skipTag:
                result.skipped += 1

            case .createNew(let primaryLabel, let body, let aliases, let evidence):
                let slug = Self.uniqueSlug(Self.slugify(primaryLabel), in: dir)
                var file = PortraitFile(
                    created: today,
                    // impact: 不传 —— portrait 不持有 impact。
                    body: Self.renderBody(title: primaryLabel, body: body),
                    source: "personality",
                    tags: ["personality", "portrait"],
                    firstOccurrence: today,
                    eventTitle: primaryLabel,
                    eventSummary: body,
                    eventType: "experience",
                    portraitFacets: [],
                    category: "personality",
                    memberFrameIds: []
                )
                file.primaryLabel = primaryLabel
                file.aliases = aliases
                file.mergeCount = 1
                file.weight = 1.0                 // 新 concept = afterMerge(0,0)
                file.lastModified = today
                file.evidenceEventIds = Self.capEvidence(evidence)
                try PortraitFileIO.write(file, to: dir.appendingPathComponent(slug + ".md"))
                result.created += 1
                result.writtenSlugs.append(slug)

            case .mergeInto(let conceptSlug, let mergedBody, let newAliases, let evidence):
                let url = dir.appendingPathComponent(conceptSlug + ".md")
                guard FileManager.default.fileExists(atPath: url.path) else {
                    pmLog.error("mergeInto: concept not found — \(conceptSlug, privacy: .public)")
                    result.skipped += 1
                    continue
                }
                var file = try PortraitFileIO.read(from: url)
                let label = file.primaryLabel ?? file.eventTitle
                file.body = Self.renderBody(title: label, body: mergedBody)
                file.eventSummary = mergedBody
                // aliases 并集，保序去重。
                for a in newAliases where !file.aliases.contains(a) {
                    file.aliases.append(a)
                }
                // evidence 并集（旧在前、保序、去重），尾部截断到 50。
                var mergedEvidence = file.evidenceEventIds
                for e in evidence where !mergedEvidence.contains(e) {
                    mergedEvidence.append(e)
                }
                file.evidenceEventIds = Self.capEvidence(mergedEvidence)
                // EMA：旧 weight 衰减到今天再 +1。
                file.weight = ema.afterMerge(
                    stored: file.weight,
                    daysSinceModified: file.daysSinceModified(now: today))
                file.mergeCount += 1
                file.lastModified = today
                file.recordOccurrence(on: today)
                try PortraitFileIO.write(file, to: url)
                result.merged += 1
                result.writtenSlugs.append(conceptSlug)
            }
        }
        return result
    }

    /// evidence 列表上限 50 —— 满了保留最近的（尾部）。
    private static func capEvidence(_ ids: [String]) -> [String] {
        ids.count > 50 ? Array(ids.suffix(50)) : ids
    }

    // MARK: - Prompt

    fileprivate static func buildPrompt(
        snapshot: PersonalityDailySnapshot,
        concepts: [(slug: String, file: PortraitFile)]
    ) -> String {
        var lines: [String] = [MemoryPrompts.personalityMerge]
        lines.append("")
        lines.append("EXISTING PERSONALITY CONCEPTS (slug | primary_label | aliases):")
        if concepts.isEmpty {
            lines.append("  (none — every tag is necessarily createNew)")
        } else {
            for (slug, f) in concepts {
                let label = f.primaryLabel ?? f.eventTitle
                let aliases = f.aliases.joined(separator: ", ")
                let bodyProse = Self.prose(of: f.body)
                let trimBody = bodyProse.count > 320
                    ? String(bodyProse.prefix(320)) + "…" : bodyProse
                lines.append("  - [\(slug)] \(label) | aliases: \(aliases)")
                lines.append("      body: \(trimBody.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("")
        lines.append("TODAY'S DATE: \(snapshot.date)")
        lines.append("OBSERVED TAGS to place (one decision each):")
        for t in snapshot.tags {
            lines.append("  - \(t.name)")
        }
        return lines.joined(separator: "\n")
    }

    /// 从已渲染 body 抽纯正文（去掉 `# 标题` 行）。
    private static func prose(of body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderBody(title: String, body: String) -> String {
        "# \(title)\n\n\(body)\n"
    }

    // MARK: - JSON 解析

    private static func parseActions(
        from response: String,
        tags: [PersonalityTag]
    ) throws -> [PersonalityMergeAction] {
        guard let first = response.firstIndex(of: "["),
              let last = response.lastIndex(of: "]") else {
            throw MergerError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
        guard let data = jsonStr.data(using: .utf8) else {
            throw MergerError.malformedJSON("response not UTF-8")
        }
        let arr: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw MergerError.malformedJSON("top-level not an array of objects")
            }
            arr = parsed
        } catch let e as MergerError {
            throw e
        } catch {
            throw MergerError.malformedJSON(error.localizedDescription)
        }

        return arr.compactMap { obj -> PersonalityMergeAction? in
            let action = (obj["action"] as? String) ?? ""
            let tagName = (obj["tag"] as? String) ?? ""
            // 该 tag 的 evidence 从 snapshot 取 —— LLM 不必回传，避免漏 slug。
            let evidence = tags.first { $0.name == tagName }?.evidence ?? []
            switch action {
            case "mergeInto":
                guard let slug = obj["conceptSlug"] as? String, !slug.isEmpty,
                      let body = obj["mergedBody"] as? String, !body.isEmpty else { return nil }
                let aliases = (obj["aliases"] as? [String]) ?? []
                return .mergeInto(conceptSlug: slug, mergedBody: body,
                                  newAliases: aliases, evidence: evidence)
            case "createNew":
                guard let label = obj["primaryLabel"] as? String, !label.isEmpty,
                      let body = obj["body"] as? String, !body.isEmpty else { return nil }
                let aliases = (obj["aliases"] as? [String]) ?? []
                return .createNew(primaryLabel: label, body: body,
                                  aliases: aliases, evidence: evidence)
            case "skipTag", "skipTrait":
                return .skipTag(tag: tagName,
                                reason: (obj["reason"] as? String) ?? "unspecified")
            default:
                return nil
            }
        }
    }

    // MARK: - slug 工具

    /// tag → kebab-case slug。tag 本身已是 kebab-case 单名词，这里只做
    /// 防御性规整：小写、非字母数字折成连字符（**保留连字符**，不转下划线，
    /// 这样 slug == tag name，跟 daily snapshot 一致）。
    private static func slugify(_ s: String) -> String {
        var out = ""
        var lastSep = false
        for scalar in s.lowercased().unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c); lastSep = false
            } else if !lastSep {
                out.append("-"); lastSep = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.isEmpty { return "tag" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
    }

    private static func uniqueSlug(_ base: String, in dir: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(base + ".md").path) { return base }
        for n in 2...99 {
            let candidate = "\(base)_\(n)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate + ".md").path) {
                return candidate
            }
        }
        return base
    }
}

// MARK: - PiAgent 事件流 Coordinator（PersonalityMerger 私用）

private actor MergerCoordinator {
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
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending = cont
        }
    }

    func consumeError() -> String? { lastError }

    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d):
            buffer.append(d)
        case .assistantFinalText(let t):
            if buffer.isEmpty { buffer = t }
        case .agentEnd:
            if let p = pending { pending = nil; p.resume(returning: buffer) }
        case .error(let msg):
            lastError = msg
            if let p = pending { pending = nil; p.resume(returning: buffer) }
        default:
            break
        }
    }
}
