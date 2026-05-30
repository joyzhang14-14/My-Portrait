import Foundation

/// 项目维度的 event 分组流水线。**只动 `events/_folders/*.json`**,
/// 不动任何 .md 文件,所以 distill / archive / weight / staging 都无感。
///
/// 跑法:
///   1. 收集"未分组" events(在 events/*/*.md 但不在任何 folder.events 里)
///   2. 喂给 LLM:[已有 folders] + [未分组 events title+summary+tags]
///   3. LLM 返回: 已有 folder 的 append、新 folder 的 create(≥ 3 个事件才创建)、
///      其余留 ungrouped(下次跑可能凑够)
///   4. 程序化 patch `_folders/*.json`
///
/// **跑在 event job 之后、distill 之前**:有新事件就分,分完 distill。
@MainActor
final class EventClassifier {
    /// dry-run CLI 等地方需要的默认值。生产 classifier 一律用 init 时传入。
    static let defaultMinNewFolderEvents = 3

    /// 单批喂给 LLM 的未分组 event 上限。批太大 LLM 容易漏 / JSON 截断。
    /// 剩下的下一轮调度自然消化。
    let batchCap: Int
    /// LLM 创建新 folder 的最小事件数。少于这个数留 ungrouped,等下次凑齐。
    /// 用户原话:"3个以上相似的event就可以打包成一个folder"。
    let minEventsForNewFolder: Int

    private let provider: Provider
    private let model: String
    private let perCallTimeout: TimeInterval

    init(provider: Provider = .chatgpt,
         model: String = "gpt-5.4",
         batchCap: Int = 80,
         minEventsForNewFolder: Int = 3,
         perCallTimeout: TimeInterval = 180) {
        self.provider = provider
        self.model = model
        self.batchCap = batchCap
        self.minEventsForNewFolder = minEventsForNewFolder
        self.perCallTimeout = perCallTimeout
    }

    /// 一次 classify 跑的汇总结果,UI 拿去显示。
    struct Result: Sendable {
        var totalUnclassified: Int = 0     // 跑前未分组 event 数
        var classifiedInThisRun: Int = 0   // 本次被归类的 event 数
        var newFoldersCreated: Int = 0
        var existingFoldersUpdated: Int = 0
        var stillUngrouped: Int = 0        // 本次没归类成功 / 数量不足开 folder
        /// 本次落地的 folder 改动,UI 列表显示。
        var folderDeltas: [FolderDelta] = []
    }

    struct FolderDelta: Sendable, Identifiable {
        enum Kind: String, Sendable { case created, updated }
        let id = UUID()
        let slug: String
        let name: String
        let kind: Kind
        /// 本次被加进来的事件数(不含 folder 原有事件)。
        let addedCount: Int
    }

    enum ClassifierError: LocalizedError {
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

    // MARK: - Public entry

