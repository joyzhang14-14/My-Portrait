import Foundation

/// 边的渲染方式。
public enum GraphEdgeStyle: Sendable {
    /// 等宽细线(Obsidian 式),全部边一条 Path 一次 stroke
    case line
    /// 锥形橡皮筋(两端粗中间细),逐边填充
    case taperedFill
}

/// 图谱视图的全部可调常数(旋钮)集中在这一处。
public enum GraphConstants {

    // MARK: 连接线

    /// 边的画法。2026-07-01 update:改用纯线(taperedFill 代码保留,改这一行即可切回)。
    public static let edgeStyle: GraphEdgeStyle = .line
    /// 纯线模式线宽(屏幕 pt,不随 zoom —— Obsidian 式等粗)
    public static let lineEdgeWidth: Double = 1.3

    // MARK: 连接线(橡皮筋:两端粗中间细,taperedFill 模式用)

    /// 端点半宽 = 所连球的半径,hub↔主球边和末端球边上限均为 7。
    public static let edgeEndWidthMax: Double = 7
    public static let leafEdgeEndWidthMax: Double = 7
    /// 腰部半宽 = 两端较细一侧 × 此比例
    public static let waistRatio: Double = 0.18

    /// 球半径 → 端点半宽(hub↔主球的边)。
    public static func edgeEndWidth(ballRadius: Double) -> Double {
        min(ballRadius, edgeEndWidthMax)
    }

    /// 球半径 → 端点半宽(连着末端球的边,整条上限 7)。
    public static func leafEdgeEndWidth(ballRadius: Double) -> Double {
        min(ballRadius, leafEdgeEndWidthMax)
    }

    // MARK: 球半径(世界单位)

    public static let mainRadius: Double = 44
    /// 分区球(portrait 画布,统一大小)
    public static let categoryRadius: Double = 22
    /// folder 球 = f0 + kf·√count,clamp 到 [f0, folderRadiusMax]
    public static let folderRadiusBase: Double = 10
    public static let folderRadiusScale: Double = 1.4
    public static let folderRadiusMax: Double = 28
    /// event 球 = clamp(e0 + ke·currentWeight, min, max),上限不超过最小 folder 球。
    /// 下限 1.5 保底,避免最小陨石看不见/点不中;w<0.55 的陨石齐底,层次由陨石带三层圈表达。
    public static let eventRadiusBase: Double = 0.2
    public static let eventRadiusScale: Double = 2.4
    public static let eventRadiusMin: Double = 1.5
    public static let eventRadiusMax: Double = 14
    /// portrait 小球 = p0 + kp·min(weight, 18)
    public static let portraitRadiusBase: Double = 2.5
    public static let portraitRadiusScale: Double = 0.69

    // MARK: 连接强度

    /// 分区球 → 主球:常数
    public static let categoryStrength: Double = 20
    /// folder → 主球:自加权平均(Σw²/Σw)之外再加的基数
    public static let folderStrengthBase: Double = 5
    /// event → hub:occurrences.count 的截断上限
    public static let eventStrengthMax: Double = 15
    /// portrait 小球 → 分区球:weight 线性截断上限(>18 全一样)
    public static let portraitStrengthMax: Double = 18

    // MARK: 气泡(07-02:每 hub 的叶子绕它 360° 成圆)

