import CryptoKit
import Foundation

/// Premium offload 的包契约:manifest 模型、DONE 协议、哈希、`.partial` → rename 原子写、
/// 跨进程交换锁。导出见 `PremiumExchangeExporter`,导入见 `PremiumExchangeImporter`,
/// 和收件服务之间的上传 / 下载见 `PremiumRemote`。
/// 输入包与结果包都是一个目录(打成 tar.gz 传),只认有 `DONE` 且 DONE 内容 = manifest.json
/// 的 sha256 的目录。
enum PremiumExchange {

    static let integrationId = "premium"
    /// 2 = event 链按区间(`pending.event_intervals`、`frames/<interval_id>.jsonl`),
    /// personality 按本地日(`frames/pday_<day>.jsonl`)。
    static let schemaVersion = 2
    /// 交换的三棵树(相对数据根)。
    static let treeNames = ["events", "portrait", "personality_daily"]
    static let triggerNightly = "nightly"

    /// `<UTC yyyyMMddTHHmmssZ>-<主机短名>-<8 位随机十六进制>`(同一秒导出两个包也不撞)。
    static func makeBundleId(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let host = ProcessInfo.processInfo.hostName
            .split(separator: ".").first.map(String.init)?.lowercased() ?? "mac"
        let short = String(host.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
        let rand = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        return "\(f.string(from: now))-\(short.isEmpty ? "mac" : short)-\(rand)"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: - 哈希

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileSHA(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(d)
    }

    /// 某相对路径是否不参与交换:events 下的 `INDEX.md`,任何 `_quarantine` 目录。
    static func isExcluded(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/")
        if parts.contains("_quarantine") { return true }
        if parts.first == "events", parts.last == "INDEX.md" { return true }
        return false
    }

    /// 数据根下三棵树的全部文件(相对路径,"/" 分隔),已按交换规则过滤。
    static func listTreeFiles(root: URL) -> [String] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().path
        var out: [String] = []
        for tree in treeNames {
            let dir = root.appendingPathComponent(tree, isDirectory: true)
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(base + "/") else { continue }
                let rel = String(full.dropFirst(base.count + 1))
                if isExcluded(rel) { continue }
                out.append(rel)
            }
        }
        return out.sorted()
    }

    /// 相对路径 → sha256。
    static func hashTrees(root: URL) -> [String: String] {
        var out: [String: String] = [:]
        for rel in listTreeFiles(root: root) {
            if let h = fileSHA(root.appendingPathComponent(rel)) { out[rel] = h }
        }
        return out
    }

    // MARK: - 跨进程交换锁

    /// `<数据根>/.staging/premium.lock` 上的 flock。封区间 + 导出(helper 进程 / app tick / Run now)
    /// 与导入(app tick)都拿它,拿不到就本次跳过。
    final class FileLock: @unchecked Sendable {
        private var fd: Int32

        private init(fd: Int32) { self.fd = fd }

        static func url(root: URL = Storage.rootURL) -> URL {
            root.appendingPathComponent(".staging/premium.lock")
        }

