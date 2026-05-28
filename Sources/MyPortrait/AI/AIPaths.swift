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

    /// AI agent 用的 CLI 工具目录(注入到 spawned subprocess 的 PATH 里)。
    /// 启动时把 app 主二进制 symlink 进这里成 `mp-query`,agent 通过 bash
    /// 直接调用拿屏幕数据。
    static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    static var mpQueryLink: URL { binDir.appendingPathComponent("mp-query") }

    static func ensureExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    }

    /// 启动时调一次。把 `~/.portrait/bin/mp-query` 指到当前运行的 app 主
    /// 二进制(Bundle.main.executablePath),agent 调 `mp-query ...` 即等于
    /// 调 `MyPortrait --mp-query ...`。app 升级后路径会变,所以每次启动都
    /// 校验 + 重链。
    @discardableResult
    static func installMpQueryLink() -> Bool {
        guard let exec = Bundle.main.executablePath else { return false }
        let fm = FileManager.default
        let link = mpQueryLink.path
        // 1. dir 存在
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        // 2. 已存在的 link / 文件:检查目标是否指当前 exec,不是就重建
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
            if existing == exec { return true }
            try? fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            try? fm.removeItem(atPath: link)
        }
        // 3. 起 symlink。失败(权限 / 文件系统)就放弃,功能 degrade。
        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: exec)
            return true
        } catch {
            return false
        }
    }
}