    /// 气泡内叶子的装填密度:π·气泡半径² ≥ hub球面积 + Σ叶面积/此值。叶多圆大、叶少圆小,完全由内容涌现。
    /// 值不能太大:挤的气泡里叶子被碰撞顶到同壳层,日期半径映射会被抹平,需要空旷空间才摆得开远近环。
    public static let bubbleFill: Double = 0.26
    /// 气泡半径的额外呼吸边距(世界 pt)
    public static let bubblePadding: Double = 4
    /// hub→主球弹簧 rest = 主球半径 + 气泡半径 + 此间隙(气泡贴主球排布)
    public static let bubbleGap: Double = 12
    /// 气泡间软碰撞刚度(圆与圆绝不重叠的速度域推开;硬解算兜底)
    public static let bubbleCollideStrength: Float = 0.5
    /// 缓分限速:成型后(!beltForming)且重叠 > DeepOverlap 时,速度域推挤的重叠项(每 tick 速度增量上限)
    /// 和位置硬解算每轮纠正(每 tick 位置纠正上限)都封顶,深重叠慢慢滑开。
    /// ⚠️ 浅重叠(≤DeepOverlap)必须走原全量解算,否则弹簧压入 vs 硬解算推出的常态接触平衡被限速后
    /// 会变成永动微振,静不下来。深重叠只可能来自拖拽(常态物理圆不互穿),生成期(beltForming)不限。
    public static let bubbleEaseVelCap: Float = 2
    public static let bubbleEasePosCap: Float = 0.5
    public static let bubbleEaseDeepOverlap: Float = 10
    /// 家族帧携带比例:**任何** hub 每 tick 的净位移(拖/被推/回弹/反推力,不问来源)按此比例直接
    /// 带给自家圈内叶,残余由弹簧回弹 —— 等效加硬 hub-叶连线;位置域
    /// 携带无弹簧震荡,1=完全刚体,0=纯弹簧。陨石不带(三态另有携带/弹簧机制)。
    public static let familyCarry: Float = 0.9
    /// 线长档位:最新的叶贴 hub(此比例×最大线长),最旧顶到气泡边缘
    public static let bubbleRestFloor: Double = 0.25
    /// 线长抖动幅度:每叶 ±此比例,由文件路径哈希决定 —— **确定性**,同一份
    /// 数据每次打开布局一致(真随机会破坏会话缓存/可复现性)。
    public static let bubbleRestJitter: Double = 0.12

    // MARK: 陨石带(07-03 update:weight<1.5 的 event 不进气泡,
    // 挂在自家气泡外侧、背主球方向的弧带上;三层圈,无连接线,颜色
    // 随自家 folder;交互与普通 event 球完全一致。仅 Events 画布)

    /// 进陨石带的 weight 上限;层界:[1,1.5)最内 / [0.5,1)中 / [0,0.5)最外
    public static let beltWeightMax: Double = 1.5
    /// folder 存活门:核心球
    /// (weight≥beltWeightMax)不足此数的 folder 散架 —— 其全部 event
    /// (核心+陨石)并入 Unclassified 继续显示。weight 衰减成陨石后核心数
    /// 自然减少,衰减殆尽的 folder 就消失。
    ///
    /// ⚠️ 三处共用这一个门,改这里三处一起变:
    ///   1. Neural Graph —— GraphSceneBuilder.buildEvents(不上画布)
    ///   2. Text 列表   —— MemoriesView.makeFolderSplit(不成组)
    ///   3. 生产 pipeline —— EventClassifier(不创建新 folder)
    public static let folderMinCoreEvents: Int = 5
    /// Unclassified 成区门 —— **Text 列表专用**(08-09 update:三档):
    /// 0 个 folder 纯平铺 / 1–2 个粗灰线隔开 / ≥3 个收成灰色 Unclassified 组。
    ///
    /// ⚠️ 图谱**不用**这个门,它有自己的 `unclassifiedHubMinFolders`。
    public static let unclassifiedFolderMin: Int = 3

    /// Unclassified 分区球成球门 —— **图谱专用**。存活 folder 达到此数才把
    /// 未分类事件收成灰分区球;不够就让它们直连主球。
    ///
    /// 跟 Text 的三档有意不同:图谱是二维布局,
    /// 主球周围挂几十颗散球会跟 folder 气泡抢空间,列表没有这个问题。
    public static let unclassifiedHubMinFolders: Int = 2

