import Foundation

/// `~/.portrait/events/_folders/*.json` 的 IO。每个 folder 一个 JSON。
///
/// 单文件 / per-folder 拆分是有意为之:
///   - 多 folder 并发写(EventClassifier 一次性创建多个)→ 互不锁
///   - 用户手改某个 folder(改名 / 删事件)→ 不影响其他
///   - 同步冲突最小 —— iCloud / git 单文件冲突更好处理
///
/// `_folders/` 前缀下划线 → Finder 排序排在 yyyy-MM-dd 日目录上方;
/// 程序化扫 `events/` 时排除以 `_` 开头的项就过滤掉了。
enum EventFolderStore {

    /// `~/.portrait/events/_folders/`
    static var foldersDir: URL {
        Storage.eventsDir.appendingPathComponent("_folders", isDirectory: true)
    }

    /// 列出所有 folder(读盘,按 name 排序)。空目录返回 [],不抛。
    static func loadAll() -> [EventFolder] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: foldersDir.path) else {
            return []
        }
        var out: [EventFolder] = []
        for name in entries where name.hasSuffix(".json") {
            let url = foldersDir.appendingPathComponent(name)
            if let f = try? load(at: url) {
                out.append(f)
            }
        }
        return out.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// 读单个 folder。文件不存在 / JSON 损坏抛错。
    static func load(at url: URL) throws -> EventFolder {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EventFolder.self, from: data)
    }

    /// 按 slug 读;不存在返回 nil(常见路径,不抛)。
    static func load(slug: String) -> EventFolder? {
        let url = foldersDir.appendingPathComponent("\(slug).json")
        return try? load(at: url)
    }

    /// 原子写一个 folder。目录不存在自动建。
    static func save(_ folder: EventFolder) throws {
        try FileManager.default.createDirectory(
            at: foldersDir, withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(folder)
        let url = foldersDir.appendingPathComponent("\(folder.slug).json")
        try data.write(to: url, options: .atomic)
    }

    /// 删一个 folder。不存在静默成功(idempotent)。
    static func delete(slug: String) throws {
        let url = foldersDir.appendingPathComponent("\(slug).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 当前已被任意 folder 索引的 event relativePath 集合。EventClassifier 用它
    /// 算"哪些事件还没分组",只跑增量。
    static func classifiedEventPaths() -> Set<String> {
        var s = Set<String>()
        for f in loadAll() {
            for e in f.events { s.insert(e) }
        }
        return s
    }

    /// name → slug。kebab-case ASCII。冲突时由调用方加后缀。
    static func makeSlug(from name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : out
    }
}