        /// 非阻塞试锁,拿不到每秒重试,最多等 `wait` 秒;失败 → nil。
        static func acquire(root: URL = Storage.rootURL, wait: TimeInterval) async -> FileLock? {
            let u = url(root: root)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let fd = open(u.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { return nil }
            let deadline = Date().addingTimeInterval(wait)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard Date() < deadline else { close(fd); return nil }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return FileLock(fd: fd)
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    // MARK: - 原子写 + DONE 协议

    /// 先写同目录 `.<name>.partial` 再 rename。
    static func writeAtomic(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).partial")
        try? fm.removeItem(at: tmp)
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    /// 包内所有文件写完后调:DONE = manifest.json 的 sha256。
    static func writeDone(bundleDir: URL) throws {
        let manifest = try Data(contentsOf: bundleDir.appendingPathComponent("manifest.json"))
        try writeAtomic(Data(sha256Hex(manifest).utf8), to: bundleDir.appendingPathComponent("DONE"))
    }

    /// DONE 存在且与 manifest.json 的 sha256 相符。
    static func isDone(_ bundleDir: URL) -> Bool {
        guard let done = try? String(contentsOf: bundleDir.appendingPathComponent("DONE"), encoding: .utf8),
              let m = fileSHA(bundleDir.appendingPathComponent("manifest.json"))
        else { return false }
        return done.trimmingCharacters(in: .whitespacesAndNewlines) == m
    }

    /// 结果包完整:DONE 有效、`db_ops.json` 在、`result_trees` 点名的文件都在(DONE 只担保 manifest)。
    static func resultReady(_ dir: URL) -> Bool {
        guard isDone(dir),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("db_ops.json").path),
              let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(PremiumResultManifest.self, from: d) else { return false }
        return m.resultTrees.keys.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// 某目录下的包 id(跳过隐藏 / `.partial` 目录),升序。
    static func bundleIds(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".partial") }.sorted()
    }

    // MARK: - JSON

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

}

// MARK: - 模型(键名与 spec §2–§4 一致,显式 CodingKeys —— 树路径 / dump 文件名
// 当字典键,不能套 snake_case 转换)

struct PremiumProcessingLogEntry: Codable, Equatable {
    var date: String
    var rawStatus: String?
    var eventStatus: String?
    var impactStatus: String?
    var personalityStatus: String?
    var distillStatus: String?
    var classifyStatus: String?
    var retryCount: Int?

    enum CodingKeys: String, CodingKey {
        case date
        case rawStatus = "raw_status"
        case eventStatus = "event_status"
        case impactStatus = "impact_status"
        case personalityStatus = "personality_status"
        case distillStatus = "distill_status"
        case classifyStatus = "classify_status"
        case retryCount = "retry_count"
    }
}

/// 一个区间。manifest `pending.event_intervals` 里字段齐全(当前台账状态 + 取帧用的
/// 帧 id 范围);db_ops `event_intervals` 里 Premium 回写 id + 状态,其余字段原样带回即可。
struct PremiumIntervalEntry: Codable, Equatable {
    var id: String
    var startMs: Int64?
    var endMs: Int64?
    var tzOffsetMin: Int?
    var trigger: String?
    var eventStatus: String?
    var impactStatus: String?
    var retryCount: Int?
    var frameCount: Int?
    var afterFrameId: Int64?
    var maxFrameId: Int64?

    enum CodingKeys: String, CodingKey {
        case id, trigger
        case startMs = "start_ms"
        case endMs = "end_ms"
        case tzOffsetMin = "tz_offset_min"
        case eventStatus = "event_status"
        case impactStatus = "impact_status"
        case retryCount = "retry_count"
        case frameCount = "frame_count"
        case afterFrameId = "after_frame_id"
        case maxFrameId = "max_frame_id"
    }
}

extension PremiumIntervalEntry {
    init(_ iv: EventInterval) {
        self.init(id: iv.id, startMs: iv.startMs, endMs: iv.endMs, tzOffsetMin: iv.tzOffsetMin,
                  trigger: iv.trigger, eventStatus: iv.event.rawValue, impactStatus: iv.impact.rawValue,
                  retryCount: iv.retryCount, frameCount: iv.frameCount,
                  afterFrameId: iv.afterFrameId, maxFrameId: iv.maxFrameId)
    }
}

/// personality 的一个本地日。manifest 顶层 `personality_log` 与 db_ops `personality_days` 共用。
struct PremiumPersonalityDayEntry: Codable, Equatable {
    var day: String
    var tzOffsetMin: Int?
    var status: String?
    var retryCount: Int?

