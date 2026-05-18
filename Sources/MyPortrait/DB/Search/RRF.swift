import Foundation

/// Reciprocal Rank Fusion — 把多个排序列表融成一个综合排序。
///
/// 公式：`RRF(d) = Σ 1 / (k + rank_i(d))`，其中 `rank_i(d)` 是文档 d 在第 i 个
/// 列表中的位次（1-based）。k 默认 60（业界经验值，TREC paper 推荐）。
///
/// 直觉：每个列表给文档一个倒数排名分数（越靠前分越高），然后所有列表的分数相加。
/// 既不要求两个列表分数可比（FTS bm25 和 cosine 相似度本来就不一个量级），又不
/// 受任一列表的极值影响。Hybrid 搜索的标准做法。
enum RRF {

    /// 融合 N 个 (id, ...) 排序列表，返回按 RRF 分数倒序的 id + score 列表。
    /// `rankings` 每个子列表是已经按相关度排好序的 id 数组。
    /// `k` 越大越平滑（>= 1）。
    static func fuse(_ rankings: [[Int64]], k: Double = 60) -> [(id: Int64, score: Double)] {
        var totals: [Int64: Double] = [:]
        for list in rankings {
            for (idx, id) in list.enumerated() {
                let rank = Double(idx + 1)
                totals[id, default: 0] += 1.0 / (k + rank)
            }
        }
        return totals
            .map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
    }
}
