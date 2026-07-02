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

    /// 完美圆 v2(07-02 二稿):hub **等距**(用户:距离不等很奇怪),
    /// 改为按比例缩放每家的叶距,让所有 fan 外缘仍落同一大圆:
    /// rest' = rest × (outer − hubDist) / 该家最远 rest。
    static let eventOuterRadius: Double = 320
    static let portraitOuterRadius: Double = 240   // 07-02:分区球太远,外圆收小→等距公式值≈100
    static let eventHubDistance: Double = 150
    static let portraitHubDistance: Double = 150
    /// hub 间角向碰撞刚度(07-02 物理化,取代目标角弹簧):相邻 hub 的角向
    /// "圆盘"(半宽 = 楔形份额/2)重叠时切向推开,权重 ∝ 叶数 ——
    /// 大 folder 自然挤开邻居,扇区宽 ∝ 内容**涌现**,碰撞平衡处即边界。
    /// 2.0:需压过大 folder 叶群斥力的扭矩 —— 弱了缺口被压 <80%,
    /// 且大 folder 两侧被叶群推出 ~150% 的空洞(无缝圆被破)。
    static let hubAngularStrength: Float = 2.0
    /// last_occurred → 距离 的对数映射端点(event 画布)
    static let eventLeafDistanceNear: Double = 60
    static let eventLeafDistanceFar: Double = 200
    /// portrait 画布(分区内更紧凑)
    static let portraitLeafDistanceNear: Double = 40
    static let portraitLeafDistanceFar: Double = 140
    /// 时间窗:超过这么多天全部趴在 Far 外圈
    static let timeWindowDays: Double = 30

    // MARK: 物理(d3-force 语义;P0 实测 1.9ms/tick@5000,后台线程)

    /// 斥力强度(负=互斥)。07-02 物理化减半:球距改由半径感知碰撞力管,
    /// 点电荷斥力只提供松散感 —— 太强时大 folder 的叶群集体扭矩会把
    /// 邻居 hub 推出碰撞盘接触距离,环上出现大空洞(无缝圆被破)。
    static let manyBodyStrength: Float = -15
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
    /// 领地墙力度(07-02 定稿:动态领地分割 —— 相邻 hub 极角间隙按份额
    /// 加权定边界,叶子原点极角越界 → ×此系数×alpha 切向回正)。
    /// 0.8:要打得过全力碰撞力的外推(0.3 时 12% 叶被挤过界)。
    static let sectorStrength: Float = 0.8
    /// 花瓣内聚力:叶子向自家 hub 轴线的弱角向弹簧(领地内全程存在,
    /// 不只在边界)。稀疏 folder 靠它收拢成瓣不散开;密集 folder 碰撞力
    /// 占优照样铺满楔形 —— 花瓣形态的两种密度自适应。
    static let sectorCenterStrength: Float = 0.08
    /// 扇区间排斥:**只在边界起效**(07-02 三稿:排斥泡太大会造成扇区间
    /// 巨大空隙"护城河");半径只罩 hub 近旁,防别家叶贴脸。
    static let sectorRepelStrength: Float = 0.35
    static let sectorRepelRadius: Float = 80
    /// 叶距硬上限:dist(leaf, hub) ≤ rest × 此系数 —— 完美圆的外缘保证
    ///(否则各种持续力把叶子挤出 rest,fan 半径失控)。
    static let leafMaxStretch: Float = 1.2
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
