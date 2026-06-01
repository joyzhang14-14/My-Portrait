import Foundation

/// Installs the `@mariozechner/pi-coding-agent` npm package via Bun and writes
/// Pi's `models.json` provider config under `~/.pi/agent/` (Pi's hard-coded
/// config dir — same as Orphies uses).
enum PiInstaller {

    /// Pin the same Pi version Orphies ships.
    static let packageSpec = "@mariozechner/pi-coding-agent@0.60.0"

    enum InstallError: LocalizedError {
        case bunMissing
        case installFailed(String)
        case cliMissing
        var errorDescription: String? {
            switch self {
            case .bunMissing:           return "Bun runtime not installed."
            case .installFailed(let m): return "bun add failed: \(m)"
            case .cliMissing:           return "Pi cli.js missing after install."
            }
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AIPaths.piCliJS.path)
    }

    /// Install (or upgrade to the pinned version) and write models.json.
    static func install() async throws {
        guard BunInstaller.isInstalled else { throw InstallError.bunMissing }
        try AIPaths.ensureExists()
        let fm = FileManager.default
        try fm.createDirectory(at: AIPaths.piDir, withIntermediateDirectories: true)

        try await bunAdd(in: AIPaths.piDir, spec: packageSpec)

        guard isInstalled else { throw InstallError.cliMissing }

        try writeModelsJSON(providers: [.chatgpt])
    }

    /// Pi 0.60 起内置 catalog 覆盖 openai-codex / openai / anthropic / google
    /// 等主流 provider —— 这些**不需要** models.json。这个方法现在只为
    /// **非内置** provider(ollama / perplexity / deepseek)写自定义 entry,schema 走
    /// Pi 0.60 的 ModelsConfigSchema:
    ///   { providers: { <name>: { baseUrl, api, apiKey, models: [...] } } }
    /// apiKey 值是个 env var 名(resolveConfigValue 会拿 process.env 去解析),
    /// 实际值由 PiAgent.start 时通过 env 注入。
    /// 没传或全是内置 provider → models.json 删掉(避免老残留污染)。
    static func writeModelsJSON(providers: [Provider]) throws {
        let custom = providers.filter { needsCustomEntry($0) }
        let configDir = piGlobalConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let path = configDir.appendingPathComponent("models.json")

        if custom.isEmpty {
            // 没自定义 provider → 删掉文件,免得老的 schema 残留报错。
            try? FileManager.default.removeItem(at: path)
            return
        }

        var providerMap: [String: Any] = [:]
        for p in custom {
            providerMap[p.piName] = providerEntry(for: p)
        }
        let root: [String: Any] = ["providers": providerMap]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    /// 内置 provider 不需要 models.json(Pi 0.60 自带 catalog)。
    private static func needsCustomEntry(_ p: Provider) -> Bool {
        switch p {
        case .ollama, .perplexity, .deepseek: return true
        default:                    return false
        }
    }

    // MARK: - private

    /// Pi reads its provider config from this hard-coded location, regardless
    /// of which app installed Pi. Mirrors Orphies' `get_pi_config_dir()`.
    private static func piGlobalConfigDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    /// 给一个自定义(非 Pi 0.60 内置)provider 拼 models.json entry。
    /// schema:Pi 0.60 ModelsConfigSchema(model-registry.js)
    ///   { baseUrl, api, apiKey, models: [{ id, input, cost, maxTokens, ... }] }
    /// apiKey 字段写的是 env var 名 —— resolveConfigValue 会 process.env
    /// 去拿真值,真值由 PiAgent.start 时通过 env 注入(perplexity 走
    /// PERPLEXITY_API_KEY)。ollama 不验 key,写个 placeholder。
    private static func providerEntry(for p: Provider) -> [String: Any] {
        let apiKeyField: String = {
            switch p {
            case .ollama:     return "ollama"   // Ollama 不验,占位即可
            default:          return p.apiKeyEnv.isEmpty ? "" : p.apiKeyEnv
            }
        }()
        let modelDefs: [[String: Any]] = p.availableModels.map { model in
            return [
                "id": model,
                "name": model,
                "input": ["text"],
                "maxTokens": 4096,
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]
            ]
        }
        return [
            "baseUrl": p.baseURL,
            "api": p.wireApi,            // 都是 "openai-completions"
            "apiKey": apiKeyField,
            "models": modelDefs
        ]
    }

    private static func bunAdd(in dir: URL, spec: String) async throws {
        let bun = AIPaths.bunBinary
        let bunDir = AIPaths.bunDir
        // 整段同步阻塞放 detached 线程(别堵协程池)。两个老坑一并规避:
        //   ① 原来 terminationHandler 装在 run() 之后 —— 进程若在 run 与装 handler
        //      之间退出,handler 永不触发 → continuation 永挂。改用 waitUntilExit
        //      收尸,与时序无关,无竞争。
        //   ② 原来 stdout/stderr 全程不抽干 —— bun add 输出 >64KB 会撑满管道缓冲,
        //      子进程卡在 write 永不退出。这里把 stderr 并进 stdout 一条管道,持续
        //      readDataToEndOfFile 读到 EOF(= 子进程退出),边读边排空,不会卡。
        // Process 在闭包内创建,避免跨线程捕获非 Sendable 对象。
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = bun
            p.arguments = ["add", spec, "--no-save"]
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["BUN_INSTALL"] = bunDir.path     // Bun needs HOME to find its cache.
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe                // 合并两路,单管道排空即可
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let out = String(data: data, encoding: .utf8) ?? ""
                throw InstallError.installFailed(out.isEmpty ? "exit \(p.terminationStatus)" : out)
            }
        }.value
    }
}
