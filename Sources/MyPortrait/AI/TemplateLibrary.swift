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

    // v2 = adapted for My-Portrait data model (uses mp-query memories /
    // mp-folders skills + portrait/ + events/). v1 was the screenpipe-style
    // generic "screen activity" set. Old v1 UserDefaults data is kept
    // (not deleted), but the app reads v2 only — users see the new seeds.
    private let key = "MyPortrait.summaryTemplates.v2"

    /// 「已退休的种子清过一次没有」标志。见 removeRetiredFolderSeed。
    private let retiredSeedsKey = "MyPortrait.summaryTemplates.retiredSeeds.v3"

    private init() {
        load()
        if templates.isEmpty {
            templates = Self.seeds
            save()
        }
        removeRetiredFolderSeed()
    }

    /// 已退休的种子:标题 → prompt 里必须出现的特征串。
    ///
    /// - Folder Suggestions:归档到文件夹已经由 pipeline 自己做了
    /// - Standup Update:产出形态是团队站会(Slack / Blockers),不通用
    /// - My Portrait Update:跟 Portraits Distiller 每天做的事重复,
    ///   区别只是它不落盘
    private static let retiredSeeds: [String: String] = [
        "Folder Suggestions":  "mp-folders",
        "Standup Update":      "standup update",
        "My Portrait Update":  "long-term portrait",
        "Schedule a Cron Job":  "activity-summary",
    ]

    /// 一次性清掉已退休的种子。
    ///
    /// 种子只在**首次**启动时写进 UserDefaults,之后就是用户自己的列表了 ——
    /// 从 `seeds` 里删掉只对全新安装生效,老用户首页照旧摆着它们。
    ///
    /// 只删**没被改过**的(标题没变 + prompt 里还留着那句特征串):用户要是把
    /// 某张卡改成了别的东西,那就是他自己的快捷方式,不能替他删。
    /// 靠一个标志只跑一次 —— 否则用户之后自己新建一个同名的又会被吃掉。
    private func removeRetiredFolderSeed() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: retiredSeedsKey) else { return }
        defaults.set(true, forKey: retiredSeedsKey)
        let before = templates
        templates.removeAll { t in
            guard let marker = Self.retiredSeeds[t.title] else { return false }
            return t.prompt.lowercased().contains(marker)
        }
        // 补上新加的种子 —— 只删不补的话,新种子永远只有全新安装能看到
        // (老用户的列表非空,init 里那句 `if templates.isEmpty` 不会执行)。
        // 同样靠上面那个标志只跑一次:用户之后自己删掉的卡不会再长回来。
        let titles = Set(templates.map(\.title))
        for seed in Self.seeds where !titles.contains(seed.title) {
            templates.append(seed)
        }
        if templates != before { save() }
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
        .init(emoji: "🔔", title: "Setup Follow-up Reminder",
              subtitle: "Catch promises and loose ends you may have forgotten",
              prompt: """
                Set up a cron job for me: title "Follow-up Reminders", runs \
                every 60 minutes, context window "last 3h", no connections. \
                Show me the schedule and confirm before you call \
                `mp-query cronjob add`. Use exactly this prompt body:

                ---
                You are a follow-up assistant. You run every hour. Your goal is to surface **promises, follow-ups and stuck items the user may have forgotten** — not to recap what they just did.

                **Input**: the last 3 hours of activity (screen OCR, transcripts, typing) is already injected above this prompt — read it directly. If the last 3 hours are quiet, or you suspect something was promised on an earlier day, also call:
                  - `mp-query memories --scope events --start "7d ago"` — this week's distilled events (already summarised + tagged)
                  - `mp-query writing --start "7d ago" --q "<keyword>"` — what the user actually typed, more reliable than OCR
                  - `mp-query memories --scope portrait` — long-term portrait: what they care about, who they deal with
                  - `mp-query read --path events/<day>/<file>.md` — the full body of one event

                Use these to **connect** things: a promise made today against something said last week and never done; an email they said they'd reply to; a build left broken. Cross-day, cross-source links are the whole point of this job.

                ## Step 1 — Read the existing todo file

                Read `~/.portrait/cron_jobs/follow-up-reminders/output/todos.md`. If it doesn't exist, start fresh. **This step is mandatory** — step 4 decides whether to notify entirely from the `notified` fields in this file.

                ## Step 2 — Scan for action items

                Scan the injected 3-hour activity for:
                - promises the user made ("I'll send that", "I'll follow up", "I'll get back to you tomorrow")
                - tasks someone assigned to them
                - deadlines mentioned
                - messages they haven't replied to
                - failures (a broken build, a command that errored)

                If the last 3 hours are thin, go further back with `mp-query` (see Input). Pay special attention to **urgent items still open in todos.md**: should this run escalate them, move them forward, or close them?

                If neither the injected context nor `mp-query` turns up any action item, just say "nothing new to follow up on" and stop. Don't update the file. Don't invent anything.

                ## Step 3 — Update the todo file

                Write `~/.portrait/cron_jobs/follow-up-reminders/output/todos.md` as markdown:

                ```markdown
                # Todo List
                Last updated: <ISO timestamp>

                ## Urgent (do today)
                - [ ] Task — source: where / who / when — notified: <ISO timestamp or empty>

                ## This Week
                - [ ] Task — source

                ## Waiting on
                - [ ] Waiting on <person> — when to check back

                ## Completed (last 3 days)
                - [x] Task — done <date>
                ```

                **Rules**:
                - Deduplicate — never list the same task twice ("send Sarah the doc" = "get the doc to Sarah")
                - Mark done when there is evidence: email sent, reply posted, build green, file committed
                - Drop items older than 7 days
                - Never invent an item
                - Every urgent item carries a `notified` field (empty = the user hasn't been told yet)

                ## Step 4 — Notification rules (important: no repeat pings)

                Go through the urgent list you just wrote and pick the subset worth notifying:
                - `notified` is **empty** → first time this urgent item appears → **notify**
                - `notified` is **more than 24 hours old** → they may have forgotten → **notify again**
                - `notified` is **within 24 hours** → **do not notify**, they were just told

                If nothing qualifies, **do not write a `### Notify` block at all** — the system then skips the notification. If something does, append this to the end of your reply:

                ```
                ### Notify
                🔔 Needs follow-up:
                - <most urgent 1>
                - <most urgent 2>
                (N total)
                ```

                Then **set `notified` to the current ISO timestamp on exactly the items you just notified about**, in the same write as step 3. Don't forget this.

                Keep the Notify block to 5 lines or fewer, and keep narration out of it.

                ## ⚠ Anti-patterns

                - Don't stop at screen OCR — leaving `mp-query` unused wastes this job; the cross-day links are its value
                - Don't treat something the user did 5 minutes ago as urgent — that's in progress, not forgotten
                - Don't notify about the same item twice within 24 hours
                - Don't invent a source — "somewhere" is banned; a source must name an app, a person and a time
                ---
                """,
              window: .none),

        .init(emoji: "📋", title: "Day Recap",
              subtitle: "Today's accomplishments grouped by project",
              prompt: """
                Recap my day. First call \
                `mp-query memories --scope events --start today` to read \
                the LLM-distilled events from today (these are higher signal \
                than raw OCR — already grouped + summarized). For long ones \
                you want to quote, follow up with \
                `mp-query read --path events/<day>/<file>.md` for the full \
                body. Group accomplishments by project / folder, highlight \
                what shipped, flag anything unfinished. Cite event titles.
                """,
              window: .today),


        // (08-10 update 删掉 "Folder Suggestions" 这条种子:归档到文件夹已经是
        //  pipeline 自己在做的事,不再需要用户手动点一个快捷方式去问。
        //  老用户的 UserDefaults 里还留着,由 removeRetiredFolderSeed 清一次。)
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
