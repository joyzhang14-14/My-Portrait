import Foundation
import Observation

/// A background AI worker. The user defines a name + prompt + cadence; the
/// PipeRunner schedules it, and each fire creates a fresh conversation +
/// records a `PipeRun` entry. Pipes survive across launches via UserDefaults.
@MainActor
@Observable
final class PipeStore {
    static let shared = PipeStore()

    private(set) var pipes: [PipeJob] = []

    private let key = "MyPortrait.pipes.v1"
    private let runsCap = 50

    private init() { load() }

    // MARK: - CRUD

    func add(_ p: PipeJob) { pipes.append(p); save() }

    func update(_ p: PipeJob) {
        guard let i = pipes.firstIndex(where: { $0.id == p.id }) else { return }
        pipes[i] = p; save()
    }

    func delete(_ id: UUID) {
        pipes.removeAll { $0.id == id }; save()
    }

    func toggleEnabled(_ id: UUID) {
        guard let i = pipes.firstIndex(where: { $0.id == id }) else { return }
        pipes[i].isEnabled.toggle(); save()
    }

    /// Record a run on a pipe. Caps the runs list at `runsCap` so the JSON
    /// blob doesn't grow forever.
    func appendRun(_ run: PipeRun, to id: UUID) {
        guard let i = pipes.firstIndex(where: { $0.id == id }) else { return }
        pipes[i].runs.insert(run, at: 0)
        if pipes[i].runs.count > runsCap {
            pipes[i].runs = Array(pipes[i].runs.prefix(runsCap))
        }
        pipes[i].lastRunAt = run.startedAt
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PipeJob].self, from: data) else { return }
        pipes = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pipes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct PipeJob: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var prompt: String
    var window: ContextWindow
    var schedule: Cadence
    var isEnabled: Bool
    var runs: [PipeRun]
    var lastRunAt: Date?
    /// Integration ids (see `IntegrationRegistry`) this pipe uses. At run
    /// time their credentials are injected into the agent process as env
    /// vars. Old stored pipes without this key decode to `[]`.
    var connections: [String] = []

    init(id: UUID = UUID(), name: String, prompt: String, window: ContextWindow,
         schedule: Cadence = .everyMinutes(60), isEnabled: Bool = true,
         runs: [PipeRun] = [], lastRunAt: Date? = nil, connections: [String] = []) {
        self.id = id; self.name = name; self.prompt = prompt; self.window = window
        self.schedule = schedule; self.isEnabled = isEnabled
        self.runs = runs; self.lastRunAt = lastRunAt; self.connections = connections
    }
}

struct PipeRun: Identifiable, Hashable, Codable {
    var id: UUID
    /// ChatStore conversation produced by this run — click to open it.
    var convId: UUID
    var startedAt: Date
    /// First ~120 chars of the assistant reply, shown in the runs list.
    var preview: String

    init(id: UUID = UUID(), convId: UUID, startedAt: Date = Date(), preview: String) {
        self.id = id; self.convId = convId; self.startedAt = startedAt; self.preview = preview
    }
}
