import Foundation

/// 手动触发的"缓冲区"：跑之前给 `events/` 或 `portrait/` 整棵树拍快照，跑完
/// 进入审核——**Reject** 用快照整树还原、**Approve** 删快照保留。
///
/// 快照落在 `~/.portrait/.staging/`，重启 app 仍在 → 审核可跨重启继续。
/// `hasPending` = 快照目录还在，就是有结果等审核。
///
/// 只管文件树。ProcessingLog 的回退（reject 时把那几天重置回 pending）由
/// 调用方拿 `pendingDays` 自己做。
enum MemoryStaging {
    enum Kind: String, Sendable, CaseIterable {
        case events, portrait, personality, classify
    }

    enum StagingError: LocalizedError {
        case alreadyPending
        var errorDescription: String? {
            switch self {
            case .alreadyPending:
                return "A previous run is still waiting for review."
            }
        }
    }

    /// 一个有实质改动的暂存文件 —— 用于审核列表 + 内容预览。
    struct StagedChange: Identifiable, Sendable, Equatable {
        let id: String           // 相对路径
        let relativePath: String
        let displayTitle: String
        let isNew: Bool
        let beforeText: String?  // 快照里的原文（新文件为 nil）
        let afterText: String    // 跑完的现文
    }

    // MARK: - 路径

    private static var stagingRoot: URL {
        Storage.rootURL.appendingPathComponent(".staging", isDirectory: true)
    }
    private static func backupDir(_ k: Kind) -> URL {
        stagingRoot.appendingPathComponent("\(k.rawValue)_backup", isDirectory: true)
    }
    private static func daysManifest(_ k: Kind) -> URL {
        stagingRoot.appendingPathComponent("\(k.rawValue)_days.json")
    }
    private static func liveDir(_ k: Kind) -> URL {
        switch k {
        case .events:      return Storage.eventsDir
        case .portrait:    return Storage.portraitDir
        case .personality: return Storage.portraitDir.appendingPathComponent("personality", isDirectory: true)
        case .classify:    return EventFolderStore.foldersDir
        }
    }

    // MARK: - 状态

    /// 该 kind 是否有结果在等审核（快照目录存在）。
    static func hasPending(_ k: Kind) -> Bool {
        FileManager.default.fileExists(atPath: backupDir(k).path)
    }

    /// 这次 staged run 处理的 ProcessingLog 行 key（日期串 / `_distill_anchor`）。
    /// reject 时调用方据此重置 ProcessingLog。
    static func pendingDays(_ k: Kind) -> [String] {
        guard let data = try? Data(contentsOf: daysManifest(k)),
              let days = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return days
    }

    // MARK: - 生命周期

    /// 跑之前调：把 live 树整个拷进快照。已有 pending 审核则抛 `alreadyPending`。
    static func beginRun(_ k: Kind) throws {
        let fm = FileManager.default
        guard !hasPending(k) else { throw StagingError.alreadyPending }
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let live = liveDir(k)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.copyItem(at: live, to: backupDir(k))
    }

    /// 跑完调：记下处理的天，供 reject 重置 ProcessingLog。
    static func markRan(_ k: Kind, days: [String]) throws {
        let data = try JSONEncoder().encode(days)
        try data.write(to: daysManifest(k))
    }

    /// 有实质改动的暂存文件列表。**只算实质改动** —— 只有 weight /
    /// last_modified / raw_impact / rebalance_count / impact_source 这类机械
    /// 重算的文件被过滤掉（否则一次 weight pass 会把整棵树标成"改动"）。
    static func changes(_ k: Kind) -> [StagedChange] {
        guard hasPending(k) else { return [] }
        let before = mdTexts(under: backupDir(k))
        let after = mdTexts(under: liveDir(k))
        var out: [StagedChange] = []
        for (rel, afterText) in after {
            if let beforeText = before[rel] {
                guard beforeText != afterText,
                      !onlyMechanicalChange(beforeText, afterText) else { continue }
                out.append(StagedChange(
                    id: rel, relativePath: rel,
                    displayTitle: title(of: afterText, fallback: rel),
                    isNew: false, beforeText: beforeText, afterText: afterText))
            } else {
                out.append(StagedChange(
                    id: rel, relativePath: rel,
                    displayTitle: title(of: afterText, fallback: rel),
                    isNew: true, beforeText: nil, afterText: afterText))
            }
        }
        return out.sorted {
            if $0.isNew != $1.isNew { return $0.isNew && !$1.isNew }
            return $0.relativePath < $1.relativePath
        }
    }

    /// 批准：保留 live，删快照 + 清单。
    static func approve(_ k: Kind) throws {
        let fm = FileManager.default
        for url in [backupDir(k), daysManifest(k)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// 拒绝：用快照整树还原 live，删快照 + 清单。
    static func reject(_ k: Kind) throws {
        let fm = FileManager.default
        let backup = backupDir(k)
        let live = liveDir(k)
        guard fm.fileExists(atPath: backup.path) else { return }
        if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
        try fm.moveItem(at: backup, to: live)
        let manifest = daysManifest(k)
        if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
    }

    // MARK: - 工具

    /// 收集 root 下所有 .md 的 (相对路径 → 原文)。
    private static func mdTexts(under root: URL) -> [String: String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: String] = [:]
        let prefix = root.path + "/"
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let rel = url.path.replacingOccurrences(of: prefix, with: "")
            out[rel] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return out
    }

    /// 机械字段（weight / 衰减锚点 / rebalance 中间量）的 frontmatter 行。
    /// 这些一变不算"实质改动"。
    private static let mechanicalKeys = [
        "weight:", "last_modified:", "raw_impact:",
        "rebalance_count:", "impact_source:", "merge_count:",
    ]

    /// 两份原文除了机械字段行之外完全相同 → 只是机械重算，不进审核列表。
    private static func onlyMechanicalChange(_ a: String, _ b: String) -> Bool {
        stripMechanical(a) == stripMechanical(b)
    }

    private static func stripMechanical(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !mechanicalKeys.contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
    }

    /// 从 .md 原文取展示标题：优先 frontmatter 的 event_title，回退文件名。
    private static func title(of text: String, fallback rel: String) -> String {
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("event_title:") else { continue }
            let v = line.dropFirst("event_title:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !v.isEmpty { return v }
        }
        return (rel as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
    }
}
