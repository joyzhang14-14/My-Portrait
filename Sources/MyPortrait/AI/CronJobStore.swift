import Foundation
import Observation

/// A background AI worker. The user defines a name + prompt + cadence; the
/// CronJobRunner schedules it, and each fire creates a fresh conversation +
/// records a `CronJobRun` entry. Cron Jobs survive across launches as one
/// directory per cronJob under `~/.portrait/cronJobs/` (screenpipe-style):
/// `<slug>/cron_job.md` (frontmatter + prompt) + `<slug>/runs.json` (history).
@MainActor
@Observable
final class CronJobStore {
    static let shared = CronJobStore()

    private(set) var cronJobs: [CronJob] = []

    /// Legacy UserDefaults key — only read once for the one-time migration.
    private let legacyKey = "MyPortrait.cronJobs.v1"
    /// runs.json 留多少条 —— 读 GeneralConfig.cronJobHistoryLimit。0 = 不裁。
    /// 用户在 Settings → General 改下拉时实时生效(applyHistoryLimit 主动调一次)。
    private var runsCap: Int {
        ConfigStore.shared.current.general.cronJobHistoryLimit
    }

    private init() {
        load()
        // mp-query cronjob add/remove 落盘后 post Darwin notification,
        // 主 app 这边 observe 一下立刻重读,免得用户为了看新 cron job 重启 app。
        // observer 回调在任意线程,跳回 main 调 load()。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(MPQueryCronJobCLI.reloadNotification),
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.load() }
        }
    }

    // MARK: - CRUD

    func add(_ p: CronJob) { cronJobs.append(p); save() }

    func update(_ p: CronJob) {
        guard let i = cronJobs.firstIndex(where: { $0.id == p.id }) else { return }
        cronJobs[i] = p; save()
    }

    func delete(_ id: UUID) {
        cronJobs.removeAll { $0.id == id }; save()
    }

    func toggleEnabled(_ id: UUID) {
        guard let i = cronJobs.firstIndex(where: { $0.id == id }) else { return }
        cronJobs[i].isEnabled.toggle(); save()
    }

    /// 静音/解静音指定 cron job 的通知。任务执行不受影响,只是 banner 不弹。
    /// 调用方:CronJobsView 详情 toggle、通知 banner 的 Mute 按钮、Settings →
    /// Notifications 的 Unmute、ConfigStore 的老名单迁移。
    func setMuted(_ id: UUID, _ muted: Bool) {
        guard let i = cronJobs.firstIndex(where: { $0.id == id }) else { return }
        guard cronJobs[i].muted != muted else { return }
        cronJobs[i].muted = muted
        save()
    }

    /// Record a run on a cronJob. Caps the runs list at `runsCap` so the JSON
    /// blob doesn't grow forever.
    ///
    /// **关键**:LLM 还没跑完就要先 appendRun 一次,占位 preview="" —— 让
    /// TimelineSidebar 的 `cronJobConvIds` 立刻能识别这条 conv 是 cron run,
    /// 不会出现在 RECENTS 里。LLM 跑完调 `updateRunPreview` 补 preview。
    /// 不这样的话:cronJob 跑了 LLM 几分钟 / 失败 / app 中途退出 → conv 永远
    /// 显示在 RECENTS 里。
    func appendRun(_ run: CronJobRun, to id: UUID) {
        guard let i = cronJobs.firstIndex(where: { $0.id == id }) else { return }
        cronJobs[i].runs.insert(run, at: 0)
        let cap = runsCap
        if cap > 0, cronJobs[i].runs.count > cap {
            // 裁掉超出 cap 的那部分 —— **同时把对应 conv 从 ChatStore 删掉**。
            // 不删的话,被 cronJob runs[] 剔除的 conv 因为没人引用了,
            // TimelineSidebar.cronJobConvIds 反查不到,会回弹到 RECENTS 区,
            // 完全不是用户预期的"超 cap 自动 GC"行为。
            let dropped = cronJobs[i].runs.suffix(from: cap)
            for r in dropped {
                ChatStore.shared.deleteConversation(r.convId)
            }
            cronJobs[i].runs = Array(cronJobs[i].runs.prefix(cap))
        }
        cronJobs[i].lastRunAt = run.startedAt
        save()
    }

    /// 用户改 Settings → General → CronJob history limit 时调一次,把所有
    /// cronJob 的 runs[] 裁到当前 cap。limit=0(no limit)→ 全保留。
    /// 跟 appendRun 一样,被裁掉的 run 对应的 conv 同步从 ChatStore 删,
    /// 避免回弹到 RECENTS。
    func applyHistoryLimit() {
        let cap = runsCap
        guard cap > 0 else { return }
        var changed = false
        for i in cronJobs.indices where cronJobs[i].runs.count > cap {
            let dropped = cronJobs[i].runs.suffix(from: cap)
            for r in dropped {
                ChatStore.shared.deleteConversation(r.convId)
            }
            cronJobs[i].runs = Array(cronJobs[i].runs.prefix(cap))
            changed = true
        }
        if changed { save() }
    }

    /// LLM 跑完后更新已有 run 的 preview。按 convId 找。LLM 中途失败的话
    /// preview 留空,run 仍然在,RECENTS 仍然不显示这条 conv。
    func updateRunPreview(convId: UUID, preview: String) {
        for i in cronJobs.indices {
            guard let runIdx = cronJobs[i].runs.firstIndex(where: { $0.convId == convId })
            else { continue }
            cronJobs[i].runs[runIdx].preview = preview
            save()
            return
        }
    }

    // MARK: - Persistence

    /// Run history sidecar (`runs.json`) — runtime data kept out of cron_job.md.
    private struct RunsSidecar: Codable {
        var runs: [CronJobRun]
        var lastRunAt: Date?
    }

    /// Load all cronJobs from `~/.portrait/cronJobs/`. If that directory has no
    /// cronJob sub-directories, attempt a one-time migration from the legacy
    /// UserDefaults JSON blob.
    private func load() {
        let fm = FileManager.default
        let dir = Storage.cronJobsDir

        let subdirs = (try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []

        let withCronJobMd = subdirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("cron_job.md").path) }

        guard !withCronJobMd.isEmpty else {
            migrateFromUserDefaults()
            return
        }

        var loaded: [CronJob] = []
        for sub in withCronJobMd {
            let mdURL = sub.appendingPathComponent("cron_job.md")
            guard let text = try? String(contentsOf: mdURL, encoding: .utf8),
                  var job = CronJobFile.parseMarkdown(text, fallbackName: sub.lastPathComponent) else { continue }
            if let rData = try? Data(contentsOf: sub.appendingPathComponent("runs.json")),
               let sidecar = try? JSONDecoder().decode(RunsSidecar.self, from: rData) {
                job.runs = sidecar.runs
                job.lastRunAt = sidecar.lastRunAt
            }
            loaded.append(job)
        }
        cronJobs = loaded
    }

    /// One-time migration: decode the legacy `[CronJob]` JSON, write it out
    /// in the new directory format, then drop the UserDefaults key.
    private func migrateFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let decoded = try? JSONDecoder().decode([CronJob].self, from: data) else { return }
        cronJobs = decoded
        save()
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// Full rewrite of `~/.portrait/cronJobs/` (cronJob count is tiny). Each cronJob
    /// gets `<slug>/cron_job.md` + `<slug>/runs.json`; slug collisions get a
    /// numeric suffix; directories for deleted cronJobs are removed.
    private func save() {
        let fm = FileManager.default
        let root = Storage.cronJobsDir
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var usedSlugs: Set<String> = []
        var keepDirs: Set<String> = []

        for cronJob in cronJobs {
            var slug = CronJobFile.slug(cronJob.name)
            var n = 2
            while usedSlugs.contains(slug) { slug = "\(CronJobFile.slug(cronJob.name))-\(n)"; n += 1 }
            usedSlugs.insert(slug)
            keepDirs.insert(slug)

            let dir = root.appendingPathComponent(slug, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let md = CronJobFile.renderMarkdown(cronJob)
            try? md.write(to: dir.appendingPathComponent("cron_job.md"), atomically: true, encoding: .utf8)

            let sidecar = RunsSidecar(runs: cronJob.runs, lastRunAt: cronJob.lastRunAt)
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            if let rData = try? enc.encode(sidecar) {
                try? rData.write(to: dir.appendingPathComponent("runs.json"), options: .atomic)
            }
        }

        // Drop directories that no longer correspond to a live cronJob.
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
    /// Integration ids (see `IntegrationRegistry`) this cronJob uses. At run
    /// time their credentials are injected into the agent process as env
    /// vars. Old stored cronJobs without this key decode to `[]`.
    var connections: [String] = []
    /// 用户在 banner 上点 Mute / 详情面板 toggle 标这条 = 任务照常跑,
    /// 但 NotificationCenterService 拦掉它的 .cronJobRun 通知。老 cron_job.md
    /// 没这字段时 parseMarkdown 默认 false。
    var muted: Bool = false

    init(id: UUID = UUID(), name: String, prompt: String, window: ContextWindow,
         schedule: Cadence = .everyMinutes(60), isEnabled: Bool = true,
         runs: [CronJobRun] = [], lastRunAt: Date? = nil, connections: [String] = [],
         muted: Bool = false) {
        self.id = id; self.name = name; self.prompt = prompt; self.window = window
        self.schedule = schedule; self.isEnabled = isEnabled
        self.runs = runs; self.lastRunAt = lastRunAt; self.connections = connections
        self.muted = muted
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