    /// 0 个 folder 时全部事件直连主球 —— 这一族的专属线长参数。
    ///
    /// 主球周围只有它们、没有别的气泡竞争空间,沿用气泡内默认参数(rest floor
    /// 0.25)会挤成一坨。气泡整体放大一截把线拉长,
    /// floor 压到 0.10 把最近/最旧的长度差拉开,可用行程从 3 倍拉到 10 倍。
    public static let rootBubbleScale: Double = 1.5
    public static let rootRestFloor: Double = 0.10
    public static let beltTier1Max: Double = 1.0
    public static let beltTier2Max: Double = 0.5
    /// 环基准间隙:环半径 = 罩住{主球 + 全部气泡}的最小
    /// 包围圆半径 + 此值;同时是层基线的第一排起点(BeltLayout cursor)。
    public static let beltGap: Double = 10
    /// 环心平滑跟随系数(每 tick 向当前最小包围圆圆心 lerp 的比例,
    /// 0.08~0.12 防抖;生成期直接用幽灵终局环心,不走平滑)。
    public static let ringCenterLerp: Float = 0.1
    /// 环半径余量(定环/监督调整共用目标)= **死区中央**:死区 =
    /// [encR+gap+10, encR+gap+margin+slack] = 余量 [10, 80],目标 45 落
    /// 正中 → 调整后两侧各 35pt 缓冲。⚠️ 必须居中:allStatic 后 hub 还会慢爬,
    /// 目标离下限太近会爬穿再触发,变成连跳。
    public static let ringPredMargin: Float = 45
    /// 监督死区上富余(上限 = margin+此值 = 80):covered 区间内环一动
    /// 不动;罩不住(余量<10,嵌入)才长、太松(>80)才缩,各一次 lerp。
    public static let ringSlack: Float = 35
    /// 扇形云弧半宽上限(rad ≈172°,以背主球方向为中心,接近全圆,朝主球死角与邻圆
    /// 由动态裁剪守住):弧度随数量先展开到此上限,再往外延长
    /// (BeltLayout.homes)。真实可用弧由引擎**每 tick 动态裁剪**
    /// (邻圆/主球挡住的一侧收缩,整片云往空侧平移延伸)
    public static let beltMaxHalfArc: Double = 3.0
    /// 陨石带径向排距(每排外移 slotW×此值,值越大带越厚)
    public static let beltRowGap: Double = 1.3
    /// 端部渐隐强度(Unclassified 弧两端别直线硬截,要慢慢没、越来
    /// 越贴内层):每排弧半宽 = famArc×(1−此值×depth²),depth=该家已放置
    /// 比例(0 内→1 外)→ 内排宽、外排窄 = 透镜/彗尾,端部只剩最里层延伸。
    /// 0=矩形硬截,越大越尖
    public static let beltEndTaper: Double = 0.45
    /// 家位弹簧刚度(仅**绑定期**用;velocity 域,×max(alpha,0.1) 同
    /// linkPass 地板)。解绑后**零引力**(纯碎石漂浮,只被碰撞排开)。
    /// ⚠️ 解绑态若加回拉力,拖拽瞬间会把全场陨石抽向 hub 方位(一动全聚中心),别加回来
    public static let beltSpring: Float = 0.06

    // MARK: 影子引擎(07-08 update:预判 folder 终局,环提前就位)

    /// 影子累计步数封顶(病态不收敛兜底 → 交结果收工,不再烧 CPU)
    public static let shadowTickCap: Int = 3000

    // MARK: 开局揭幕(找到位置后再显示,透明度一点一点拉高;只适用于开局 init/explode,
    // 拖动松手不藏。隐藏期 hover/点击/拖起全部无效)

    /// 缓滑胡萝卜:目标太远时,槽位弹簧本 tick 只追"沿弧 ≤ArcCap、
    /// 径向 ≤RadialCap"的近端假目标 → 匀速贴弧缓滑,不再朝远目标大甩。
    /// 只作用于成型后(!beltForming)的调整移动,开局绽放不限(揭幕前
    /// 不可见)。⚠️ 必须 >24(穿透免碰撞阈值):压到以下,长途回流全程
    /// 带碰撞,会卡半路
    public static let beltGlideArcCap: Float = 40
    public static let beltGlideRadialCap: Float = 30
    /// 淡入步长(每 tick 加,60Hz 下 ≈0.8s 拉满)
    public static let beltRevealStep: Float = 0.02
    /// 兜底超时(tick 计):armed 后超过此数无条件开始淡入 —— 影子卡死/
    /// 到位判定失效也**绝不永久隐身**。⚠️ 全局 gate 若无兜底会导致永久空白+无交互
    public static let beltRevealTimeoutTicks: UInt64 = 600

    // MARK: 视角取景(07-09 update:开局/松手视角跟隐形环走,占比适中)

    /// 取景占比:隐形环**基准直径**占视口较短边的比例。0.72 → 环占约
    /// 七成,四周留呼吸边(外圈陨石在基准环外还有径向偏移,故不取满);
    /// 越大越贴边,越小越缩。开局固定、松手缓移都以此为目标。
    public static let cameraFrameFill: Double = 0.72
    /// 点 folder 球聚焦该 folder 视图(07-09 update):以隐形圆(气泡)心为
    /// 画布中心、气泡直径占视口较短边此比例。比环取景大(0.82,无外圈
    /// 陨石要留边,气泡叶群贴满更聚焦);越大越贴边。
    public static let cameraFolderFill: Double = 0.82
    /// 松手后相机缓移每帧 lerp 系数(中心+缩放同步);越小越慢越顺。
    /// 60Hz 下 0.08 ≈ 0.5s 收敛九成 —— "缓慢调整到指定位置"。
    public static let cameraTrackLerp: Double = 0.08
    /// 点击聚焦(folder/空白)平滑动画帧数(~60fps):目标点走直线到屏幕
    /// 中心 + 缩放几何插值 + ease-in-out,消除"先缩后平移"的拉回感。
    /// 越大越慢越顺。
    public static let cameraFocusFrames: Int = 36

