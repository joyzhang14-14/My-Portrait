import Foundation
import OSLog
import AppKit
import Darwin

enum DiagnosticBundleMode: String, Sendable {
    case publicReport = "public"
    case privateSupport = "private-support"
}

/// 导出两类诊断包到 Downloads：适合公开 issue 的严格脱敏包，或信息更完整的
/// 私下支持包。两者都不读取采集内容、聊天、记忆文件或 SecretStore。
enum DiagnosticBundle {

    /// Build the bundle. 返回写好的 zip 的 URL。失败抛错由 UI 弹 alert。
    @MainActor
    static func build(mode: DiagnosticBundleMode = .publicReport) async throws -> URL {
        // ConfigStore 属于 MainActor；先只取一份已脱敏/白名单化的数据快照，
        // 后面的日志扫描、目录遍历和 zip 全放后台，避免导出时冻结整个窗口。
        let (configName, configData) = try configSnapshot(for: mode)
        let stallsData = try stallsSnapshot(for: mode)
        let healthLogURL = HealthMonitor.logFileURL
        let terminationURLs = (RunTerminationTracker.stateFileURL,
                               RunTerminationTracker.historyFileURL)
        return try await Task.detached(priority: .userInitiated) {
            try buildOffMain(mode: mode, configName: configName, configData: configData,
                             stallsData: stallsData, healthLogURL: healthLogURL,
                             terminationURLs: terminationURLs)
        }.value
    }

    private static func buildOffMain(
        mode: DiagnosticBundleMode, configName: String, configData: Data,
        stallsData: Data, healthLogURL: URL,
        terminationURLs: (state: URL, history: URL)
    ) throws -> URL {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        let ts = isoFmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        // 1) 临时工作目录(后面打包成 zip)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("myportrait-diag-\(ts)", isDirectory: true)
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 2) 各组件写文件 —— 任何一项失败 swallow + 继续(把能拿的拿到)。
        writeText(readme(for: mode), to: workDir.appendingPathComponent("README.txt"))
        try? writePrivacyManifest(mode: mode, to: workDir.appendingPathComponent("privacy.json"))
        try? writeSystemInfo(to: workDir.appendingPathComponent("system.json"))
        try? configData.write(to: workDir.appendingPathComponent(configName), options: .atomic)
        try? copyHealthLog(mode: mode, from: healthLogURL,
                           to: workDir.appendingPathComponent("health.log"))
        try? stallsData.write(to: workDir.appendingPathComponent("stalls.json"), options: .atomic)
        try? writeProcessingLog(mode: mode, to: workDir.appendingPathComponent("processing_log.json"))
        try? writeDbStats(mode: mode, to: workDir.appendingPathComponent("db_stats.json"))
        try? writeOSLog24h(mode: mode, to: workDir)
        copyDiagnosticLogs(mode: mode, to: workDir)
        copyCrashReports(mode: mode, to: workDir)
        copyHangSamples(mode: mode, to: workDir)
        copyRunTerminationRecords(mode: mode, urls: terminationURLs, to: workDir)
        try? writeJetsamSummary(to: workDir.appendingPathComponent("jetsam-summary.json"))

