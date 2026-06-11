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
    /// distill 消费标记快照(relPath → distilledInto)。只对 .portrait 生成。
    private static func marksManifest(_ k: Kind) -> URL {
        stagingRoot.appendingPathComponent("\(k.rawValue)_marks.json")
    }

    // MARK: - distill 消费标记快照(.portrait 专属)

    /// 主快照只盖 portrait/,但 distiller 还会把 "<category>/<slug>" 消费
    /// 标记(distilledInto)写到 **events/** 的事件文件上。不随 Reject 回滚
    /// 的话,重跑 distiller 会把上次已消费的事件当"已蒸馏"跳过 —— 产出
    /// 变少、每 reject 一次缩一圈。
    /// 不能整树快照 events/:staging pending 期间 event job 可能新建事件,
    /// 整树回滚会把新事件删掉。所以只记/只还原 distilledInto 字段。
    private static func snapshotDistillMarks() throws {
        var map: [String: [String]] = [:]
        forEachEventFile { rel, url in
            if let f = try? PortraitFileIO.read(from: url) {
                map[rel] = f.distilledInto
            }
        }
        let data = try JSONEncoder().encode(map)
        try data.write(to: marksManifest(.portrait), options: .atomic)
    }

    /// Reject 时调:把每个事件的 distilledInto 还原成快照值。读当前文件、
    /// 只换这一个字段再写回 —— 快照之后新建的事件(map 里没有)不动,
    /// 文件的其它新改动也保留。best-effort,单文件失败不阻塞其余。
    private static func restoreDistillMarks() {
        guard let data = try? Data(contentsOf: marksManifest(.portrait)),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        var restored = 0
        forEachEventFile { rel, url in
            guard let recorded = map[rel] else { return }   // 快照后新建:不动
            guard var f = try? PortraitFileIO.read(from: url),
                  f.distilledInto != recorded else { return }
            f.distilledInto = recorded
            if (try? PortraitFileIO.write(f, to: url)) != nil { restored += 1 }
        }
        if restored > 0 {
            print("[MemoryStaging] reject: restored distilledInto on \(restored) event file(s)")
        }
    }

    /// 遍历 events/ 树的事件 .md(跳过 INDEX / _archive / _quarantine ——
    /// 跟 distiller 的扫描口径一致,标记只会出现在这些文件上)。
    private static func forEachEventFile(_ body: (String, URL) -> Void) {
        let fm = FileManager.default
        let root = Storage.eventsDir
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return }
        let prefix = root.path + "/"
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            body(url.path.replacingOccurrences(of: prefix, with: ""), url)
        }
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
        if k == .portrait {
            do { try snapshotDistillMarks() }
            catch {
                // 标记快照失败 → 撤掉主快照再抛,别留"主树能回滚、标记回滚
                // 不了"的半套状态(正是这快照要修的坑)。
                try? fm.removeItem(at: backupDir(k))
                throw error
            }
        }
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
        for url in [backupDir(k), daysManifest(k), marksManifest(k)]
            where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// 拒绝：用快照整树还原 live，删快照 + 清单。
    ///
    /// ⚠️ days 清单缺失 = run 没跑完就中断了(markRan 从未执行)。此时**不能**
    /// 用快照覆盖 live 树:多天 run 里先完成的天 events 已落盘、ProcessingLog
    /// 已标 complete,盲目整树回滚会把这些天的 events 抹掉而状态仍 complete
    /// → isEventCandidate 永远 false,这些天再也不重建,数据永久丢失。
    /// 没有清单就不知道哪些天动过 → 只丢快照、保留 live 树(中断那天的
    /// 半成品由调度器的崩溃恢复 deleteEvents + 重跑负责清理)。
    static func reject(_ k: Kind) throws {
        let fm = FileManager.default
        let backup = backupDir(k)
        let live = liveDir(k)
        guard fm.fileExists(atPath: backup.path) else { return }
        guard fm.fileExists(atPath: daysManifest(k).path) else {
            try discardOrphan(k)
            return
        }
        if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
        try fm.moveItem(at: backup, to: live)
        // distill 的消费标记(distilledInto)写在 events/ 树上,主快照盖不到
        // —— 不还原的话重跑 distiller 会把上次已消费的事件当"已蒸馏"跳过。
        if k == .portrait { restoreDistillMarks() }
        for url in [daysManifest(k), marksManifest(k)]
            where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// 孤儿快照 = 有 backup 目录但 days 清单不存在 —— staged run 在 markRan
    /// 之前崩了(SIGKILL / 断电),结果不完整、不可审。清单存在 = run 跑完
    /// 等审核,是合法 pending,不算孤儿。
    static func isOrphan(_ k: Kind) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: backupDir(k).path)
            && !fm.fileExists(atPath: daysManifest(k).path)
    }

    /// 丢弃孤儿快照:只删 backup,**不动 live 树**(理由见 reject 的注释——
    /// 没有清单不知道哪些天动过,回滚必丢已 complete 的天)。删完
    /// hasPending 变 false,被它卡住的定时调度恢复。
    static func discardOrphan(_ k: Kind) throws {
        let fm = FileManager.default
        for url in [backupDir(k), marksManifest(k)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
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
