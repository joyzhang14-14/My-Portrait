import Foundation

/// Swift representation of one portrait Markdown file.
///
/// On disk:
///   ---
///   created: 2026-05-17
///   impact: 4
///   weight: 3.6
///   occurrences: [2026-05-09, 2026-05-17]
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
    /// **Event-only**：LLM 评出的 impact（1–5）。portrait 文件不再持有 impact
    /// —— 语义上 impact 是事件强度，画像维度不依赖。portrait 文件读这个字段
    /// 永远 nil，序列化时整行 skip。
    var impact: Double?
    var rawImpact: Double               // LLM's original score, never modified
                                        // by the budget pass. Source of truth
                                        // for any future re-rebalance.
    var rebalanceCount: Int             // # of times the budget pass touched
                                        // this file. Capped at 5 (then frozen).
    var impactSource: String            // "unscored" / "llm:gpt-5.4" / "user_override"
    var weight: Double                  // computed, ≥0
    var occurrences: [Date]             // **per-day** deduped occurrence dates.
                                        // One date per day on which the event
                                        // happened, regardless of how many times
                                        // within that day. Drives both decay
                                        // (days since the last one) and the
                                        // spacing-effect boost: log(1 + count).
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
    var distilledInto: [String]         // portrait slugs this event has already
                                        // been distilled into — set by the
                                        // distiller, lets later runs skip an
                                        // already-consumed event + supports
                                        // provenance. Empty for un-distilled.
    var source: String?                 // backward-compat origin reference
    var tags: [String]
    var supersededBy: String?           // relative path under portrait/
    var pinned: Bool
    var archivedAt: Date?

    // Phase 3 — EMA weight + personality concept fields. Uniform across all
    // PortraitFile uses; non-personality files just leave primaryLabel nil
    // and aliases [].
    var mergeCount: Int                 // # of merges/rewrites into this file.
                                        // 1 for a brand-new file.
    var primaryLabel: String?           // personality concept's single-noun
                                        // tag label (nil for non-personality)
    var aliases: [String]               // synonym tags folded into this concept
    var lastModified: Date              // last body change — EMA decay anchor
    var evidenceEventIds: [String]      // personality concept: accumulated
                                        // evidence event slugs across days,
                                        // capped at 50. [] for non-personality.

    var body: String                    // raw markdown after frontmatter

    /// Initialiser for a brand-new file (sensible defaults).
    /// `impact: nil` 用于 portrait 文件（不持有 impact）；event 文件必传值。
    init(
        created: Date = Date(),
        impact: Double? = nil,
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
        // raw_impact 跟 impact 同源；portrait（impact=nil）落 0 作残留可接受值。
        self.rawImpact = impact ?? 0
        self.rebalanceCount = 0
        self.impactSource = "unscored"
        self.weight = 0                  // weight pass fills this in
        self.occurrences = [stamp]
        self.eventTitle = eventTitle
        self.eventSummary = eventSummary
        self.eventType = eventType
        self.portraitFacets = portraitFacets
        self.category = category
        self.memberFrameIds = memberFrameIds
        self.distilledInto = []          // a brand-new event is un-distilled
        self.source = source
        self.tags = tags
        self.supersededBy = nil
        self.pinned = false
        self.archivedAt = nil
        self.mergeCount = 1
        self.primaryLabel = nil
        self.aliases = []
        self.lastModified = created
        self.evidenceEventIds = []
        self.body = body
    }

    /// Designated init used by the parser — every field explicit.
    init(
        created: Date,
        impact: Double?,
        rawImpact: Double,
        rebalanceCount: Int,
        impactSource: String,
        weight: Double,
        occurrences: [Date],
        eventTitle: String,
        eventSummary: String,
        eventType: String,
        portraitFacets: [EventBuilder.PortraitFacet],
        category: String,
        memberFrameIds: [Int64],
        distilledInto: [String] = [],
        source: String?,
        tags: [String],
        supersededBy: String?,
        pinned: Bool,
        archivedAt: Date?,
        mergeCount: Int = 1,
        primaryLabel: String? = nil,
        aliases: [String] = [],
        lastModified: Date? = nil,
        evidenceEventIds: [String] = [],
        body: String
    ) {
        self.created = created
        self.impact = impact
        self.rawImpact = rawImpact
        self.rebalanceCount = rebalanceCount
        self.impactSource = impactSource
        self.weight = weight
        // Defensive: collapse any datetime occurrences to startOfDay so
        // legacy files migrate transparently.
        self.occurrences = occurrences.map(Self.truncateToDay).uniqued()
        self.eventTitle = eventTitle
        self.eventSummary = eventSummary
        self.eventType = eventType
        self.portraitFacets = portraitFacets
        self.category = category
        self.memberFrameIds = memberFrameIds
        self.distilledInto = distilledInto
        self.source = source
        self.tags = tags
        self.supersededBy = supersededBy
        self.pinned = pinned
        self.archivedAt = archivedAt
        self.mergeCount = mergeCount
        self.primaryLabel = primaryLabel
        self.aliases = aliases
        self.lastModified = lastModified ?? created
        self.evidenceEventIds = evidenceEventIds
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

    /// Most recent day this event occurred — for decay calculations.
    var lastOccurrence: Date? { occurrences.max() }

    /// Whole-day count since the last occurrence (≥0). Falls back to
    /// `created` if `occurrences` is somehow empty.
    func daysSinceLastOccurrence(now: Date = Date()) -> Int {
        let reference = lastOccurrence ?? created
        let secs = now.timeIntervalSince(reference)
        return max(0, Int(secs / 86_400))
    }

    /// 距 `lastModified` 的天数（分数）—— 给 EMA lazy 衰减用。
    /// 跟 `daysSinceLastOccurrence` 不同：那是事件粒度的整数日；EMA 是连续
    /// 衰减，需要分数 days 才能反映"修改后几小时也有微小衰减"。
    func daysSinceModified(now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(lastModified) / 86_400)
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
