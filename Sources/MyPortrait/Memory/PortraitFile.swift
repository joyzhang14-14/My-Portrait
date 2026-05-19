import Foundation

/// Swift representation of one portrait Markdown file.
///
/// On disk:
///   ---
///   created: 2026-05-17
///   impact: 4
///   weight: 3.6
///   access_count: 7
///   access_history: [2026-05-09, 2026-05-12, 2026-05-17]
///   occurrences: [2026-05-17T14:20:00Z]
///   source: meeting_2026-05-17_v2_review
///   tags: [产品, 决策]
///   superseded_by: null
///   pinned: false
///   archived_at: null
///   ---
///
///   # Title
///
///   Body markdown...
///
/// Schema matches design doc §6.1. `body` is everything after the closing `---`.
struct PortraitFile: Equatable {
    /// Valid range for both `impact` and `rawImpact`. All writers (LLM
    /// scoring, budget rebalance, future JOIN micro-bumps) MUST clamp
    /// before assigning — see `clampImpact`. Schema-level invariant.
    static let impactRange: ClosedRange<Double> = 1.0...5.0

    /// Use at every write site instead of raw assignment.
    static func clampImpact(_ v: Double) -> Double {
        min(impactRange.upperBound, max(impactRange.lowerBound, v))
    }

    var created: Date
    var impact: Double                  // FINAL impact used by WeightCalculator.
                                        // Initially equals rawImpact; the
                                        // MemoryBudget weekly pass may scale
                                        // it down when the week is overloaded.
    var rawImpact: Double               // LLM's original score, never modified
                                        // by the budget pass. Source of truth
                                        // for any future re-rebalance.
    var rebalanceCount: Int             // # of times the budget pass touched
                                        // this file. Capped at 5 (then frozen).
    var impactSource: String            // "baseline_duration" / "llm:gpt-5.4" / "user_override"
    var weight: Double                  // computed, ≥0
    var accessCount: Int
    var accessHistory: [Date]           // most recent N=10, oldest → newest
    var occurrences: [Date]             // **per-day** deduped occurrence dates.
                                        // One date per day on which the event
                                        // happened, regardless of how many times
                                        // within that day. Used by the spacing
                                        // effect: log(1 + count) gives the
                                        // "how many distinct days" boost.
    var eventTitle: String              // short human-readable event name (LLM)
    var eventSummary: String            // one-paragraph description (LLM)
    var eventType: String               // "experience" / "emotion" (LLM)
    var portraitFacets: [EventBuilder.PortraitFacet]
                                        // LLM-attached portrait signals
                                        // (most events have []; only stable
                                        // identity signals get a facet)
    var category: String                // DEPRECATED. Kept for backward-compat
                                        // file reads only. Distiller no longer
                                        // routes by this field.
    var memberFrameIds: [Int64]         // timeline frame IDs that contributed
                                        // to this event (across days + apps)
    var source: String?                 // backward-compat origin reference
    var tags: [String]
    var supersededBy: String?           // relative path under portrait/
    var pinned: Bool
    var archivedAt: Date?
    var body: String                    // raw markdown after frontmatter

    /// Max entries we keep in `accessHistory` (older are dropped).
    static let accessHistoryCap = 10

    /// Initialiser for a brand-new file (sensible defaults).
    init(
        created: Date = Date(),
        impact: Double,
        body: String,
        source: String? = nil,
        tags: [String] = [],
        firstOccurrence: Date? = nil,
        eventTitle: String = "",
        eventSummary: String = "",
        eventType: String = "experience",
        portraitFacets: [EventBuilder.PortraitFacet] = [],
        category: String = "",
        memberFrameIds: [Int64] = []
    ) {
        let stamp = Self.truncateToDay(firstOccurrence ?? created)
        self.created = created
        self.impact = impact
        self.rawImpact = impact
        self.rebalanceCount = 0
        self.impactSource = "baseline_duration"
        self.weight = 0                  // weight pass fills this in
        self.accessCount = 0
        self.accessHistory = []
        self.occurrences = [stamp]
        self.eventTitle = eventTitle
        self.eventSummary = eventSummary
        self.eventType = eventType
        self.portraitFacets = portraitFacets
        self.category = category
        self.memberFrameIds = memberFrameIds
        self.source = source
        self.tags = tags
        self.supersededBy = nil
        self.pinned = false
        self.archivedAt = nil
        self.body = body
    }