    /// 执行一次分类。返回 Result;若没未分组 event 直接返回零值 result(不调 LLM)。
    func classify() async throws -> Result {
        var result = Result()

        // 1) 扫盘列出所有 events 的 relativePath + 拉对应 PortraitFile metadata
        let allEvents = scanAllEvents()
        let classified = EventFolderStore.classifiedEventPaths()
        let unclassified = allEvents.filter { !classified.contains($0.path) }
        result.totalUnclassified = unclassified.count
        guard !unclassified.isEmpty else { return result }

        // 2) 切批
        let batch = Array(unclassified.prefix(batchCap))
        let existing = EventFolderStore.loadAll()

        // 3) 调 LLM
        let prompt = Self.buildPrompt(
            unclassified: batch,
            existingFolders: existing,
            minNewFolderEvents: minEventsForNewFolder
        )
        let raw = try await runLLM(prompt: prompt)
        let decision = try Self.parseDecision(from: raw)

        // 4) 落地 _folders/*.json
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let allPaths = Set(batch.map(\.path))   // 防 LLM 输出未知 path

        // 4a) append 到现有 folder
        var existingBySlug = Dictionary(uniqueKeysWithValues: existing.map { ($0.slug, $0) })
        for assign in decision.appendToExisting {
            guard var folder = existingBySlug[assign.folderSlug] else { continue }
            let toAdd = assign.eventPaths.filter { allPaths.contains($0) && !folder.events.contains($0) }
            guard !toAdd.isEmpty else { continue }
            folder.events.append(contentsOf: toAdd)
            folder.updatedAtMs = nowMs
            try EventFolderStore.save(folder)
            existingBySlug[folder.slug] = folder
            result.existingFoldersUpdated += 1
            result.classifiedInThisRun += toAdd.count
            result.folderDeltas.append(.init(slug: folder.slug, name: folder.name,
                                             kind: .updated, addedCount: toAdd.count))
        }

        // 4b) 创建新 folder(≥ minEventsForNewFolder 才创)
        for newF in decision.newFolders {
            let filtered = newF.eventPaths.filter { allPaths.contains($0) }
            guard filtered.count >= minEventsForNewFolder else { continue }
            var slug = EventFolderStore.makeSlug(from: newF.name)
            // 防 slug 冲突(LLM 可能给跟现有重的 name)
            if existingBySlug[slug] != nil {
                var i = 2
                while existingBySlug["\(slug)-\(i)"] != nil { i += 1 }
                slug = "\(slug)-\(i)"
            }
            let folder = EventFolder(
                slug: slug,
                name: newF.name,
                description: newF.description,
                events: filtered,
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            try EventFolderStore.save(folder)
            existingBySlug[slug] = folder
            result.newFoldersCreated += 1
            result.classifiedInThisRun += filtered.count
            result.folderDeltas.append(.init(slug: slug, name: folder.name,
                                             kind: .created, addedCount: filtered.count))
        }

        result.stillUngrouped = result.totalUnclassified - result.classifiedInThisRun
        return result
    }

    // MARK: - Dry-run hooks (CLI 用,生产路径完全不触发)

    /// dry-run 用:暴露 scan 结果(已分类计数 + 未分组事件列表),不调 LLM。
    struct DryRunScan {
        let classifiedCount: Int
        let unclassified: [EventSummary]
    }
    func dryRunScan() -> DryRunScan {
        let all = scanAllEvents()
        let classified = EventFolderStore.classifiedEventPaths()
        let unclassified = all.filter { !classified.contains($0.path) }
        return DryRunScan(classifiedCount: classified.count, unclassified: unclassified)
    }

    /// dry-run 用:跟生产 classify() 一样调一次 LLM,返回**解析后的 Decision**
    /// (不落盘、不删 LLM 提的未知 path)。
    struct DryRunDecision {
        struct Append { let folderSlug: String; let eventPaths: [String] }
        struct New { let name: String; let description: String; let eventPaths: [String] }
        let appendToExisting: [Append]
        let newFolders: [New]
    }
    func dryRunLLM(
        unclassified: [EventSummary],
        existingFolders: [EventFolder]
    ) async throws -> DryRunDecision {
        let prompt = Self.buildPrompt(
            unclassified: unclassified,
            existingFolders: existingFolders,
            minNewFolderEvents: minEventsForNewFolder
        )
        let raw = try await runLLM(prompt: prompt)
        let parsed = try Self.parseDecision(from: raw)
        return DryRunDecision(
            appendToExisting: parsed.appendToExisting.map {
                .init(folderSlug: $0.folderSlug, eventPaths: $0.eventPaths)
            },
            newFolders: parsed.newFolders.map {
                .init(name: $0.name, description: $0.description, eventPaths: $0.eventPaths)
            }
        )
    }

    // MARK: - Disk scan

    /// `events/<day>/*.md` 全扫。relativePath + title + summary + tags + day。
    /// 跳 `_folders` / `_archive` 等下划线开头的目录(metadata,不是事件)。
    private func scanAllEvents() -> [EventSummary] {
        let fm = FileManager.default
        let root = Storage.eventsDir
        guard let dayDirs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [EventSummary] = []
        for day in dayDirs where !day.hasPrefix("_") {
            let dayURL = root.appendingPathComponent(day, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: dayURL.path) else { continue }
            for name in files where name.hasSuffix(".md") {
                let url = dayURL.appendingPathComponent(name)
                guard let file = try? PortraitFileIO.read(from: url) else { continue }
                // body 头几十字符兜底,极少数老文件 eventTitle/eventSummary 为空。
                let fallback = String(file.body.prefix(120))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(EventSummary(
                    path: "\(day)/\(name)",
                    title: file.eventTitle.isEmpty ? fallback : file.eventTitle,
                    summary: file.eventSummary,
                    tags: file.tags,
                    day: day
                ))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// LLM 喂的 event 索引行 —— 不含全文,只索引。
    /// internal(默认)而非 private,让 dry-run CLI 也能拿到。
    struct EventSummary: Sendable {
        let path: String     // "2026-05-26/foo.md"
        let title: String
        let summary: String
        let tags: [String]
        let day: String
    }

    // MARK: - LLM round-trip (跟 EventBuilder 同结构)

    private func runLLM(prompt: String) async throws -> String {
        let agent = try MemoryAgentFactory.make(provider: provider, model: model)
        do { try await agent.start() }
        catch { throw ClassifierError.agentSpawn(error.localizedDescription) }
        defer { agent.stop() }

        let coordinator = ResponseCoordinator()
        let consumerTask = Task { [events = agent.events] in
            for await event in events { await coordinator.handle(event) }
        }
        defer { consumerTask.cancel() }

        let requestID = UUID().uuidString
        await coordinator.startTurn(id: requestID)
        do { try agent.sendPrompt(prompt, id: requestID) }
        catch { throw ClassifierError.agentSpawn(error.localizedDescription) }

        let collected: String
        do {
            collected = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { await coordinator.awaitTurn() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.perCallTimeout * 1_000_000_000))
                    throw ClassifierError.agentTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw ClassifierError.agentTimeout
        }

        if let err = await coordinator.consumeError(), BudgetSignal.isExhausted(err) {
            throw BudgetExhaustedError(processor: "EventClassifier", message: err)
        }
        return collected
    }

    // MARK: - Prompt + Parsing

    /// LLM 输出契约。
    private struct Decision {
        struct AppendAssignment { let folderSlug: String; let eventPaths: [String] }
        struct NewFolderSpec { let name: String; let description: String; let eventPaths: [String] }
        let appendToExisting: [AppendAssignment]
        let newFolders: [NewFolderSpec]
    }

    private static func buildPrompt(
        unclassified: [EventSummary],
        existingFolders: [EventFolder],
        minNewFolderEvents: Int
    ) -> String {
        var lines: [String] = []
        lines.append("""
        You are grouping events into PROJECT-level folders for a personal-memory app.

        Rules:
        - Folder granularity = PROJECT or BIG ENDEAVOR (e.g. "My Portrait", "Valis",
          "UCI Application", "Family Trip 2026"). NOT topic-level
          (e.g. NOT "audio bugs", NOT "settings UI").
        - One event = at most one folder.
        - Only propose a NEW folder if you have at least \(minNewFolderEvents) events
          for it. Fewer = leave them ungrouped (they may pool with future events).
        - Prefer appending to an EXISTING folder when the project matches.
        - Conservative bias: when unsure, leave ungrouped. Wrong assignment is
          costlier than missed assignment.

        Output: a SINGLE JSON object, no prose. Schema:
        {
          "append_to_existing": [
            { "folder_slug": "<existing slug>", "event_paths": ["<path>", ...] }
          ],
          "new_folders": [
            { "name": "<Project Name>", "description": "<one sentence>",
              "event_paths": ["<path>", ...] }
          ]
        }
        Omit a key if empty.
        """)

        lines.append("")
        lines.append("EXISTING FOLDERS (\(existingFolders.count)):")
        if existingFolders.isEmpty {
            lines.append("  (none yet — propose new ones if patterns emerge)")
        } else {
            for f in existingFolders {
                let count = f.events.count
                let desc = f.description.isEmpty ? "(no description)" : f.description
                lines.append("- slug=\(f.slug)  name=\"\(f.name)\"  count=\(count)")
                lines.append("    \(desc)")
            }
        }

        lines.append("")
        lines.append("UNCLASSIFIED EVENTS (\(unclassified.count)):")
        for ev in unclassified {
            let tags = ev.tags.isEmpty ? "" : "  tags=[\(ev.tags.prefix(5).joined(separator: ","))]"
            lines.append("- path=\(ev.path)")
            lines.append("    title: \(ev.title)")
            if !ev.summary.isEmpty {
                let snippet = String(ev.summary.prefix(180))
                lines.append("    summary: \(snippet)")
            }
            if !tags.isEmpty { lines.append("   \(tags)") }
        }
        return lines.joined(separator: "\n")
    }

    /// 找 JSON 物体 + 解析。LLM 偶尔吐 markdown ```json fence,做点宽容处理。
    private static func parseDecision(from raw: String) throws -> Decision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉可能的 ``` 包围
        let inner: String = {
            if trimmed.hasPrefix("```") {
                let dropped = trimmed.split(separator: "\n").dropFirst().dropLast()
                return dropped.joined(separator: "\n")
            }
            return trimmed
        }()
        guard let startIdx = inner.firstIndex(of: "{"),
              let endIdx = inner.lastIndex(of: "}") else {
            throw ClassifierError.noJSONInResponse
        }
        let json = String(inner[startIdx...endIdx])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClassifierError.malformedJSON("not a JSON object")
        }

        var appends: [Decision.AppendAssignment] = []
        if let arr = root["append_to_existing"] as? [[String: Any]] {
            for entry in arr {
                let slug = entry["folder_slug"] as? String ?? ""
                let paths = entry["event_paths"] as? [String] ?? []
                guard !slug.isEmpty, !paths.isEmpty else { continue }
                appends.append(.init(folderSlug: slug, eventPaths: paths))
            }
        }

        var news: [Decision.NewFolderSpec] = []
        if let arr = root["new_folders"] as? [[String: Any]] {
            for entry in arr {
                let name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let desc = (entry["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let paths = entry["event_paths"] as? [String] ?? []
                guard !name.isEmpty, !paths.isEmpty else { continue }
                news.append(.init(name: name, description: desc, eventPaths: paths))
            }
        }

        return Decision(appendToExisting: appends, newFolders: news)
    }
}
