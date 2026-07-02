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
    /// 分区球(portrait 画布,统一大小;07-02 反馈再缩:27→22)
    static let categoryRadius: Double = 22
    /// folder 球 = f0 + kf·√count,clamp 到 [f0, folderRadiusMax]
    static let folderRadiusBase: Double = 14
    static let folderRadiusScale: Double = 1.4
    static let folderRadiusMax: Double = 36
    /// event 球 = e0 + ke·currentWeight,上限不超过最小 folder 球。
    /// 07-02 反馈:末端球下限降低,上限不变(低 weight 更小更细腻)。
    static let eventRadiusBase: Double = 2.5
    static let eventRadiusScale: Double = 0.9
    static let eventRadiusMax: Double = 14
    /// portrait 小球 = p0 + kp·min(weight, 18);下限降,斜率补偿保上限
    static let portraitRadiusBase: Double = 2.5
    static let portraitRadiusScale: Double = 0.69

    // MARK: 连接强度

    /// 分区球 → 主球:常数
    static let categoryStrength: Double = 20
    /// folder → 主球:自加权平均(Σw²/Σw)之外再加的基数
    static let folderStrengthBase: Double = 10
    /// event → hub:occurrences.count 的截断上限
    static let eventStrengthMax: Double = 15
    /// portrait 小球 → 分区球:weight 线性截断上限(>18 全一样)
    static let portraitStrengthMax: Double = 18

    // MARK: 气泡(07-02 重构定稿:每 hub 的叶子绕它 360° 成圆)

    /// 气泡内叶子的装填密度:π·气泡半径² ≥ hub球面积 + Σ叶面积/此值。
    /// 叶多圆大(1000 叶巨圆)、叶少圆小(10 叶小圆),完全由内容涌现。
    /// 07-02 扁圆反馈:0.55→0.42 再松一档,大家叶群不挤圆更分散。
    static let bubbleFill: Double = 0.42
    /// 气泡半径的额外呼吸边距(世界 pt)
    static let bubblePadding: Double = 4
    /// hub→主球弹簧 rest = 主球半径 + 气泡半径 + 此间隙(气泡贴主球排布)
    static let bubbleGap: Double = 12
    /// 气泡间软碰撞刚度(圆与圆绝不重叠的速度域推开;硬解算兜底)
    static let bubbleCollideStrength: Float = 0.5
    /// 线长档位:最新的叶贴 hub(此比例×最大线长),最旧顶到气泡边缘
    static let bubbleRestFloor: Double = 0.25
    /// 线长抖动幅度(07-02 反馈:均匀排列之上加一点排列随机性,别太
    /// 机械):每叶 ±此比例,由文件路径哈希决定 —— **确定性**,同一份
    /// 数据每次打开布局一致(真随机会破坏会话缓存/可复现性)。
    static let bubbleRestJitter: Double = 0.12

    // MARK: 物理(d3-force 语义;P0 实测 1.9ms/tick@5000,后台线程)

    /// 斥力电荷(负=互斥),分角色(07-02 用户确诊:主球斥力+跨圆叶叶
    /// 斥力把整家叶子压到背面半圆,圈只用一半):
    /// - hub:保持,负责 hub 间松散感
    static let manyBodyStrength: Float = -15
    /// - 主球:大降 —— 球不叠靠主球硬碰撞,电荷只会把叶群推向圆的远端
    static let mainBodyStrength: Float = -4
    /// - 叶:近零 —— 圈内间距归半径感知碰撞力管,电荷大了跨圆互推,
    ///   把彼此边界侧清空(半边圆元凶;-6 时邻家 569 叶的聚合电荷仍
    ///   把 6 叶小家压进 121° 弧)
    static let leafBodyStrength: Float = -2
    /// 家内角向匀布力 v2(07-02 密度偏半边反馈):排序后每叶向两侧角向
    /// 邻居的**中点**回正(左右间隙相等时力归零)—— 局部弛豫链式传导,
    /// 挤的一侧流向疏的一侧,叶群质心回到 hub。全家适用(v1 只推不拉
    /// 且限 40 叶,大家云团仍偏半边:质心偏移实测 34%)。
    static let familySpreadStrength: Float = 0.3
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
    /// 半径感知碰撞力(d3 forceCollide 同款,07-02 物理化):球与球按
    /// 半径之和互相推开 —— "每球清晰可见不重叠"的物理表达。
    /// 点电荷斥力(manyBody)不认半径,这条才是缺的核心力。
    /// 0.7:1.0 会过冲(残余震荡反而多 13% 重叠+更多越墙),实测最优
    static let collideStrength: Float = 0.7
    /// 碰撞附加间隙(世界 pt,让球之间留一线缝)
    static let collidePadding: Float = 1
    /// 每 tick 碰撞解算轮数(d3 默认 1;挤压重时可加,成本 ∝ 轮数)
    static let collideIterations: Int = 3

    // MARK: 交互动画

    /// 神经脉冲沿边传播速度(世界 pt/s;07-02 三次反馈:700 仍偏快,再降)
    static let pulseSpeed: Double = 450
    /// 级联跳数:主球 2 跳,其它 hub 只 1 跳(07-01 反馈:只有主球 bounce 两次)
    static let pulseMaxDepthMain: Int = 2
    static let pulseMaxDepthOther: Int = 1
    /// 脉冲形态 = ||| 三条垂直于连线的细白杠,沿行进方向间隔(屏幕 pt)
    static let pulseTickCount: Int = 3
    static let pulseTickSpacing: Double = 5
    /// 杠长 = 连线的**实际渲染粗细**×此倍数。07-02 反馈定稿:=1,
    /// 杠长与线宽完全贴合(此前 ×3 仍被指出"没有完美贴合")
    static let pulseTickLengthScale: Double = 1
    static let pulseTickStrokeWidth: Double = 1.2
    /// hover 白闪频率(Hz)
    static let hoverBlinkHz: Double = 2.2
    /// hub/主球标签 LOD 淡出(07-01 反馈):zoom ≥ Hi 全显,≤ Lo 消失,间上线性
    static let labelFadeZoomHi: Double = 0.55
    static let labelFadeZoomLo: Double = 0.32
    /// 浮窗:鼠标移出后自动关闭延迟(s)
    static let floatWindowAutoCloseDelay: TimeInterval = 1.0

    // MARK: folder → 主球 连接强度(需求 §4.2)

    /// 自加权平均:Σw²/Σw(高 weight 的 event 话语权大)+ 基数。空 folder = 基数。
    static func folderStrength(memberWeights: [Double]) -> Double {
        let sum = memberWeights.reduce(0, +)
        guard sum > 0 else { return folderStrengthBase }
        let sq = memberWeights.reduce(0) { $0 + $1 * $1 }
        return sq / sum + folderStrengthBase
    }

}
