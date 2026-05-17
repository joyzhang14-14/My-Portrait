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
    var created: Date
    var impact: Double                  // 1-5; Double so LLM can micro-adjust
    var impactSource: String            // "baseline_duration" / "llm:gpt-5.4" / "user_override"
    var weight: Double                  // computed, ≥0
    var accessCount: Int
    var accessHistory: [Date]           // most recent N=10, oldest → newest
    var occurrences: [Date]             // all occurrence timestamps
    var source: String?
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
        firstOccurrence: Date? = nil
    ) {
        let stamp = firstOccurrence ?? created
        self.created = created
        self.impact = impact
        self.impactSource = "baseline_duration"
        self.weight = 0                  // weight pass fills this in
        self.accessCount = 0
        self.accessHistory = []
        self.occurrences = [stamp]
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
        impactSource: String,
        weight: Double,
        accessCount: Int,
        accessHistory: [Date],
        occurrences: [Date],
        source: String?,
        tags: [String],
        supersededBy: String?,
        pinned: Bool,
        archivedAt: Date?,
        body: String
    ) {
        self.created = created
        self.impact = impact
        self.impactSource = impactSource
        self.weight = weight
        self.accessCount = accessCount
        self.accessHistory = accessHistory
        self.occurrences = occurrences
        self.source = source
        self.tags = tags
        self.supersededBy = supersededBy
        self.pinned = pinned
        self.archivedAt = archivedAt
        self.body = body
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

    /// Append an access timestamp (called at retrieval time) — trims to cap.
    mutating func recordAccess(at when: Date = Date()) {
        accessCount += 1
        accessHistory.append(when)
        if accessHistory.count > Self.accessHistoryCap {
            accessHistory.removeFirst(accessHistory.count - Self.accessHistoryCap)
        }
    }

    /// Append an occurrence (Tier 1 merge / repeat detection).
    mutating func recordOccurrence(at when: Date) {
        occurrences.append(when)
    }
}