    enum CodingKeys: String, CodingKey {
        case day, status
        case tzOffsetMin = "tz_offset_min"
        case retryCount = "retry_count"
    }
}

extension PremiumPersonalityDayEntry {
    init(_ d: PersonalityDay) {
        self.init(day: d.day, tzOffsetMin: d.tzOffsetMin, status: d.status.rawValue, retryCount: d.retryCount)
    }
}

struct PremiumPending: Codable, Equatable {
    var eventIntervals: [PremiumIntervalEntry]
    /// 本地日。
    var personalityDays: [String]
    var distillPending: Bool
    var classifyPending: Bool
    var writingStyleEnabled: Bool
    var writingRecordsUnprocessed: Int
    /// `personalityDays` 各天的台账行(偏移 / 重试);写进 manifest 顶层 `personality_log`,
    /// 不在 pending 里编码。
    var personalityLog: [PremiumPersonalityDayEntry] = []

    enum CodingKeys: String, CodingKey {
        case eventIntervals = "event_intervals"
        case personalityDays = "personality_days"
        case distillPending = "distill_pending"
        case classifyPending = "classify_pending"
        case writingStyleEnabled = "writing_style_enabled"
        case writingRecordsUnprocessed = "writing_records_unprocessed"
    }

    var isEmpty: Bool { chainsWithWork.isEmpty }

    /// 链的固定顺序(config 键名),包里的 `chains` 按它排。
    static let chainOrder = ["event", "portrait", "personality", "writing_style"]

    /// 有待处理工作的链(config 键名,event → portrait → personality → writing_style)。
    var chainsWithWork: [String] {
        var c: [String] = []
        if !eventIntervals.isEmpty || classifyPending { c.append("event") }
        if distillPending { c.append("portrait") }
        if !personalityDays.isEmpty { c.append("personality") }
        if writingStyleEnabled && writingRecordsUnprocessed > 0 { c.append("writing_style") }
        return c
    }

    /// 只留 `chains` 里的链,其余字段置空 / false / 0。
    func only(_ chains: [String]) -> PremiumPending {
        let ev = chains.contains("event"), ws = chains.contains("writing_style")
        let pe = chains.contains("personality")
        return PremiumPending(
            eventIntervals: ev ? eventIntervals : [],
            personalityDays: pe ? personalityDays : [],
            distillPending: chains.contains("portrait") && distillPending,
            classifyPending: ev && classifyPending,
            writingStyleEnabled: ws && writingStyleEnabled,
            writingRecordsUnprocessed: ws ? writingRecordsUnprocessed : 0,
            personalityLog: pe ? personalityLog : [])
    }
}

struct PremiumParams: Codable, Equatable {
    var dailyBudget: Double
    var peakProtection: Double
    var maxRebalances: Int
    var windowDays: Int
    var distillEvidenceThreshold: Int
    var archiveMaxWeight: Double
    var archiveMinDaysIdle: Int
    var weightHalfLifeDays: Int
    var beltWeightMax: Double
    var folderMinCoreEvents: Int
    var writingStyleBatch: Int
    var model: String
    var modelLight: String

    enum CodingKeys: String, CodingKey {
        case dailyBudget = "daily_budget"
        case peakProtection = "peak_protection"
        case maxRebalances = "max_rebalances"
        case windowDays = "window_days"
        case distillEvidenceThreshold = "distill_evidence_threshold"
        case archiveMaxWeight = "archive_max_weight"
        case archiveMinDaysIdle = "archive_min_days_idle"
        case weightHalfLifeDays = "weight_half_life_days"
        case beltWeightMax = "belt_weight_max"
        case folderMinCoreEvents = "folder_min_core_events"
        case writingStyleBatch = "writing_style_batch"
        case model
        case modelLight = "model_light"
    }
}

struct PremiumBundleManifest: Codable {
    var schemaVersion: Int = PremiumExchange.schemaVersion
    var bundleId: String
    var exportedAtMs: Int64
    var macNowMs: Int64
    var appVersion: String
    /// `nightly`(封区间检查发的包)或 `run_now`(某条链的 Run on Premium)。
    var trigger: String
    /// 本包包含的链;不在其中的链 pending 恒为空 / false。
    var chains: [String]
    var pending: PremiumPending
    /// 只有 `_distill_anchor` / `_classify_anchor` 两行。
    var processingLog: [PremiumProcessingLogEntry]
    /// `pending.personality_days` 各天的台账行。
    var personalityLog: [PremiumPersonalityDayEntry]
    var aboutUserBlock: String
    var params: PremiumParams
    var trees: [String: String]
    /// 帧文件与写作记录(相对包目录)→ sha256,收件服务按它核对。
    var files: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bundleId = "bundle_id"
        case exportedAtMs = "exported_at_ms"
        case macNowMs = "mac_now_ms"
        case appVersion = "app_version"
        case trigger, chains, pending
        case processingLog = "processing_log"
        case personalityLog = "personality_log"
        case aboutUserBlock = "about_user_block"
        case params, trees, files
    }
}

