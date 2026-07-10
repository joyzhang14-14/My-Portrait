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

    /// UI 改名:只改 `name`,**不动 slug**(slug 是文件名 + cron job/AI 引用
    /// folder 的 stable id;改 slug 会让 cron 下次 add 找不到、分裂出重复
    /// folder)。跟 `mp-folders rename` 同语义。
    static func rename(slug: String, to newName: String) throws {
        guard var f = load(slug: slug) else { return }
        f.name = newName
        f.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try save(f)
    }

    /// UI 改颜色:写 colorHex(load→改→save,保留其它字段)。nil = 清掉回默认色。
    static func setColor(slug: String, hex: String?) throws {
        guard var f = load(slug: slug) else { return }
        f.colorHex = hex
        f.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try save(f)
    }

    /// 一次性迁移(07-10 用户定稿"随机色生成之后就不会变"):没设过颜色的
    /// 存量 folder 随机固化一个预设色写盘。此前默认色用 Swift hashValue,
    /// 每次启动随机化种子 → 没设色的 folder 每次启动换色且易撞色(颜色
    /// 冲突的历史遗留根因)。幂等:colorHex 非 nil 一律跳过(不覆盖手选色),
    /// 全部已固化时零写盘。App 启动调一次。
    static func migrateAssignColors() {
        let all = loadAll()
        var used = Set(all.compactMap(\.colorHex))
        for var f in all where f.colorHex == nil {
            let hex = FolderPalette.assignHex(used: used)
            f.colorHex = hex
            used.insert(hex)
            try? save(f)
        }
    }

    /// 把一个 event 移到目标 folder:先从**所有**别的 folder 移除(模型约束 ——
    /// 一个 event 只属一个 folder),再加进 target。target 不存在静默不做。
    static func assignEvent(_ rel: String, toSlug target: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for var f in loadAll() {
            if f.slug == target { continue }
            if f.events.contains(rel) {
                f.events.removeAll { $0 == rel }
                f.updatedAtMs = now
                try save(f)
            }
        }
        guard var t = load(slug: target) else { return }
        if !t.events.contains(rel) {
            t.events.append(rel)
            t.updatedAtMs = now
            try save(t)
        }
    }

    /// 某 event 被删除时,从所有 folder 的 events[] 摘掉它的引用(避免 folder
    /// 指向死路径 + count 虚高)。
    static func removeEventEverywhere(_ rel: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for var f in loadAll() where f.events.contains(rel) {
            f.events.removeAll { $0 == rel }
            f.updatedAtMs = now
            try save(f)
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
