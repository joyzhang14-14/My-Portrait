import Foundation
import SQLite3

/// `mp-query` CLI —— 给 AI agent(pi-coding-agent / Claude Code 等)用的
/// 屏幕数据查询接口。设计端口自 screenpipe 的 SKILL.md(REST API),改成
/// 纯 CLI + JSON stdout(我们不用起 HTTP server,agent 通过 bash 调即可)。
///
/// 调用形式:
///   mp-query search        --start "1h ago" [--q "..."] [--app "Chrome"] [--limit 10]
///   mp-query activity-summary --start "1h ago"
///   mp-query memories      --q "..." [--limit 20]
///   mp-query audio         --start "1h ago" [--speaker "Joy"]
///
/// 时间格式:
///   - 绝对:`2026-05-27T15:00:00Z` 或 `2026-05-27 15:00:00`(本地时区)
///   - 相对:`30m ago` / `1h ago` / `2d ago` / `today` / `yesterday` / `now`
///
/// 输出:JSON 到 stdout(单行 `{}`),错误 JSON 到 stderr + exit 1。
/// AI 用 bash 调 `mp-query ...` 拿到 JSON 后自己解析。
enum MPQueryCLI {

    static func run(args: [String]) -> Never {
        guard !args.isEmpty else {
            printUsage()
            exit(2)
        }
        let sub = args[0]
        let rest = Array(args.dropFirst())
        switch sub {
        case "search":            runSearch(args: rest)
        case "activity-summary":  runActivitySummary(args: rest)
        case "memories":          runMemories(args: rest)
        case "audio":             runAudio(args: rest)
        case "help", "--help", "-h":
            printUsage()
            exit(0)
        default:
            errJSON("unknown subcommand: \(sub). try `mp-query help`.")
        }
    }

    // MARK: - Subcommands

    /// `search` —— 跨 OCR/audio 全文检索。
    private static func runSearch(args: [String]) -> Never {
        let opts = parseOpts(args)
        let start = parseTime(opts["start"], anchor: .start) ?? Date().addingTimeInterval(-3600)
        let end = parseTime(opts["end"], anchor: .end) ?? Date()
        let limit = Int(opts["limit"] ?? "10") ?? 10
        let q = opts["q"]
        let appFilter = opts["app"]
        let contentType = opts["content"] ?? "all"   // all | ocr | audio

        let db = TimelineDB()
        guard db.exists else {
            errJSON("timeline DB not found at \(db.dbPath)")
        }

        var out: [[String: Any]] = []

        // OCR results
        if contentType == "all" || contentType == "ocr" {
            let ocrLimit = contentType == "all" ? max(limit / 2, 3) : limit
            let ocrRows = searchFrames(db: db, q: q, appFilter: appFilter,
                                        start: start, end: end, limit: ocrLimit)
            for r in ocrRows {
                out.append([
                    "type": "OCR",
                    "content": [
                        "frame_id": r.id,
                        "timestamp": iso8601(r.timestamp),
                        "app_name": r.appName ?? "",
                        "window_name": r.windowName ?? "",
                        "browser_url": r.browserUrl ?? "",
                        // searchFrames 已经按 600 字符 snippet 截过(并居中
                        // 在 query 周围),这里直接用,不再二次 prefix。
                        "text": r.ocrText
                    ]
                ])
            }
        }

        // Audio transcriptions
        if contentType == "all" || contentType == "audio" {
            let audioLimit = contentType == "all" ? max(limit / 2, 3) : limit
            let trs = searchTranscripts(db: db, q: q, start: start, end: end, limit: audioLimit)
            for t in trs {
                out.append([
                    "type": "Audio",
                    "content": [
                        "timestamp": iso8601(t.timestamp),
                        "text": t.text,
                        "device": t.device,
                        "is_input": t.isInput,
                        "speaker_id": t.speakerId.map { $0 as Any } ?? NSNull()
                    ]
                ])
            }
        }

        emitJSON([
            "data": out,
            "query": q ?? NSNull(),
            "start_time": iso8601(start),
            "end_time": iso8601(end),
            "result_count": out.count
        ])
    }

