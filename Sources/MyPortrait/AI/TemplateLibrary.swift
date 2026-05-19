import Foundation
import Observation

/// User-editable "shortcut" prompts surfaced as the 6 cards at the top of
/// Home. Each template carries an optional time window — when the user
/// clicks the card, we resolve that window into a ContextChip
/// and send the bundled prompt to chat.
@MainActor
@Observable
final class TemplateLibrary {
    static let shared = TemplateLibrary()

    private(set) var templates: [SummaryTemplate] = []

    private let key = "MyPortrait.summaryTemplates.v1"

    private init() {
        load()
        if templates.isEmpty {
            templates = Self.seeds
            save()
        }
    }

    // MARK: - CRUD

    func add(_ t: SummaryTemplate) {
        templates.append(t); save()
    }

    func update(_ t: SummaryTemplate) {
        guard let i = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates[i] = t; save()
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        save()
    }

    func reorder(from src: IndexSet, to dst: Int) {
        templates.move(fromOffsets: src, toOffset: dst); save()
    }

    func resetToSeeds() {
        templates = Self.seeds; save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SummaryTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Seed defaults

    static let seeds: [SummaryTemplate] = [
        .init(emoji: "⚡️", title: "Automate My Work",
              subtitle: "Analyze your habits and find time-savers",
              prompt: "Look at my recent screen activity and suggest 3 specific automations or shortcuts that would save me time. Be concrete.",
              window: .lastHours(8)),
        .init(emoji: "📋", title: "Day Recap",
              subtitle: "Today's accomplishments, key moments, next steps",
              prompt: "Summarize what I worked on today across all apps. Group by topic, highlight key accomplishments, flag anything unfinished.",
              window: .today),
        .init(emoji: "🏢", title: "Standup Update",
              subtitle: "Yesterday + today + blockers, ready to paste",
              prompt: "Generate a standup update: 'Yesterday I...' / 'Today I'll...' / 'Blockers:'. Be terse and actionable. Use bullet points.",
              window: .today),
        .init(emoji: "💡", title: "What's Top of Mind",
              subtitle: "Recurring topics + themes from your activity",
              prompt: "What topics keep coming up in my recent activity? List 3-5 themes, each with a one-sentence explanation of why I might be focused on it.",
              window: .lastHours(8)),
        .init(emoji: "✨", title: "Custom Summary",
              subtitle: "Build your own",
              prompt: "Summarize my recent activity. Highlight what you think is most important.",
              window: .lastHours(2)),
        .init(emoji: "🔍", title: "Discover",
              subtitle: "Surface something I didn't notice",
              prompt: "Look at my recent screen activity and tell me one thing I might have missed — a pattern, a topic that recurs, or something I started but didn't finish.",
              window: .today)
    ]
}

/// A reusable prompt + optional context window. `schedule` (optional) lets
/// the template re-run itself on a cadence while the app is open.
struct SummaryTemplate: Identifiable, Hashable, Codable {
    var id: UUID
    var emoji: String
    var title: String
    var subtitle: String
    var prompt: String
    var window: ContextWindow
    var schedule: Cadence = .never
    /// Last time this template auto-ran (so the runner skips dupes).
    var lastRunAt: Date? = nil

    init(id: UUID = UUID(), emoji: String, title: String, subtitle: String,
         prompt: String, window: ContextWindow,
         schedule: Cadence = .never, lastRunAt: Date? = nil) {
        self.id = id; self.emoji = emoji; self.title = title; self.subtitle = subtitle
        self.prompt = prompt; self.window = window
        self.schedule = schedule; self.lastRunAt = lastRunAt
    }
}

/// How often a scheduled template auto-runs.
enum Cadence: Hashable, Codable {
    case never
    case everyMinutes(Int)
    /// Local time of day in 24h, e.g. 9 = 09:00. Fires once per day.
    case dailyAt(hour: Int)
    /// 1=Sun…7=Sat (Calendar.weekday convention). Fires once per week.
    case weeklyOn(weekday: Int, hour: Int)

    var label: String {
        switch self {
        case .never:                       return "never"
        case .everyMinutes(let m):
            if m % 60 == 0 { return "every \(m/60)h" }
            return "every \(m)m"
        case .dailyAt(let h):              return String(format: "daily at %02d:00", h)
        case .weeklyOn(let d, let h):
            let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "weekly \(names[d]) \(String(format: "%02d:00", h))"
        }
    }

    /// Has `now` reached the next fire time after `lastRun`?
    func isDue(lastRun: Date?, now: Date = Date()) -> Bool {
        switch self {
        case .never:
            return false
        case .everyMinutes(let m):
            guard let last = lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(m * 60)
        case .dailyAt(let h):
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = h; comps.minute = 0
            guard let todayFire = cal.date(from: comps) else { return false }
            guard now >= todayFire else { return false }
            guard let last = lastRun else { return true }
            return last < todayFire
        case .weeklyOn(let d, let h):
            let cal = Calendar.current
            let wkday = cal.component(.weekday, from: now)
            guard wkday == d else { return false }
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = h; comps.minute = 0
            guard let fire = cal.date(from: comps), now >= fire else { return false }
            guard let last = lastRun else { return true }
            return last < fire
        }
    }
}

/// Time window the template auto-attaches as a ContextChip when run.
enum ContextWindow: Hashable, Codable {
    case none
    case lastMinutes(Int)
    case lastHours(Int)
    case today

    var label: String {
        switch self {
        case .none:                 return "no context"
        case .lastMinutes(let m):   return "last \(m) min"
        case .lastHours(let h):     return "last \(h) h"
        case .today:                return "today"
        }
    }

    /// Convert to a runtime ContextChip the chat send pipeline understands.
    func resolveChip() -> ContextChip? {
        switch self {
        case .none:                 return nil
        case .lastMinutes(let m):   return ContextChip(spec: .lastMinutes(m))
        case .lastHours(let h):     return ContextChip(spec: .lastMinutes(h * 60))
        case .today:                return ContextChip(spec: .today)
        }
    }
}
