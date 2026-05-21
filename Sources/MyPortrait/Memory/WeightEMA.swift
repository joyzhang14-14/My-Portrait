import Foundation

/// Phase 3 的 portrait weight 模型：指数移动平均（EMA）。
///
/// 取代旧的 event-based `WeightCalculator` 公式。语义变化：
///   - 存储的 `PortraitFile.weight` = 上次 `lastModified` 时刻的 EMA 值。
///   - 读取时按"距 lastModified 的天数"做 lazy 半衰期衰减得到当前值。
///   - 每次合并 / 改写：先把旧值衰减到今天，再 +1。
///
/// 半衰期 `halfLifeDays`：经过这么多天，weight 衰减到一半。可配
/// （MemoryConfig.weightHalfLifeDays，默认 180）。
struct WeightEMA {
    let halfLifeDays: Double

    /// Lazy 衰减：给定存储值与"距上次修改的天数"，算当前 weight。
    func currentWeight(stored: Double, daysSinceModified: Double) -> Double {
        guard halfLifeDays > 0 else { return stored }
        let decay = exp(-log(2.0) * max(0, daysSinceModified) / halfLifeDays)
        return stored * decay
    }

    /// 合并时：把旧值衰减到今天，再 +1。
    func afterMerge(stored: Double, daysSinceModified: Double) -> Double {
        currentWeight(stored: stored, daysSinceModified: daysSinceModified) + 1.0
    }
}