    /// `activity-summary` —— 时间段内 top app + top window + 总时长概览。
    private static func runActivitySummary(args: [String]) -> Never {
        let opts = parseOpts(args)
        // `--start yesterday` = 昨天 00:00; `--end yesterday` 该是昨天 23:59,
        // 别用同一个 startOfDay 当 end。解析时按 anchor 给两种语义。
        let start = parseTime(opts["start"], anchor: .start) ?? Date().addingTimeInterval(-3600)
        let end = parseTime(opts["end"], anchor: .end) ?? Date()

        let db = TimelineDB()
        guard db.exists else { errJSON("timeline DB not found at \(db.dbPath)") }

        let activity = db.activity(from: start, to: end)
        let totalMins = activity.totalActiveMinutes

        // 用 SuggestionEngine 已有的分类逻辑给个 inferred mode。
        let mode = inferModeLabel(from: activity)

        // share_pct 按 active_minutes 算占比(分子分母都是真实时长)。
        // sum(每个 app 的 active_minutes) 会 > total_active_minutes
        // 因为同分钟切了多个 app 各算 1 分钟,所以用 sum 当分母不用总数。
        let summed = activity.apps.reduce(0) { $0 + $1.activeMinutes }

        let apps: [[String: Any]] = activity.apps.prefix(10).map { a in
            [
                "app_name": a.appName,
                "active_minutes": a.activeMinutes,
                "frame_count": a.frameCount,   // raw count, 别用来推时间
                "share_pct": summed > 0
                    ? Int(round(Double(a.activeMinutes) / Double(summed) * 100))
                    : 0
            ]
        }
        let windows: [[String: Any]] = activity.windows.prefix(10).map { w in
            [
                "app_name": w.appName,
                "window_name": w.windowName,
                "active_minutes": w.activeMinutes,
                "frame_count": w.frameCount
            ]
        }

        emitJSON([
            "start_time": iso8601(start),
            "end_time": iso8601(end),
            "mode": mode,
            "total_active_minutes": totalMins,
            "total_frames": activity.totalFrames,
            "apps": apps,
            "windows": windows
        ])
    }

    /// `memories` —— 列出 / 搜索 portrait + events 知识库文件。
    private static func runMemories(args: [String]) -> Never {
        let opts = parseOpts(args)
        let q = opts["q"]?.lowercased()
        let limit = Int(opts["limit"] ?? "20") ?? 20

        let root = Storage.portraitDir
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            emitJSON(["data": [Any](), "result_count": 0])
        }

