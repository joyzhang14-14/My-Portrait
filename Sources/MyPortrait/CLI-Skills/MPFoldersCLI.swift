import Foundation

/// `mp-folders` CLI — chat AI 整理 event folder 的工具面。
///
/// 替代 EventClassifier(自动分 folder)的下线 —— folder 不再自动跑 LLM,
/// 改由 chat AI 按用户对话需求,通过这个 CLI 手动 create / add / remove /
/// rename / delete。语义跟 EventFolderStore 一致(每个 folder 是一个
/// `~/.portrait/events/_folders/<slug>.json`,只持 metadata,不动 .md 本体)。
///
/// 子命令:
///   mp-folders list                                       → 所有 folder 概览
///   mp-folders show <slug>                                → folder 详情
///   mp-folders search-events --q "..." [--tag ...] [--start ...] [--end ...]
///                            [--unclassified] [--limit 20]
///                                                         → 候选 event
///   mp-folders create --name "..." --description "..." [--events e1,e2,...]
///   mp-folders add    --slug X --events e1,e2,...
///   mp-folders remove --slug X --events e1,e2,...
///   mp-folders rename --slug X [--name "..."] [--description "..."]
///   mp-folders delete --slug X                            → folder 删,event 回 unclassified
///
/// 时间格式(--start / --end):`today` / `yesterday` / `Nd ago` /
/// `yyyy-MM-dd`。Folder 改动直接落盘(没有 approve/reject 中间态)——
/// folder 是元数据,改错改回去就行,走审核会让"整理 5 天的事"变啰嗦。
///
/// 输出:JSON 到 stdout(成功),JSON {"error": "..."} 到 stderr + exit 1(失败)。
enum MPFoldersCLI {

