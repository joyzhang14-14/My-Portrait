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

        // Required: created, impact, weight, access_count, access_history,
        // occurrences, tags, pinned. Optional: source, superseded_by, archived_at.
        let created = try requireDate(fields, "created")
        let impact = try requireDouble(fields, "impact")
        // impact_source defaults to baseline_duration so older files (pre-LLM
        // scoring) read cleanly without a re-migration.
        let impactSource = (try? optionalString(fields, "impact_source")) ?? nil ?? "baseline_duration"
        let weight = try requireDouble(fields, "weight")
        let accessCount = try requireInt(fields, "access_count")
        let accessHistory = try requireDateArray(fields, "access_history")
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
        let memberFrameIds = (try? optionalInt64Array(fields, "member_frame_ids")) ?? []

        return PortraitFile(
            created: created,
            impact: impact,
            impactSource: impactSource,
            weight: weight,
            accessCount: accessCount,
            accessHistory: accessHistory,
            occurrences: occurrences,
            eventTitle: eventTitle,
            eventSummary: eventSummary,
            memberFrameIds: memberFrameIds,
            source: source,
            tags: tags,
            supersededBy: supersededBy,
            pinned: pinned,
            archivedAt: archivedAt,
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
        lines.append("impact: \(formatDouble(f.impact))")
        lines.append("impact_source: \(f.impactSource)")
        lines.append("weight: \(formatDouble(f.weight))")
        lines.append("access_count: \(f.accessCount)")
        lines.append("access_history: \(formatDateArray(f.accessHistory, dateOnly: true))")
        lines.append("occurrences: \(formatDateArray(f.occurrences, dateOnly: false))")
        lines.append("event_title: \(formatNullableString(f.eventTitle.isEmpty ? nil : f.eventTitle))")
        lines.append("event_summary: \(formatNullableString(f.eventSummary.isEmpty ? nil : f.eventSummary))")
        lines.append("member_frame_ids: \(formatInt64Array(f.memberFrameIds))")
        lines.append("source: \(formatNullableString(f.source))")
        lines.append("tags: \(formatStringArray(f.tags))")
        lines.append("superseded_by: \(formatNullableString(f.supersededBy))")
        lines.append("pinned: \(f.pinned)")
        lines.append("archived_at: \(f.archivedAt.map { formatDateTime($0) } ?? "null")")
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + f.body
    }

    // MARK: - Tiny YAML parser (flat key-value only)

    /// Parses the small subset of YAML we actually emit. Returns raw string
    /// values keyed by field name. Each field's typed parser then converts.
    private static func parseFlatYAML(_ yaml: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw IOError.malformedFrontmatter("no colon in line: \(line)")
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: colon)
            var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            // Strip an inline `# comment` (but only if not inside quotes/brackets).
            if !value.hasPrefix("[") && !value.hasPrefix("\""),
               let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            out[key] = value
        }
        return out
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
        // Strip surrounding quotes if present.
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
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
        return inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Date format helpers
    //
    // We emit two formats:
    //   - date-only:  2026-05-17       (created, access_history items)
    //   - date+time:  2026-05-17T14:20:00Z (occurrences, archived_at)
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

    private static func formatDouble(_ d: Double) -> String {
        // Drop trailing zeros: 3.0 -> "3", 3.6 -> "3.6".
        if d.rounded() == d { return String(format: "%g", d) }
        return String(format: "%.4g", d)
    }

    private static func formatNullableString(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "null" }
        return needsQuotes(s) ? "\"\(s)\"" : s
    }

    /// Quote if the value would confuse the parser (contains `,`, `:`, etc).
    private static func needsQuotes(_ s: String) -> Bool {
        s.contains(",") || s.contains(":") || s.contains("[") || s.contains("]")
    }
}
