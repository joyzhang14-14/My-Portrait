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

        // Pi (depends on Bun)
        if !PiInstaller.isInstalled {
            state = .installingPi
            do { try await PiInstaller.install() }
            catch {
                state = .error(error.localizedDescription)
                return
            }
        } else {
            // Re-write models.json each launch so a token rotation / model change
            // takes effect without forcing a reinstall.
            try? PiInstaller.writeModelsJSON(model: "gpt-5.4")
        }

        state = .ready
    }
}
