import Foundation

/// 边的渲染方式。
enum GraphEdgeStyle {
    /// 等宽细线(Obsidian 式),全部边一条 Path 一次 stroke
    case line
    /// 锥形橡皮筋(两端粗中间细),逐边填充
    case taperedFill
}

/// 图谱视图的全部可调常数(旋钮)集中在这一处。
/// 需求文档:~/Desktop/Obsidian/Memory图谱视图·需求与实现方案.md §8
enum GraphConstants {

    // MARK: 连接线

    /// 边的画法。2026-07-01 反馈:锥形在实机上卡且视觉不明显,先用纯线;
    /// taperedFill 代码保留,改这一行即可切回。
    static let edgeStyle: GraphEdgeStyle = .line
    /// 纯线模式线宽(屏幕 pt,不随 zoom —— Obsidian 式等粗)
    static let lineEdgeWidth: Double = 1.3

    // MARK: 连接线(橡皮筋:两端粗中间细,taperedFill 模式用)

    /// 端点半宽 = 所连球的半径(用户 2026-07-01 定稿:神经末端粗度=球半径)。
    /// hub↔主球的边上限 15;**末端球的边整条上限 7**(07-01 二次反馈:
    /// hub 连接保持现状,末端连接减细)。
    static let edgeEndWidthMax: Double = 15
    static let leafEdgeEndWidthMax: Double = 7
    /// 腰部半宽 = 两端较细一侧 × 此比例(用户要求「中间细的地方更细一点」)
    static let waistRatio: Double = 0.18

    /// 球半径 → 端点半宽(hub↔主球的边)。
    static func edgeEndWidth(ballRadius: Double) -> Double {
        min(ballRadius, edgeEndWidthMax)
    }

    /// 球半径 → 端点半宽(连着末端球的边,整条上限 7)。
    static func leafEdgeEndWidth(ballRadius: Double) -> Double {
        min(ballRadius, leafEdgeEndWidthMax)
    }

    // MARK: 球半径(世界单位)

    static let mainRadius: Double = 44
    /// 分区球(portrait 画布,统一大小;07-01 反馈再减 10%:30→27)
    static let categoryRadius: Double = 27
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

    /// folder 等距环 / 分区等距环(2026-07-01 用户反馈:folder 环 300→100,
    /// 分区环 280→140,两类 hub 都贴近主球)
    static let folderRingDistance: Double = 100
    static let categoryRingDistance: Double = 140
    /// last_occurred → 距离 的对数映射端点(event 画布)
    static let eventLeafDistanceNear: Double = 60
    static let eventLeafDistanceFar: Double = 200
    /// portrait 画布(分区内更紧凑)
    static let portraitLeafDistanceNear: Double = 40
    static let portraitLeafDistanceFar: Double = 140
    /// 时间窗:超过这么多天全部趴在 Far 外圈
    static let timeWindowDays: Double = 30

    // MARK: 物理(d3-force 语义;P0 实测 1.9ms/tick@5000,后台线程)

    /// 斥力强度(负=互斥)。「每个点分明」靠它:相邻球实时互相推开。
    static let manyBodyStrength: Float = -30
    /// Barnes-Hut 精度 θ²(d3 默认 θ=0.9;收紧到 0.5 成本翻倍,别动)
    static let bhTheta2: Float = 0.81
    /// 斥力最小距离²(防重叠点无穷大力)
    static let bhDistanceMin2: Float = 1
    /// 冷却:每 tick alpha += (target − alpha) × decay;< alphaMin 且 target=0 → 休眠
    static let alphaDecay: Float = 0.0228
    static let alphaMin: Float = 0.001
    /// 速度阻尼(每 tick 乘;= 1 − d3 默认 velocityDecay 0.4)
    static let velocityDamping: Float = 0.6
    /// 向心力强度(把孤岛拉回原点方向)
    static let centerStrength: Float = 0.05
    /// 拖拽/交互 reheat 的 alphaTarget(d3 惯例 0.3)
    static let dragAlphaTarget: Float = 0.3
    /// 物理线程定步频率(60 = d3/Obsidian 的 rAF 同款;120 视觉无差但
    /// 背景 CPU 翻倍,07-01 拖拽卡顿优化降回 60)
    static let physicsHz: Double = 60
    /// 开场炸开:初始位置挤在中心这个半径内
    static let explosionRadius: Float = 30
    /// 主球碰撞硬约束的额外间隙:任何球不得进入 主球半径+自身半径+此值
    ///(斥力是点电荷模型不认半径,没这条低 weight 小球会叠在主球上)
    static let mainCollisionPadding: Float = 4
    /// hub→主球弹簧刚度 override(d3 默认=1/度数,folder 度数几百 → 弹簧
    /// 太软被斥力推远;定为 1.0 让 folder/分区贴住等距环)
    static let hubSpringStrength: Double = 1.0
    /// 180° 扇区软阻力(07-01 反馈):folder/分区的末端球须待在 hub 背向
    /// 主球的半圆里,越界深度×此系数×alpha 的力推回。不是硬墙。
    static let sectorStrength: Float = 0.15
    /// 扇区间排斥(07-01 反馈):末端球被**别家 hub** 近距推开,相邻扇形
    /// 不互相渗透。线性衰减,radius 外无力。
    static let sectorRepelStrength: Float = 0.6
    static let sectorRepelRadius: Float = 200

    // MARK: 交互动画

    /// 神经脉冲沿边传播速度(世界 pt/s;07-01 二次反馈:1400 太快,减半)
    static let pulseSpeed: Double = 700
    /// 级联跳数:主球 2 跳,其它 hub 只 1 跳(07-01 反馈:只有主球 bounce 两次)
    static let pulseMaxDepthMain: Int = 2
    static let pulseMaxDepthOther: Int = 1
    /// 脉冲形态 = ||| 三条垂直于连线的细白杠,沿行进方向间隔(屏幕 pt)
    static let pulseTickCount: Int = 3
    static let pulseTickSpacing: Double = 5
    /// 杠长 = 连线的**实际渲染粗细**×此倍数(07-01 二次反馈:必须跟画出来的
    /// 线同量级,不能用锥形概念宽度 —— 线改细后那个超标太多)
    static let pulseTickLengthScale: Double = 3
    static let pulseTickStrokeWidth: Double = 1.2
    /// hover 白闪频率(Hz)
    static let hoverBlinkHz: Double = 2.2
    /// hub/主球标签 LOD 淡出(07-01 反馈):zoom ≥ Hi 全显,≤ Lo 消失,间上线性
    static let labelFadeZoomHi: Double = 0.55
    static let labelFadeZoomLo: Double = 0.32
    /// 浮窗:鼠标移出后自动关闭延迟(s)
    static let floatWindowAutoCloseDelay: TimeInterval = 1.0

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

}
