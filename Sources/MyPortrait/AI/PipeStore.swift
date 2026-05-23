import Foundation
import Observation

/// A background AI worker. The user defines a name + prompt + cadence; the
/// CronJobRunner schedules it, and each fire creates a fresh conversation +
/// records a `CronJobRun` entry. Pipes survive across launches as one
/// directory per pipe under `~/.portrait/pipes/` (screenpipe-style):
/// `<slug>/pipe.md` (frontmatter + prompt) + `<slug>/runs.json` (history).
@MainActor
@Observable
final class CronJobStore {
    static let shared = CronJobStore()

    private(set) var cronJobs: [CronJob] = []

    /// Legacy UserDefaults key — only read once for the one-time migration.
    private let legacyKey = "MyPortrait.cronJobs.v1"
    private let runsCap = 50

    private init() { load() }

    // MARK: - CRUD

    func add(_ p: CronJob) { pipes.append(p); save() }

    func update(_ p: CronJob) {
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
    func appendRun(_ run: CronJobRun, to id: UUID) {
        guard let i = pipes.firstIndex(where: { $0.id == id }) else { return }
        pipes[i].runs.insert(run, at: 0)
        if pipes[i].runs.count > runsCap {
            pipes[i].runs = Array(pipes[i].runs.prefix(runsCap))
        }
        pipes[i].lastRunAt = run.startedAt
        save()
    }

    // MARK: - Persistence

    /// Run history sidecar (`runs.json`) — runtime data kept out of pipe.md.
    private struct RunsSidecar: Codable {
        var runs: [CronJobRun]
        var lastRunAt: Date?
    }

    /// Load all pipes from `~/.portrait/pipes/`. If that directory has no
    /// pipe sub-directories, attempt a one-time migration from the legacy
    /// UserDefaults JSON blob.
    private func load() {
        let fm = FileManager.default
        let dir = Storage.cronJobsDir

        let subdirs = (try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []

        let withPipeMd = subdirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("pipe.md").path) }

        guard !withPipeMd.isEmpty else {
            migrateFromUserDefaults()
            return
        }

        var loaded: [CronJob] = []
        for sub in withPipeMd {
            let mdURL = sub.appendingPathComponent("pipe.md")
            guard let text = try? String(contentsOf: mdURL, encoding: .utf8),
                  var job = CronJobFile.parseMarkdown(text, fallbackName: sub.lastPathComponent) else { continue }
            if let rData = try? Data(contentsOf: sub.appendingPathComponent("runs.json")),
               let sidecar = try? JSONDecoder().decode(RunsSidecar.self, from: rData) {
                job.runs = sidecar.runs
                job.lastRunAt = sidecar.lastRunAt
            }
            loaded.append(job)
        }
        pipes = loaded
    }

    /// One-time migration: decode the legacy `[CronJob]` JSON, write it out
    /// in the new directory format, then drop the UserDefaults key.
    private func migrateFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let decoded = try? JSONDecoder().decode([CronJob].self, from: data) else { return }
        pipes = decoded
        save()
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// Full rewrite of `~/.portrait/pipes/` (pipe count is tiny). Each pipe
    /// gets `<slug>/pipe.md` + `<slug>/runs.json`; slug collisions get a
    /// numeric suffix; directories for deleted pipes are removed.
    private func save() {
        let fm = FileManager.default
        let root = Storage.cronJobsDir
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var usedSlugs: Set<String> = []
        var keepDirs: Set<String> = []

        for pipe in pipes {
            var slug = CronJobFile.slug(pipe.name)
            var n = 2
            while usedSlugs.contains(slug) { slug = "\(CronJobFile.slug(pipe.name))-\(n)"; n += 1 }
            usedSlugs.insert(slug)
            keepDirs.insert(slug)

            let dir = root.appendingPathComponent(slug, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let md = CronJobFile.renderMarkdown(pipe)
            try? md.write(to: dir.appendingPathComponent("pipe.md"), atomically: true, encoding: .utf8)

            let sidecar = RunsSidecar(runs: pipe.runs, lastRunAt: pipe.lastRunAt)
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            if let rData = try? enc.encode(sidecar) {
                try? rData.write(to: dir.appendingPathComponent("runs.json"), options: .atomic)
            }
        }

        // Drop directories that no longer correspond to a live pipe.
        let existing = (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for sub in existing {
            let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir, !keepDirs.contains(sub.lastPathComponent) {
                try? fm.removeItem(at: sub)
            }
        }
    }
}

struct CronJob: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var prompt: String
    var window: ContextWindow
    var schedule: Cadence
    var isEnabled: Bool
    var runs: [CronJobRun]
    var lastRunAt: Date?
    /// Integration ids (see `IntegrationRegistry`) this pipe uses. At run
    /// time their credentials are injected into the agent process as env
    /// vars. Old stored pipes without this key decode to `[]`.
    var connections: [String] = []

    init(id: UUID = UUID(), name: String, prompt: String, window: ContextWindow,
         schedule: Cadence = .everyMinutes(60), isEnabled: Bool = true,
         runs: [CronJobRun] = [], lastRunAt: Date? = nil, connections: [String] = []) {
        self.id = id; self.name = name; self.prompt = prompt; self.window = window
        self.schedule = schedule; self.isEnabled = isEnabled
        self.runs = runs; self.lastRunAt = lastRunAt; self.connections = connections
    }
}

struct CronJobRun: Identifiable, Hashable, Codable {
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