struct PremiumResultManifest: Codable {
    struct Stage: Codable {
        var name: String
        var status: String
        var llmCalls: Int?
        var seconds: Double?
        enum CodingKeys: String, CodingKey {
            case name, status, seconds
            case llmCalls = "llm_calls"
        }
    }
    var schemaVersion: Int?
    var bundleId: String
    var pipelineVersion: String?
    var startedMs: Int64?
    var endedMs: Int64?
    var status: String
    var stages: [Stage]?
    var baseTrees: [String: String]
    var resultTrees: [String: String]
    var deleted: [String]?
    var summary: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bundleId = "bundle_id"
        case pipelineVersion = "pipeline_version"
        case startedMs = "started_ms"
        case endedMs = "ended_ms"
        case status, stages, deleted, summary
        case baseTrees = "base_trees"
        case resultTrees = "result_trees"
    }
}

struct PremiumDbOps: Codable {
    struct Changelog: Codable {
        var entityId: String
        var fieldName: String?
        var before: String?
        var after: String
        var triggeredByEventId: String?
        var timestampMs: Int64
        enum CodingKeys: String, CodingKey {
            case entityId = "entity_id"
            case fieldName = "field_name"
            case before, after
            case triggeredByEventId = "triggered_by_event_id"
            case timestampMs = "timestamp_ms"
        }
    }
    struct WritingStyleRun: Codable {
        var runId: String
        var mode: String
        var status: String
        var startedAt: Int64
        var completedAt: Int64?
        var recordsCount: Int?
        var draftsCount: Int?
        var inputRecordIds: [Int64]?
        var errorMessage: String?
        enum CodingKeys: String, CodingKey {
            case runId = "run_id"
            case mode, status
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case recordsCount = "records_count"
            case draftsCount = "drafts_count"
            case inputRecordIds = "input_record_ids"
            case errorMessage = "error_message"
        }
    }
    struct WritingStyle: Codable {
        var run: WritingStyleRun?
        var processedRecordIds: [Int64]?
        var processedAtMs: Int64?
        enum CodingKeys: String, CodingKey {
            case run
            case processedRecordIds = "processed_record_ids"
            case processedAtMs = "processed_at_ms"
        }
    }
    struct PipelineRun: Codable {
        var pipeline: String
        var outcome: String
        var detail: String?
    }

    var processingLog: [PremiumProcessingLogEntry]?
    var eventIntervals: [PremiumIntervalEntry]?
    var personalityDays: [PremiumPersonalityDayEntry]?
    var distillChangelog: [Changelog]?
    var writingStyle: WritingStyle?
    var pipelineRuns: [PipelineRun]?
    var journalAppend: [String: String]?
    var lastRunDays: [String: String]?
    var llmDumps: [String: String]?

    enum CodingKeys: String, CodingKey {
        case processingLog = "processing_log"
        case eventIntervals = "event_intervals"
        case personalityDays = "personality_days"
        case distillChangelog = "distill_changelog"
        case writingStyle = "writing_style"
        case pipelineRuns = "pipeline_runs"
        case journalAppend = "journal_append"
        case lastRunDays = "last_run_days"
        case llmDumps = "llm_dumps"
    }
}


