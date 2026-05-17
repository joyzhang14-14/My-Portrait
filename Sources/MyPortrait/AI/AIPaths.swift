import Foundation

/// Filesystem layout for AI subsystem.
/// Lives under `~/Library/Application Support/MyPortrait/` per Apple guidelines,
/// separate from the legacy `~/.portrait/` tree managed by `Storage`.
enum AIPaths {
    static var supportDir: URL {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil,
                               create: true)
        return base.appendingPathComponent("MyPortrait", isDirectory: true)
    }

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
