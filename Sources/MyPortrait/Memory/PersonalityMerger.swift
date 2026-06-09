import Foundation
import os.log

private let pmLog = Logger(subsystem: "com.myportrait.memory", category: "personality-merger")

// MARK: - Multi-source 候选 / 操作 / 概念 body

/// tag 候选的来源。三源:events / portraits / ocr。
enum PersonalitySource: String, Sendable, Equatable, Codable, CaseIterable {
    case events, portraits, ocr
}

/// 一个 tag 候选 —— 从某一源观测到的某个 tag,带证据。
struct PersonalityTagCandidate: Sendable, Equatable {
    let tag: String                  // single noun / kebab-case
    let source: PersonalitySource
    let evidence: [String]           // events:event slug;portraits:portrait 相对路径;ocr:"<date>: w1, w2"
}

/// 上游 PersonalityClusterAgent 把候选 tag 聚类后的产物。一个 cluster =
/// 一组同义候选 + 一个 canonical kebab-case head。下游 merger 一个 cluster
/// 一个决策(mergeInto / createNew / skipCluster)。
struct PersonalityCluster: Sendable, Equatable {
    let head: String                          // canonical kebab-case
    let members: [PersonalityTagCandidate]    // 同义候选(含多源)
}

/// LLM 对每个 cluster 的归属决定。
/// `description` 是 LLM 输出的一句话定义(给"标题就是一个词"的 tag 加可读
/// 解释 —— `verification` / `multitasking` 这种纯单词标签下面就有人能看懂
/// 的句子)。skipCluster 没 description。
enum PersonalityMergeAction: Sendable, Equatable {
    case mergeInto(conceptSlug: String, cluster: PersonalityCluster, description: String?)
    case createNew(cluster: PersonalityCluster, description: String?)
    case skipCluster(head: String, reason: String)
}

/// 概念文件 body 的结构化形式 —— 三个 section,每个 section 一组 string。
/// 落盘是 markdown:`## events / ## portraits / ## ocr` + 列表。
/// 读取时反解析,write 前再 render。**body 即 trace,无 prose**。
struct ConceptBody: Equatable, Sendable {
    var events: [String] = []
    var portraits: [String] = []
    var ocr: [String] = []
    private static let cap = 50

    static func parse(_ text: String) -> ConceptBody {
        var ev: [String] = [], pt: [String] = [], oc: [String] = []
        var cur: PersonalitySource? = nil
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## events") { cur = .events; continue }
            if line.hasPrefix("## portraits") { cur = .portraits; continue }
            if line.hasPrefix("## ocr") { cur = .ocr; continue }
            if line.hasPrefix("#") { cur = nil; continue }     // 别的 heading,退出 section
            guard line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2))
            if item == "(none)" { continue }
            switch cur {
            case .events: ev.append(item)
            case .portraits: pt.append(item)
            case .ocr: oc.append(item)
            case nil: continue
            }
        }
        return ConceptBody(events: ev, portraits: pt, ocr: oc)
    }

    /// **不再前置 `# title`**(已在 frontmatter event_title,UI 自渲)。
    /// `description` 是一句话定义,渲染成 markdown blockquote 放在最顶部。
    /// 老调用方仍可传 title=primaryLabel,内部不用。
    func render(title: String, description: String? = nil) -> String {
        _ = title
        var out = ""
        if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            out += "> \(desc)\n\n"
        }
        func sec(_ name: String, _ items: [String]) {
            out += "## \(name)\n"
            if items.isEmpty { out += "- (none)\n" }
            else { for it in items { out += "- \(it)\n" } }
            out += "\n"
        }
        sec("events", events)
        if !portraits.isEmpty { sec("portraits", portraits) }
        sec("ocr", ocr)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    mutating func add(_ source: PersonalitySource, items: [String]) {
        switch source {
        case .events:
            for it in items where !events.contains(it) { events.append(it) }
            if events.count > Self.cap { events = Array(events.suffix(Self.cap)) }
        case .portraits:
            for it in items where !portraits.contains(it) { portraits.append(it) }
            if portraits.count > Self.cap { portraits = Array(portraits.suffix(Self.cap)) }
        case .ocr:
            for it in items where !ocr.contains(it) { ocr.append(it) }
            if ocr.count > Self.cap { ocr = Array(ocr.suffix(Self.cap)) }
        }
    }
}

// MARK: - PersonalityMerger

/// 把三源汇总的 tag 候选合进 portrait/personality/ 概念文件。
/// **没有 prose body** —— 概念文件 body 是结构化 trace(events/portraits/ocr)。
@MainActor
final class PersonalityMerger {

    enum MergerError: LocalizedError {
        case agentSpawn(String), agentTimeout, noJSONInResponse, malformedJSON(String)
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

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .chatgpt, model: String = "gpt-5.4", perRunTimeout: TimeInterval = 90) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    // MARK: - 读取现有 concept