        // 3) zip 到 Downloads(用户原话:放在 download 里)
        let downloads = try downloadsURL()
        let zipURL = downloads.appendingPathComponent("My-Portrait-diagnostic-\(mode.rawValue)-\(ts).zip")
        try? FileManager.default.removeItem(at: zipURL)
        try runZip(srcDir: workDir, dstZip: zipURL)
        return zipURL
    }

    // MARK: - 子组件

    private static func readme(for mode: DiagnosticBundleMode) -> String {
        let sharing = mode == .publicReport
            ? "This PUBLIC bundle is designed for a public GitHub issue. Free-form log messages and configuration values are excluded."
            : "This PRIVATE SUPPORT bundle contains sanitized free-form errors and detailed timestamps. Review it and share it only through a private channel."
        let privacyWarning = mode == .publicReport
            ? "The public export uses an allowlist: arbitrary log context and messages are removed."
            : "Raw capture files are excluded, but sanitized error messages may contain values supplied by external services. Review before sharing."
        return """
    My Portrait — Diagnostic Bundle
    ================================

    \(sharing)

    INCLUDED:
      - app / macOS / hardware and resource metrics
      - capture health, queue sizes, row counts and pipeline status
      - structured diagnostic events and recent automatic hang samples
      - recent crash reports, with local paths and identifiers redacted
      - clean/unexpected exit state and My Portrait-only memory-kill summaries

    EXCLUDED BY THE EXPORTER:
      - any .md file (events, portrait, personality)
      - OCR text, typing events, transcriptions
      - audio/video/image files
      - chats, prompts, API keys, OAuth tokens or personal profile values

    \(privacyWarning)

    See privacy.json for the exact export policy. You can open the zip and
    inspect every file before sharing.
    """
    }

    private static func writePrivacyManifest(mode: DiagnosticBundleMode, to url: URL) throws {
        let payload: [String: Any] = [
            "mode": mode.rawValue,
            "safe_for_public_issue": mode == .publicReport,
            "excluded": [
                "captured images/audio/video", "OCR and transcription text",
                "typing content", "chat content", "memory markdown",
                "secrets and personal profile values",
            ],
            "redactions": [
                "home directory", "email addresses", "URLs and IP addresses",
                "UUIDs", "device identifiers", "free-form context values",
                "other process names from public memory-kill summaries",
            ],
            "private_mode_note": mode == .privateSupport
                ? "Contains sanitized free-form error messages and detailed pipeline timestamps. Share privately."
                : "Contains no free-form unified-log messages or full configuration values.",
        ]
        try writeJSON(payload, to: url)
    }

    private static func writeText(_ s: String, to url: URL) {
        try? s.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// system.json: app version + macOS + hardware + ~/.portrait 总大小
    private static func writeSystemInfo(to url: URL) throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let proc = ProcessInfo.processInfo
        var dict: [String: Any] = [:]
        dict["app_version_marketing"] = info["CFBundleShortVersionString"] ?? "?"
        dict["app_version_build"]     = info["CFBundleVersion"] ?? "?"
        dict["app_bundle_id"]         = info["CFBundleIdentifier"] ?? "?"
        dict["macos_version"]         = proc.operatingSystemVersionString
        dict["physical_memory_bytes"] = proc.physicalMemory
        dict["processor_count"]       = proc.activeProcessorCount
        dict["host_arch"]             = (try? hostArch()) ?? "unknown"
        dict["system_uptime_sec"]     = Int(proc.systemUptime)
        dict["generated_at"]          = ISO8601DateFormatter().string(from: Date())
        dict["portrait_root_size_bytes"] = directorySize(Storage.rootURL)
        let resource = currentProcessResourceUsage()
        dict["process_physical_footprint_bytes"] = resource.footprint
        dict["process_resident_bytes"] = resource.resident
        dict["process_virtual_bytes"] = resource.virtual
        try writeJSON(dict, to: url)
    }

    /// ConfigStore 只在 MainActor 读取；返回值已经完成白名单/脱敏，可安全交给后台写盘。
    @MainActor
    private static func configSnapshot(for mode: DiagnosticBundleMode) throws -> (String, Data) {
        let cfg = ConfigStore.shared.current
        let object: Any
        let name: String
        if mode == .publicReport {
            name = "config-summary.json"
            object = [
                "schema_version": cfg.schemaVersion,
                "screen_capture": [
                    "enabled": cfg.capture.screen.enabled,
                    "ocr_accuracy_booster": cfg.capture.screen.ocrAccuracyBooster,
                ],
                "audio_capture": [
                    "enabled": cfg.capture.audio.enabled,
                    "engine": cfg.capture.audio.engine,
                    "capture_system_audio": cfg.capture.audio.captureSystemAudio,
                    "speaker_id_enabled": cfg.capture.audio.speakerIdEnabled,
                    "filter_music": cfg.capture.audio.filterMusic,
                    "transcription_power_mode": cfg.capture.audio.transcriptionPowerMode.rawValue,
                ],
                "typing_capture": [
                    "enabled": cfg.capture.typingCaptureEnabled,
                    "record_paste_events": cfg.capture.typingRecordPasteEvents,
                ],
                "system_power_mode": cfg.capture.system.powerMode,
                "ai_preset_count": cfg.aiModels.presets.count,
            ] as [String: Any]
        } else {
            name = "config-redacted.json"
            let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cfg))
            object = redactConfigObject(raw)
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return (name, data)
    }

    @MainActor
    private static func stallsSnapshot(for mode: DiagnosticBundleMode) throws -> Data {
        let recent = StallDetector.shared.recent
        let pause = IntentionalPauseState.shared
        let payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "pause_state": [
                "drm_active": pause.drmActive,
                "screen_asleep": pause.screenAsleep,
                "capture_disabled": pause.captureDisabled,
                "audio_transcription_paused": pause.audioTranscriptionPaused,
            ],
            "recent_verdicts": recent.map { v -> [String: Any] in
                [
                    "kind": v.kind.rawValue,
                    "reason": redactText(v.reason, limit: mode == .publicReport ? 160 : 1_000),
                    "cause": redactText(v.cause ?? "", limit: mode == .publicReport ? 160 : 1_000),
                    "detected_at": ISO8601DateFormatter().string(from: v.detectedAt),
                ]
            },
        ]
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func redactConfigObject(_ value: Any, key: String = "") -> Any {
        let lower = key.lowercased()
        let sensitive = [
            "personal_info", "prompt", "key", "token", "secret", "password",
            "ref", "url", "endpoint", "vocabulary", "language", "device_uid",
            "pause_audio_apps", "custom_icon",
        ].contains { lower.contains($0) }
            || lower == "id" || lower.hasSuffix("_id")
            || lower == "name" || lower.hasSuffix("_name")
        if sensitive {
            if let s = value as? String { return s.isEmpty ? "<empty>" : "<redacted>" }
            if let a = value as? [Any] { return a.isEmpty ? [] : ["<redacted>"] }
            return "<redacted>"
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = redactConfigObject(v, key: k)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redactConfigObject($0) }
        }
        return value
    }

    /// 导出结构化日志。公开包只保留事件名、数字/布尔值和白名单枚举值；
    /// 私下包保留脱敏后的错误文本。两种模式都不直接复制原日志。
    private static func copyDiagnosticLogs(mode: DiagnosticBundleMode, to workDir: URL) {
        let fm = FileManager.default
        let base = DiagLog.logFileURL
        let candidates = [base] + (1...5).map { base.appendingPathExtension("\($0)") }
        for src in candidates where fm.fileExists(atPath: src.path) {
            let dst = workDir.appendingPathComponent("sanitized-\(src.lastPathComponent)")
            let maxBytes = mode == .publicReport ? 250_000 : 750_000
            guard let text = readTail(src, maxBytes: maxBytes) else { continue }
            let lines = text.split(separator: "\n").compactMap {
                sanitizeDiagnosticLine(String($0), mode: mode)
            }
            writeText(lines.joined(separator: "\n") + "\n", to: dst)
        }
    }

    private static func sanitizeDiagnosticLine(
        _ line: String, mode: DiagnosticBundleMode
    ) -> String? {
        guard let data = line.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let ctx = obj["ctx"] as? [String: Any] {
            var clean: [String: Any] = [:]
            let safeStrings: Set<String> = [
                "status", "state", "kind", "phase", "component", "engine",
                "mode", "operation", "processor", "provider", "model",
                "result", "cause", "error_type",
            ]
            for (key, value) in ctx {
                let lower = key.lowercased()
                let alwaysSensitive = [
                    "window", "path", "file", "snapshot", "device",
                    "title", "slug", "category", "text", "content", "prompt",
                    "url", "query", "command",
                ].contains { lower.contains($0) }
                    || lower == "app" || lower == "app_name" || lower.contains("bundle")
                if alwaysSensitive {
                    clean[key] = "<redacted>"
                } else if value is Bool || value is NSNumber {
                    clean[key] = value
                } else if mode == .privateSupport, let value = value as? String {
                    clean[key] = redactText(value, limit: 1_000)
                } else if safeStrings.contains(key), let value = value as? String {
                    clean[key] = redactText(value, limit: 120)
                } else {
                    clean[key] = "<redacted>"
                }
            }
            obj["ctx"] = clean
        }
        guard let cleanData = try? JSONSerialization.data(withJSONObject: obj),
              let cleanLine = String(data: cleanData, encoding: .utf8) else { return nil }
        return cleanLine
    }

    /// 系统崩溃报告:~/Library/Logs/DiagnosticReports/ 下最近 5 份
    /// `MyPortrait-*.ips`(+ 老格式 `.crash`)拷进 bundle 的 `crash-reports/`。
    /// **排查闪退最关键的东西** —— 之前 bundle 漏了它,用户报闪退却没崩溃栈可看。
    /// 读真实 ~/Library(非容器),跟读 ~/.portrait 一致;读不到就 swallow。
    private static func copyCrashReports(mode: DiagnosticBundleMode, to workDir: URL) {
        let fm = FileManager.default
        let reportsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(
            at: reportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        // 两类都要:
        //   - MyPortrait-<date>-….ips/.crash —— app 自己的代码崩溃(进程名 = MyPortrait)
        //   - JetsamEvent-<date>-….ips —— **OOM**:进程被系统 SIGKILL,不生成
        //     MyPortrait-*.ips,只进系统级 jetsam 报告。**闪退却没 .ips 多半是这个**,
        //     jetsam 报告里有被杀进程清单(含 MyPortrait + 内存占用)。
        let crashes = items.filter {
            let n = $0.lastPathComponent
            let allowedName = n.hasPrefix("MyPortrait")
                || (mode == .privateSupport && n.hasPrefix("JetsamEvent"))
            return ["ips", "crash"].contains($0.pathExtension.lowercased()) && allowedName
        }
        guard !crashes.isEmpty else { return }
        let recent = crashes.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }.prefix(mode == .publicReport ? 2 : 3)
        let dstDir = workDir.appendingPathComponent("crash-reports", isDirectory: true)
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        for src in recent {
            copySanitizedText(
                from: src,
                to: dstDir.appendingPathComponent(src.lastPathComponent),
                maxBytes: mode == .publicReport ? 750_000 : 1_500_000,
                limit: mode == .publicReport ? 400 : 1_000)
        }
    }

    private static func copyHangSamples(mode: DiagnosticBundleMode, to workDir: URL) {
        let fm = FileManager.default
        let base = Storage.dailyLogsDir.appendingPathComponent("hang-sample.txt")
        let candidates = [base] + (1...3).map { base.appendingPathExtension("\($0)") }
        let existing = candidates.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        let dstDir = workDir.appendingPathComponent("hang-samples", isDirectory: true)
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        for src in existing {
            copySanitizedText(
                from: src,
                to: dstDir.appendingPathComponent(src.lastPathComponent),
                maxBytes: mode == .publicReport ? 750_000 : 1_000_000,
                limit: mode == .publicReport ? 400 : 1_000)
        }
    }

    /// 上次是否走过正常退出 + 最后一份资源心跳。字段全部由 app 自己生成，
    /// 不含自由文本；公开包额外去掉无排障价值的 PID。
    private static func copyRunTerminationRecords(
        mode: DiagnosticBundleMode, urls: (state: URL, history: URL), to workDir: URL
    ) {
        let fm = FileManager.default
        let dstDir = workDir.appendingPathComponent("process-lifecycle", isDirectory: true)
        let sources = [urls.state, urls.history]
        guard sources.contains(where: { fm.fileExists(atPath: $0.path) }) else { return }
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: urls.state),
           var state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if mode == .publicReport { state.removeValue(forKey: "pid") }
            try? writeJSON(state, to: dstDir.appendingPathComponent("current-run-state.json"))
        }

        guard let history = readTail(
            urls.history, maxBytes: 512_000) else { return }
        let lines = history.split(separator: "\n").suffix(50).compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  var event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            if mode == .publicReport { event.removeValue(forKey: "last_pid") }
            guard let clean = try? JSONSerialization.data(withJSONObject: event),
                  let string = String(data: clean, encoding: .utf8) else { return nil }
            return string
        }
        writeText(lines.joined(separator: "\n") + "\n",
                  to: dstDir.appendingPathComponent("unexpected-terminations.jsonl"))
    }

    /// Jetsam 报告会列出当时系统中的所有进程，不能原样放进公开包。这里递归查找
    /// 直接标识为 My Portrait 的进程节点，只导出该节点中的技术字段。
    private static func writeJetsamSummary(to url: URL) throws {
        let fm = FileManager.default
        let reportsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(
            at: reportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let jetsam = items.filter {
            $0.lastPathComponent.hasPrefix("JetsamEvent") && $0.pathExtension == "ips"
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }.prefix(10)

        var summaries: [[String: Any]] = []
        for report in jetsam {
            let size = (try? report.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= 20_000_000, let data = try? Data(contentsOf: report) else { continue }
            var matches: [[String: Any]] = []
            for root in parseIPSObjects(data) {
                collectMyPortraitJetsamNodes(root, into: &matches)
            }
            guard !matches.isEmpty else { continue }
            let modified = (try? report.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            summaries.append([
                "report_modified_at": modified.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "my_portrait_processes": Array(matches.prefix(5)),
            ])
        }
        guard !summaries.isEmpty else { return }
        try writeJSON(["reports": summaries], to: url)
    }

    private static func parseIPSObjects(_ data: Data) -> [Any] {
        if let whole = try? JSONSerialization.jsonObject(with: data) { return [whole] }
        guard let newline = data.firstIndex(of: 0x0A) else { return [] }
        let parts = [Data(data[..<newline]), Data(data[data.index(after: newline)...])]
        var roots = parts.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        if roots.isEmpty {
            roots = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .compactMap { line in
                    guard let lineData = line.data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: lineData)
                }
        }
        return roots
    }

    private static func collectMyPortraitJetsamNodes(
        _ value: Any, into matches: inout [[String: Any]]
    ) {
        if let dict = value as? [String: Any] {
            if isMyPortraitProcessNode(dict) {
                matches.append(sanitizeJetsamProcessNode(dict))
                return
            }
            for child in dict.values {
                collectMyPortraitJetsamNodes(child, into: &matches)
            }
        } else if let array = value as? [Any] {
            for child in array { collectMyPortraitJetsamNodes(child, into: &matches) }
        }
    }

    private static func isMyPortraitProcessNode(_ dict: [String: Any]) -> Bool {
        let identityKeys: Set<String> = [
            "name", "proc", "procname", "processname", "process", "bundleid",
            "bundleidentifier", "bundle", "path",
        ]
        for (key, value) in dict {
            let normalizedKey = key.lowercased().filter { $0.isLetter }
            guard identityKeys.contains(normalizedKey), let string = value as? String else { continue }
            let normalizedValue = string.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            if normalizedValue.contains("myportrait") { return true }
        }
        return false
    }

    private static func sanitizeJetsamProcessNode(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dict {
            let lower = key.lowercased()
            if value is Bool || value is NSNumber {
                out[key] = value
            } else if let string = value as? String,
                      ["name", "proc", "process", "bundle", "reason", "state",
                       "status", "role"].contains(where: { lower.contains($0) }) {
                out[key] = redactText(string, limit: 200)
            } else if let nested = value as? [String: Any] {
                let numeric = nested.filter { $0.value is Bool || $0.value is NSNumber }
                if !numeric.isEmpty { out[key] = numeric }
            }
        }
        return out
    }

    /// 健康度日志:直接 copy ~/.portrait/logs/health.log。
    private static func copyHealthLog(
        mode: DiagnosticBundleMode, from src: URL, to url: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: src.path) else {
            writeText("(no health.log yet)", to: url)
            return
        }
        if mode == .publicReport, let text = readTail(src, maxBytes: 1_000_000) {
            let clean = text.split(separator: "\n").map { line -> String in
                let prefix = line.split(separator: "—", maxSplits: 1).first ?? line
                return redactText(String(prefix), limit: 160)
            }
            writeText(clean.joined(separator: "\n") + "\n", to: url)
        } else {
            copySanitizedText(from: src, to: url, maxBytes: 1_000_000, limit: 1_000)
        }
    }

    /// processing_log 全表 — 无 PII,只有 status / 时戳 / retry。
    private static func writeProcessingLog(mode: DiagnosticBundleMode, to url: URL) throws {
        let store = ProcessingLogStore()
        let sourceRows = store.allRows()
        if mode == .publicReport {
            var statusCounts: [String: Int] = [:]
            for row in sourceRows {
                for (step, status) in [
                    ("raw", row.raw.rawValue), ("event", row.event.rawValue),
                    ("impact", row.impact.rawValue), ("classify", row.classify.rawValue),
                    ("distill", row.distill.rawValue), ("personality", row.personality.rawValue),
                ] {
                    statusCounts["\(step).\(status)", default: 0] += 1
                }
            }
            try writeJSON([
                "row_count": sourceRows.count,
                "status_counts": statusCounts,
                "total_retries": sourceRows.reduce(0) { $0 + $1.retryCount },
            ], to: url)
            return
        }
        let rows = sourceRows.suffix(500).map { r -> [String: Any] in
            [
                "date":             r.date,
                "raw":              r.raw.rawValue,
                "event":            r.event.rawValue,
                "impact":           r.impact.rawValue,
                "classify":         r.classify.rawValue,
                "distill":          r.distill.rawValue,
                "personality":      r.personality.rawValue,
                "active_processor": r.activeProcessor ?? "",
                "heartbeat_ms":     r.heartbeatMs ?? 0,
                "retry_count":      r.retryCount,
                "updated_at_ms":    r.updatedAtMs,
            ]
        }
        try writeJSON([
            "rows": rows,
            "total_row_count": sourceRows.count,
            "truncated": sourceRows.count > rows.count,
        ], to: url)
    }

    /// db_stats.json — 各表 row count + ~/.portrait 各子目录 du。
    private static func writeDbStats(mode: DiagnosticBundleMode, to url: URL) throws {
        var dict: [String: Any] = [:]
        if mode == .privateSupport {
            dict["db_path"] = "~/.portrait/portrait.db"
        }
        dict["db_size_bytes"] = fileSize(Storage.portraitDBPath)
        dict["table_row_counts"] = readTableCounts()

        var dirs: [String: Int64] = [:]
        for (name, url) in [
            ("portrait",        Storage.portraitDir),
            ("events",          Storage.eventsDir),
            ("audio_queue",     Storage.audioQueueDir),
            ("raw_data",        Storage.rawDataDir),
            ("frames",          Storage.framesDir),
            ("video",           Storage.videoDir),
            ("logs",            Storage.dailyLogsDir),
            ("journal",         Storage.journalDir),
        ] {
            dirs[name] = directorySize(url)
        }
        dict["dir_sizes_bytes"] = dirs

        try writeJSON(dict, to: url)
    }

    private static func readTableCounts() -> [String: Int] {
        // 直接用 sqlite3 命令行(避免引 GRDB)。
        let tables = [
            "frames", "video_chunks",
            "audio_chunks", "audio_transcriptions",
            "typing_events", "keystroke_log", "writing_records",
            "processing_log", "speakers", "speaker_samples",
        ]
        var out: [String: Int] = [:]
        for t in tables {
            if let n = sqliteScalarInt("SELECT COUNT(*) FROM \(t)") {
                out[t] = n
            }
        }
        return out
    }

    private static func sqliteScalarInt(_ sql: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [Storage.portraitDBPath, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let data = try? out.fileHandleForReading.readToEnd()
        guard let s = data.flatMap({ String(data: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let n = Int(s) else { return nil }
        return n
    }

    /// 公开包只写 unified log 的分类计数，避免自由文本进入公开 issue。
    /// 私下包保留经脱敏的最近 3 MB 消息。
    private static func writeOSLog24h(mode: DiagnosticBundleMode, to workDir: URL) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let position = store.position(date: cutoff)
        let predicate = NSPredicate(format: "subsystem BEGINSWITH 'com.myportrait'")
        let entries = try store.getEntries(at: position, matching: predicate)
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if mode == .publicReport {
            var counts: [String: Int] = [:]
            var first: Date?
            var last: Date?
            for e in entries {
                guard let log = e as? OSLogEntryLog else { continue }
                counts["\(log.subsystem)|\(log.category)|\(osLogLevelName(log.level))", default: 0] += 1
                if first == nil { first = log.date }
                last = log.date
            }
            try writeJSON([
                "counts": counts,
                "first_entry": first.map { isoFmt.string(from: $0) } ?? "",
                "last_entry": last.map { isoFmt.string(from: $0) } ?? "",
            ], to: workDir.appendingPathComponent("oslog-summary.json"))
            return
        }

        var lines: [Data] = []
        var totalBytes = 0
        let maxBytes = 3_000_000
        for e in entries {
            guard let log = e as? OSLogEntryLog else { continue }
            let line: [String: Any] = [
                "ts":        isoFmt.string(from: log.date),
                "level":     osLogLevelName(log.level),
                "subsystem": log.subsystem,
                "category":  log.category,
                "msg":       redactText(log.composedMessage, limit: 1_000),
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: line) else { continue }
            data.append(0x0A)
            lines.append(data)
            totalBytes += data.count
            while totalBytes > maxBytes, !lines.isEmpty {
                totalBytes -= lines.removeFirst().count
            }
        }
        let output = lines.reduce(into: Data()) { $0.append($1) }
        try output.write(to: workDir.appendingPathComponent("oslog-24h-sanitized.jsonl"),
                         options: .atomic)
    }

    private static func osLogLevelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:    return "debug"
        case .info:     return "info"
        case .notice:   return "notice"
        case .error:    return "error"
        case .fault:    return "fault"
        case .undefined: return "undefined"
        @unknown default: return "unknown"
        }
    }

    private static func readTail(_ url: URL, maxBytes: Int) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    private static func copySanitizedText(
        from src: URL, to dst: URL, maxBytes: Int, limit: Int
    ) {
        guard let text = readTail(src, maxBytes: maxBytes) else { return }
        let clean = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { redactText(String($0), limit: limit) }
            .joined(separator: "\n")
        writeText(clean, to: dst)
    }

    /// 仅用于诊断文本。保留符号名和错误类型，移除可识别用户/机器的信息。
    private static func redactText(_ text: String, limit: Int) -> String {
        var out = text.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~")
        let replacements: [(String, String)] = [
            (#"/Users/[^/\s\"']+"#, "/Users/<redacted>"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<email>"),
            (#"https?://[^\s\"']+"#, "<url>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<uuid>"),
        ]
        for (pattern, replacement) in replacements {
            out = out.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression)
        }
        if out.count > limit {
            out = String(out.prefix(limit)) + "…<truncated>"
        }
        return out
    }

    // MARK: - zip + 路径工具

    /// 用系统 `/usr/bin/zip -r` 打包,避免引第三方 ZipFoundation。
    private static func runZip(srcDir: URL, dstZip: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r 递归,-q 静默,cd 到 src 父目录这样压进 zip 的路径相对干净。
        p.arguments = ["-r", "-q", dstZip.path, srcDir.lastPathComponent]
        p.currentDirectoryURL = srcDir.deletingLastPathComponent()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "DiagnosticBundle", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip exited with \(p.terminationStatus)"])
        }
    }

    private static func downloadsURL() throws -> URL {
        let urls = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
        guard let url = urls.first else {
            throw NSError(domain: "DiagnosticBundle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't locate Downloads directory"])
        }
        return url
    }

    private static func writeJSON(_ obj: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// 递归算目录总大小(allocated size,跟 Finder 显示对齐)。
    /// 失败 / 不存在返回 0。
    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                     options: [.skipsHiddenFiles],
                                     errorHandler: nil) else { return 0 }
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func hostArch() throws -> String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func currentProcessResourceUsage() -> (
        footprint: UInt64, resident: UInt64, virtual: UInt64
    ) {
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }

        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        return (
            vmResult == KERN_SUCCESS ? vm.phys_footprint : 0,
            basicResult == KERN_SUCCESS ? basic.resident_size : 0,
            basicResult == KERN_SUCCESS ? basic.virtual_size : 0)
    }
}
