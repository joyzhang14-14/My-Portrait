import Foundation
import os.log

private let edLog = Logger(subsystem: "com.myportrait.memory", category: "edit-draft")

/// AI 聊天编辑功能的单文件暂存机制。**每个文件一份独立 draft**,跟
/// `MemoryStaging`(粗粒度整目录快照)解耦。
///
/// 流程:
///   1. `begin(originalURL:request:)` —— 创建 meta sidecar 记下用户需求
///   2. AI 用受控工具读原文件、写新 body 到 draft(`writeNewBody`)
///   3. AI 写 summary(`setSummary`) —— 一句话总结改了什么
///   4. UI 调 `preview()` 给用户看前后对比
///   5a. 用户 approve → `approve()` 把 draft body 落回原文件,追加 EditNote
///        到 frontmatter,删 draft + meta
///   5b. 用户 reject → `reject()` 直接删 draft + meta(原文件不动)
///
/// 暂存目录 `~/.portrait/.edit_draft/` 镜像 events/ + portrait/ 路径。重启
/// app 仍在,审核可跨重启继续。tick 看到 hasAnyPending() = true 会跳过自动
/// distill/personality,避免编辑期间被调度器覆盖。
enum EditDraft {

    enum DraftError: LocalizedError {
        case notUnderPortraitRoot(String)
        case originalMissing(String)
        case alreadyPending(String)
        case draftMissing(String)
        case metaMissing(String)
        case ioFailed(String)
        var errorDescription: String? {
            switch self {
            case .notUnderPortraitRoot(let p): return "Path is not under ~/.portrait: \(p)"
            case .originalMissing(let p):      return "Original file missing: \(p)"
            case .alreadyPending(let p):       return "A draft is already pending for: \(p)"
            case .draftMissing(let p):         return "No draft found for: \(p)"
            case .metaMissing(let p):          return "No draft meta found for: \(p)"
            case .ioFailed(let m):             return "Draft IO failed: \(m)"
            }
        }
    }

    /// draft 的 sidecar metadata。
    struct Meta: Codable, Sendable, Equatable {
        var originalRelPath: String        // relative to Storage.rootURL,例如 "events/2026-05-16/foo.md"
        var request: String                // 用户原话需求
        var summary: String?               // AI 一句话总结,approve 前由 AI 写
        var startedAtMs: Int64

        init(originalRelPath: String, request: String, summary: String? = nil) {
            self.originalRelPath = originalRelPath
            self.request = request
            self.summary = summary
            self.startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    // MARK: - 路径

    private static var draftRoot: URL {
        Storage.rootURL.appendingPathComponent(".edit_draft", isDirectory: true)
    }

    /// 把原文件 URL 映射成 draft 文件 URL(镜像目录结构)。
    /// 例: `~/.portrait/events/2026-05-16/foo.md`
    ///   → `~/.portrait/.edit_draft/events/2026-05-16/foo.md`
    static func draftURL(for originalURL: URL) throws -> URL {
        let rel = try relativePath(originalURL)
        return draftRoot.appendingPathComponent(rel)
    }

    /// meta sidecar URL —— 跟 draft 同目录,改后缀 `.meta.json`。
    static func metaURL(for originalURL: URL) throws -> URL {
        let draft = try draftURL(for: originalURL)
        return draft.deletingPathExtension().appendingPathExtension("meta.json")
    }

    private static func relativePath(_ url: URL) throws -> String {
        let root = Storage.rootURL.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(root) else {
            throw DraftError.notUnderPortraitRoot(p)
        }
        return String(p.dropFirst(root.count))
    }

    // MARK: - 状态查询

    /// 这个原文件有没有 pending draft?
    static func hasPending(originalURL: URL) -> Bool {
        guard let draft = try? draftURL(for: originalURL) else { return false }
        return FileManager.default.fileExists(atPath: draft.path)
    }

    /// 系统里有没有任何 pending draft?(scheduler tick 用 —— 有就跳过自动 job)
    static func hasAnyPending() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: draftRoot.path) else { return false }
        guard let en = fm.enumerator(at: draftRoot, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return false }
        while let url = en.nextObject() as? URL {
            // 至少有一个 .md draft = 有 pending(忽略 .meta.json sidecar)
            if url.pathExtension == "md" { return true }
        }
        return false
    }

