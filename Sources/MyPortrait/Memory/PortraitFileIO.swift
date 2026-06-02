import Foundation

/// Hand-rolled YAML frontmatter parser + serializer scoped to the PortraitFile
/// schema. Deliberately NOT a general YAML library — only the field types we
/// actually use (Date, Double, Int, String, [String], [Date], Bool, null).
/// Keeps the dependency surface zero.
enum PortraitFileIO {
    enum IOError: Error, CustomStringConvertible {
        case missingFrontmatter
        case malformedFrontmatter(String)
        case missingField(String)
        case typeMismatch(field: String, expected: String, got: String)

        var description: String {
            switch self {
            case .missingFrontmatter:
                return "File does not start with a `---` YAML frontmatter block."
            case .malformedFrontmatter(let detail):
                return "Malformed frontmatter: \(detail)"
            case .missingField(let f):
                return "Required field missing: \(f)"
            case .typeMismatch(let f, let expected, let got):
                return "Field \(f) expected \(expected), got \(got)"
            }
        }
    }

    // MARK: - Read

    static func read(from url: URL) throws -> PortraitFile {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> PortraitFile {
        // Split into frontmatter + body using `---` delimiters at line start.
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else {
            throw IOError.missingFrontmatter
        }
        let afterOpen = raw.index(raw.startIndex, offsetBy: raw.hasPrefix("---\r\n") ? 5 : 4)
        let rest = String(raw[afterOpen...])
        guard let closeRange = rest.range(of: "\n---") else {
            throw IOError.malformedFrontmatter("no closing `---`")
        }
        let yaml = String(rest[..<closeRange.lowerBound])
        var bodyStart = closeRange.upperBound
        // Skip optional newline(s) after the closing `---`.
        while bodyStart < rest.endIndex, (rest[bodyStart] == "\n" || rest[bodyStart] == "\r") {
            bodyStart = rest.index(after: bodyStart)
        }
        let body = String(rest[bodyStart...])

        let fields = try parseFlatYAML(yaml)

        // Required: created, weight, occurrences, tags, pinned.
        // Optional: impact (event-only — portrait files don't write it),
        //           source, superseded_by, archived_at.
        let created = try requireDate(fields, "created")
        let impact: Double? = (try? requireDouble(fields, "impact"))   // nil for portrait
        // raw_impact / rebalance_count / impact_source —— event-only。
        // portrait 文件不写它们,缺失 → nil(序列化也整行 skip)。
        let rawImpact = try? requireDouble(fields, "raw_impact")
        let rebalanceCount = try? requireInt(fields, "rebalance_count")
        let impactSource = (try? optionalString(fields, "impact_source")) ?? nil
        let weight = try requireDouble(fields, "weight")
        let occurrences = try requireDateArray(fields, "occurrences")
        let tags = try requireStringArray(fields, "tags")
        let pinned = try requireBool(fields, "pinned")
        let source = try optionalString(fields, "source")
        let supersededBy = try optionalString(fields, "superseded_by")
        let archivedAt = try optionalDate(fields, "archived_at")

        // Event-level fields — default empty for backward compat with files
        // written before the EventBuilder pipeline existed.
        let eventTitle = (try? optionalString(fields, "event_title")) ?? nil ?? ""
        let eventSummary = (try? optionalString(fields, "event_summary")) ?? nil ?? ""
        let eventType = ((try? optionalString(fields, "type")) ?? nil ?? "experience").lowercased()
        let portraitFacets = (try? facetArray(fields, "portrait_facets")) ?? []
        // `category` is legacy. Default "" — Distiller no longer routes by it.
        let category = (try? optionalString(fields, "category")) ?? nil ?? ""
        let memberFrameIds = (try? optionalInt64Array(fields, "member_frame_ids")) ?? []
        // distilled_into — portrait slugs already consumed from this event.
        // Default [] for files written before the field existed.
        let distilledInto = (try? requireStringArray(fields, "distilled_into")) ?? []
        // Phase 3 portrait-layer fields —— 全 optional，缺失 → nil（event 文件
        // 不持有这些；序列化时整行 skip）。
        let mergeCount = try? requireInt(fields, "merge_count")
        let primaryLabel = (try? optionalString(fields, "primary_label")) ?? nil
        let aliases = try? requireStringArray(fields, "aliases")
        let lastModified = (try? optionalDate(fields, "last_modified")) ?? nil
        let evidenceEventIds = try? requireStringArray(fields, "evidence_event_ids")
        let editNotes = try? editNotesArray(fields, "edit_notes")

        return PortraitFile(
            created: created,
            impact: impact,
            rawImpact: rawImpact,
            rebalanceCount: rebalanceCount,
            impactSource: impactSource,
            weight: weight,
            occurrences: occurrences,
            eventTitle: eventTitle,
            eventSummary: eventSummary,
            eventType: eventType,
            portraitFacets: portraitFacets,
            category: category,
            memberFrameIds: memberFrameIds,
            distilledInto: distilledInto,
            source: source,
            tags: tags,
            supersededBy: supersededBy,
            pinned: pinned,
            archivedAt: archivedAt,
            mergeCount: mergeCount,
            primaryLabel: primaryLabel,
            aliases: aliases,
            lastModified: lastModified,
            evidenceEventIds: evidenceEventIds,
            editNotes: editNotes,
            body: body
        )
    }

    // MARK: - Write

    static func write(_ file: PortraitFile, to url: URL) throws {
        let serialized = serialize(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try serialized.write(to: url, atomically: true, encoding: .utf8)
    }

    static func serialize(_ f: PortraitFile) -> String {
        var lines: [String] = ["---"]
        lines.append("created: \(formatDateOnly(f.created))")
        // impact 是 event-only 字段。portrait 文件 impact=nil 时整行 skip，
        // frontmatter 里完全不出现这一行。
        if let i = f.impact {
            lines.append("impact: \(formatDouble(i))")
        }
        // 3 个 event-only 字段:nil 整行 skip。portrait 文件不写。
        if let ri = f.rawImpact { lines.append("raw_impact: \(formatDouble(ri))") }
        if let rc = f.rebalanceCount { lines.append("rebalance_count: \(rc)") }
        if let isrc = f.impactSource { lines.append("impact_source: \(isrc)") }
        lines.append("weight: \(formatDouble(f.weight))")
        lines.append("occurrences: \(formatDateArray(f.occurrences, dateOnly: true))")
        lines.append("event_title: \(formatNullableString(f.eventTitle.isEmpty ? nil : f.eventTitle))")
        lines.append("event_summary: \(formatNullableString(f.eventSummary.isEmpty ? nil : f.eventSummary))")
        lines.append("type: \(f.eventType.isEmpty ? "experience" : f.eventType)")
        // 空数组 / 空集合 跳行 —— 减少无信息量的 "portrait_facets: []" /
        // "member_frame_ids: []" 噪声(personality concept 这俩天然为空)。
        if !f.portraitFacets.isEmpty {
            lines.append("portrait_facets: \(formatFacetArray(f.portraitFacets))")
        }
        if !f.category.isEmpty {
            // Only emit legacy `category` if it was present on read — keeps
            // brand-new files lean.
            lines.append("category: \(f.category)")
        }
        if !f.memberFrameIds.isEmpty {
            lines.append("member_frame_ids: \(formatInt64Array(f.memberFrameIds))")
        }
        lines.append("distilled_into: \(formatStringArray(f.distilledInto))")
        lines.append("source: \(formatNullableString(f.source))")
        lines.append("tags: \(formatStringArray(f.tags))")
        lines.append("superseded_by: \(formatNullableString(f.supersededBy))")
        lines.append("pinned: \(f.pinned)")
        lines.append("archived_at: \(f.archivedAt.map { formatDateTime($0) } ?? "null")")
        // Phase 3 portrait-layer 字段：nil 整行 skip —— event 文件不持有这些。
        if let mc = f.mergeCount { lines.append("merge_count: \(mc)") }
        if let pl = f.primaryLabel { lines.append("primary_label: \(formatNullableString(pl))") }
        if let al = f.aliases { lines.append("aliases: \(formatStringArray(al))") }
        if let lm = f.lastModified { lines.append("last_modified: \(formatDateOnly(lm))") }
        if let ev = f.evidenceEventIds { lines.append("evidence_event_ids: \(formatStringArray(ev))") }
        // AI 编辑历史。nil → 整行 skip;非空才写。
        if let notes = f.editNotes, !notes.isEmpty {
            lines.append("edit_notes: \(formatEditNotes(notes))")
        }
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + f.body
    }

    // MARK: - Tiny YAML parser (flat key-value only)

    /// Parses the small subset of YAML we actually emit. Returns raw string
    /// values keyed by field name. Each field's typed parser then converts.
    private static func parseFlatYAML(_ yaml: String) throws -> [String: String] {
        var out: [String: String] = [:]
        var lastKey: String?
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // 只有以 `snake_case_key:` 开头的行才算新字段；其余视为上一字段的
            // 续行 —— 兼容旧版序列化器写出的多行值（如多段 event_summary）。
            if let colon = line.firstIndex(of: ":"),
               isFieldKey(String(line[..<colon])) {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let valueStart = line.index(after: colon)
                var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
                // Strip an inline `# comment` (but only if not inside quotes/brackets).
                if !value.hasPrefix("[") && !value.hasPrefix("\""),
                   let hash = value.firstIndex(of: "#") {
                    value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
                }
                out[key] = value
                lastKey = key
            } else if let k = lastKey {
                out[k, default: ""] += "\n" + line
            } else {
                throw IOError.malformedFrontmatter("no colon in line: \(line)")
            }
        }
        return out
    }

    /// 一段文本是否是合法 frontmatter 字段名（全小写 ASCII + 数字 + 下划线）。
    /// 用于把"新字段行"与"上一字段值的散文续行"区分开。
    private static func isFieldKey(_ s: String) -> Bool {
        let k = s.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return false }
        return k.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII)
                              || $0.isNumber || $0 == "_" }
    }

    // MARK: - Typed field extractors

    private static func requireDouble(_ fs: [String: String], _ key: String) throws -> Double {
        guard let raw = fs[key] else { throw IOError.missingField(key) }
        guard let v = Double(raw) else {
            throw IOError.typeMismatch(field: key, expected: "Double", got: raw)
        }
        return v
    }

    private static func requireInt(_ fs: [String: String], _ key: String) throws -> Int {
        guard let raw = fs[key] else { throw IOError.missingField(key) }
        guard let v = Int(raw) else {
            throw IOError.typeMismatch(field: key, expected: "Int", got: raw)
        }
        return v
    }

    private static func requireBool(_ fs: [String: String], _ key: String) throws -> Bool {
        guard let raw = fs[key] else { throw IOError.missingField(key) }
        switch raw.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: throw IOError.typeMismatch(field: key, expected: "Bool", got: raw)
        }
    }

    private static func requireDate(_ fs: [String: String], _ key: String) throws -> Date {
        guard let raw = fs[key] else { throw IOError.missingField(key) }
        guard let v = parseDate(raw) else {
            throw IOError.typeMismatch(field: key, expected: "Date", got: raw)
        }
        return v
    }

    private static func optionalDate(_ fs: [String: String], _ key: String) throws -> Date? {
        guard let raw = fs[key], raw != "null", !raw.isEmpty else { return nil }
        guard let v = parseDate(raw) else {
            throw IOError.typeMismatch(field: key, expected: "Date?", got: raw)
        }
        return v
    }

    private static func optionalString(_ fs: [String: String], _ key: String) throws -> String? {
        guard let raw = fs[key], raw != "null", !raw.isEmpty else { return nil }
        // 加引号的值：去引号 + 反转义。未加引号的（旧文件多行原始值）原样返回。
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return unescapeString(String(raw.dropFirst().dropLast()))
        }
        return raw
    }

    /// 反转义 `formatNullableString` 写出的 `\\` / `\"` / `\n`。
    private static func unescapeString(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "n":  out.append("\n")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default:   out.append(n)
            }
        }
        return out
    }

    private static func requireStringArray(_ fs: [String: String], _ key: String) throws -> [String] {
        guard let raw = fs[key] else { throw IOError.missingField(key) }
        return parseFlowArray(raw).map { token in
            if token.hasPrefix("\""), token.hasSuffix("\"") {
                return String(token.dropFirst().dropLast())
            }
            return token
        }
    }

    /// portrait_facets serialised as YAML flow array of "facet:value" pairs:
    ///   portrait_facets: ["interests:art-history", "skills:swift-ui"]
    /// The colon triggers our `needsQuotes` so each pair is quoted. Parsing
    /// strips the quotes, then splits on the first `:`.
    private static func facetArray(_ fs: [String: String], _ key: String) throws -> [EventBuilder.PortraitFacet] {
        guard let raw = fs[key] else { return [] }
        let tokens = parseFlowArray(raw)
        var out: [EventBuilder.PortraitFacet] = []
        for raw in tokens {
            let s: String = raw.hasPrefix("\"") && raw.hasSuffix("\"")
                ? String(raw.dropFirst().dropLast()) : raw
            guard let colon = s.firstIndex(of: ":") else { continue }
            let facet = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !facet.isEmpty, !value.isEmpty else { continue }
            out.append(.init(facet: facet, value: value))
        }
        return out
    }

    private static func formatFacetArray(_ facets: [EventBuilder.PortraitFacet]) -> String {
        let parts = facets.map { "\"\($0.facet):\($0.value)\"" }
        return "[\(parts.joined(separator: ", "))]"
    }

    /// `edit_notes: [{"date":"2026-05-23","summary":"...","request":"..."}]`
    /// 用标准 JSON 解,省得自己处理字符串转义。空 / 非法 → nil。
    private static func editNotesArray(_ fs: [String: String], _ key: String) throws
        -> [PortraitFile.EditNote]?
    {
        guard let raw = fs[key], !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var out: [PortraitFile.EditNote] = []
        for obj in arr {
            guard let dateStr = obj["date"] as? String,
                  let date = parseDate(dateStr),
                  let summary = obj["summary"] as? String,
                  let request = obj["request"] as? String else { continue }
            out.append(.init(date: date, summary: summary, request: request))
        }
        return out.isEmpty ? nil : out
    }

    /// 反向 —— 编码成单行 JSON。日期取 yyyy-MM-dd(UTC,跟 occurrences 一致)。
    private static func formatEditNotes(_ notes: [PortraitFile.EditNote]) -> String {
        let arr: [[String: Any]] = notes.map {
            ["date": formatDateOnly($0.date),
             "summary": $0.summary,
             "request": $0.request]
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: arr,
                options: [.withoutEscapingSlashes, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    private static func optionalInt64Array(_ fs: [String: String], _ key: String) throws -> [Int64] {
        guard let raw = fs[key] else { return [] }
        let tokens = parseFlowArray(raw)
        var out: [Int64] = []
        out.reserveCapacity(tokens.count)
        for t in tokens {
            guard let v = Int64(t) else {
                throw IOError.typeMismatch(field: key, expected: "[Int64]", got: t)
            }
            out.append(v)
        }
        return out
    }

    private static func formatInt64Array(_ ns: [Int64]) -> String {
        let parts = ns.map { String($0) }
        return "[\(parts.joined(separator: ", "))]"
    }

    private static func requireDateArray(_ fs: [String: String], _ key: String) throws -> [Date] {
        guard let raw = fs[key] else { throw IOError.missingField(key) }
        let tokens = parseFlowArray(raw)
        var dates: [Date] = []
        dates.reserveCapacity(tokens.count)
        for t in tokens {
            guard let d = parseDate(t) else {
                throw IOError.typeMismatch(field: key, expected: "[Date]", got: t)
            }
            dates.append(d)
        }
        return dates
    }

    /// Parses `[a, b, c]` → `["a", "b", "c"]`. Returns `[]` for `[]` or empty.
    private static func parseFlowArray(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return [] }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        // 引号感知扫描:只在**引号外**的逗号切分。否则 LLM 给的自由文本 tag /
        // alias 里带逗号(如 "Tokyo, Japan")会被切成两半 + 残留引号,数据损坏。
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        for c in inner {
            if c == "\"" { inQuotes.toggle(); cur.append(c); continue }
            if c == "," && !inQuotes {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    // MARK: - Date format helpers
    //
    // We emit two formats:
    //   - date-only:  2026-05-17       (created, access_history items, occurrences)
    //   - date+time:  2026-05-17T14:20:00Z (archived_at)
    //
    // The parser accepts either, falling back through both formatters.

    // Swift 6 strict concurrency: Foundation formatters aren't Sendable, but
    // we only configure them at init and then call thread-safe methods. The
    // `nonisolated(unsafe)` opt-out is appropriate here.
    nonisolated(unsafe) private static let dateOnlyFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated(unsafe) private static let dateTimeFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let d = dateOnlyFmt.date(from: t) { return d }
        if let d = dateTimeFmt.date(from: t) { return d }
        // Some YAML emitters use a space instead of T; normalise + retry.
        let withT = t.replacingOccurrences(of: " ", with: "T")
        return dateTimeFmt.date(from: withT)
    }

    private static func formatDateOnly(_ d: Date) -> String { dateOnlyFmt.string(from: d) }
    private static func formatDateTime(_ d: Date) -> String { dateTimeFmt.string(from: d) }

    private static func formatDateArray(_ ds: [Date], dateOnly: Bool) -> String {
        let parts = ds.map { dateOnly ? formatDateOnly($0) : formatDateTime($0) }
        return "[\(parts.joined(separator: ", "))]"
    }

    private static func formatStringArray(_ ss: [String]) -> String {
        let parts = ss.map { needsQuotes($0) ? "\"\($0)\"" : $0 }
        return "[\(parts.joined(separator: ", "))]"
    }

    /// Flow-array 元素是否需要加引号（含会让解析器误判的字符）。
    private static func needsQuotes(_ s: String) -> Bool {
        s.contains(",") || s.contains(":") || s.contains("[") || s.contains("]")
    }

    private static func formatDouble(_ d: Double) -> String {
        // Drop trailing zeros: 3.0 -> "3", 3.6 -> "3.6".
        if d.rounded() == d { return String(format: "%g", d) }
        return String(format: "%.4g", d)
    }

    /// 始终加引号并转义反斜杠 / 双引号 / 换行 —— 保证多行值（如多段
    /// event_summary）序列化成单物理行，扁平 YAML 解析器才不会被续行打断。
    private static func formatNullableString(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "null" }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