    static func readConcepts() -> [(slug: String, file: PortraitFile)] {
        let fm = FileManager.default
        let dir = PortraitPaths.categoryDir("personality")
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
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

    // MARK: - merge(cluster-input)

    /// 测试入口:同时返回 prompt / LLM 原始 / 解析后 actions。
    func mergeWithRaw(
        clusters: [PersonalityCluster],
        existingConcepts: [(slug: String, file: PortraitFile)]
    ) async throws -> (prompt: String, raw: String, actions: [PersonalityMergeAction]) {
        let prompt = Self.buildPrompt(clusters: clusters, concepts: existingConcepts)
        if clusters.isEmpty {
            return (prompt: prompt, raw: "(short-circuited: no clusters)", actions: [])
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
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

        let actions = try Self.parseActions(from: collected, clusters: clusters)
        return (prompt: prompt, raw: collected, actions: actions)
    }

    func merge(
        clusters: [PersonalityCluster],
        existingConcepts: [(slug: String, file: PortraitFile)]
    ) async throws -> [PersonalityMergeAction] {
        try await mergeWithRaw(clusters: clusters,
                               existingConcepts: existingConcepts).actions
    }

    // MARK: - applyActions(落盘)

    /// 把 actions 落到 portrait/personality/。同一 slug 的多个 action
    /// (可能来自多个源)合并成一次写入。
    @discardableResult
    func applyActions(_ actions: [PersonalityMergeAction], on date: Date) throws -> ApplyResult {
        var result = ApplyResult()
        let today = PortraitFile.truncateToDay(date)
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let ema = WeightEMA(halfLifeDays: halfLife)
        let dir = PortraitPaths.categoryDir("personality")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default

        // 按目标 slug 分组(同一概念可能在一次 run 里收多个 cluster:罕见,
        // 但保留 grouping 防 LLM 把同义两组都判到同一个 existing concept)。
        var groups: [String: [PersonalityMergeAction]] = [:]
        for action in actions {
            switch action {
            case .createNew(let cluster, _):
                groups[Self.slugify(cluster.head), default: []].append(action)
            case .mergeInto(let slug, _, _):
                groups[slug, default: []].append(action)
            case .skipCluster:
                result.skipped += 1
            }
        }

        for (slug, group) in groups {
            let url = dir.appendingPathComponent(slug + ".md")
            let exists = fm.fileExists(atPath: url.path)
            // 第一个 createNew 的 cluster head 兜底 primaryLabel。
            var primaryLabel = slug
            for a in group {
                if case .createNew(let cluster, _) = a { primaryLabel = cluster.head; break }
            }

            // 取最早出现的非空 description 作为这个概念的"一句话定义"。
            // mergeInto / createNew 都可能带 description,优先 createNew 的
            // (新概念的解释更可靠),再 fallback mergeInto。
            var pickedDescription: String? = nil
            for a in group {
                if case .createNew(_, let d) = a, let s = d, !s.isEmpty {
                    pickedDescription = s; break
                }
            }
            if pickedDescription == nil {
                for a in group {
                    if case .mergeInto(_, _, let d) = a, let s = d, !s.isEmpty {
                        pickedDescription = s; break
                    }
                }
            }

            var file: PortraitFile
            var body: ConceptBody
            var aliases: [String]
            if exists {
                file = try PortraitFileIO.read(from: url)
                file.rawImpact = nil; file.rebalanceCount = nil; file.impactSource = nil
                body = ConceptBody.parse(file.body)
                aliases = file.aliases ?? []
                primaryLabel = file.primaryLabel ?? primaryLabel
            } else {
                file = PortraitFile(
                    created: today,
                    body: "",
                    source: "personality",
                    tags: ["personality", "portrait"],
                    firstOccurrence: today,
                    eventTitle: primaryLabel,
                    eventSummary: "",
                    eventType: "experience",
                    portraitFacets: [],
                    category: "personality",
                    memberFrameIds: []
                )
                body = ConceptBody()
                aliases = []
            }

            // 应用每个 cluster 的成员证据 / 别名。
            for action in group {
                switch action {
                case .createNew(let cluster, _):
                    for m in cluster.members {
                        body.add(m.source, items: m.evidence)
                        // member.tag ≠ head → 加进 aliases(head 本身就是 primary)
                        if m.tag != primaryLabel && !aliases.contains(m.tag) {
                            aliases.append(m.tag)
                        }
                    }
                case .mergeInto(_, let cluster, _):
                    // cluster 整组都是 existing concept 的同义词 → head + 成员
                    // 都进 aliases,证据按源落 body。
                    if cluster.head != primaryLabel && !aliases.contains(cluster.head) {
                        aliases.append(cluster.head)
                    }
                    for m in cluster.members {
                        body.add(m.source, items: m.evidence)
                        if m.tag != primaryLabel && !aliases.contains(m.tag) {
                            aliases.append(m.tag)
                        }
                    }
                case .skipCluster: continue
                }
            }

            file.primaryLabel = primaryLabel
            // 空数组 → nil,让 PortraitFileIO 跳过 frontmatter 行(否则会
            // 出现 "aliases: []" 这种无信息量的行)。
            file.aliases = aliases.isEmpty ? nil : aliases
            file.body = body.render(title: primaryLabel, description: pickedDescription)
            file.eventTitle = primaryLabel
            // 存一句话定义到 eventSummary —— MemoriesView 顶部 / Draft sheet
            // 都能直接读这字段渲染副标题。空串保留旧行为(skipCluster 群组)。
            file.eventSummary = pickedDescription ?? ""
            let evIds = ConceptBody.capList(body.events)
            file.evidenceEventIds = evIds.isEmpty ? nil : evIds
            file.recordOccurrence(on: today)
            file.mergeCount = (file.mergeCount ?? 0) + group.count
            // 先按「上次修改」算 EMA 衰减,再把 lastModified 推到今天 —— 顺序反了
            // 的话 daysSinceModified 永远是 0,衰减被绕过。
            if exists {
                file.weight = ema.afterMerge(
                    stored: file.weight,
                    daysSinceModified: file.daysSinceModified(now: today))
            } else {
                file.weight = 1.0
            }
            file.lastModified = today
            try PortraitFileIO.write(file, to: url)
            if exists { result.merged += 1 } else { result.created += 1 }
            result.writtenSlugs.append(slug)
        }
        return result
    }

    // MARK: - Prompt

    fileprivate static func buildPrompt(
        clusters: [PersonalityCluster],
        concepts: [(slug: String, file: PortraitFile)]
    ) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(ConfigStore.shared.current.personalInfo)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(MemoryPrompts.personalityMerge)
        lines.append("")
        lines.append("EXISTING PERSONALITY CONCEPTS (slug | primary_label | aliases):")
        if concepts.isEmpty {
            lines.append("  (none — every cluster is necessarily createNew)")
        } else {
            for (slug, f) in concepts {
                let label = f.primaryLabel ?? f.eventTitle
                let aliases = (f.aliases ?? []).joined(separator: ", ")
                lines.append("  - [\(slug)] \(label) | aliases: \(aliases)")
            }
        }
        lines.append("")
        lines.append("CLUSTERS to place (one decision each — head + member tags for context):")
        for cl in clusters {
            let memberStr = cl.members.map(\.tag).joined(separator: ", ")
            lines.append("  - head=\(cl.head)  members=[\(memberStr)]")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    private static func parseActions(
        from response: String,
        clusters: [PersonalityCluster]
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

        // head → cluster 索引,防 LLM 错配 / 漏配。
        // uniquingKeysWith「首个胜」:重复 head 不再 fatalError(parseClusters /
        // orphan 兜底都可能产生同名 head);被丢的重复项由下面 orphan 循环重新
        // 兜成 createNew,applyActions 按 slug 归并,数据不丢。
        let byHead = Dictionary(clusters.map { ($0.head, $0) }, uniquingKeysWith: { first, _ in first })
        var decided = Set<String>()
        var out: [PersonalityMergeAction] = []
        for obj in arr {
            let action = (obj["action"] as? String) ?? ""
            let head = (obj["head"] as? String) ?? ""
            guard let cluster = byHead[head] else { continue }
            decided.insert(head)
            let descRaw = (obj["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description: String? = (descRaw?.isEmpty ?? true) ? nil : descRaw
            switch action {
            case "mergeInto":
                guard let slug = obj["conceptSlug"] as? String, !slug.isEmpty else { continue }
                out.append(.mergeInto(conceptSlug: slug, cluster: cluster, description: description))
            case "createNew":
                out.append(.createNew(cluster: cluster, description: description))
            case "skipCluster", "skipTag", "skipTrait":
                out.append(.skipCluster(head: head,
                                        reason: (obj["reason"] as? String) ?? "unspecified"))
            default: continue
            }
        }
        // 兜底:LLM 漏判的 cluster → createNew(防数据丢失)。
        for cl in clusters where !decided.contains(cl.head) {
            pmLog.notice("orphan cluster head=\(cl.head, privacy: .public) — defaulting to createNew")
            out.append(.createNew(cluster: cl, description: nil))
        }
        return out
    }

    // MARK: - slug 工具

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
}

extension ConceptBody {
    /// 给 evidence_event_ids frontmatter 用的截断(跟 events section 同源)。
    static func capList(_ a: [String], cap: Int = 50) -> [String] {
        a.count > cap ? Array(a.suffix(cap)) : a
    }
}

// MARK: - PiAgent 事件流 Coordinator

private actor MergerCoordinator {
    private var buffer: String = ""
    private var currentID: String?
    private var pending: CheckedContinuation<String, Never>?
    private var lastError: String?

    func startTurn(id: String) {
        buffer = ""; currentID = id; pending = nil; lastError = nil
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
    func consumeError() -> String? { lastError }
    func handle(_ event: PiAgent.Event) {
        switch event {
        case .textDelta(let d): buffer.append(d)
        case .assistantFinalText(let t): if buffer.isEmpty { buffer = t }
        case .agentEnd:
            if let p = pending { pending = nil; p.resume(returning: buffer) }
        case .error(let msg):
            lastError = msg
            if let p = pending { pending = nil; p.resume(returning: buffer) }
        default: break
        }
    }
}