    /// Designated init used by the parser — every field explicit.
    init(
        created: Date,
        impact: Double,
        rawImpact: Double,
        rebalanceCount: Int,
        impactSource: String,
        weight: Double,
        accessCount: Int,
        accessHistory: [Date],
        occurrences: [Date],
        eventTitle: String,
        eventSummary: String,
        eventType: String,
        portraitFacets: [EventBuilder.PortraitFacet],
        category: String,
        memberFrameIds: [Int64],
        source: String?,
        tags: [String],
        supersededBy: String?,
        pinned: Bool,
        archivedAt: Date?,
        body: String
    ) {
        self.created = created
        self.impact = impact
        self.rawImpact = rawImpact
        self.rebalanceCount = rebalanceCount
        self.impactSource = impactSource
        self.weight = weight
        self.accessCount = accessCount
        self.accessHistory = accessHistory
        // Defensive: collapse any datetime occurrences to startOfDay so
        // legacy files migrate transparently.
        self.occurrences = occurrences.map(Self.truncateToDay).uniqued()
        self.eventTitle = eventTitle
        self.eventSummary = eventSummary
        self.eventType = eventType
        self.portraitFacets = portraitFacets
        self.category = category
        self.memberFrameIds = memberFrameIds
        self.source = source
        self.tags = tags
        self.supersededBy = supersededBy
        self.pinned = pinned
        self.archivedAt = archivedAt
        self.body = body
    }

    /// Truncate any timestamp to the start of its UTC calendar day. Used to
    /// enforce the per-day occurrence semantic.
    static func truncateToDay(_ d: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.startOfDay(for: d)
    }

    // MARK: - Derived helpers

    /// Most recent access — for decay calculations.
    var lastAccessedAt: Date? { accessHistory.last }

    /// Whole-day count since last access (≥0). If never accessed, count from
    /// `created` instead so brand-new files don't get treated as ancient.
    func daysSinceLastAccess(now: Date = Date()) -> Int {
        let reference = lastAccessedAt ?? created
        let secs = now.timeIntervalSince(reference)
        return max(0, Int(secs / 86_400))
    }

    /// Window inside which repeat accesses don't double-count. Stops the
    /// user from inflating their own access_count by clicking back and
    /// forth across a few entries in MemoriesView.
    static let accessDedupWindow: TimeInterval = 5 * 60   // 5 minutes

    /// Append an access timestamp (called at retrieval time). No-ops if the
    /// last access landed within `accessDedupWindow` seconds — same
    /// retrieval session shouldn't keep boosting the count.
    @discardableResult
    mutating func recordAccess(at when: Date = Date()) -> Bool {
        if let last = accessHistory.last,
           when.timeIntervalSince(last) < Self.accessDedupWindow {
            return false
        }
        accessCount += 1
        accessHistory.append(when)
        if accessHistory.count > Self.accessHistoryCap {
            accessHistory.removeFirst(accessHistory.count - Self.accessHistoryCap)
        }
        return true
    }

    /// Append an occurrence date (Tier 1 merge / repeat detection). Idempotent
    /// per day — calling twice on the same day is a no-op.
    mutating func recordOccurrence(on when: Date) {
        let day = Self.truncateToDay(when)
        if !occurrences.contains(day) {
            occurrences.append(day)
        }
    }
}

/// Tiny order-preserving dedup helper.
private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        var out: [Element] = []
        out.reserveCapacity(count)
        for e in self where seen.insert(e).inserted {
            out.append(e)
        }
        return out
    }
}
