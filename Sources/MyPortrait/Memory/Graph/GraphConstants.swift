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
    /// hub↔主球的边上限(07-02 反馈:15 太粗,降 10;07-03 再降 7);
    /// **末端球的边整条上限 7**(07-01 二次反馈:末端连接减细)。
    static let edgeEndWidthMax: Double = 7
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
    /// 07-02 反馈:上下限双降(14/36 → 10/28)
    static let folderRadiusBase: Double = 10
    static let folderRadiusScale: Double = 1.4
    static let folderRadiusMax: Double = 28
    /// event 球 = clamp(e0 + ke·currentWeight, min, max),上限不超过最小
    /// folder 球。07-02 反馈:末端球下限两连降(4→2.5→1.5),上限不变。
    /// 07-03 用户:"大部分球一样大,不好判断重要性" —— 实测 968 事件里
    /// 气泡内(w≥1.5)89% 挤在 w=1.5~2.5,旧斜率 0.9 这段半径只差 0.9pt。
    /// 斜率 0.9→1.7→**2.4**、基数 1.5→0.9→**0.2**(用户两次加码"更分明"):
    /// 主力段 w=1.5~2.5 半径 3.8→6.2,面积差 1.7x→2.2x→2.7x,相邻半档
    /// 差 1.2pt;w≥5.75 封顶。下限 1.5 保底(最小陨石不比原来小,不会
    /// 看不见/点不中;w<0.55 的陨石齐底,层次由陨石带三层圈表达)
    static let eventRadiusBase: Double = 0.2
    static let eventRadiusScale: Double = 2.4
    static let eventRadiusMin: Double = 1.5
    static let eventRadiusMax: Double = 14
    /// portrait 小球 = p0 + kp·min(weight, 18);下限降,斜率补偿保上限
    static let portraitRadiusBase: Double = 2.5
    static let portraitRadiusScale: Double = 0.69

    // MARK: 连接强度

    /// 分区球 → 主球:常数
    static let categoryStrength: Double = 20
    /// folder → 主球:自加权平均(Σw²/Σw)之外再加的基数(07-02:10→5)
    static let folderStrengthBase: Double = 5
    /// event → hub:occurrences.count 的截断上限
    static let eventStrengthMax: Double = 15
    /// portrait 小球 → 分区球:weight 线性截断上限(>18 全一样)
    static let portraitStrengthMax: Double = 18

    // MARK: 气泡(07-02 重构定稿:每 hub 的叶子绕它 360° 成圆)

    /// 气泡内叶子的装填密度:π·气泡半径² ≥ hub球面积 + Σ叶面积/此值。
    /// 叶多圆大(1000 叶巨圆)、叶少圆小(10 叶小圆),完全由内容涌现。
    /// 07-02 扁圆反馈 0.55→0.42;07-03 日期分明反馈再大胆:0.42→0.26
    ///(挤的气泡里叶子被碰撞顶到同壳层,日期半径映射被抹平 —— 空旷
    /// 才摆得开远近环)。
    static let bubbleFill: Double = 0.26
    /// 气泡半径的额外呼吸边距(世界 pt)
    static let bubblePadding: Double = 4
    /// hub→主球弹簧 rest = 主球半径 + 气泡半径 + 此间隙(气泡贴主球排布)
    static let bubbleGap: Double = 12
    /// 气泡间软碰撞刚度(圆与圆绝不重叠的速度域推开;硬解算兜底)
    static let bubbleCollideStrength: Float = 0.5
    /// 家族帧携带比例(07-03 用户:"拖 folder/分区球时叶子全因加速度
    /// 甩到后面,线要硬一点"→"被推动时会失效,需要全局生效"):**任何**
    /// hub 每 tick 的净位移(拖/被推/回弹/反推力,不问来源)按此比例直接
    /// 带给自家圈内叶,残余由弹簧回弹 —— 等效加硬 hub-叶连线;位置域
    /// 携带无弹簧震荡,1=完全刚体,0=纯弹簧(老行为)。陨石不带(三态
    /// 另有携带/弹簧机制)。0.75→0.9(用户:"再增大一点,更硬些")
    static let familyCarry: Float = 0.9
    /// 线长档位:最新的叶贴 hub(此比例×最大线长),最旧顶到气泡边缘
    static let bubbleRestFloor: Double = 0.25
    /// 线长抖动幅度(07-02 反馈:均匀排列之上加一点排列随机性,别太
    /// 机械):每叶 ±此比例,由文件路径哈希决定 —— **确定性**,同一份
    /// 数据每次打开布局一致(真随机会破坏会话缓存/可复现性)。
    static let bubbleRestJitter: Double = 0.12

    // MARK: 陨石带(07-03 用户新需求:weight<1.5 的 event 不进气泡,
    // 挂在自家气泡外侧、背主球方向的弧带上;三层圈,无连接线,颜色
    // 随自家 folder;交互与普通 event 球完全一致。仅 Events 画布)

    /// 进陨石带的 weight 上限;层界:[1,1.5)最内 / [0.5,1)中 / [0,0.5)最外
    static let beltWeightMax: Double = 1.5
    static let beltTier1Max: Double = 1.0
    static let beltTier2Max: Double = 0.5
    /// 环基准间隙(单环重构):环半径 = 罩住{主球 + 全部气泡}的最小
    /// 包围圆半径 + 此值;同时是层基线的第一排起点(BeltLayout cursor)。
    static let beltGap: Double = 10
    /// 环心平滑跟随系数(每 tick 向当前最小包围圆圆心 lerp 的比例,
    /// 0.08~0.12 防抖;生成期直接用幽灵终局环心,不走平滑)。
    static let ringCenterLerp: Float = 0.1
    /// 环半径余量(定环/监督调整共用目标)= **死区中央**:死区 =
    /// [encR+gap+10, encR+gap+margin+slack] = 余量 [10, 80],目标 45 落
    /// 正中 → 调整后两侧各 35pt 缓冲。为什么必须居中:allStatic 后 hub
    /// 还慢爬 10~25pt(实测),目标离下限太近(25/15 只差 10)会爬穿再
    /// 触发 = 连跳(far-drag 实测 3~4 次);45/[10,80] 实测 converged/
    /// after-drag/drag-back 全零调整,far-drag(极限 2× 拖)≤2 次。
    static let ringPredMargin: Float = 45
    /// 监督死区上富余(上限 = margin+此值 = 80):covered 区间内环一动
    /// 不动;罩不住(余量<10,嵌入)才长、太松(>80)才缩,各一次 lerp。
    static let ringSlack: Float = 35
    /// 扇形云弧半宽上限(rad ≈172°,以背主球方向为中心;07-03 用户两次
    /// 加码:1.92→2.6→3.0"弧线角度更大"——接近全圆,朝主球死角与邻圆
    /// 由动态裁剪守住):弧度随数量先展开到此上限,再往外延长
    /// (BeltLayout.homes)。真实可用弧由引擎**每 tick 动态裁剪**
    /// (邻圆/主球挡住的一侧收缩,整片云往空侧平移延伸)
    static let beltMaxHalfArc: Double = 3.0
    /// 陨石带径向排距(每排外移 slotW×此值;单环"更分散"指厚度 = 排摊
    /// 得更开、带更厚)。原 0.75,加大即更厚
    static let beltRowGap: Double = 1.3
    /// 端部渐隐强度(用户:Unclassified 弧两端别直线硬截,要慢慢没、越来
    /// 越贴内层):每排弧半宽 = famArc×(1−此值×depth²),depth=该家已放置
    /// 比例(0 内→1 外)→ 内排宽、外排窄 = 透镜/彗尾,端部只剩最里层延伸。
    /// 0=矩形硬截,越大越尖
    static let beltEndTaper: Double = 0.45
    /// 家位弹簧刚度(仅**绑定期**用;velocity 域,×max(alpha,0.1) 同
    /// linkPass 地板)。07-03 六稿:解绑后**零引力**(纯碎石漂浮,只被
    /// 碰撞排开)—— 解绑态的任何回拉力都会在拖拽瞬间把全场陨石抽向
    /// hub 方位(实测"一动全聚中心"),别加回来
    static let beltSpring: Float = 0.06

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
    /// 0.15:不乘 alpha 后恒定生效,0.3 会过冲抖动
    static let familySpreadStrength: Float = 0.2
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
    /// park 静止阈值(净位移窗):每 parkQuietWindow tick 与参考位置比一次,
    /// 全场最大净移动 < 此值(世界 pt)才算静止 —— 纯时间冷却会把"从远处
    /// 回弹的球"半路冻住(07-02 实测:拉远松手,回来路上突然停)。
    /// ⚠️ 不能用逐 tick 速度:冷却后恒定力(碰撞/匀布)有 ~0.3pt/tick 原地
    /// 微抖 + 家级慢环流(实测全场最大 3.4~4.1pt/0.5s),永不归零。
    /// 9 = 实测稳态 ×1.5 余量再放宽(07-03 陨石带:家级慢环流被陨石的
    /// 大半径杠杆放大 ~2x,6 会永不休眠撞 30s 兜底;缓停已让冻结柔和,
    /// 18pt/s 以下入睡视觉无感)。9→13(07-03 家族携带全局化:叶跟紧后
    /// 不再给 hub 弹簧反拉阻尼,环流振幅实测涨到 9~12pt/窗,9 正好压线
    /// 永不静止,加载 park 13s→39s 撞兜底;26pt/s 以下入睡仍无感)。
    static let parkNetMove: Float = 13
    /// 净位移窗长(tick;30 = 0.5s@60Hz)
    static let parkQuietWindow: Int = 30
    /// 缓停衰减(07-03 反馈:静止判定后一刀冻结太突兀):冷透+静止后每
    /// tick 位移 × 此值,~1.6s 从全速指数滑到 0(先快后慢,像摩擦力),
    /// 速度真正到 0 才 park;<0.02 归零。
    static let brakeDecay: Float = 0.96
    /// 静止判定兜底(tick 数,≈30s):冷透后持续运动超过此数强制休眠,
    /// 防病态运动永不 park 烧 CPU。
    static let parkRestlessCap: Int = 1800
    /// 物理线程定步频率(60 = d3/Obsidian 的 rAF 同款;120 视觉无差但
    /// 背景 CPU 翻倍,07-01 拖拽卡顿优化降回 60)
    static let physicsHz: Double = 60
    /// 开场炸开:初始位置挤在中心这个半径内(07-02:30→12,绽放更猛)
    static let explosionRadius: Float = 12
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
    /// hub/主球标签 LOD 淡出:zoom ≥ Hi 全显,≤ Lo 消失,间上线性。
    /// 07-03 精修:消失点做近(0.32→0.6)—— 稍微拉远字就该走,不用
    /// 拉到很远才消失
    static let labelFadeZoomHi: Double = 0.9
    static let labelFadeZoomLo: Double = 0.6
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
