import Foundation

/// AI 子系统的文件布局。跟 capture 层一样统一在 `~/.portrait/` 下 ——
/// 单一数据目录,易于备份 / 清理 / 迁移。旧版本曾分到
/// `~/.portrait/`,启动时 `PathMigration` 把
/// 旧位置的文件搬过来。
enum AIPaths {
    static var supportDir: URL { Storage.rootURL }

    static var secretsDB: URL { supportDir.appendingPathComponent("secrets.sqlite") }
    static var chatDB: URL    { supportDir.appendingPathComponent("chat.sqlite") }
    static var bunDir: URL    { supportDir.appendingPathComponent("bun", isDirectory: true) }
    static var bunBinary: URL { bunDir.appendingPathComponent("bin/bun") }
    static var piDir: URL     { supportDir.appendingPathComponent("pi-agent", isDirectory: true) }
    static var piCliJS: URL   { piDir.appendingPathComponent("node_modules/@mariozechner/pi-coding-agent/dist/cli.js") }
    static var piModelsJSON: URL { piDir.appendingPathComponent("models.json") }

    static func ensureExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}
