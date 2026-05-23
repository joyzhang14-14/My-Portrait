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

/// LLM 对每个 tag 候选的归属决定。
enum PersonalityMergeAction: Sendable, Equatable {
    case mergeInto(conceptSlug: String, candidate: PersonalityTagCandidate)
    case createNew(candidate: PersonalityTagCandidate)
    case skipTag(tag: String, reason: String)
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

    func render(title: String) -> String {
        var out = "# \(title)\n"
        func sec(_ name: String, _ items: [String]) {
            out += "\n## \(name)\n"
            if items.isEmpty { out += "- (none)\n" }
            else { for it in items { out += "- \(it)\n" } }
        }
        sec("events", events)
        sec("portraits", portraits)
        sec("ocr", ocr)
        return out
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

    private let model: String
    private let perRunTimeout: TimeInterval

    init(model: String = "gpt-5.4", perRunTimeout: TimeInterval = 90) {
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

    // MARK: - merge(多源)

    /// 测试入口:同时返回 prompt / LLM 原始 / 解析后 actions。
    func mergeWithRaw(
        candidates: [PersonalityTagCandidate],
        existingConcepts: [(slug: String, file: PortraitFile)]
    ) async throws -> (prompt: String, raw: String, actions: [PersonalityMergeAction]) {
        let prompt = Self.buildPrompt(candidates: candidates, concepts: existingConcepts)
        if candidates.isEmpty {
            return (prompt: prompt, raw: "(short-circuited: no candidates)", actions: [])
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

        let actions = try Self.parseActions(from: collected, candidates: candidates)
        return (prompt: prompt, raw: collected, actions: actions)
    }

    func merge(
        candidates: [PersonalityTagCandidate],
        existingConcepts: [(slug: String, file: PortraitFile)]
    ) async throws -> [PersonalityMergeAction] {
        try await mergeWithRaw(candidates: candidates,
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

        // 按目标 slug 分组(同一概念可能在一次 run 里收多个候选)。
        var groups: [String: [PersonalityMergeAction]] = [:]
        for action in actions {
            switch action {
            case .createNew(let cand):
                groups[Self.slugify(cand.tag), default: []].append(action)
            case .mergeInto(let slug, _):
                groups[slug, default: []].append(action)
            case .skipTag:
                result.skipped += 1
            }
        }

        for (slug, group) in groups {
            let url = dir.appendingPathComponent(slug + ".md")
            let exists = fm.fileExists(atPath: url.path)
            // 候选 tag 列表 + 第一个 createNew 用作 primaryLabel 兜底。
            var primaryLabel = slug
            for a in group {
                if case .createNew(let cand) = a { primaryLabel = cand.tag; break }
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

            // 应用每个 action 的 candidate evidence / 别名。
            for action in group {
                switch action {
                case .createNew(let cand):
                    body.add(cand.source, items: cand.evidence)
                    // createNew 的 tag 本身不进 aliases(它就是 primary_label)
                case .mergeInto(_, let cand):
                    body.add(cand.source, items: cand.evidence)
                    // mergeInto 的 tag 是同义词 → 加 aliases
                    if cand.tag != primaryLabel && !aliases.contains(cand.tag) {
                        aliases.append(cand.tag)
                    }
                case .skipTag: continue
                }
            }

            file.primaryLabel = primaryLabel
            file.aliases = aliases
            file.body = body.render(title: primaryLabel)
            file.eventTitle = primaryLabel
            file.eventSummary = ""
            file.evidenceEventIds = ConceptBody.capList(body.events)
            file.recordOccurrence(on: today)
            file.mergeCount = (file.mergeCount ?? 0) + group.count
            file.lastModified = today
            if exists {
                file.weight = ema.afterMerge(
                    stored: file.weight,
                    daysSinceModified: file.daysSinceModified(now: today))
            } else {
                file.weight = 1.0
            }
            try PortraitFileIO.write(file, to: url)
            if exists { result.merged += 1 } else { result.created += 1 }
            result.writtenSlugs.append(slug)
        }
        return result
    }

    // MARK: - Prompt

    fileprivate static func buildPrompt(
        candidates: [PersonalityTagCandidate],
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
                let aliases = (f.aliases ?? []).joined(separator: ", ")
                lines.append("  - [\(slug)] \(label) | aliases: \(aliases)")
            }
        }
        lines.append("")
        lines.append("OBSERVED TAGS to place (one decision each — note source for context):")
        for c in candidates {
            lines.append("  - \(c.tag)  (source: \(c.source.rawValue))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    private static func parseActions(
        from response: String,
        candidates: [PersonalityTagCandidate]
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

        var out: [PersonalityMergeAction] = []
        for obj in arr {
            let action = (obj["action"] as? String) ?? ""
            let tagName = (obj["tag"] as? String) ?? ""
            // 每个 candidate 都对应一个 action(同 tag 多源 → 多个 action,
            // 各自带源 + 证据;applyActions 会把它们 group 进同一 concept)。
            let matchedCands = candidates.filter { $0.tag == tagName }
            if matchedCands.isEmpty { continue }
            for cand in matchedCands {
                switch action {
                case "mergeInto":
                    guard let slug = obj["conceptSlug"] as? String, !slug.isEmpty else { continue }
                    out.append(.mergeInto(conceptSlug: slug, candidate: cand))
                case "createNew":
                    out.append(.createNew(candidate: cand))
                case "skipTag", "skipTrait":
                    out.append(.skipTag(tag: tagName,
                                        reason: (obj["reason"] as? String) ?? "unspecified"))
                default: continue
                }
            }
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
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending = cont
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