    // MARK: 物理(d3-force 语义;P0 实测 1.9ms/tick@5000,后台线程)

    /// 斥力电荷(负=互斥),按角色区分(主球斥力与跨圆叶叶斥力会把整家叶子压到背面半圆,圈只用一半):
    /// - hub:保持,负责 hub 间松散感
    public static let manyBodyStrength: Float = -15
    /// - 主球:大降 —— 球不叠靠主球硬碰撞,电荷只会把叶群推向圆的远端
    public static let mainBodyStrength: Float = -4
    /// - 叶:近零 —— 圈内间距归半径感知碰撞力管,电荷大了跨圆互推,
    ///   把彼此边界侧清空(半边圆元凶)
    public static let leafBodyStrength: Float = -2
    /// 家内角向匀布力 v2:排序后每叶向两侧角向
    /// 邻居的**中点**回正(左右间隙相等时力归零)—— 局部弛豫链式传导,
    /// 挤的一侧流向疏的一侧,叶群质心回到 hub。全家适用。
    /// 不乘 alpha 后恒定生效,值加大(如 0.3)会过冲抖动
    public static let familySpreadStrength: Float = 0.2
    /// hub 绕主球的角向均布力(08-09 update)。
    /// 同 familySpread 的邻居中点弛豫,圆心换成原点、成员换成 hub。
    /// 比家内那个小一档:hub 拖着整个气泡,惯性大,推猛了会甩过头。
    public static let hubAngularStrength: Float = 0.08
    /// 角向力只在 hub 数 ≤ 此值时生效(08-09 update):
    /// 少 hub 时收敛快、没出过事;多 hub 时陨石环 + 气泡碰撞
    /// 不断喂扰动,而中点弛豫不约束整体绝对角度 —— 合力矩残余养出
    /// 无阻尼公转,整圈 hub 疯转。
    /// ⚠️ 多 hub 场景本来也不需要它:球多了碰撞自然摊满一圈,不要对多 hub 也生效。
    public static let hubAngularMaxHubs: Int = 5
    /// Barnes-Hut 精度 θ²(d3 默认 θ=0.9;收紧到 0.5 成本翻倍,别动)
    public static let bhTheta2: Float = 0.81
    /// 斥力最小距离²(防重叠点无穷大力)
    public static let bhDistanceMin2: Float = 1
    /// 冷却:每 tick alpha += (target − alpha) × decay;< alphaMin 且 target=0 → 休眠
    public static let alphaDecay: Float = 0.0228
    public static let alphaMin: Float = 0.001
    /// Portrait 叶群进入冷却尾段后，渐进消除绕自家 hub 的整体自转。
    /// 只去掉全组共同角速度；叶间匀布、碰撞和径向运动不受影响。
    public static let portraitRotationDampingStartAlpha: Float = 0.02
    /// 速度阻尼(每 tick 乘;= 1 − d3 默认 velocityDecay 0.4)
    public static let velocityDamping: Float = 0.6
    /// 向心力强度(把孤岛拉回原点方向)
    public static let centerStrength: Float = 0.05
    /// 拖拽/交互 reheat 的 alphaTarget(d3 惯例 0.3)
    public static let dragAlphaTarget: Float = 0.3
    /// park 静止阈值(净位移窗):每 parkQuietWindow tick 与参考位置比一次,
    /// 全场最大净移动 < 此值(世界 pt)才算静止 —— 纯时间冷却会把"从远处
    /// 回弹的球"半路冻住。
    /// ⚠️ 不能用逐 tick 速度:冷却后恒定力(碰撞/匀布)有原地
    /// 微抖 + 家级慢环流,永不归零。
    public static let parkNetMove: Float = 13
    /// 净位移窗长(tick;30 = 0.5s@60Hz)
    public static let parkQuietWindow: Int = 30
    /// 缓停衰减(07-03 update:静止判定后一刀冻结太突兀):冷透+静止后每
    /// tick 位移 × 此值,~1.6s 从全速指数滑到 0(先快后慢,像摩擦力),
    /// 速度真正到 0 才 park;<0.02 归零。
    public static let brakeDecay: Float = 0.96
    /// 静止判定兜底(tick 数,≈30s):冷透后持续运动超过此数强制休眠,
    /// 防病态运动永不 park 烧 CPU。
    public static let parkRestlessCap: Int = 1800
    /// 物理线程定步频率(60 = d3/Obsidian 的 rAF 同款;120 视觉无差但
    /// 背景 CPU 翻倍)
    public static let physicsHz: Double = 60
    /// 开场炸开:初始位置挤在中心这个半径内
    public static let explosionRadius: Float = 12
    /// 主球碰撞硬约束的额外间隙:任何球不得进入 主球半径+自身半径+此值
    ///(斥力是点电荷模型不认半径,没这条低 weight 小球会叠在主球上)
    public static let mainCollisionPadding: Float = 4
    /// hub→主球弹簧刚度 override(d3 默认=1/度数,folder 度数几百 → 弹簧
    /// 太软被斥力推远;定为 1.0 让 folder/分区贴住等距环)
    public static let hubSpringStrength: Double = 1.0
    /// 半径感知碰撞力(d3 forceCollide 同款):球与球按
    /// 半径之和互相推开,是缺的核心力(点电荷斥力 manyBody 不认半径)。
    /// 0.7 为最优值:1.0 会过冲,残余震荡反而更多重叠
    public static let collideStrength: Float = 0.7
    /// 碰撞附加间隙(世界 pt,让球之间留一线缝)
    public static let collidePadding: Float = 1
    /// 每 tick 碰撞解算轮数(d3 默认 1;挤压重时可加,成本 ∝ 轮数)
    public static let collideIterations: Int = 3

