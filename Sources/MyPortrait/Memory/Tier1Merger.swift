import Foundation

/// Cheapest-tier dedup per design doc §6.4.
///
/// Rule: consecutive raw events with same `appName + windowName` and
/// gap < `mergeWindow` collapse into one event. The merged event keeps
/// its first timestamp as `firstSeen` and appends every other timestamp
/// (including app-switch interruptions and returns) to `occurrences[]`.
///
/// Purpose: 70% of captured frames are "user switched to messaging, then back"
/// noise. Tier 1 squashes that at the capture layer before any LLM runs.
enum Tier1Merger {
    /// What we feed in — minimal columns from the screenpipe `frames` table.
    struct RawEvent {
        let timestamp: Date
        let appName: String
        let windowName: String
        let browserURL: String?
        let frameId: Int64
    }

    /// What comes out — one "session" of contiguous activity in the same app.
    struct MergedEvent {
        var appName: String
        var windowName: String
        var browserURL: String?
        var firstSeen: Date
        var lastSeen: Date
        var occurrences: [Date]            // every observed timestamp
        var sourceFrameIds: [Int64]        // for traceback
    }

    /// Default 5-minute merge window (design doc §6.4).
    static let defaultMergeWindow: TimeInterval = 5 * 60

    static func merge(
        _ events: [RawEvent],
        within window: TimeInterval = defaultMergeWindow
    ) -> [MergedEvent] {
        guard !events.isEmpty else { return [] }

        // Sort by timestamp to make the merge logic deterministic.
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var result: [MergedEvent] = []
        var current = makeMerged(from: sorted[0])

        for event in sorted.dropFirst() {
            let sameTarget = event.appName == current.appName
                && event.windowName == current.windowName
            let gap = event.timestamp.timeIntervalSince(current.lastSeen)

            if sameTarget && gap < window {
                // Extend current session.
                current.lastSeen = event.timestamp
                current.occurrences.append(event.timestamp)
                current.sourceFrameIds.append(event.frameId)
                // Update URL if we now have one and didn't before, or it changed.
                if let u = event.browserURL, !u.isEmpty {
                    current.browserURL = u
                }
            } else {
                // Different target OR same target but gap too large → new session.
                result.append(current)
                current = makeMerged(from: event)
            }
        }
        result.append(current)
        return result
    }

    private static func makeMerged(from e: RawEvent) -> MergedEvent {
        MergedEvent(
            appName: e.appName,
            windowName: e.windowName,
            browserURL: e.browserURL,
            firstSeen: e.timestamp,
            lastSeen: e.timestamp,
            occurrences: [e.timestamp],
            sourceFrameIds: [e.frameId]
        )
    }
}
