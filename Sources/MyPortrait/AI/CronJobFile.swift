import Foundation

/// Serializes / parses a `CronJob` to the screenpipe-style on-disk format:
/// a per-cron-job directory containing `cron_job.md` (frontmatter + prompt) and
/// `runs.json` (run history sidecar).
///
/// `cron_job.md` layout — two `---` fences; everything after the 2nd fence is
/// the prompt body verbatim (so the prompt may contain any character):
/// ```
/// ---
/// id: <UUID>
/// title: <name>
/// enabled: true
/// schedule: every 60m
/// window: last 2h
/// connections:
/// - obsidian
/// ---
///
/// <prompt body markdown>
/// ```
///
/// String round-trip formats (serialize + parse back):
///   schedule: `never` | `every 60m` (everyMinutes) |
///             `daily at 21` (dailyAt hour) | `weekly 2 at 9` (weeklyOn weekday hour)
///   window:   `none` | `last 30m` (lastMinutes) | `last 2h` (lastHours) | `today`
enum CronJobFile {

    // MARK: - Cadence <-> String

    static func encode(_ c: Cadence) -> String {
        switch c {
        case .never:                       return "never"
        case .everyMinutes(let m):         return "every \(m)m"
        case .dailyAt(let h):              return "daily at \(h)"
        case .weeklyOn(let d, let h):      return "weekly \(d) at \(h)"
        }
    }

    static func decodeCadence(_ s: String) -> Cadence {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "never" { return .never }
        let parts = t.split(separator: " ").map(String.init)
        switch parts.first {
        case "every":
            // "every 60m"
            if parts.count == 2, let m = Int(parts[1].dropLast()) { return .everyMinutes(m) }
        case "daily":
            // "daily at 21"
            if parts.count == 3, let h = Int(parts[2]) { return .dailyAt(hour: h) }
        case "weekly":
            // "weekly 2 at 9"
            if parts.count == 4, let d = Int(parts[1]), let h = Int(parts[3]) {
                return .weeklyOn(weekday: d, hour: h)
            }
        default: break
        }
        return .never
    }

    // MARK: - ContextWindow <-> String

    static func encode(_ w: ContextWindow) -> String {
        switch w {
        case .none:                 return "none"
        case .lastMinutes(let m):   return "last \(m)m"
        case .lastHours(let h):     return "last \(h)h"
        case .today:                return "today"
        }
    }

    static func decodeWindow(_ s: String) -> ContextWindow {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "none" { return .none }
        if t == "today" { return .today }
        let parts = t.split(separator: " ").map(String.init)
        // "last 30m" / "last 2h"
        if parts.count == 2, parts[0] == "last" {
            let v = parts[1]
            if v.hasSuffix("m"), let n = Int(v.dropLast()) { return .lastMinutes(n) }
            if v.hasSuffix("h"), let n = Int(v.dropLast()) { return .lastHours(n) }
        }
        return .none
    }

    // MARK: - cron_job.md generate

    /// Build the full `cron_job.md` text for a cronJob.
    static func renderMarkdown(_ p: CronJob) -> String {
        var fm = "---\n"
        fm += "id: \(p.id.uuidString)\n"
        fm += "title: \(p.name)\n"
        fm += "enabled: \(p.isEnabled)\n"
        fm += "muted: \(p.muted)\n"
        fm += "schedule: \(encode(p.schedule))\n"
        fm += "window: \(encode(p.window))\n"
        if p.connections.isEmpty {
            fm += "connections: []\n"
        } else {
            fm += "connections:\n"
            for c in p.connections { fm += "- \(c)\n" }
        }
        fm += "---\n\n"
        return fm + p.prompt
    }

    // MARK: - cron_job.md parse

    /// Parse a `cron_job.md`. Returns nil if the frontmatter is malformed.
    /// `runs` / `lastRunAt` come from the runs.json sidecar, not here.
    static func parseMarkdown(_ text: String, fallbackName: String) -> CronJob? {
        // Split into frontmatter + body on the first two `---` fence lines.
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var closeIdx: Int? = nil
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closeIdx = i; break
        }
        guard let close = closeIdx else { return nil }

        let fmLines = Array(lines[1..<close])
        // Body is everything after the closing fence; drop one leading blank line.
        var bodyLines = Array(lines[(close + 1)...])
        if bodyLines.first == "" { bodyLines.removeFirst() }
        let prompt = bodyLines.joined(separator: "\n")

        // Parse frontmatter: `key: value` lines, plus `- item` lines that
        // belong to the most recent list-valued key.
        var scalars: [String: String] = [:]
        var connections: [String] = []
        var currentListKey: String? = nil
        for raw in fmLines {
            if raw.hasPrefix("- ") {
                let item = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if currentListKey == "connections", !item.isEmpty { connections.append(item) }
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                currentListKey = key
            } else {
                currentListKey = nil
                scalars[key] = value
            }
        }

        let id = scalars["id"].flatMap { UUID(uuidString: $0) } ?? UUID()
        let name = scalars["title"] ?? fallbackName
        let enabled = (scalars["enabled"] ?? "true") == "true"
        // 老 cron_job.md 没 muted 字段 → default false。
        let muted = (scalars["muted"] ?? "false") == "true"
        let schedule = decodeCadence(scalars["schedule"] ?? "never")
        let window = decodeWindow(scalars["window"] ?? "none")

        return CronJob(id: id, name: name, prompt: prompt, window: window,
                       schedule: schedule, isEnabled: enabled,
                       connections: connections, muted: muted)
    }

    // MARK: - slug

    /// Lowercase, spaces -> `-`, strip anything not alphanumeric/`-`.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if ch == " " || ch == "-" || ch == "_" {
                if !lastDash && !out.isEmpty { out.append("-"); lastDash = true }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "cronJob" : out
    }
}
