import Foundation

/// 图谱视图的全部可调常数(旋钮)集中在这一处。
/// 需求文档:~/Desktop/Obsidian/Memory图谱视图·需求与实现方案.md §8
enum GraphConstants {

    // MARK: 连接线(橡皮筋:两端粗中间细)

    /// 连接强度 → 端点半宽 系数
    static let widthScale: Double = 0.35
    /// 端点半宽下限 / 上限(世界单位 pt)
    static let widthMin: Double = 0.8
    static let widthMax: Double = 7.0
    /// 腰部半宽 = 端点半宽均值 × 此比例
    static let waistRatio: Double = 0.30

    // MARK: 球半径(世界单位)

    static let mainRadius: Double = 44
    /// 分区球(portrait 画布,统一大小)
    static let categoryRadius: Double = 30
    /// folder 球 = f0 + kf·√count,clamp 到 [f0, folderRadiusMax]
    static let folderRadiusBase: Double = 14
    static let folderRadiusScale: Double = 1.4
    static let folderRadiusMax: Double = 36
    /// event 球 = e0 + ke·currentWeight,上限不超过最小 folder 球
    static let eventRadiusBase: Double = 4
    static let eventRadiusScale: Double = 0.9
    static let eventRadiusMax: Double = 14
    /// portrait 小球 = p0 + kp·min(weight, 18)
    static let portraitRadiusBase: Double = 5
    static let portraitRadiusScale: Double = 0.55

    // MARK: 连接强度

    /// 分区球 → 主球:常数
    static let categoryStrength: Double = 20
    /// folder → 主球:自加权平均(Σw²/Σw)之外再加的基数
    static let folderStrengthBase: Double = 10
    /// event → hub:occurrences.count 的截断上限
    static let eventStrengthMax: Double = 15
    /// portrait 小球 → 分区球:weight 线性截断上限(>18 全一样)
    static let portraitStrengthMax: Double = 18

    // MARK: 距离(弹簧自然长度,世界单位)

    /// folder 等距环 / 分区等距环
    static let folderRingDistance: Double = 300
    static let categoryRingDistance: Double = 280
    /// last_occurred → 距离 的对数映射端点(event 画布)
    static let eventLeafDistanceNear: Double = 60
    static let eventLeafDistanceFar: Double = 200
    /// portrait 画布(分区内更紧凑)
    static let portraitLeafDistanceNear: Double = 40
    static let portraitLeafDistanceFar: Double = 140
    /// 时间窗:超过这么多天全部趴在 Far 外圈
    static let timeWindowDays: Double = 30

    // MARK: last_occurred → 距离 映射(两画布共用公式)

    /// D = near + (far−near) × ln(1 + min(d, window)) / ln(1 + window)
    /// 对数:越近变化越平缓,相邻一两天肉眼不可辨(需求 §4.4)。
    static func leafDistance(daysAgo: Double, near: Double, far: Double) -> Double {
        let d = max(0, min(daysAgo, timeWindowDays))
        return near + (far - near) * log(1 + d) / log(1 + timeWindowDays)
    }

    // MARK: folder → 主球 连接强度(需求 §4.2)

    /// 自加权平均:Σw²/Σw(高 weight 的 event 话语权大)+ 基数。空 folder = 基数。
    static func folderStrength(memberWeights: [Double]) -> Double {
        let sum = memberWeights.reduce(0, +)
        guard sum > 0 else { return folderStrengthBase }
        let sq = memberWeights.reduce(0) { $0 + $1 * $1 }
        return sq / sum + folderStrengthBase
    }

    /// 连接强度 → 端点半宽
    static func edgeWidth(strength: Double) -> Double {
        min(max(strength * widthScale, widthMin), widthMax)
    }
}
