import Foundation
import Observation

/// App-wide orchestrator for one-time installs: Bun runtime → Pi npm package.
/// UI observes `state` and surfaces a banner during install.
@MainActor
@Observable
final class AISetup {
    static let shared = AISetup()

    enum State: Equatable {
        case idle
        case checking
        case installingBun(progress: Double)        // 0...1
        case installingPi
        case ready
        case error(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    private init() {}

    /// Idempotent — call from App init or first use. Skips work if already ready.
    func ensureInstalled() {
        if case .ready = state { return }
        if task != nil { return }
        task = Task { await run() }
    }

    /// True if both Bun and Pi are on disk.
    var isReady: Bool {
        if case .ready = state { return true }
        return BunInstaller.isInstalled && PiInstaller.isInstalled
    }

    private func run() async {
        defer { task = nil }
        state = .checking

        // Bun
        if !BunInstaller.isInstalled {
            state = .installingBun(progress: 0)
            do {
                try await BunInstaller.install { [weak self] p in
                    self?.state = .installingBun(progress: p)
                }
            } catch {
                state = .error(error.localizedDescription)
                return
            }
        }

        // Ollama 的模型列表要现拉(不写死),先拉好再写 models.json,否则它的 entry 是空的。
        if Self.ollamaConnected { await OllamaModelStore.shared.refresh() }

        // Pi (depends on Bun)
        if !PiInstaller.isInstalled {
            state = .installingPi
            do {
                try await PiInstaller.install()
                try PiInstaller.writeModelsJSON(providers: Self.configuredProviders())
            }
            catch {
                state = .error(error.localizedDescription)
                return
            }
        } else {
            // Re-write models.json each launch with all currently-configured
            // providers so credential rotation / new providers take effect
            // without forcing a reinstall.
            try? PiInstaller.writeModelsJSON(providers: Self.configuredProviders())
        }

        state = .ready
    }

    /// Ollama 没有凭据可查,看 Connections 里连没连(AppState 存在 UserDefaults 的那份)。
    static var ollamaConnected: Bool {
        UserDefaults.standard.stringArray(forKey: AppState.connectedDefaultsKey)?.contains("ollama") ?? false
    }

    /// All providers the user appears to have credentials for. Used to seed
    /// `models.json` so Pi knows about every configured backend.
    static func configuredProviders() -> [Provider] {
        var out: [Provider] = []
        if ChatGPTOAuth.isLoggedIn() { out.append(.chatgpt) }
        for p in Provider.allCases {
            guard let key = p.secretKey, SecretStore.shared.get(key) != nil else { continue }
            if !out.contains(p) { out.append(p) }
        }
        if ollamaConnected { out.append(.ollama) }
        let local = ConfigStore.shared.current.localModel
        if !local.baseURL.isEmpty, !local.model.isEmpty { out.append(.localModel) }
        return out
    }
}
