import Foundation

/// AI 子系统的文件布局。跟 capture 层一样统一在 `~/.portrait/` 下 ——
/// 单一数据目录,易于备份 / 清理 / 迁移。
enum AIPaths {
    static var supportDir: URL { Storage.rootURL }

    /// ⚠️ **凭据永远留在真实目录**。dev mode 不切它 —— 这样演示配置拷过去就
    /// 直接能用(TOML 里只有引用名),既不用重新绑定供应商,也不会把 API key
    /// 多复制一份到演示目录里。
    static var secretsDir: URL { supportDir.appendingPathComponent("secrets", isDirectory: true) }
    static var secretsDB: URL { secretsDir.appendingPathComponent("secrets.sqlite") }
    /// secrets.sqlite 的 AES 主密钥(0600)。
    static var masterKey: URL { secretsDir.appendingPathComponent("master.key") }
    /// 首次启动自动下载的运行程序(Bun、pi-agent 包、PATH 目录),跟数据分开放;
    /// 删了会按原逻辑重新安装(10-27 update,原来直接在 `~/.portrait/` 下)。
    static var runtimeDir: URL { supportDir.appendingPathComponent("runtime", isDirectory: true) }
    static var bunDir: URL    { runtimeDir.appendingPathComponent("bun", isDirectory: true) }
    static var bunBinary: URL { bunDir.appendingPathComponent("bin/bun") }
    static var piDir: URL     { runtimeDir.appendingPathComponent("pi-agent", isDirectory: true) }
    static var piCliJS: URL   { piDir.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/cli.js") }
    static var piModelsJSON: URL { piDir.appendingPathComponent("models.json") }

    /// AI agent 用的 CLI 工具目录(注入到 spawned subprocess 的 PATH 里)。
    static var binDir: URL { runtimeDir.appendingPathComponent("bin", isDirectory: true) }

    static func ensureExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    }
}