    static func run(args: [String]) -> Never {
        guard !args.isEmpty else { printUsage(); exit(2) }
        let sub = args[0]
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":           runList()
        case "show":           runShow(args: rest)
        case "search-events":  runSearchEvents(args: rest)
        case "create":         runCreate(args: rest)
        case "add":            runAdd(args: rest)
        case "remove":         runRemove(args: rest)
        case "rename":         runRename(args: rest)
        case "delete":         runDelete(args: rest)
        case "help", "--help", "-h": printUsage(); exit(0)
        default: errJSON("unknown subcommand: \(sub). try `mp-folders help`.")
        }
    }

    // MARK: - list

    private static func runList() -> Never {
        let folders = EventFolderStore.loadAll()
        let arr: [[String: Any]] = folders.map { f in
            [
                "slug":         f.slug,
                "name":         f.name,
                "description":  f.description,
                "count":        f.count,
                "created_at":   isoMs(f.createdAtMs),
                "updated_at":   isoMs(f.updatedAtMs),
            ]
        }
        emitJSON(["folders": arr, "total": folders.count])
    }

    // MARK: - show

    private static func runShow(args: [String]) -> Never {
        guard let slug = args.first(where: { !$0.hasPrefix("--") }) else {
            errJSON("missing <slug>. usage: mp-folders show <slug>")
        }
        guard let f = EventFolderStore.load(slug: slug) else {
            errJSON("folder not found: \(slug)")
        }
        // 拼每个 event 的 metadata(title / day / weight),让 AI 决策时有上下文。
        var events: [[String: Any]] = []
        for rel in f.events {
            let url = Storage.eventsDir.appendingPathComponent(rel)
            if let file = try? PortraitFileIO.read(from: url) {
                events.append([
                    "rel":     rel,
                    "title":   file.eventTitle,
                    "summary": file.eventSummary,
                    "weight":  file.weight,
                    "tags":    file.tags,
                ])
            } else {
                events.append(["rel": rel, "missing": true])
            }
        }
        emitJSON([
            "slug":        f.slug,
            "name":        f.name,
            "description": f.description,
            "count":       f.count,
            "created_at":  isoMs(f.createdAtMs),
            "updated_at":  isoMs(f.updatedAtMs),
            "events":      events,
        ])
    }

    // MARK: - search-events

    private static func runSearchEvents(args: [String]) -> Never {
        let opts = parseOpts(args)
        let q       = opts["q"]?.lowercased()
        let tag     = opts["tag"]?.lowercased()
        let start   = parseDay(opts["start"])
        let end     = parseDay(opts["end"])
        let onlyUnc = opts["unclassified"] != nil
        let limit   = Int(opts["limit"] ?? "20") ?? 20

        let classified = EventFolderStore.classifiedEventPaths()
        let all = scanEventPaths(startDay: start, endDay: end)
        var hits: [[String: Any]] = []
        for rel in all {
            if onlyUnc && classified.contains(rel) { continue }
            let url = Storage.eventsDir.appendingPathComponent(rel)
            guard let f = try? PortraitFileIO.read(from: url) else { continue }
            if let q = q,
               !f.eventTitle.lowercased().contains(q),
               !f.eventSummary.lowercased().contains(q) { continue }
            if let tag = tag,
               !f.tags.contains(where: { $0.lowercased() == tag }) { continue }
            hits.append([
                "rel":          rel,
                "title":        f.eventTitle,
                "summary":      f.eventSummary,
                "weight":       f.weight,
                "tags":         f.tags,
                "classified":   classified.contains(rel),
            ])
            if hits.count >= limit { break }
        }
        emitJSON(["events": hits, "returned": hits.count])
    }

    // MARK: - create

    private static func runCreate(args: [String]) -> Never {
        let opts = parseOpts(args)
        guard let name = opts["name"], !name.isEmpty else {
            errJSON("--name required")
        }
        let desc = opts["description"] ?? ""
        let eventList = parseEventsArg(opts["events"])
        let baseSlug = EventFolderStore.makeSlug(from: name)
        let slug = resolveSlugConflict(baseSlug)
        // 验证 event 路径存在(避免 AI 拼错路径建一个全是死链的 folder)
        var validated: [String] = []
        for rel in eventList {
            let url = Storage.eventsDir.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                errJSON("event not found: \(rel)")
            }
            validated.append(rel)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // 自动建 folder 也在创建时随机固化一色(07-10 用户定稿:随机色生成
        // 后永不变;原来 CLI 建的 folder colorHex=nil,落进每次启动漂移的
        // hashValue 默认色 = 颜色冲突的历史遗留根因之一)。
        let used = Set(EventFolderStore.loadAll().compactMap(\.colorHex))
        let f = EventFolder(slug: slug, name: name, description: desc,
                            events: validated, createdAtMs: now, updatedAtMs: now,
                            colorHex: FolderPalette.assignHex(used: used))
        do {
            try EventFolderStore.save(f)
        } catch {
            errJSON("save failed: \(error.localizedDescription)")
        }
        emitJSON(["ok": true, "slug": slug, "name": name, "count": validated.count])
    }

    // MARK: - add

    private static func runAdd(args: [String]) -> Never {
        let opts = parseOpts(args)
        guard let slug = opts["slug"], !slug.isEmpty else { errJSON("--slug required") }
        let eventList = parseEventsArg(opts["events"])
        guard !eventList.isEmpty else { errJSON("--events required (comma-separated)") }
        guard var f = EventFolderStore.load(slug: slug) else {
            errJSON("folder not found: \(slug)")
        }
        let existing = Set(f.events)
        var added: [String] = []
        for rel in eventList {
            let url = Storage.eventsDir.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                errJSON("event not found: \(rel)")
            }
            if !existing.contains(rel) {
                f.events.append(rel)
                added.append(rel)
            }
        }
        f.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        do { try EventFolderStore.save(f) }
        catch { errJSON("save failed: \(error.localizedDescription)") }
        emitJSON(["ok": true, "slug": slug, "added": added, "count": f.count])
    }

    // MARK: - remove

    private static func runRemove(args: [String]) -> Never {
        let opts = parseOpts(args)
        guard let slug = opts["slug"], !slug.isEmpty else { errJSON("--slug required") }
        let eventList = parseEventsArg(opts["events"])
        guard !eventList.isEmpty else { errJSON("--events required (comma-separated)") }
        guard var f = EventFolderStore.load(slug: slug) else {
            errJSON("folder not found: \(slug)")
        }
        let toRemove = Set(eventList)
        let before = f.events.count
        f.events.removeAll { toRemove.contains($0) }
        let removed = before - f.events.count
        f.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        do { try EventFolderStore.save(f) }
        catch { errJSON("save failed: \(error.localizedDescription)") }
        emitJSON(["ok": true, "slug": slug, "removed": removed, "count": f.count])
    }

    // MARK: - rename

    private static func runRename(args: [String]) -> Never {
        let opts = parseOpts(args)
        guard let slug = opts["slug"], !slug.isEmpty else { errJSON("--slug required") }
        guard var f = EventFolderStore.load(slug: slug) else {
            errJSON("folder not found: \(slug)")
        }
        if let n = opts["name"], !n.isEmpty { f.name = n }
        if let d = opts["description"] { f.description = d }
        f.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        do { try EventFolderStore.save(f) }
        catch { errJSON("save failed: \(error.localizedDescription)") }
        emitJSON(["ok": true, "slug": slug, "name": f.name, "description": f.description])
    }

    // MARK: - delete

    private static func runDelete(args: [String]) -> Never {
        let opts = parseOpts(args)
        guard let slug = opts["slug"], !slug.isEmpty else { errJSON("--slug required") }
        guard EventFolderStore.load(slug: slug) != nil else {
            errJSON("folder not found: \(slug)")
        }
        do { try EventFolderStore.delete(slug: slug) }
        catch { errJSON("delete failed: \(error.localizedDescription)") }
        emitJSON(["ok": true, "slug": slug, "deleted": true])
    }

    // MARK: - Helpers

    /// 列 events/<day>/*.md 的相对路径,可选窗口过滤。`_` 开头目录跳过
    /// (那是 `_folders/`)。
    private static func scanEventPaths(startDay: String?, endDay: String?) -> [String] {
        let fm = FileManager.default
        let root = Storage.eventsDir
        guard let dayDirs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [String] = []
        // 按日新→旧排,大概率 AI 最关心近期。
        let sorted = dayDirs.filter { !$0.hasPrefix("_") }.sorted(by: >)
        for day in sorted {
            if let s = startDay, day < s { continue }
            if let e = endDay,   day > e { continue }
            let dayURL = root.appendingPathComponent(day, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: dayURL.path) else { continue }
            for name in files where name.hasSuffix(".md") {
                out.append("\(day)/\(name)")
            }
        }
        return out
    }

    /// makeSlug 冲突时加 `-2 / -3 / ...` 后缀。
    private static func resolveSlugConflict(_ base: String) -> String {
        if EventFolderStore.load(slug: base) == nil { return base }
        var n = 2
        while EventFolderStore.load(slug: "\(base)-\(n)") != nil { n += 1 }
        return "\(base)-\(n)"
    }

    /// `--events "a/x.md,b/y.md"` → ["a/x.md", "b/y.md"]。trim + 去空。
    private static func parseEventsArg(_ raw: String?) -> [String] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 输出 yyyy-MM-dd 字符串供 day-prefix 比较;接受 `today` / `yesterday` /
    /// `Nd ago` / `yyyy-MM-dd`。失败返回 nil。
    private static func parseDay(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let lower = s.lowercased()
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        if lower == "today"     { return df.string(from: Date()) }
        if lower == "yesterday" {
            return df.string(from: cal.date(byAdding: .day, value: -1, to: Date())!)
        }
        let pattern = #"^(\d+)\s*d\s*ago$"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let nRange = Range(m.range(at: 1), in: lower),
           let n = Int(lower[nRange]) {
            return df.string(from: cal.date(byAdding: .day, value: -n, to: Date())!)
        }
        // yyyy-MM-dd:直接当字符串用(只校验格式)
        if df.date(from: s) != nil { return s }
        return nil
    }

    private static func parseOpts(_ args: [String]) -> [String: String] {
        // 见 MPQueryCLI.parseOpts 同款注释 —— 用 updateValue,别用下标赋值。
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let stripped = String(a.dropFirst(2))
            if let eq = stripped.firstIndex(of: "=") {
                let key = String(stripped[..<eq])
                let val = String(stripped[stripped.index(after: eq)...])
                out.updateValue(val, forKey: key)
                i += 1
                continue
            }
            // 下一个 token 也是 -- 开头 → 当前是 boolean flag(占位空串)。
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out.updateValue(args[i + 1], forKey: stripped)
                i += 2
            } else {
                out.updateValue("", forKey: stripped)
                i += 1
            }
        }
        return out
    }

    private static func isoMs(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }

    private static func emitJSON(_ obj: Any) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        exit(0)
    }

    private static func errJSON(_ msg: String) -> Never {
        let obj = ["error": msg]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }
        exit(1)
    }

    private static func printUsage() {
        let usage = """
        mp-folders — manage My Portrait event folders (project-level grouping)

        usage:
          mp-folders list
          mp-folders show <slug>
          mp-folders search-events --q "..." [--tag ...] [--start ...] [--end ...]
                                   [--unclassified] [--limit 20]
          mp-folders create --name "..." --description "..." [--events e1,e2,...]
          mp-folders add    --slug X --events e1,e2,...
          mp-folders remove --slug X --events e1,e2,...
          mp-folders rename --slug X [--name "..."] [--description "..."]
          mp-folders delete --slug X

        time: today | yesterday | Nd ago | yyyy-MM-dd
        events: comma-separated relative paths under events/ (e.g. 2026-05-16/foo.md)

        Output: JSON to stdout. Errors: JSON {"error": "..."} to stderr + exit 1.
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}
