import Foundation
import os.log

/// 一次性数据路径整合:把历史散落在 `~/.myportrait/` 和
/// `~/Library/Application Support/MyPortrait/` 的用户数据全部归到
/// `~/.portrait/` 下,实现"单一数据目录"。
///
/// 触发时机:每次启动调一次,内部判断"目标已存在 / 源不存在"即 no-op。
/// 文件全部 rename(同卷瞬时,不复制),不可能丢数据 —— 移完才删空目录。
///
/// 调用方:`AppDelegate.applicationDidFinishLaunching` 第一行,
/// **必须在 Services / ConfigStore / AIPaths 任何读路径之前**。
enum PathMigration {

    private static let logger = Logger(subsystem: "com.myportrait", category: "path-migration")

    /// 启动调一次。把旧位置的文件搬到 `~/.portrait/`,旧目录变空就删。
    static func runOnceIfNeeded() {
        let fm = FileManager.default
        let target = Storage.rootURL
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)

        let home = fm.homeDirectoryForCurrentUser

        // 1. config.toml: ~/.myportrait/ → ~/.portrait/
        let oldMyPortrait = home.appendingPathComponent(".myportrait", isDirectory: true)
        if fm.fileExists(atPath: oldMyPortrait.path) {
            for name in (try? fm.contentsOfDirectory(atPath: oldMyPortrait.path)) ?? [] {
                moveIfNeeded(
                    from: oldMyPortrait.appendingPathComponent(name),
                    to: target.appendingPathComponent(name))
            }
            removeIfEmpty(oldMyPortrait)
        }

        // 2. AI 子系统: ~/Library/Application Support/MyPortrait/ → ~/.portrait/
        guard let appSupportBase = try? fm.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: false)
        else { return }
        let oldAI = appSupportBase.appendingPathComponent("MyPortrait", isDirectory: true)
        if fm.fileExists(atPath: oldAI.path) {
            for name in (try? fm.contentsOfDirectory(atPath: oldAI.path)) ?? [] {
                moveIfNeeded(
                    from: oldAI.appendingPathComponent(name),
                    to: target.appendingPathComponent(name))
            }
            removeIfEmpty(oldAI)
        }
    }

    /// 源存在 + 目标不存在 → rename。任一不满足 → 跳过(留给用户/管理员处理)。
    private static func moveIfNeeded(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        guard !fm.fileExists(atPath: dst.path) else {
            logger.notice("skip migrate: target exists \(dst.path, privacy: .public)")
            return
        }
        do {
            try fm.moveItem(at: src, to: dst)
            logger.notice("migrated \(src.lastPathComponent, privacy: .public) → \(dst.path, privacy: .public)")
        } catch {
            logger.error("migrate failed \(src.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// 目录里只剩 .DS_Store(或全空)就删掉。有别的东西就留着。
    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let meaningful = items.filter { $0 != ".DS_Store" }
        guard meaningful.isEmpty else { return }
        try? fm.removeItem(at: dir)
        logger.notice("removed empty dir \(dir.path, privacy: .public)")
    }
}
