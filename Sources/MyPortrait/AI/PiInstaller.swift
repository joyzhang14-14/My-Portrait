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

        try writeModelsJSON(model: "gpt-5.4")
    }

    /// Always re-write `models.json` (cheap; idempotent).
    static func writeModelsJSON(model: String) throws {
        let configDir = piGlobalConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let path = configDir.appendingPathComponent("models.json")

        // Merge with any existing config so we don't clobber other providers.
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
        }
        var providers = (root["providers"] as? [String: Any]) ?? [:]
        providers["openai-chatgpt"] = chatgptProviderEntry(model: model)
        root["providers"] = providers

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    // MARK: - private

    /// Pi reads its provider config from this hard-coded location, regardless
    /// of which app installed Pi. Mirrors Orphies' `get_pi_config_dir()`.
    private static func piGlobalConfigDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    private static func chatgptProviderEntry(model: String) -> [String: Any] {
        // GPT-5 / o-series reject `max_tokens`; require `max_completion_tokens`.
        let needsCompletionTokens = model.hasPrefix("gpt-5") || model.hasPrefix("o1")
                                 || model.hasPrefix("o3") || model.hasPrefix("o4")
        var modelDef: [String: Any] = [
            "id": model,
            "name": model,
            "input": ["text", "image"],
            "maxTokens": 16384,
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]
        ]
        if needsCompletionTokens {
            modelDef["compat"] = ["maxTokensField": "max_completion_tokens"]
        }
        return [
            "baseUrl": "https://chatgpt.com/backend-api",
            "api": "openai-codex-responses",
            "apiKey": "OPENAI_CHATGPT_TOKEN",
            "models": [modelDef]
        ]
    }

    private static func bunAdd(in dir: URL, spec: String) async throws {
        let p = Process()
        p.executableURL = AIPaths.bunBinary
        p.arguments = ["add", spec, "--no-save"]
        p.currentDirectoryURL = dir
        // Bun needs HOME to find its cache.
        var env = ProcessInfo.processInfo.environment
        env["BUN_INSTALL"] = AIPaths.bunDir.path
        p.environment = env

        let stderr = Pipe()
        p.standardError = stderr
        let stdout = Pipe()
        p.standardOutput = stdout

        try p.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in cont.resume() }
        }

        guard p.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.installFailed(err.isEmpty ? "exit \(p.terminationStatus)" : err)
        }
    }
}
