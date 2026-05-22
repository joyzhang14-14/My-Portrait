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
        case events, portrait
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

    struct Summary: Sendable {
        let added: Int       // 跑出来的新文件数
        let modified: Int    // 被改动的已有文件数
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
        k == .events ? Storage.eventsDir : Storage.portraitDir
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

    /// 审核摘要：跟快照比，新增 / 改动了多少 .md。nil = 没有 pending。
    static func summary(_ k: Kind) -> Summary? {
        guard hasPending(k) else { return nil }
        let before = mdFiles(under: backupDir(k))
        let after = mdFiles(under: liveDir(k))
        var added = 0, modified = 0
        for (rel, afterData) in after {
            if let beforeData = before[rel] {
                if beforeData != afterData { modified += 1 }
            } else {
                added += 1
            }
        }
        return Summary(added: added, modified: modified)
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

    /// 收集 root 下所有 .md 的 (相对路径 → 内容)。
    private static func mdFiles(under root: URL) -> [String: Data] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: Data] = [:]
        let prefix = root.path + "/"
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let rel = url.path.replacingOccurrences(of: prefix, with: "")
            out[rel] = (try? Data(contentsOf: url)) ?? Data()
        }
        return out
    }
}
