import Foundation

/// Pure-function weight model per design doc §6.2:
///
///   weight = impact × power_decay(days_since_last_occurrence) × log(1 + occurrence_days)
///
/// Three terms:
///   - `impact`            (1-5, Double, may be micro-adjusted by LLM)
///   - `power_decay(d)`    = (1 + d) ^ -α     — power law, not exponential
///   - `freq_boost(n)`     = log(1 + n)        — n = number of distinct days
///                                              the event occurred (spacing
///                                              effect: recurring events stick)
///
/// All inputs are taken from a PortraitFile; no I/O happens here.
enum WeightCalculator {
    /// Tunable parameters — user-configurable in the long run.
    struct Params {
        /// Power-law exponent. Bigger α → faster forgetting.
        /// 0.3 gives weight ≈ 0.5 after ~10 days, ≈ 0.25 after ~100 days,
        /// which matches the rough "month feels like ages but not gone" feel
        /// the cognitive-science literature describes.
        var alpha: Double = 0.3

        /// Floor — never returns a value below this. Keeps log() honest and
        /// guarantees the archive rule `weight < 0.05` is reachable.
        var minWeight: Double = 0

        static let `default` = Params()

        @MainActor
        static var fromConfig: Params {
            let m = ConfigStore.shared.current.memory
            return Params(alpha: m.alpha, minWeight: m.minWeight)
        }
    }

    /// Compute weight for a single PortraitFile. Reference clock can be
    /// injected for testing.
    static func weight(for file: PortraitFile,
                       now: Date = Date(),
                       params: Params = .default) -> Double {
        let days = Double(file.daysSinceLastOccurrence(now: now))
        let decay = pow(1.0 + days, -params.alpha)
        let freq = log(1.0 + Double(file.occurrences.count))
        // log(1) == 0, so a single-day event would yield weight 0 if we
        // multiplied straight. Use (1 + log()) so frequency only BOOSTS,
        // never zeroes out the base impact×decay signal.
        let raw = file.impact * decay * (1.0 + freq)
        return max(params.minWeight, raw)
    }

    /// Recompute weight on a file in-place. Returns the new value for
    /// convenience.
    @discardableResult
    static func recompute(_ file: inout PortraitFile,
                          now: Date = Date(),
                          params: Params = .default) -> Double {
        let w = weight(for: file, now: now, params: params)
        file.weight = w
        return w
    }
}