    /// 列出所有 pending draft,给 UI 渲染审核列表。
    static func listPending() -> [(originalURL: URL, meta: Meta)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: draftRoot.path) else { return [] }
        guard let en = fm.enumerator(at: draftRoot, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Meta)] = []
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let m = try? JSONDecoder().decode(Meta.self, from: data) else { continue }
            let original = Storage.rootURL.appendingPathComponent(m.originalRelPath)
            out.append((original, m))
        }
        return out.sorted { $0.1.startedAtMs < $1.1.startedAtMs }
    }

    // MARK: - 生命周期

    /// 开一份新 draft session。先验证原文件存在 + 没有现存 pending,然后
    /// 写 meta sidecar(draft body 还没,等 AI 调 writeNewBody 才落)。
    @discardableResult
    static func begin(originalURL: URL, request: String) throws -> Meta {
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw DraftError.originalMissing(originalURL.path)
        }
        if hasPending(originalURL: originalURL) {
            throw DraftError.alreadyPending(originalURL.path)
        }
        let rel = try relativePath(originalURL)
        let meta = Meta(originalRelPath: rel, request: request)
        try writeMeta(meta, originalURL: originalURL)
        return meta
    }

    /// AI 写新 body 到 draft。读原 frontmatter + AI 给的新 body,合一份
    /// 完整 .md 文件落 draftURL。重复调用覆盖上一份。
    static func writeNewBody(originalURL: URL, newBody: String) throws {
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw DraftError.originalMissing(originalURL.path)
        }
        let original = try PortraitFileIO.read(from: originalURL)
        var draft = original
        draft.body = newBody
        let draftPath = try draftURL(for: originalURL)
        try FileManager.default.createDirectory(
            at: draftPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try PortraitFileIO.write(draft, to: draftPath)
    }

    /// AI 写 summary —— approve 落 frontmatter 时用这一句话作 EditNote.summary。
    static func setSummary(originalURL: URL, summary: String) throws {
        let meta = try readMeta(originalURL: originalURL)
        var updated = meta
        updated.summary = summary
        try writeMeta(updated, originalURL: originalURL)
    }

    /// UI 预览:返回(原 body, draft body)。draft 不存在 → throw。
    static func preview(originalURL: URL) throws -> (before: String, after: String) {
        let draftPath = try draftURL(for: originalURL)
        guard FileManager.default.fileExists(atPath: draftPath.path) else {
            throw DraftError.draftMissing(draftPath.path)
        }
        let original = try PortraitFileIO.read(from: originalURL)
        let draft = try PortraitFileIO.read(from: draftPath)
        return (before: original.body, after: draft.body)
    }

    /// 读 draft meta。
    static func readMeta(originalURL: URL) throws -> Meta {
        let metaPath = try metaURL(for: originalURL)
        guard let data = try? Data(contentsOf: metaPath),
              let m = try? JSONDecoder().decode(Meta.self, from: data) else {
            throw DraftError.metaMissing(metaPath.path)
        }
        return m
    }

    private static func writeMeta(_ meta: Meta, originalURL: URL) throws {
        let metaPath = try metaURL(for: originalURL)
        try FileManager.default.createDirectory(
            at: metaPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: metaPath, options: .atomic)
    }

    // MARK: - approve / reject

    /// 用 draft body 替换原文件,追加 EditNote 到 frontmatter,删 draft + meta。
    /// summary 缺失(AI 没写)时,fallback 成 request 前 80 字。
    static func approve(originalURL: URL) throws {
        let meta = try readMeta(originalURL: originalURL)
        let draftPath = try draftURL(for: originalURL)
        guard FileManager.default.fileExists(atPath: draftPath.path) else {
            throw DraftError.draftMissing(draftPath.path)
        }
        let draft = try PortraitFileIO.read(from: draftPath)

        var updated = try PortraitFileIO.read(from: originalURL)
        updated.body = draft.body

        let summary = meta.summary ?? String(meta.request.prefix(80))
        let note = PortraitFile.EditNote(
            date: PortraitFile.truncateToDay(Date()),
            summary: summary,
            request: meta.request)
        var notes = updated.editNotes ?? []
        notes.append(note)
        updated.editNotes = notes

        try PortraitFileIO.write(updated, to: originalURL)
        try cleanup(originalURL: originalURL)
        edLog.notice("approved edit for \(meta.originalRelPath, privacy: .public): \(summary, privacy: .public)")
    }

    /// 删 draft + meta,原文件不动。
    static func reject(originalURL: URL) throws {
        try cleanup(originalURL: originalURL)
        edLog.notice("rejected edit for \(originalURL.lastPathComponent, privacy: .public)")
    }

    private static func cleanup(originalURL: URL) throws {
        let fm = FileManager.default
        for url in [try draftURL(for: originalURL), try metaURL(for: originalURL)]
            where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        // 父目录空了就清掉(保持 .edit_draft/ 干净)。
        try? cleanupEmptyAncestors(from: try draftURL(for: originalURL).deletingLastPathComponent())
    }

    private static func cleanupEmptyAncestors(from dir: URL) throws {
        let fm = FileManager.default
        let rootPath = draftRoot.standardizedFileURL.path
        var current = dir.standardizedFileURL
        while current.path.hasPrefix(rootPath), current.path != rootPath {
            let items = (try? fm.contentsOfDirectory(atPath: current.path)) ?? []
            guard items.isEmpty else { break }
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}