        var out: [[String: Any]] = []
        let enumer = fm.enumerator(at: root,
                                   includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumer?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

            if let q, !body.lowercased().contains(q),
               !url.lastPathComponent.lowercased().contains(q) {
                continue
            }
            let title = url.deletingPathExtension().lastPathComponent
            let snippet = body.prefix(300).description
            out.append([
                "title": title,
                "path": url.path,
                "scope": url.deletingLastPathComponent().lastPathComponent,
                "modified": iso8601(modified),
                "snippet": snippet
            ])
            if out.count >= limit { break }
        }
        emitJSON([
            "data": out,
            "result_count": out.count,
            "query": q ?? NSNull()
        ])
    }

    /// `audio` —— 时间段内 / 按 speaker 过滤的转录条目。
    private static func runAudio(args: [String]) -> Never {
        let opts = parseOpts(args)
        let start = parseTime(opts["start"], anchor: .start) ?? Date().addingTimeInterval(-3600)
        let end = parseTime(opts["end"], anchor: .end) ?? Date()
        let speaker = opts["speaker"]
        let limit = Int(opts["limit"] ?? "60") ?? 60

        let db = TimelineDB()
        guard db.exists else { errJSON("timeline DB not found at \(db.dbPath)") }

        let trs = searchTranscripts(db: db, q: nil, start: start, end: end,
                                    limit: limit, speakerName: speaker)
        let out: [[String: Any]] = trs.map { t in
            [
                "timestamp": iso8601(t.timestamp),
                "text": t.text,
                "device": t.device,
                "is_input": t.isInput,
                "speaker_id": t.speakerId.map { $0 as Any } ?? NSNull(),
                "speaker_name": t.speakerName ?? ""
            ]
        }
        emitJSON([
            "data": out,
            "start_time": iso8601(start),
            "end_time": iso8601(end),
            "result_count": out.count
        ])
    }

    // MARK: - Helpers

    private static func parseOpts(_ args: [String]) -> [String: String] {
        // ⚠ **用 updateValue 不要用 subscript 赋值** —— Swift 6 / macOS 26
        // 工具链上,`out[key] = val` 这种 Dictionary 下标赋值在 enum 的
        // private static func 里偶发会被优化掉(opts 永远空 dict),花了一
        // 小时定位。换成 updateValue(_:forKey:) 一切正常。
        //
        // 同时支持两种形式(AI agent 实际两种都会试):
        //   --start today        (空格分隔)
        //   --start=today        (等号 inline)
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let stripped = String(a.dropFirst(2))
            // inline 等号形式
            if let eq = stripped.firstIndex(of: "=") {
                let key = String(stripped[..<eq])
                let val = String(stripped[stripped.index(after: eq)...])
                out.updateValue(val, forKey: key)
                i += 1
                continue
            }
            // 空格分隔形式
            if i + 1 < args.count {
                out.updateValue(args[i + 1], forKey: stripped)
                i += 2
            } else {
                // 单独的 flag(没值)—— e.g. --help。当前用不到,跳过。
                i += 1
            }
        }
        return out
    }

    /// 时间锚:解析"日"为单位的关键词时,start = 当天 00:00,end = 当天 23:59:59。
    enum TimeAnchor { case start, end }

    /// 解析相对/绝对时间。失败返回 nil。
    private static func parseTime(_ raw: String?, anchor: TimeAnchor = .start) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let lower = s.lowercased()
        let now = Date()
        let cal = Calendar.current
        if lower == "now"        { return now }
        if lower == "today" {
            let startOfToday = cal.startOfDay(for: now)
            switch anchor {
            case .start: return startOfToday
            case .end:   return now   // today + end = 现在,别跳到明天 00:00
            }
        }
        if lower == "yesterday" {
            let startOfToday = cal.startOfDay(for: now)
            let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
            switch anchor {
            case .start: return startOfYesterday
            case .end:   return startOfToday.addingTimeInterval(-1)   // 昨天 23:59:59
            }
        }

        // 形如 "30m ago" / "1h ago" / "2d ago"
        let pattern = #"^(\d+)\s*([smhd])\s*ago$"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let nRange = Range(m.range(at: 1), in: lower),
           let uRange = Range(m.range(at: 2), in: lower),
           let n = Double(lower[nRange]) {
            let unit = lower[uRange]
            let sec: TimeInterval = {
                switch unit {
                case "s": return n
                case "m": return n * 60
                case "h": return n * 3600
                case "d": return n * 86400
                default:  return 0
                }
            }()
            return now.addingTimeInterval(-sec)
        }

        // ISO 8601 / 通用日期
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func emitJSON(_ obj: Any) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        exit(0)
    }

    private static func errJSON(_ msg: String) -> Never {
        let obj = ["error": msg]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }
        exit(1)
    }

    private static func printUsage() {
        let usage = """
        mp-query — query My Portrait local screen activity data

        USAGE
          mp-query <subcommand> [options]

        SUBCOMMANDS
          search            full-text search across OCR + audio
          activity-summary  top apps / windows over a time range
          memories          search the user's portrait notes / events
          audio             audio transcriptions over a time range

        COMMON OPTIONS
          --start <time>    "30m ago" | "1h ago" | "today" | ISO 8601
          --end <time>      defaults to "now"
          --q "<text>"      keyword filter (FTS-style contains)
          --app "<name>"    e.g. "Cursor", "Google Chrome"
          --limit <n>       default 10 (search) / 20 (memories) / 60 (audio)
          --content <type>  search: all | ocr | audio (default: all)
          --speaker "<n>"   audio: filter by speaker name

        EXAMPLES
          mp-query activity-summary --start "1h ago"
          mp-query search --start "today" --q "deadline" --content ocr
          mp-query memories --q "preference"
          mp-query audio --start "30m ago" --speaker "Joy"
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }

    private static func inferModeLabel(from a: TimelineDB.RecentActivity) -> String {
        // 复用 SuggestionEngine 的 mode 表达成纯字符串。
        // 简化版:看 top app 名落在哪一类。
        guard let top = a.apps.first else { return "idle" }
        let n = top.appName.lowercased()
        if n.contains("cursor") || n.contains("code") || n.contains("xcode")
            || n.contains("zed") || n.contains("intellij") || n.contains("vim") {
            return "coding"
        }
        if n.contains("chrome") || n.contains("safari") || n.contains("firefox")
            || n.contains("arc") || n.contains("brave") {
            return "browsing"
        }
        if n.contains("zoom") || n.contains("teams") || n.contains("meet") {
            return "meeting"
        }
        if n.contains("slack") || n.contains("discord") || n.contains("messages")
            || n.contains("mail") {
            return "communication"
        }
        if n.contains("notion") || n.contains("obsidian") || n.contains("notes") {
            return "writing"
        }
        return "mixed"
    }

    // MARK: - DB helpers

    private struct FrameSearchResult {
        let id: Int64
        let timestamp: Date
        let appName: String?
        let windowName: String?
        let browserUrl: String?
        let ocrText: String
    }
    private struct TranscriptResult {
        let timestamp: Date
        let text: String
        let device: String
        let isInput: Bool
        let speakerId: Int?
        let speakerName: String?
    }

    private static func searchFrames(
        db: TimelineDB, q: String?, appFilter: String?,
        start: Date, end: Date, limit: Int
    ) -> [FrameSearchResult] {
        // **per-frame SQL LIKE 直查** —— frames.full_text 每帧独立存 OCR,
        // 直接 WHERE full_text LIKE '%q%' 命中精确帧。之前把所有帧 OCR 合
        // 200k 大 blob 然后 substring 匹配,200k 一截大量帧丢了,而且匹配
        // 粒度也丢了(blob 命中就 return 头 N 帧,不是真匹配的帧)。
        var db_: OpaquePointer?
        guard sqlite3_open_v2(db.dbPath, &db_, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db_) }

        // SQL 拼接:基础时间段过滤,可选 app + q 子句。
        var sql = """
            SELECT id, timestamp_ms, app_name,
                   COALESCE(window_name, ''),
                   COALESCE(browser_url, ''),
                   COALESCE(full_text, '')
            FROM frames
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
              AND app_name IS NOT NULL AND app_name != ''
            """
        if appFilter != nil {
            sql += " AND LOWER(app_name) LIKE ?"
        }
        if q != nil {
            // 命中 OCR 全文,或者窗口标题(用户搜 "Gmail" 也能命中 "Gmail - 浏览…")
            sql += " AND (LOWER(full_text) LIKE ? OR LOWER(window_name) LIKE ?)"
        }
        sql += " ORDER BY timestamp_ms DESC LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db_, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var bindIdx: Int32 = 1
        sqlite3_bind_int64(stmt, bindIdx, Int64(start.timeIntervalSince1970 * 1000))
        bindIdx += 1
        sqlite3_bind_int64(stmt, bindIdx, Int64(end.timeIntervalSince1970 * 1000))
        bindIdx += 1
        if let appLower = appFilter?.lowercased() {
            sqlite3_bind_text(stmt, bindIdx, "%\(appLower)%", -1, TRANSIENT)
            bindIdx += 1
        }
        if let qLower = q?.lowercased() {
            let pat = "%\(qLower)%"
            sqlite3_bind_text(stmt, bindIdx, pat, -1, TRANSIENT)
            bindIdx += 1
            sqlite3_bind_text(stmt, bindIdx, pat, -1, TRANSIENT)
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))

        var out: [FrameSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_int64(stmt, 1)
            let app = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let win = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
            let full = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? ""
            // 截 OCR 文本 ~600 字符给 AI(全文太大撑爆 context)。
            let snippet = extractSnippet(fullText: full, query: q, maxChars: 600)
            out.append(.init(
                id: id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000),
                appName: app,
                windowName: win,
                browserUrl: url.isEmpty ? nil : url,
                ocrText: snippet
            ))
        }
        return out
    }

    /// 从一整段 OCR 文本里抠 query 周围 ~600 字符的窗口,AI 能直接看到上下文。
    /// 没 query / 没命中 → 返头部 600 字符。
    private static func extractSnippet(fullText: String, query: String?, maxChars: Int) -> String {
        guard !fullText.isEmpty else { return "" }
        guard let q = query, !q.isEmpty,
              let range = fullText.range(of: q, options: .caseInsensitive) else {
            return String(fullText.prefix(maxChars))
        }
        let lower = max(fullText.startIndex,
                        fullText.index(range.lowerBound,
                                       offsetBy: -maxChars / 3,
                                       limitedBy: fullText.startIndex)
                          ?? fullText.startIndex)
        let upper = min(fullText.endIndex,
                        fullText.index(range.upperBound,
                                       offsetBy: maxChars * 2 / 3,
                                       limitedBy: fullText.endIndex)
                          ?? fullText.endIndex)
        var snip = String(fullText[lower..<upper])
        if lower != fullText.startIndex { snip = "…" + snip }
        if upper != fullText.endIndex { snip = snip + "…" }
        return snip
    }

    private static func searchTranscripts(
        db: TimelineDB, q: String?, start: Date, end: Date,
        limit: Int, speakerName: String? = nil
    ) -> [TranscriptResult] {
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let half = end.timeIntervalSince(start) / 2
        let rows = db.audioTranscripts(around: mid, before: half, after: half)
        var out: [TranscriptResult] = []
        let qLower = q?.lowercased()
        for r in rows {
            if let qLower, !r.text.lowercased().contains(qLower) { continue }
            // speakerName 暂不可用(audioTranscripts 没 JOIN speakers),先返 nil。
            // 后续如果要支持 --speaker 过滤,需在 TimelineDB 加 JOIN。
            _ = speakerName
            out.append(.init(
                timestamp: r.timestamp,
                text: r.text,
                device: r.device,
                isInput: r.isInput,
                speakerId: r.speakerId,
                speakerName: nil
            ))
            if out.count >= limit { break }
        }
        return out
    }
}
