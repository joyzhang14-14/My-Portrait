import Foundation
import os.log

private let paLog = Logger(subsystem: "com.myportrait.memory", category: "personality-agent")

/// 单日观察到的一个 personality tag —— 单名词 + 它的证据 event slug 列表。
struct PersonalityTag: Codable, Equatable, Sendable {
    let name: String                   // single noun / kebab-case，如 "verification"
    let evidence: [String]             // 支撑这个 tag 的 event slug（输入子集）
    let ocrKeywords: [String]          // OCR 验证用的关键词（3-6 个），LLM 提供

    enum CodingKeys: String, CodingKey {
        case name
        case evidence
        case ocrKeywords = "ocr_keywords"
    }

    init(name: String, evidence: [String], ocrKeywords: [String] = []) {
        self.name = name
        self.evidence = evidence
        self.ocrKeywords = ocrKeywords
    }

    /// 兼容旧 snapshot(没 ocr_keywords 字段) —— decode 失败回退空数组。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        self.ocrKeywords = try c.decodeIfPresent([String].self, forKey: .ocrKeywords) ?? []
    }
}

/// 单日 personality 快照。PersonalityAgent 输出，PersonalityMerger（P2）消费。
/// Codable —— LLM 返回的 JSON 直接 decode。1-3 个 tag，证据 tag-level。
struct PersonalityDailySnapshot: Codable, Equatable, Sendable {
    let date: String                   // "YYYY-MM-DD"
    let tags: [PersonalityTag]         // 1-3 个；events 不足时空
}

/// 一天的事件 → personality 快照。LLM 路径复刻 ImpactScorer 的 PiAgent +
/// Coordinator + budget 检测，每个 processor 自己一份 actor，不抽共享基类。
///
/// P1 阶段只产 in-memory snapshot：不写盘（P6 才落 personality_daily/），
/// 也不读 portrait/personality/*.md（P2 Merger 的事）。
@MainActor
final class PersonalityAgent {

    enum AgentError: LocalizedError {
        case agentSpawn(String)
        case agentTimeout
        case noJSONInResponse
        case malformedJSON(String)

        var errorDescription: String? {
            switch self {
            case .agentSpawn(let m):    return "Failed to spawn LLM agent: \(m)"
            case .agentTimeout:         return "LLM did not respond within timeout"
            case .noJSONInResponse:     return "LLM response contained no JSON"
            case .malformedJSON(let m): return "LLM JSON parse failed: \(m)"
            }
        }
    }

    private let provider: Provider
    private let model: String
    private let perRunTimeout: TimeInterval

    init(provider: Provider = .chatgpt, model: String = "gpt-5.4", perRunTimeout: TimeInterval = 90) {
        self.provider = provider
        self.model = model
        self.perRunTimeout = perRunTimeout
    }

    // MARK: - 读取一天的 events