    // MARK: 交互动画

    /// 神经脉冲沿边传播速度(世界 pt/s)。**主球**用它(2 跳级联);
    /// folder/分区球改自适应,见 pulseHubTravelSeconds。
    public static let pulseSpeed: Double = 225
    /// folder/分区球脉冲的**行程时间**(秒):速度 = 该球连线平均长度 / 此值,
    /// 使脉冲恰好用这么久走完一条平均长度的边 —— 不论 folder 大小、连线长短,
    /// 点亮自家球的观感时长一致。
    public static let pulseHubTravelSeconds: Double = 1
    /// 脉冲抵达末端球 → 点亮闪一下(07-11 update)。白光峰值不透明度 + 淡出时长
    /// (秒,线性衰减到 0)。⚠️ 改大时长要同步 GraphRootView 的脉冲清空定时
    /// (清早了闪光会被切断:pulses 空 → 不再重绘且 drawBalls 读不到抵达时刻)。
    public static let pulseArriveFlashPeak: Double = 0.85
    public static let pulseArriveFlashSec: Double = 0.45
    /// 级联跳数:主球 2 跳,其它 hub 只 1 跳
    public static let pulseMaxDepthMain: Int = 2
    public static let pulseMaxDepthOther: Int = 1
    /// 脉冲形态 = ||| 三条垂直于连线的细白杠,沿行进方向间隔(屏幕 pt),
    /// 间距 1,几乎重合成一条粗线
    public static let pulseTickCount: Int = 3
    public static let pulseTickSpacing: Double = 1
    /// 杠长 = 连线的**实际渲染粗细**×此倍数,=1 时杠长与线宽完全贴合
    public static let pulseTickLengthScale: Double = 1
    public static let pulseTickStrokeWidth: Double = 1.2
    /// hover 白闪频率(Hz)
    public static let hoverBlinkHz: Double = 2.2
    /// hub/主球标签 LOD 淡出:zoom ≥ Hi 全显,≤ Lo 消失,间上线性。
    /// 消失点较近,稍微拉远字就该走,不用拉到很远才消失
    public static let labelFadeZoomHi: Double = 0.9
    public static let labelFadeZoomLo: Double = 0.6

    // MARK: folder → 主球 连接强度(需求 §4.2)

    /// 自加权平均:Σw²/Σw(高 weight 的 event 话语权大)+ 基数。空 folder = 基数。
    public static func folderStrength(memberWeights: [Double]) -> Double {
        let sum = memberWeights.reduce(0, +)
        guard sum > 0 else { return folderStrengthBase }
        let sq = memberWeights.reduce(0) { $0 + $1 * $1 }
        return sq / sum + folderStrengthBase
    }

}
