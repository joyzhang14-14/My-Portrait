import Foundation

/// AI 聊天编辑功能的受控 CLI 工具面。每个子命令是一条原子操作,AI 通过
/// Bash 调用,绝不直接 Read/Write 原文件。配合 EditDraft 的 approve/reject
/// 流程,保证「AI 提议、用户拍板」。
///
/// 路径输入统一用相对路径(相对 ~/.portrait/),例如:
///   - `events/2026-05-16/foo.md`
///   - `portrait/personality/bar.md`
/// 子命令拒绝任何不以 `events/` / `portrait/` 开头的路径,防止 AI 误改
/// 别的文件。
enum AIEditCLI {

    /// dispatcher。返回 true = 命中并执行(已 exit);false = 不识别,交回主路由。
    @discardableResult
    static func dispatch(args: [String]) -> Bool {
        guard let cmd = args.dropFirst().first(where: { $0.hasPrefix("--ai-") }) else {
            return false
        }
        switch cmd {
        case "--ai-list-targets":        listTargets();                 exit(0)
        case "--ai-read":                read(args: args);              exit(0)
        case "--ai-grep":                grep(args: args);              exit(0)
        case "--ai-find-related":        findRelated(args: args);       exit(0)
        case "--ai-draft-begin":         draftBegin(args: args);        exit(0)
        case "--ai-draft-write-body":    draftWriteBody(args: args);    exit(0)
        case "--ai-draft-set-summary":   draftSetSummary(args: args);   exit(0)
        case "--ai-draft-preview":       draftPreview(args: args);      exit(0)
        case "--ai-draft-list-pending":  draftListPending();            exit(0)
        default: return false
        }
    }

    // MARK: - 路径校验

    private static func resolveRel(_ rel: String) -> URL? {
        let url = Storage.rootURL.appendingPathComponent(rel)
        let normalized = url.standardizedFileURL.path
        let allowedRoots = [
            Storage.eventsDir.standardizedFileURL.path + "/",
            Storage.portraitDir.standardizedFileURL.path + "/",
        ]
        guard allowedRoots.contains(where: { normalized.hasPrefix($0) }) else { return nil }
        return url
    }

    private static func argValue(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
        exit(1)
    }

    // MARK: - read 类