    /// 扫 `events/<day>/` 把每个事件读成 `(slug, PortraitFile)`。slug = 文件名
    /// 去 `.md`，用于 snapshot 的 evidenceEventIds 回引。CLI 与 scheduler(P7)
    /// 共用。可选 `minWeight` 过滤(personality refresh 只看高权重事件)。
    static func readEvents(for day: Date,
                           minWeight: Double? = nil) -> [(slug: String, file: PortraitFile)] {
        let fm = FileManager.default
        let dir = PortraitPaths.eventsDayDir(for: day)
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
            if let min = minWeight, f.weight < min { continue }
            out.append((url.deletingPathExtension().lastPathComponent, f))
        }
        return out
    }

    // MARK: - 生成快照

    /// 生产入口：跑一次 LLM round-trip 返回 snapshot。
    func generateDailySnapshot(
        date: Date,
        events: [(slug: String, file: PortraitFile)]
    ) async throws -> PersonalityDailySnapshot {
        try await runWithRaw(date: date, events: events).snapshot
    }

    /// 测试入口（`--personality-prompt-test` CLI 调）：同时返回拼好的 prompt、
    /// LLM 原始 JSON、解析后的 snapshot，方便人工评估 trait 质量。
    func runWithRaw(
        date: Date,
        events: [(slug: String, file: PortraitFile)]
    ) async throws -> (prompt: String, raw: String, snapshot: PersonalityDailySnapshot) {
        let dateStr = Self.dayString(date)
        let sources = events.map { Self.project(slug: $0.slug, file: $0.file) }
        let prompt = Self.buildPrompt(date: dateStr, sources: sources)

        // 空事件日短路：不浪费 LLM round-trip。1-4 个事件的 skip 规则交给
        // LLM（prompt 里的 SKIP CONDITION，阈值 < 5）。
        if events.isEmpty {
            let s = PersonalityDailySnapshot(date: dateStr, tags: [])
            return (prompt: prompt, raw: "(short-circuited: events.isEmpty)", snapshot: s)
        }

        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = Coordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)
        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw AgentError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perRunTimeout * 1_000_000_000))
                    throw AgentError.agentTimeout
                }
                let r = try await group.next()!
                group.cancelAll()
                return r
            }
        } catch is CancellationError {
            throw AgentError.agentTimeout
        }

        // 撞额度优先于解析失败 —— LLM 报额度错时 buffer 空，解析报 noJSON
        // 会掩盖真因。
        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "PersonalityAgent", message: err)
        }

        let parsed = try Self.parseSnapshot(from: collected, fallbackDate: dateStr)
        return (prompt: prompt, raw: collected, snapshot: parsed)
    }

    // MARK: - Prompt 构造

    /// prompt 用的 event 投影 —— 只保留 LLM 需要的字段，不把整个 PortraitFile
    /// 塞进去。
    fileprivate struct SourceEvent {
        let slug: String                // evidenceEventIds 回引
        let title: String
        let summary: String
        let tags: [String]
        let impact: Double              // event 必有，?? 0 仅类型防御
        let portraitFacets: [String]    // 已有 facet 标记（"interests:art" 等），可空
    }

    fileprivate static func project(slug: String, file f: PortraitFile) -> SourceEvent {
        SourceEvent(
            slug: slug,
            title: f.eventTitle,
            summary: f.eventSummary,
            tags: f.tags,
            impact: f.impact ?? 0,
            portraitFacets: f.portraitFacets.map { "\($0.facet):\($0.value)" }
        )
    }

    fileprivate static func buildPrompt(date: String, sources: [SourceEvent]) -> String {
        var lines: [String] = []
        let about = MemoryPrompts.aboutUserBlock(ConfigStore.shared.current.personalInfo)
        if !about.isEmpty { lines.append(about); lines.append("") }
        lines.append(personalityIntro)
        lines.append("DATE: \(date)")
        lines.append("")
        lines.append("EVENTS — id | title | impact | tags | facets:")
        if sources.isEmpty {
            lines.append("  (none)")
        } else {
            for s in sources {
                let trim = s.summary.count > 240
                    ? String(s.summary.prefix(240)) + "…" : s.summary
                lines.append("  - [\(s.slug)] \(s.title) | impact=\(String(format: "%.1f", s.impact)) | tags=[\(s.tags.joined(separator: ","))] | facets=[\(s.portraitFacets.joined(separator: ","))]")
                lines.append("      summary: \(trim.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("")
        lines.append(MemoryPrompts.personalityDailySnapshot)
        return lines.joined(separator: "\n")
    }

    private static let personalityIntro =
        "You are extracting a single day's personality observations from the user's activity events."

    // MARK: - JSON 解析

    private static func parseSnapshot(
        from response: String,
        fallbackDate: String
    ) throws -> PersonalityDailySnapshot {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}") else {
            throw AgentError.noJSONInResponse
        }
        let jsonStr = String(response[first...last])
        guard let data = jsonStr.data(using: .utf8) else {
            throw AgentError.malformedJSON("response not UTF-8")
        }
        do {
            let s = try JSONDecoder().decode(PersonalityDailySnapshot.self, from: data)
            // LLM 偶尔漏 date —— 用 fallback 补。
            guard s.date.isEmpty else { return s }
            return PersonalityDailySnapshot(date: fallbackDate, tags: s.tags)
        } catch {
            throw AgentError.malformedJSON(error.localizedDescription)
        }
    }

    // MARK: - 工具

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static func dayString(_ d: Date) -> String { dayFmt.string(from: d) }
}

// MARK: - PiAgent 事件流 Coordinator（PersonalityAgent 私用，不共享基类）

private actor Coordinator {
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

    /// 本轮 LLM `.error` 事件携带的错误文本（无错误返回 nil）。
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
