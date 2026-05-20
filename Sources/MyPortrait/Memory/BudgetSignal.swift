import Foundation

/// LLM 额度 / 配额耗尽信号。三个 LLM processor（EventBuilder / ImpactScorer /
/// PortraitDistiller）共用，让调度器把"撞额度"和"真实失败"分开：
///   - 真实失败  → status=failed，retry_count +1，3 次转 dead_letter。
///   - 撞额度    → status=budget_deferred，retry_count 不变，等额度恢复自动重试。
enum BudgetSignal {

    /// 判断一段 LLM 错误信息是否表示额度 / 配额 / 限流耗尽。
    ///
    /// 只匹配额度类信号（429 / quota / rate limit / billing）。鉴权失败（401
    /// 错误 key）这类是真实失败，不在此列 —— 它不会因为"等一等"就好。
    static func isExhausted(_ message: String) -> Bool {
        let m = message.lowercased()
        let markers = [
            "429",
            "quota",
            "rate limit", "rate_limit", "ratelimit",
            "insufficient_quota",
            "too many requests",
            "usage limit", "usage_limit",
            "billing",
            "exceeded your current",
        ]
        return markers.contains { m.contains($0) }
    }
}

/// 三个 LLM processor 撞额度时统一抛这个。调度器 `catch let _ as BudgetExhaustedError`
/// 据此把当天 / 当次标 `budget_deferred` 而非 `failed`。
struct BudgetExhaustedError: LocalizedError {
    let processor: String   // "EventBuilder" / "ImpactScorer" / "PortraitDistiller"
    let message: String

    var errorDescription: String? {
        "LLM budget exhausted (\(processor)): \(message)"
    }
}