    /// 列出所有可编辑文件:`<rel-path> | <title>` 一行一个。
    /// 给 AI 找 slug 用,过滤归档 / 隔离。
    private static func listTargets() {
        let fm = FileManager.default
        var rows: [String] = []
        for root in [Storage.eventsDir, Storage.portraitDir] {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
                if url.pathComponents.contains("_archive")
                    || url.pathComponents.contains("_quarantine") { continue }
                let rel = relativePath(url)
                let title = (try? PortraitFileIO.read(from: url))
                    .map { $0.eventTitle.isEmpty ? rel : $0.eventTitle } ?? rel
                rows.append("\(rel) | \(title)")
            }
        }
        rows.sort()
        for r in rows { print(r) }
    }

    private static func relativePath(_ url: URL) -> String {
        let root = Storage.rootURL.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
    }

    /// `--ai-read <rel-path>` — print 整个 .md 内容(frontmatter + body)。
    private static func read(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-read"), idx + 1 < args.count else {
            die("usage: --ai-read <rel-path>")
        }
        let rel = args[idx + 1]
        guard let url = resolveRel(rel) else { die("path not under events/ or portrait/: \(rel)") }
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else {
            die("read failed: \(url.path)")
        }
        print(s)
    }

    /// `--ai-grep <pattern>` — 跨 events/ + portrait/ 找 pattern,输出
    /// `<rel-path>: <line>`(case-insensitive substring,不是 regex 防 AI 误用)。
    private static func grep(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-grep"), idx + 1 < args.count else {
            die("usage: --ai-grep <pattern>")
        }
        let pattern = args[idx + 1].lowercased()
        guard !pattern.isEmpty else { die("empty pattern") }
        let fm = FileManager.default
        for root in [Storage.eventsDir, Storage.portraitDir] {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
                if url.pathComponents.contains("_archive")
                    || url.pathComponents.contains("_quarantine") { continue }
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let rel = relativePath(url)
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if line.lowercased().contains(pattern) {
                        print("\(rel):\(i + 1): \(line)")
                    }
                }
            }
        }
    }

    /// `--ai-find-related <rel-path>` — 顺 `evidence_event_ids` /
    /// `distilled_into` 符号关系走,列出当前文件双向链接的其他 .md。
    /// 给 AI 第二轮"同步修改"用。
    private static func findRelated(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-find-related"), idx + 1 < args.count else {
            die("usage: --ai-find-related <rel-path>")
        }
        let rel = args[idx + 1]
        guard let url = resolveRel(rel) else { die("path not under events/ or portrait/: \(rel)") }
        guard let f = try? PortraitFileIO.read(from: url) else { die("read failed: \(url.path)") }

        var hits: [String] = []
        // event → distilled_into 指向的 portrait
        for slug in f.distilledInto {
            if let p = locatePortrait(slug: slug) { hits.append(p) }
        }
        // portrait → evidence_event_ids 指向的 events
        for slug in (f.evidenceEventIds ?? []) {
            if let p = locateEvent(slug: slug) { hits.append(p) }
        }
        // 也找谁引用了 self —— 反向扫(symbolic 闭包)
        let selfSlug = url.deletingPathExtension().lastPathComponent
        hits += findReferrers(toSlug: selfSlug)
        for h in Set(hits).sorted() { print(h) }
    }

    private static func locateEvent(slug: String) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Storage.eventsDir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return nil }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
            if url.deletingPathExtension().lastPathComponent == slug {
                return relativePath(url)
            }
        }
        return nil
    }

    private static func locatePortrait(slug: String) -> String? {
        // slug 可能形如 "personality/micro-iteration" 或单纯 "micro-iteration"
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Storage.portraitDir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return nil }
        let bare = (slug as NSString).lastPathComponent
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
            if url.deletingPathExtension().lastPathComponent == bare {
                return relativePath(url)
            }
        }
        return nil
    }

    /// 反向扫:谁 frontmatter 里提了 slug。慢但简单(全表扫),编辑场景频次低。
    private static func findReferrers(toSlug slug: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for root in [Storage.eventsDir, Storage.portraitDir] {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
                guard let f = try? PortraitFileIO.read(from: url) else { continue }
                if f.distilledInto.contains(slug)
                    || (f.evidenceEventIds ?? []).contains(slug) {
                    out.append(relativePath(url))
                }
            }
        }
        return out
    }

    // MARK: - draft 类

    /// `--ai-draft-begin <rel-path> --request-file <file>`
    /// 用户需求从文件读(支持多行)。
    private static func draftBegin(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-draft-begin"), idx + 1 < args.count else {
            die("usage: --ai-draft-begin <rel-path> --request-file <file>")
        }
        let rel = args[idx + 1]
        guard let url = resolveRel(rel) else { die("bad path: \(rel)") }
        guard let reqFile = argValue(args, flag: "--request-file"),
              let request = try? String(contentsOfFile: reqFile, encoding: .utf8) else {
            die("missing --request-file <file>")
        }
        do {
            let meta = try EditDraft.begin(originalURL: url, request: request)
            print("draft started at \(meta.startedAtMs) for \(meta.originalRelPath)")
        } catch { die(error.localizedDescription) }
    }

    /// `--ai-draft-write-body <rel-path> --body-file <file>`
    private static func draftWriteBody(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-draft-write-body"), idx + 1 < args.count else {
            die("usage: --ai-draft-write-body <rel-path> --body-file <file>")
        }
        let rel = args[idx + 1]
        guard let url = resolveRel(rel) else { die("bad path: \(rel)") }
        guard let bodyFile = argValue(args, flag: "--body-file"),
              let body = try? String(contentsOfFile: bodyFile, encoding: .utf8) else {
            die("missing --body-file <file>")
        }
        do {
            try EditDraft.writeNewBody(originalURL: url, newBody: body)
            print("draft body written: \(rel)")
        } catch { die(error.localizedDescription) }
    }

    /// `--ai-draft-set-summary <rel-path> --summary "<text>"` —— summary 短,
    /// inline 即可,不上 --file 模式。
    private static func draftSetSummary(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-draft-set-summary"), idx + 1 < args.count else {
            die("usage: --ai-draft-set-summary <rel-path> --summary <text>")
        }
        let rel = args[idx + 1]
        guard let url = resolveRel(rel) else { die("bad path: \(rel)") }
        guard let summary = argValue(args, flag: "--summary"), !summary.isEmpty else {
            die("missing --summary <text>")
        }
        do {
            try EditDraft.setSummary(originalURL: url, summary: summary)
            print("summary set: \(summary)")
        } catch { die(error.localizedDescription) }
    }

    /// `--ai-draft-preview <rel-path>` — 输出 unified diff 样式(给 AI 自检用)。
    private static func draftPreview(args: [String]) {
        guard let idx = args.firstIndex(of: "--ai-draft-preview"), idx + 1 < args.count else {
            die("usage: --ai-draft-preview <rel-path>")
        }
        let rel = args[idx + 1]
        guard let url = resolveRel(rel) else { die("bad path: \(rel)") }
        do {
            let (before, after) = try EditDraft.preview(originalURL: url)
            print("=== BEFORE ===")
            print(before)
            print("=== AFTER ===")
            print(after)
        } catch { die(error.localizedDescription) }
    }

    /// `--ai-draft-list-pending` — 每行一份 pending draft。
    private static func draftListPending() {
        let pending = EditDraft.listPending()
        for (url, meta) in pending {
            let rel = relativePath(url)
            let summary = meta.summary ?? "(no summary yet)"
            print("\(rel) | request=\"\(meta.request.prefix(60))\" | summary=\"\(summary.prefix(60))\"")
        }
    }
}
