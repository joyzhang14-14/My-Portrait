import Foundation
import simd

/// 力导向物理引擎(d3-force 语义的零依赖移植,P0 spike 验证版的产线化)。
///
/// 模型:Barnes-Hut 四叉树斥力(O(n log n)) + 逐边弹簧(自然长度 = 场景的
/// restLength)+ 向心力 + alpha 冷却。主球(index 0)钉在原点。
///
/// 线程模型:
///   - 独立后台线程定步 tick(GraphConstants.physicsHz)
///   - `simLock` 保护 sim 全部可变状态(tick / 拖拽 / reheat / 场景更新)
///   - `snapLock` 只保护位置快照 —— 渲染读快照**永不**等待整个 tick
///   - alpha 冷透且无 alphaTarget → 线程 park(CPU→0),交互 signal 唤醒
///   - park 状态变化通过 AsyncStream 发给 SwiftUI(暂停/恢复 TimelineView)
///
/// Sendable:@unchecked —— 所有可变状态都在上述两把锁之内,逐条核对过。
public final class GraphPhysicsEngine: @unchecked Sendable {

    // MARK: - 状态(simLock 保护)

    private var n: Int
    private var pos: [SIMD2<Float>]
    private var vel: [SIMD2<Float>]
    private var nodeRadius: [Float]
    /// 分角色斥力电荷(主球/hub/叶不同强度,07-02 半边圆确诊)。
    private var nodeCharge: [Float]
    /// 家籍(叶=自家 hub 节点下标;主球/hub=-1):07-02 用户定稿"正常时
    /// 只受自家 folder 球和兄弟球影响,排除外部影响"—— 碰撞力按家隔离。
    private var nodeFamily: [Int32]
    /// 向心力开关(1=hub,0=叶/主球):向心是"每节点→原点"的弹簧,对叶
    /// 施加会把整家压成朝主球的半月(07-02 半边圆的另一半根因)——
    /// 叶由自家 hub 弹簧锚定,不需要全局向心。
    private var nodeCenterScale: [Float]
    private var edgesA: [Int32], edgesB: [Int32]
    private var linkStrength: [Float], linkBias: [Float], linkRest: [Float]
    /// 非主球 hub 的下标(folder/分区)。
    private var hubIndices: [Int32] = []
    /// 气泡半径(07-02 气泡重构:每 hub 的叶子绕它成圆,builder 按内容
    /// 面积算出;≤0 = 无)与质量(叶数+1,重的动得少)。
    /// 物理保证:气泡间/气泡与主球零重叠(软碰撞+硬解算)。
    private var hubBubbleR: [Float] = [], hubMass: [Float] = []
    /// 气泡对主球的净空(= 家内最大叶径 + pad):圆的内缘叶不许被主球
    /// 碰撞壳顶出圈外。
    private var hubMainClear: [Float] = []
    /// 全部末端球下标 + 各自所属 hub(主球=0)+ 各自的圈内硬上限
    ///(= 自家气泡半径 − 叶半径 − 缝;叶子绝不出自家隐形圆)。
    private var leafIndices: [Int32] = [], leafOwnHub: [Int32] = []
    private var leafMaxDist: [Float] = []
    /// 家内角向匀布(07-02):按家分组的叶(仅 2..maxCount 的稀疏家)。
    /// familyLeaf 连续存放,familyRange = (hub 节点下标, 起止)。
    private var familyLeaf: [Int32] = []
    private var familyRange: [(hub: Int32, lo: Int, hi: Int)] = []
    /// 陨石带(单环重构):weight<1.5 的 event,挂在**全场唯一一个陨石
    /// 环**上(环心=罩住主球+全部气泡的最小包围圆圆心,环半径一次算死)。
    /// 四数组同序:节点下标 / 自家 hub / 径向偏移(距环基准 ringR 的
    /// 层距+抖动)/ 槽位角(相对自家 hub 绕环心的极角)。不进
    /// leafIndices(不受圈内夹钳)、不进 familyLeaf(不参与匀布);
    /// 碰撞按家隔离照常。
    private var beltIdx: [Int32] = [], beltHub: [Int32] = []
    private var beltRing: [Float] = [], beltAng: [Float] = []
    /// 陨石环几何(单环重构):环半径 = 影子终局最小包围圆半径 + beltGap,
    /// **一次算死**(explode/updateScene 置 ringDirty 重算;拖动不变)。
    /// 环心 = 每 tick 平滑追目标环心(lerp 防抖);开场直接钉影子
    /// warmup 后的终局几何 —— 环一次变好。
    private var ringRad: Float = 0
    private var ringDirty = true
    private var ringC: SIMD2<Float> = .zero
    /// 环目标(半径+圆心):预测时定死,之后由**持续监督**维护不变量
    /// "目标环始终罩住当前布局(余量∈[10, margin+slack])"——covered
    /// 零动(死区迟滞防振荡),越界(嵌入/太松)才调一次。⚠️ 不能只
    /// 校验一次就 latch:allStatic(每窗<6pt)≠停止,校验后 hub 还会
    /// 慢爬 10~25pt(实测),一次性 latch 会把"folder 嵌进陨石带"定格
    /// 成永久 bug(用户实机实证)。
    private var ringTargetRad: Float = 0
    private var ringTargetC: SIMD2<Float> = .zero
    /// 全节点陨石标记(碰撞用):陨石×陨石**跨家也常开**碰撞 —— 平弧
    /// 云在家与家交界处会交叠,家隔离原则只管圈内叶(07-03 五稿)。
    private var nodeBelt: [Bool] = []
    /// 穿透标记(十稿:"松手移动时会被别的球卡住"):回流中(离目标
    /// >24pt)的陨石对碰撞免疫,可穿过任何球;接近终点恢复实体,落点
    /// 重叠由碰撞解开。beltPass 每 tick 刷新;explode 清零。
    private var nodeTransit: [Bool] = []
    /// 自家 hub 在 hubIndices 里的槽号(绑定期帧携带查 dPhi 用)。
    private var beltHubSlot: [Int32] = []
    /// 陨石三态(07-03 八稿用户定稿:"生成/拖着/松手后三种状态不同计算"):
    /// ① 生成态(explode 起到首次拖球,beltForming=true):帧携带+槽位
    ///   弹簧+动态裁剪 —— 开场收敛 hub 大幅公转,不携带整条带会被甩散;
    /// ② 拖拽中(draggedIndex != nil):**完全自由** —— 隐形圆力场对
    ///   陨石关闭,只剩球体本身的碰撞/清障排开(边界 = 球个体);
    /// ③ 松手后(beltForming=false 且无拖拽):**实时槽位弹簧**(无携带)
    ///   —— 家位按当前布局每 tick 重算,"去处"自动重新生成,被波及的
    ///   全部 folder 跟着重算。
    /// 此前的单向解绑闩/零引力/原位快照(五~七稿)均被此取代。
    /// 九稿补充:三态全程**无隐形圆力场**(卡半路回不去的根源是回程被
    /// 圆挡住);拖拽中不再零力,回「拖拽开始瞬间」的原位快照(定点弹簧,
    /// 拖过之处像水合拢,不是散沙)。
    private var beltForming = true
    /// 拖拽开始瞬间的陨石原位快照(仅拖拽中用;每次 beginDrag 边沿重拍)。
    private var beltDragHome: [SIMD2<Float>] = []
    private var wasDragging = false
    /// 帧携带参考:上 tick 各 hub 位置(空 = 下 tick 重建)。
    private var hubPrev: [SIMD2<Float>] = []
    private var beltTmpNow: [SIMD2<Float>] = []
    private var beltTmpC: [Float] = [], beltTmpS: [Float] = []
    /// 每家陨石云的自然弧半宽(= max|家位角|,动态裁剪的期望宽度)
    /// 与最大环偏移(径向带门控:挡板圆径向够不着环带就不裁弧;
    /// 0 = 该家无陨石)。
    private var beltFamW: [Float] = []
    private var beltFamReach: [Float] = []
    /// 动态弧裁剪的可用角**自由段并集**(相对自家主球极角,升序不重叠)。
    /// 07-03 提前排布定稿:不再每 tick 按实时位置算(hub 还在漂移时环
    /// 先定一次型、hub 到位后又变一次)—— 改用**影子引擎预演终局**,
    /// 开场/松手一次算死,环一次变好。边际二修:
    /// 单一 [lo,hi] 对"卡在弧中间的挡板"会裁掉一整侧 → 改成挖洞后的
    /// 分段并集,家位重映射到并集上,挡板两侧自然排开不堆积。
    private var beltPredSegs: [[(Float, Float)]] = []
    /// 影子需重建标记(07-08 影子引擎:explode/数据刷新/松手边沿置位)。
    private var beltPredDirty = true
    /// 影子**当前** hub 位置(每真实 tick 从影子刷新;快进领先真实
    /// 布局,影子收敛后 = 终局)—— 动 hub 的挡板"计划位"。
    private var beltPredPos: [SIMD2<Float>] = []
    /// 静/动帧判定(每 0.5s 窗看净位移,迟滞 6/12pt):静 hub 的挡板用
    /// 实时位置(真理),动 hub 用幽灵终局位置(计划)—— carveBeltSegs。
    private var hubQuietRef: [SIMD2<Float>] = []
    private var hubStatic: [Bool] = []
    /// 判定窗基准 tick(对抗审查①:窗相位若挂死 tickCount%30,explode/
    /// 重建后的截断窗会把开场飞行中的 hub 误标"静" —— 不满整窗禁翻转)。
    private var hubQuietBase: UInt64 = 0
    /// 家位仿射参数(每家每 tick 算一次:最佳段选择+平移/压缩+积压微调,
    /// 球循环里只做 base+slope×槽位角)与黏滞记忆(上 tick 选中段的中心,
    /// 防几何微动时两段得分打平 tick 间乒乓换段)。
    private var beltFamBase: [Float] = [], beltFamSlope: [Float] = []
    private var beltFamSel: [Float] = []
    private var beltTmpPol: [Float] = []
    private var alpha: Float = 1
    private var alphaTarget: Float = 0
    /// 静止判定(simLock 保护):alpha 是纯时间冷却,不看球到没到位 ——
    /// 只看 alpha 会把"从远处回弹的球"半路冻住(07-02 实测:拉远松手,
    /// 回来路上突然停)。⚠️ 不能用逐 tick 速度:冷却后碰撞/匀布等恒定力
    /// 有 ~0.3pt/tick 原地微抖 + 家级慢环流,永不归零 —— 用净位移窗
    /// (每 0.5s 与参考位置比一次),原地抖/慢环流放行,真位移才算动。
    private var quietRef: [SIMD2<Float>] = []
    private var quietFlag = false
    /// 缓停比例(07-03 反馈:静止判定后一刀冻结太突兀):冷透+静止后
    /// 位移按此比例逐 tick 指数衰减(×brakeDecay,~1.6s 滑到 0),速度
    /// 一点点变慢到 0 才 park;任何 reheat 立即回 1。
    private var brake: Float = 1
    /// 冷透但未静止的连续 tick 数(病态运动兜底,超时强制 park)。
    private var restlessTicks: Int = 0
    /// 本 tick 陨石×陨石最大穿深(collidePass 顺手记录):>1.5pt 时静止
    /// 判定一票否决 —— 压力实测:拖后回流的陨石穿透落点重合,实体化时
    /// 全场已静,缓停 1.6s 冻结前碰撞来不及顶开 = 71/360 对"花生"粘连;
    /// 有残余穿深就不入睡,碰撞几 tick 顶开后再 park(restless 30s 兜底)。
    private var beltPenMax: Float = 0
    /// 本 tick 是否还有陨石在穿透飞行(dLen>24 免碰撞):有就不许 park ——
    /// 冻结正在飞的穿透球会把途中重叠一起定格(压力取证:12s 追逐期
    /// pen 恒 0,park 后 71 对叠着 —— 重叠全藏在免碰撞的穿透态里)。
    private var beltTransitAny = false
    /// 家族帧携带参考:上 tick 各 hub 位置(空 = 下 tick 重建;explode/
    /// updateScene 置空防 teleport 位移被当真位移携带)+ 节点位移缓冲。
    private var famPrev: [SIMD2<Float>] = []
    private var famDelta: [SIMD2<Float>] = []
    /// tick 计数(拖拽降载:重力学隔 tick 跑)。
    private var tickCount: UInt64 = 0
    /// 叶子出生角的整体相位(随种子变,07-02:随机种子每次开花不同)。
    private var seedPhase: Float = 0
    /// 拖拽钉住:index → 目标位置(每次 drag move 更新;d3 的 fx/fy 语义)。
    /// 主球恒钉原点,不进这个表(单独处理)。
    /// ⚠️ 由 dragLock(不是 simLock)保护:drag(to:) 在 120Hz 指针事件里跑,
    /// 若抢 simLock 会被整个 tick(Debug 下数 ms)阻塞 → 拖拽卡顿。
    /// 锁序纪律:dragLock 与 simLock 绝不嵌套,顺序获取。
    private var draggedIndex: Int? = nil
    private var draggedTo: SIMD2<Float> = .zero
    /// 被拖球上一 tick 的钉位(扫掠清障用,防高速隧穿)+ 邻域缓冲。
    private var dragPrevPos: SIMD2<Float>? = nil
    private var dragNbr: [Int32] = []
    /// 挂号的 alphaTarget(dragLock 保护):beginDrag/endDrag 不再抢
    /// simLock —— 收敛中 tick 握锁 20~40ms(Debug),主线程"抓球那一下"
    /// 会顿一拍(07-02 实测);physics 线程下个循环自取自用。
    private var pendingAlphaTarget: Float? = nil
    private let dragLock = NSLock()

    // MARK: - 影子引擎(07-08 用户定稿:"预判 folder 球最终会飘到哪,
    // 环提前到此位置,而不是跟着实时调整")

    /// 同一 GraphScene 构造的第二个完整引擎实例:克隆主引擎当刻
    /// pos/vel/alpha 后全力系快放 —— 同物理+同初始态 ⇒ 影子终局 =
    /// 真实终局(取代旧 12 体幽灵近似:只模拟 hub、叶云聚合电荷,
    /// 结构性算不准,环心可差 ~100pt)。**异步**(07-08 用户实机"还是
    /// 卡顿,tick 再快一点":分帧快进每帧仍挤占物理 tick 预算 —— 改
    /// 把影子丢到低优先级后台队列**全速一口气**跑到 hub 全静,物理
    /// 线程零额外负载;克隆在物理线程做,实例移交后只被任务线程碰,
    /// 结果经 shadowLock 交接)。拖拽开始/explode/updateScene 用
    /// shadowGen 递增废弃在跑任务的结果。
    private var shadowGen: UInt64 = 0
    private var shadowDone = false
    /// 任务→物理线程的结果交接(shadowLock 保护)。
    private let shadowLock = NSLock()
    private var shadowReady = false
    private var shadowResult: [SIMD2<Float>] = []
    /// 拖拽预热(07-08 用户"延迟优化到极致"):拖拽中每隔一段按"假设
    /// 此刻松手"克隆预算;松手位置与最近预算克隆位够近 → 结果现成,
    /// 零延迟直飞。以下三个只在物理线程读写(无锁)。
    private var shadowClonePosPending: SIMD2<Float>? = nil
    /// 锁定时刻(消费影子结果那 tick):之后 45 tick 内槽位弹簧 ×2.5
    /// —— 弹簧零速起步头 200ms 位移只有百分之几,肉眼像"没动"被感知
    /// 为延迟;起飞窗口加力让第一帧就有可见移动(生成态不加,绽放
    /// 节奏不变;窗口后回常规增益,极坐标弹簧自带 ease-out 收尾)
    private var beltLockTick: UInt64 = 0
    private var dragSpawnPos = SIMD2<Float>(.infinity, .infinity)
    private var lastShadowSpawnTick: UInt64 = 0
    private var lastDragPos: SIMD2<Float> = .zero
    /// 影子身份:true = 本实例是影子(init 不起线程,beltPass 走实时
    /// 挡板分支)。
    private let isShadow: Bool
    /// 场景留存(重建影子用;updateScene 同步换新)。
    private var sceneRef: GraphScene

    // MARK: - 开局揭幕(07-08 用户:陨石开局先聚中心再展开不美观 ——
    // 等找到位置后再显示,透明度一点一点拉高;**只适用于开局**)

    /// 陨石渲染透明度乘子 0…1(simLock 保护)。init/explode(开局的
    /// 两条路:数据变了走新引擎 init、指纹没变走 updateScene+explode)
    /// 置 0 布防;拖动松手**不碰**(只适用于开局)。无陨石/影子实例
    /// 恒 1(⚠️ 影子必须 1:park/淡入逻辑对影子无意义,置 0 会让
    /// beltPass 顶部的兜底分支空转)。
    private var beltReveal: Float = 1
    /// 淡入已启动闩(单向;到位判定或超时兜底置 true)。启动后每 tick
    /// 无条件推进 —— 中途拖拽/影子重建都不撤销,绝不倒退回隐身。
    private var beltRevealGo = false
    /// 布防时刻(tick 计,超时兜底基准)。
    private var beltRevealArm: UInt64 = 0
    /// 渲染侧副本(snapLock 保护,publishSnapshot 同步;渲染每帧读它,
    /// 不碰 simLock —— Debug 一个 tick 7ms,读 simLock 会卡渲染)。
    private var beltRevealSnap: Float = 1

    // 四叉树扁平数组(容量随 n 分配,tick 内复用)
    private var qChild: [Int32] = []
    private var qMass: [Float] = []
    private var qCom: [SIMD2<Float>] = []
    private var qWidth: [Float] = []
    /// 子树内最大球半径(forceCollide 剪枝用,聚合于 buildTree)。
    private var qMaxR: [Float] = []
    private var qCount = 0
    private var nextPoint: [Int32] = []
    /// 根节点几何(collide 遍历需要真实区域边界,不能用质心近似剪枝)。
    private var rootCenter: SIMD2<Float> = .zero
    private var rootHalf: Float = 0
    /// collide 遍历栈(预分配复用,免得每 tick 4 次数组分配)。
    private var cStackNode = [Int32](repeating: 0, count: 256)
    private var cStackCX = [Float](repeating: 0, count: 256)
    private var cStackCY = [Float](repeating: 0, count: 256)
    private var cStackHalf = [Float](repeating: 0, count: 256)

    private let simLock = NSLock()

    // MARK: - 快照(snapLock 保护)

    private var snapshot: [SIMD2<Float>]
    private let snapLock = NSLock()

    // MARK: - 线程控制

    private let cond = NSCondition()
    private var shouldRun = true
    private var parkedFlag = false
    private var parkContinuation: AsyncStream<Bool>.Continuation?
    /// park 状态流(true = 已休眠)。视图订阅它来暂停/恢复 TimelineView。
    public let parkEvents: AsyncStream<Bool>

    // MARK: - 初始化

    /// - Parameter seed: 炸开初始位置的随机种子(定值 → 同数据同布局可复现)。
    /// - Parameter isShadow: true = 影子实例(不起后台线程,不再造影子;
    ///   只被主引擎在物理线程里同步 tick 做终局预演)。
    public init(scene: GraphScene, seed: UInt64 = 7, isShadow: Bool = false) {
        self.isShadow = isShadow
        sceneRef = scene
        n = scene.nodes.count
        var rng = SplitMix64(seed: seed)
        pos = Self.explosionPositions(n: n, rng: &rng)
        seedPhase = Float.random(in: 0..<(2 * .pi), using: &rng)
        vel = .init(repeating: .zero, count: n)
        nodeRadius = scene.nodes.map { Float($0.radius) }
        nodeCharge = Self.chargeArray(scene: scene)
        nodeCenterScale = Self.centerScaleArray(scene: scene)
        nodeFamily = Self.familyIdArray(scene: scene)
        snapshot = pos
        (edgesA, edgesB, linkStrength, linkBias, linkRest) = Self.linkArrays(scene: scene)
        (hubIndices, hubBubbleR, hubMass, hubMainClear) = Self.hubArrays(scene: scene)
        (leafIndices, leafOwnHub, leafMaxDist) = Self.leafArrays(scene: scene)
        (familyLeaf, familyRange) = Self.familyArrays(scene: scene)
        (beltIdx, beltHub, beltRing, beltAng, beltHubSlot, beltFamW, beltFamReach)
            = Self.beltArrays(scene: scene)
        nodeBelt = scene.nodes.map { $0.beltTier != nil }
        nodeTransit = .init(repeating: false, count: n)
        // 07-02 终稿:开场 = 物理收敛(从中心炸开,力系统自然摊成圆)。
        // 目标落位/绽放出生已删 —— 布局不再有"成品位",只有平衡态。
        // 开局揭幕布防(新引擎 init = 开局路径之一;另一条 explode)。
        // 只藏陨石,主球/folder/叶照常炸开。无陨石(portrait 图)/影子
        // 恒 1,否则 beltPass 顶部兜底走不到,park 门永堵
        beltReveal = (isShadow || beltIdx.isEmpty) ? 1 : 0
        beltRevealSnap = beltReveal
        beltRevealGo = false
        beltRevealArm = 0

        var continuation: AsyncStream<Bool>.Continuation?
        parkEvents = AsyncStream { continuation = $0 }
        parkContinuation = continuation
        allocateTree()   // 必须在全部存储属性就位后(方法调用要求 self 完整)
        seedLeafAngles()
        snapshot = pos

        // 影子不起线程:它只被主引擎在物理线程里同步 tick(快放预演)
        guard !isShadow else { return }
        let t = Thread { [weak self] in self?.loop() }
        t.name = "graph-physics"
        // .userInitiated(不是 .userInteractive):tick 重载(Debug 30Hz
        // 饱和)时不许抢主线程的渲染/手势 —— 被拖球由渲染端钉指针,
        // 物理慢半拍只影响邻居跟随,主线程掉帧才是"卡"(07-02 实测)。
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// 停线程(被替换 / 会话清理时调)。幂等。
    public func shutdown() {
        cond.lock()
        shouldRun = false
        cond.signal()
        cond.unlock()
        parkContinuation?.finish()
    }

    // MARK: - 对外操作(任意线程;内部拿锁)

    /// 渲染每帧读:最新位置快照。只等 snapLock(µs 级),不等 tick。
    public func readSnapshot() -> [SIMD2<Float>] {
        snapLock.lock(); defer { snapLock.unlock() }
        return snapshot
    }

    /// 渲染/命中每帧读:陨石揭幕透明度 0…1(开局隐藏期 <1;=1 常态)。
    /// 只等 snapLock,与 readSnapshot 同源同拍。
    public var beltRevealAlpha: Float {
        snapLock.lock(); defer { snapLock.unlock() }
        return beltRevealSnap
    }

    public var isParked: Bool {
        cond.lock(); defer { cond.unlock() }
        return parkedFlag
    }

    /// 调试只读(harness 画环/断言用):当前环心 / 环半径(无 belt 时
    /// ringR = 0)。
    public var ringCenter: SIMD2<Float> {
        simLock.lock(); defer { simLock.unlock() }
        return ringC
    }
    public var ringR: Float {
        simLock.lock(); defer { simLock.unlock() }
        return ringRad
    }

    /// 开始拖某个球(index 0 主球由调用方挡掉)。只碰 dragLock,绝不等 tick。
    public func beginDrag(index: Int, at world: SIMD2<Float>) {
        dragLock.lock()
        draggedIndex = index
        draggedTo = world
        pendingAlphaTarget = GraphConstants.dragAlphaTarget
        dragLock.unlock()
        wake()
    }

    /// 120Hz 指针事件热路径:只碰 dragLock(µs 级),绝不等 tick。
    public func drag(to world: SIMD2<Float>) {
        dragLock.lock()
        draggedTo = world
        dragLock.unlock()
    }

    public func endDrag() {
        dragLock.lock()
        draggedIndex = nil
        pendingAlphaTarget = 0
        dragLock.unlock()
        wake()   // 若恰在 park 边缘,确保有 tick 来消费挂号
    }

    /// 重新炸开(手动刷新且数据变了 / 换画布新数据)。
    public func explode(seed: UInt64 = 7) {
        simLock.lock()
        var rng = SplitMix64(seed: seed)
        pos = Self.explosionPositions(n: n, rng: &rng)
        seedPhase = Float.random(in: 0..<(2 * .pi), using: &rng)
        vel = .init(repeating: .zero, count: n)
        seedLeafAngles()
        // 重新生成 → 陨石回生成态(帧携带成型,首次拖球后转实时槽位),
        // 影子按新种子重建预演终局;环半径/环心一并重算(一次算死)
        beltForming = true
        beltPredDirty = true
        ringDirty = true
        // 清旧环(07-09 出场偏差修):切走再切回复用引擎走这条路,若不清,
        // ringRad/ringC 仍是**上次布局**的值(尤其上次把环拖大过)——相机
        // 开局取景一读就按旧环定帧 = 偏差,本轮重新钉环后又没跟上。归零 →
        // 相机取景轮询会等到本轮影子重新钉环(ringDirty 消费处)才定帧。
        // 揭幕期陨石隐藏 + 等待态不动,归零窗口不可见。
        ringRad = 0; ringC = .zero
        ringTargetRad = 0; ringTargetC = .zero
        shadowLock.lock(); shadowGen &+= 1; shadowLock.unlock()   // 废弃在跑影子任务
        nodeTransit = .init(repeating: false, count: n)
        hubPrev = []
        hubQuietRef = []   // 静动帧判定重置(全员从"动"起步 = 纯预判)
        famPrev = []       // teleport 位移不携带
        alpha = 1
        // 开局揭幕布防(explode = 开局路径之二:刷新按钮/切回画布走
        // updateScene+explode)。拖动松手不经过这里 → 不藏
        beltReveal = beltIdx.isEmpty ? 1 : 0
        beltRevealGo = false
        beltRevealArm = tickCount
        publishSnapshot()
        simLock.unlock()
        wake()
    }

    /// 叶子出生角 = 黄金角均匀绕自家 hub(d3 phyllotaxis 同思路)。
    /// 07-02 反馈:有的家只用半边圆 —— 角向扩散靠球间斥力,收敛前铺
    /// 不满一圈;出生即均匀,物理只需保持。半径小起步(圈的 1/3),
    /// 绽放感由弹簧给出。确定性:同数据同布局。
    private func seedLeafAngles() {
        guard !leafIndices.isEmpty else { return }
        let golden: Float = 2.39996323
        var counter: [Int32: Int] = [:]
        for li in 0..<leafIndices.count {
            let hub = leafOwnHub[li]
            let j = counter[hub, default: 0]
            counter[hub] = j + 1
            let leaf = Int(leafIndices[li])
            let hubIdx = Int(hub)
            // 家族错相 + 种子相位(随机种子 → 每次开花方位不同)
            let a = golden * Float(j) + Float(hubIdx) * 0.7 + seedPhase
            // 0.1×圈半径出生(07-02:展开效果再强烈一点)—— 贴着 hub 喷出
            let maxD = leafMaxDist[li]
            let r = maxD > 0 ? max(maxD * 0.1, nodeRadius[hubIdx] + 3)
                             : nodeRadius[hubIdx] + 8
            pos[leaf] = pos[hubIdx] + SIMD2<Float>(cos(a), sin(a)) * r
        }
        // 陨石出生(07-03):出生角 = 各自槽位方向(hub 当前极角 + 槽位
        // 偏移),半径 = (自家气泡 + 环偏移)的 40%(生得太贴 hub 会穿越
        // 整片叶群一路碰撞;40% 处起飞冲出去更顺)。开场保留喷出绽放
        // 效果(用户拍板,"先排位"只用于松手后)。
        for bi in 0..<beltIdx.count {
            let hubIdx = Int(beltHub[bi])
            let hp = pos[hubIdx]
            let a = atan2(hp.y, hp.x) + beltAng[bi]
            let bub = max(hubBubbleR[Int(beltHubSlot[bi])], 0)
            let r = max(nodeRadius[hubIdx] + 3, (bub + beltRing[bi]) * 0.4)
            pos[Int(beltIdx[bi])] = hp + SIMD2<Float>(cos(a), sin(a)) * r
        }
    }

    /// 数据轻刷新:节点集合没变(fingerprint 相等),只更新边参数
    /// (rest 每天随 last_occurred 漂移)。**保留位置**,微加热让布局适应。
    public func updateScene(_ scene: GraphScene) {
        simLock.lock()
        guard scene.nodes.count == n else { simLock.unlock(); return }   // 防御:调用方保证
        sceneRef = scene   // 影子重建用最新场景
        nodeRadius = scene.nodes.map { Float($0.radius) }
        nodeCharge = Self.chargeArray(scene: scene)
        nodeCenterScale = Self.centerScaleArray(scene: scene)
        nodeFamily = Self.familyIdArray(scene: scene)
        (edgesA, edgesB, linkStrength, linkBias, linkRest) = Self.linkArrays(scene: scene)
        (hubIndices, hubBubbleR, hubMass, hubMainClear) = Self.hubArrays(scene: scene)
        (leafIndices, leafOwnHub, leafMaxDist) = Self.leafArrays(scene: scene)
        (familyLeaf, familyRange) = Self.familyArrays(scene: scene)
        (beltIdx, beltHub, beltRing, beltAng, beltHubSlot, beltFamW, beltFamReach)
            = Self.beltArrays(scene: scene)
        nodeBelt = scene.nodes.map { $0.beltTier != nil }
        nodeTransit = .init(repeating: false, count: n)
        beltPredDirty = true
        shadowLock.lock(); shadowGen &+= 1; shadowLock.unlock()   // 旧影子任务作废
        ringDirty = true   // 数据变了 → 环半径按新影子终局重算
        hubPrev = []   // 帧携带参考失效,下 tick 重建
        hubQuietRef = []   // 槽位数可能变,静动帧判定重建
        famPrev = []   // 家族携带参考同理重建
        alpha = max(alpha, 0.1)   // 轻推一下,别炸开
        simLock.unlock()
        wake()
    }

    // MARK: - 物理线程

    private func loop() {
        while true {
            // 状态判定在锁内,park 事件在锁外发。
            // ⚠️ NSCondition 不可重入 —— 持有 cond 锁时绝不能再调任何会
            // cond.lock() 的方法(初版在这里嵌套 setParked 直接死锁)。
            cond.lock()
            if !shouldRun { cond.unlock(); return }
            dragLock.lock()
            let pending = pendingAlphaTarget
            pendingAlphaTarget = nil
            let dragging = draggedIndex != nil
            dragLock.unlock()
            simLock.lock()
            if let p = pending {
                alphaTarget = p
                if p > 0, alpha < p { alpha = p }
            }
            // 用户首次拖球 → 生成态结束(单向闩,explode 重置)。
            // 每次拖拽开始的边沿:快照全部陨石当前位置(拖拽期回这些
            // 定点 —— 定点弹簧无全局涌动,拖过之处像水合拢)
            if dragging {
                beltForming = false
                if !wasDragging { beltDragHome = beltIdx.map { pos[Int($0)] } }
            } else if wasDragging {
                // 松手边沿:预热命中判定 —— 拖拽中已按"假设此刻松手"
                // 预算过,最近预算的克隆位与松手位置够近(<40pt)→ 结果
                // 现成/在途,不重建(零/极低延迟);否则照常重建(3~8 tick)
                if let cp = shadowClonePosPending,
                   simd_length(cp - lastDragPos) < 60 {
                    // 命中:结果 ready 则下 tick 即消费;在途则等它几 tick
                } else {
                    beltPredDirty = true
                }
                // 静动判定同步刷新(对抗审查②):拖拽期判定冻结,被拖拽
                // 推土机推开的邻居若还挂着拖前的 static 旗,松手后最长
                // 0.5s 会拿"被推开的瞬时位置"当真挡板切碎弧 —— 位移超
                // 迟滞阈的立即降级为"动"(用幽灵帧),并重开一个完整窗
                if hubQuietRef.count == hubIndices.count {
                    for s in 0..<hubQuietRef.count {
                        let p = pos[Int(hubIndices[s])]
                        if simd_length(p - hubQuietRef[s]) > 12 { hubStatic[s] = false }
                        hubQuietRef[s] = p
                    }
                    hubQuietBase = tickCount
                }
            }
            wasDragging = dragging
            // park = 冷透 && 真静止(最大移动量低于阈值)。alpha 冷却是纯
            // 时间表(松手 ~4s 必冷透),球从远处回弹走不完就会被冻在半路;
            // 静止判定兜底:病态微抖超时(≈30s)强制休眠,防 CPU 烧死。
            let coldNow = alpha < GraphConstants.alphaMin && alphaTarget == 0
            let quiet = brake == 0   // 缓停滑完(速度已到 0)才真正入睡
            if coldNow && !quiet { restlessTicks += 1 } else { restlessTicks = 0 }
            // 揭幕没完成不许睡(07-08 教训:park 后 tick 停摆+渲染暂停,
            // 淡入会冻在半路 = 永久隐身/半透明)。超时兜底保证 beltReveal
            // 必达 1,此门最多多醒几秒,不会永堵
            let cooled = coldNow && (quiet || restlessTicks > GraphConstants.parkRestlessCap)
                && beltReveal >= 1
            simLock.unlock()
            let sleeping = cooled && !dragging
            let stateChanged = parkedFlag != sleeping
            parkedFlag = sleeping
            if sleeping && !stateChanged {
                // 已在 park 态:等 signal(0.5s 兜底轮询防丢信号;wait 自动放锁)
                cond.wait(until: Date().addingTimeInterval(0.5))
                let run = shouldRun
                cond.unlock()
                if !run { return }
                continue
            }
            cond.unlock()
            if stateChanged { parkContinuation?.yield(sleeping) }
            if sleeping { continue }   // 刚转入 park:下一圈进 wait

            let t0 = DispatchTime.now().uptimeNanoseconds
            simLock.lock()
            tick()
            // 高温期子步(07-03 用户"让图像更早归位"):alpha 还热的收敛
            // 段每帧多跑一步 —— 同一部电影快放,动力学/终局布局/park 判定
            // (阈值全按 tick 计,对子步透明)分毫不变,只是墙钟时间减半。
            // 拖拽中不启用:交互热路径保持每帧一步的实时手感与 tick 预算
            if !dragging, alpha > 0.02 { tick() }
            publishSnapshot()
            simLock.unlock()
            let spent = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            let budget = 1.0 / GraphConstants.physicsHz
            if spent < budget { usleep(useconds_t((budget - spent) * 1e6)) }
        }
    }

    private func wake() {
        cond.lock()
        cond.signal()
        cond.unlock()
    }

    /// 调用方须持有 simLock。
    private func publishSnapshot() {
        snapLock.lock()
        snapshot = pos
        beltRevealSnap = beltReveal
        snapLock.unlock()
    }

    // MARK: - 一次 tick(调用方须持有 simLock)

    private func tick() {
        guard n > 0 else { alpha = 0; return }
        tickCount &+= 1
        // 拖拽降载(07-02 实测:Debug 下满力学 tick 超预算一倍 → 30Hz
        // 饱和,physics 线程抢核致主线程卡顿):拖拽中重力学(建树/斥力/
        // 碰撞)隔 tick 跑,轻 tick 只跑弹簧/墙/约束 —— 邻居跟随本就是
        // 惯性动画,视觉无差,CPU 近半。
        let heavy = alphaTarget == 0 || tickCount % 2 == 0
        if heavy {
            buildTree()
            manyBodyPass()
        }
        linkPass()
        beltPass()
        bubblePass()
        if heavy { familySpreadPass() }   // 匀布是慢整形力,拖拽中隔 tick 足够
        // 碰撞每 tick 跑(07-02:不重叠是最基本要求)—— 轻 tick 复用上个
        // tick 的树(位置只差一步,剪枝留了 pad 余量),省掉建树大头。
        collidePass()
        centerAndIntegrate()
        alpha += (alphaTarget - alpha) * GraphConstants.alphaDecay
        // 静止判定净位移窗:每 parkQuietWindow tick 与参考位置比一次。
        if tickCount % UInt64(GraphConstants.parkQuietWindow) == 0 {
            if quietRef.count == n {
                var m2: Float = 0
                let t2 = GraphConstants.parkNetMove * GraphConstants.parkNetMove
                for i in 1..<n {
                    m2 = max(m2, simd_length_squared(pos[i] - quietRef[i]))
                    if m2 >= t2 { break }
                }
                // 陨石残余穿深/穿透飞行一票否决:有叠压不算静(碰撞顶开
                // 再睡),还有球在穿透飞行也不算静(冻结会连途中重叠一起
                // 定格);restless 30s 兜底防病态不眠
                quietFlag = m2 < t2 && beltPenMax < 1.5 && !beltTransitAny
            } else {
                quietFlag = false   // 场景刚换,等一个完整窗
            }
            quietRef = pos
        }
        // 缓停:冷透+静止 → 位移比例指数衰减到 0(速度一点点变慢);
        // 否则(reheat/还在动)立即恢复全速。
        if alpha < GraphConstants.alphaMin && alphaTarget == 0 && quietFlag {
            brake *= GraphConstants.brakeDecay
            if brake < 0.02 { brake = 0 }
        } else {
            brake = 1
        }
        // 早停快照已删(07-02 终稿):布局没有"成品位",冷却到 alphaMin
        // 自然 park —— 开场/收敛全程都是物理,本身即丝滑。
    }

    /// 陨石带回位弹簧(07-03):每颗陨石有确定性槽位 = 自家 hub 极角
    /// (主球钉原点,hub 极角即背主球方向)+ 槽位角偏移、半径 = 环半径。
    /// hub 移动/绕主球转时槽位实时跟着走 —— 弧带永远背对主球。被拖颗
    /// 不加(拖拽钉住覆盖速度,加了也白算,与叶弹簧同理无须豁免)。
    private func beltPass() {
        guard !beltIdx.isEmpty else { return }
        // 开局揭幕推进(放最顶:拖拽/待命/影子各分支早退都不能拦它)。
        // Go 后每 tick 无条件拉高;未 Go 超时无条件兜底启动(影子卡死/
        // 到位判定失效也绝不永久隐身)。正常启动在陨石主循环的到位判定
        if beltReveal < 1, !isShadow {
            if beltRevealGo {
                beltReveal = min(beltReveal + GraphConstants.beltRevealStep, 1)
            } else if tickCount &- beltRevealArm
                        > GraphConstants.beltRevealTimeoutTicks {
                beltRevealGo = true
            }
        }
        dragLock.lock()
        let di = draggedIndex ?? -1
        dragLock.unlock()
        // ② 拖拽中(九稿改版,八稿零力"散沙"被否):回**拖拽开始瞬间**的
        //   原位快照 —— 定点弹簧零初始力、无全局涌动,被拖球推开的陨石
        //   在它身后像水合拢;边界 = 球个体(隐形圆力场三态全关)。
        if di >= 0 {
            hubPrev = []
            // 拖拽预热:拖的是 hub 且离上次预算克隆位 >40pt(节流 ≥20
            // tick)→ 按"假设此刻松手"克隆预算(spawnShadow 内含 gen
            // 递增,自动废弃上一发)。拖到新位置停顿 ≥0.3s,松手时结果
            // 已现成 = 零延迟
            lastDragPos = pos[di]
            if di != 0, nodeFamily[di] < 0,
               simd_length(pos[di] - dragSpawnPos) > 30,
               tickCount &- lastShadowSpawnTick >= 10 {
                spawnShadow(releasedSim: di)
                dragSpawnPos = pos[di]
                lastShadowSpawnTick = tickCount
            }
            guard beltDragHome.count == beltIdx.count else { return }
            let k = GraphConstants.beltSpring * max(alpha, 0.1)
            pos.withUnsafeBufferPointer { P in
            vel.withUnsafeMutableBufferPointer { V in
                for bi in 0..<beltIdx.count {
                    let i = Int(beltIdx[bi])
                    if i == di { continue }
                    let delta = beltDragHome[bi] - P[i] - V[i]
                    // 距离增益(九稿:太远回不去卡半路):>150pt 开始加力,
                    // 封顶 ×3 —— 远球加速度大,冲得回来
                    let dLen = simd_length(delta)
                    let boost = min(1 + dLen / 150, 3)
                    V[i] += delta * (k * boost)
                    // 穿透(十稿):回流途中(>24pt)对碰撞免疫,近终点实体化
                    nodeTransit[i] = dLen > 24
                }
            }}
            return
        }
        // ①③ 共用槽位机(家位按当前布局实时重算):
        //   生成态额外帧携带(开场收敛 hub 绕主球公转大半圈,纯弹簧拖
        //   不动整条带,169/599 流散实测);松手后**纯弹簧**(无携带)——
        //   "去处"随新布局重新生成,被波及的全部 folder 跟着重算。
        // 地板 0.35(不是 linkPass 的 0.1,压力取证):反推力冷场持续
        // 转 hub,目标 2~6pt/tick 走,弹簧 0.1 地板只追 0.45pt/tick ——
        // 永远落后 >24pt = 永久穿透免碰撞,park 冻结时 71/360 对叠着
        var k = GraphConstants.beltSpring * max(alpha, 0.35)
        if !beltForming, tickCount &- beltLockTick < 45 {
            k *= 2.5   // 起飞窗口(见 beltLockTick 注释)
        }
        do {
            let nh = hubIndices.count
            if hubPrev.count != nh {
                hubPrev = (0..<nh).map { pos[Int(hubIndices[$0])] }
                beltTmpNow = hubPrev
                beltTmpC = .init(repeating: 1, count: nh)
                beltTmpS = .init(repeating: 0, count: nh)
                beltTmpPol = .init(repeating: 0, count: nh)
                return
            }
            for s in 0..<nh { beltTmpNow[s] = pos[Int(hubIndices[s])] }
            // 静/动帧判定(0.5s 窗净位移,迟滞 6/12pt):动 hub 的挡板
            // 用幽灵终局,停下的 hub 用实时位置(预判失准自动被纠正)。
            // 窗基准 = 重建/上次判定的 tick,不满整窗禁翻转(对抗审查①:
            // 挂死 tickCount%30 的话 explode 后截断窗会把飞行 hub 误标静)
            if hubQuietRef.count != nh {
                hubQuietRef = beltTmpNow
                hubStatic = .init(repeating: false, count: nh)
                hubQuietBase = tickCount
            } else if tickCount &- hubQuietBase >= 30 {
                for s in 0..<nh {
                    let m = simd_length(beltTmpNow[s] - hubQuietRef[s])
                    if hubStatic[s] { if m > 12 { hubStatic[s] = false } }
                    else if m < 6 { hubStatic[s] = true }
                    hubQuietRef[s] = beltTmpNow[s]
                }
                hubQuietBase = tickCount
            }
            // 影子快放(07-08,取代 12 体幽灵 predictBeltClip):
            // beltPredDirty = 影子需重建(explode/刷新/松手边沿)。影子
            // 克隆当刻状态全力快放,每真实 tick 再快进几步 —— 挡板计划
            // 位/环目标直接读影子当前几何(领先真实,done 后=终局)。
            // 影子实例自身不再造影子(防递归):它就是终局演算,挡板
            // 计划位直接用实时位置(等价全静帧)。
            if isShadow {
                // 影子瘦身:陨石已冻结(不进树不碰撞),环/carve/槽位弹簧
                // 全无消费方 —— 静动判定(上面,done 判据要读 hubStatic)
                // 维护完就收工。影子只为一件事:hub 终局。
                return
            } else {
                // 异步影子:dirty(explode/刷新/松手)→ 克隆+丢后台全速跑;
                // 结果 ready → 消费一次(挡板终局 + 开场正式钉环)→ done,
                // beltPredPos 定格终局
                if beltPredDirty || beltPredPos.count != nh {
                    spawnShadow()
                    beltPredDirty = false
                } else if !shadowDone {
                    shadowLock.lock()
                    let ok = shadowReady
                    let res = shadowResult
                    if ok { shadowReady = false }
                    shadowLock.unlock()
                    if ok, res.count == nh {
                        beltPredPos = res
                        let (cs, rs) = enclosureCircles(hubAt: { res[$0] })
                        if ringDirty {
                            // 开场:正式钉死(爆炸掩护,不可见)
                            let (c, encR) = Self.minEnclosingCircle(
                                centers: cs, radii: rs)
                            ringRad = encR + Float(GraphConstants.beltGap)
                                + GraphConstants.ringPredMargin
                            ringTargetRad = ringRad
                            ringC = c
                            ringTargetC = c
                            ringDirty = false
                        } else if !ringCovered(cs, rs) {
                            // 松手:ready 即按影子终局(≈真实停位)一次
                            // 调环 —— 陨石从当前位置直飞最终位置不改道;
                            // 死区内零动。停稳校验退回纯兜底
                            let (c, encR) = Self.minEnclosingCircle(
                                centers: cs, radii: rs)
                            ringTargetC = c
                            ringTargetRad = encR
                                + Float(GraphConstants.beltGap)
                                + GraphConstants.ringPredMargin
                        }
                        shadowDone = true
                        beltLockTick = tickCount
                    }
                }
            }
            // 环结算(07-08 用户定稿"等停再变"):环的可见变化只剩
            // **停稳校验**这一处(布局停稳/冷透兜底时按实时圆集走
            // ringCovered 死区,covered 零动、越界调一次)—— 松手后环
            // 纹丝不动,folder 飘到位停稳后才平滑调一次。影子只喂 carve
            // 挡板计划位与开场钉环(开场在爆炸掩护里,不可见)。拖动中
            // beltPass 早退,"拖动整环不变"。
            let allStatic = hubStatic.count == nh && !hubStatic.contains(false)
            if allStatic || alpha < GraphConstants.alphaMin {
                let (cs, rs) = enclosureCircles(hubAt: { beltTmpNow[$0] })
                if !ringCovered(cs, rs) {
                    let (c, encR) = Self.minEnclosingCircle(
                        centers: cs, radii: rs)
                    ringTargetC = c
                    ringTargetRad = encR + Float(GraphConstants.beltGap)
                        + GraphConstants.ringPredMargin
                }
            }
            // 环**硬切**(07-08 用户"动的时候一步到位":环是隐形的,lerp
            // 平滑毫无意义 —— lerp 期间陨石目标跟着环每帧漂移;平滑感
            // 由陨石的极坐标弹簧提供,目标必须从锁定那刻就是最终值)
            ringC = ringTargetC
            ringRad = ringTargetRad
            let rc = ringC
            // 极角/角增量绕**环心**;帧携带 = 绕环心刚体公转,按自家 hub
            // 相对环心的角增量
            for s in 0..<nh {
                let rel = beltTmpNow[s] - rc
                let relPrev = hubPrev[s] - rc
                let d = atan2(rel.y, rel.x) - atan2(relPrev.y, relPrev.x)
                beltTmpC[s] = cos(d); beltTmpS[s] = sin(d)
                // 家方位 = **主球→folder 射线与环的交点**(用户定稿:弧、
                // folder 球、主球三点一线才是"正上方";此前用 folder 相对
                // 环心的极角,环心被巨泡拉偏后两者不一致)。附带:环心漂移
                // 时交点始终钉在射线上 —— 弧方向不再随环心晃,只有径向
                // 微调,环心切换/平滑的视觉跳动被结构性消掉。主球钉原点,
                // 环罩住主球(原点在环内)⇒ 判别式恒正、正根恒存在。
                // ⚠️ 射线端点一律锁 beltPredPos(07-08 用户"动的时候一步
                // 到位":实时位置会让弧追着 folder 飘移滑 19°/7s;先改
                // 混合帧后仍剩翻静慢爬期 3.5° 慢漂 —— 干脆全锁影子终局,
                // spawn 占位=当刻实时、ready 后=终局,下次交互才刷新。
                // 弧从锁定那刻起纹丝不动,陨石直飞;终态弧位与真实停位
                // 差 ~3.5° 用户接受[丝滑>精确])
                let f = beltPredPos.count == nh
                    ? beltPredPos[s] : beltTmpNow[s]
                let fl = simd_length(f)
                let u = fl > 1e-4 ? f / fl : SIMD2<Float>(1, 0)
                let b = simd_dot(u, rc)
                let disc = max(b * b - simd_length_squared(rc)
                    + ringRad * ringRad, 0)
                let p = u * (b + sqrt(disc)) - rc
                beltTmpPol[s] = atan2(p.y, p.x)
            }
            // 每 tick 混合帧裁剪 + 每家一次的家位仿射参数
            carveBeltSegs()
            if beltFamBase.count != nh {
                beltFamBase = .init(repeating: 0, count: nh)
                beltFamSlope = .init(repeating: 1, count: nh)
                beltFamSel = .init(repeating: 0, count: nh)
            }
            for s in 0..<nh {
                let segs = beltPredSegs[s]
                let fw = max(beltFamW[s], 0.05)
                guard !segs.isEmpty else {
                    beltFamBase[s] = 0; beltFamSlope[s] = 1; continue
                }
                // 整家选**一个最佳自由段**(边际五修用户法则:"同一个球
                // 的陨石必须连贯"):容量够 2×家宽的段里选离自家方位(0)
                // 最近的;黏滞加分防 tick 间乒乓换段
                var best = segs[0]
                if segs.count > 1 {
                    var bestScore = -Float.greatestFiniteMagnitude
                    for (l, h) in segs {
                        let dist = l > 0 ? l : (h < 0 ? -h : 0)
                        var score = min(h - l, 2 * fw) * 2 - dist
                        if beltFamSel[s] >= l, beltFamSel[s] <= h { score += fw * 0.8 }
                        if score > bestScore { bestScore = score; best = (l, h) }
                    }
                }
                let (lo, hi) = best
                beltFamSel[s] = (lo + hi) / 2
                // 单段规则(与旧逐球代码等价的仿射形):装得下整体平移
                // 贴自家方位;装不下线性压缩(密而不断)
                var base: Float = 0
                var slope: Float = 1
                if 2 * fw <= hi - lo {
                    base = min(max(0, lo + fw), hi - fw)
                } else {
                    base = (lo + hi) / 2
                    slope = (hi - lo) / (2 * fw)
                }
                // 积压微调(07-03 用户拍板:"有积压就再往反方向转一点")
                let lossR = max(0, fw - hi)
                let lossL = max(0, fw + lo)
                base += min(max((lossL - lossR) * 0.08, -0.12), 0.12)
                beltFamBase[s] = base
                beltFamSlope[s] = slope
            }
            let carrying = beltForming   // ① 生成态才携带;③ 松手后纯弹簧
            // 待命(07-08 用户"可接受延迟,动则一步到位"+"出场跳两次"):
            // 影子结果未到时陨石零力待命 —— 不朝占位/临时目标起跑,等
            // 终局锁定后一次性直飞/绽放,全程不改道。**开场也待命**
            // (原先临时环+ready 正式环 = 环钉两次 → 陨石先朝临时弧位
            // 飞再改道 = 两跳;待命后头几帧只被爆炸力推散,一跳成型)。
            // 穿透标记清掉(待命=实体,参与碰撞)
            if !shadowDone {
                for bi in 0..<beltIdx.count {
                    nodeTransit[Int(beltIdx[bi])] = false
                }
                beltTransitAny = false
                for s in 0..<nh { hubPrev[s] = beltTmpNow[s] }
                return
            }
            var transitAny = false
            let measureArrive = beltReveal < 1 && !beltRevealGo
            pos.withUnsafeMutableBufferPointer { P in
            vel.withUnsafeMutableBufferPointer { V in
                for bi in 0..<beltIdx.count {
                    let i = Int(beltIdx[bi])
                    let s = Int(beltHubSlot[bi])
                    // 帧携带(仅生成态):绕**环心**刚体公转(家位是环心
                    // 极坐标,随自家 hub 相对环心的角增量走;半径差由
                    // 弹簧修正)
                    if carrying {
                        let p0 = P[i] - rc
                        P[i] = rc + SIMD2<Float>(
                            p0.x * beltTmpC[s] - p0.y * beltTmpS[s],
                            p0.x * beltTmpS[s] + p0.y * beltTmpC[s])
                    }
                    // 家位角装进可用弧:每家的选段/平移/压缩/积压微调已
                    // 在球循环外算成仿射参数,这里只查表
                    let a = beltFamBase[s] + beltFamSlope[s] * beltAng[bi]
                    let homeAng = beltTmpPol[s] + a
                    // 目标 = 环心极坐标大圆上的点(全场唯一环:半径 =
                    // 一次算死的 ringR + 该球径向偏移,拖动不变)
                    let rr = ringRad + beltRing[bi]
                    var target = rc + SIMD2<Float>(cos(homeAng), sin(homeAng)) * rr
                    // 家位投影出**实时**气泡(07-03 边际bug:大球被拖到环带
                    // 上回不去老家,预测没料到 → 家位埋在它圆里,回位弹簧
                    //(带增益)与滑出限速打平,净位移≈0 被 park 冻在圆内。
                    // 目标本身挪到圆外缘,弹簧和滑出不再打架)
                    for jj in 0..<nh {
                        guard hubBubbleR[jj] > 0 else { continue }
                        let dv = target - beltTmpNow[jj]
                        let dist = simd_length(dv)
                        let minD = hubBubbleR[jj] + nodeRadius[i] + 2
                        if dist < minD {
                            let dir = dist > 1e-4 ? dv / dist : SIMD2<Float>(1, 0)
                            target = beltTmpNow[jj] + dir * minD
                        }
                    }
                    // 极坐标弹簧(用户定稿:先到半径、再旋转,两个动作一起
                    // 做):把"到目标"的位移拆成**径向**(到对应环半径)+
                    // **切向**(绕环心旋转到对应角),两分量同时施力 —— 陨石沿
                    // 弧螺旋到位,不再切弦穿过环内部("直接换位"不好看)。
                    // 增量小步 + 每 tick 按新位置重算方向 = 天然沿弧,无需大
                    // 角度精确公式。参考系 = 环心 rc。
                    let relC = P[i] - rc
                    let rCur = simd_length(relC)
                    let relT = target - rc
                    let disp: SIMD2<Float>
                    if rCur > 1e-3 {
                        let radialDir = relC / rCur
                        let tangDir = SIMD2<Float>(-radialDir.y, radialDir.x)
                        var dth = atan2(relT.y, relT.x) - atan2(relC.y, relC.x)
                        while dth > .pi { dth -= 2 * .pi }
                        while dth < -.pi { dth += 2 * .pi }
                        var dr = simd_length(relT) - rCur
                        var arc = rCur * dth
                        // 缓滑胡萝卜(07-08 用户"幅度有点大":只在成型后的
                        // 调整移动限距 —— 远目标只追近端假目标,匀速贴弧
                        // 缓滑;顺带距离增益 boost 因 dLen 被封顶自动≈1,
                        // 起飞窗口 ×2.5 仍在但速度有界,快起步不大甩)
                        if !carrying {
                            let ac = GraphConstants.beltGlideArcCap
                            let rc2 = GraphConstants.beltGlideRadialCap
                            arc = max(-ac, min(ac, arc))
                            dr = max(-rc2, min(rc2, dr))
                        }
                        disp = radialDir * dr + tangDir * arc
                    } else {
                        disp = relT   // 退化:恰在环心(几乎不可能),回退笛卡尔
                    }
                    let delta = disp - V[i]
                    // 距离增益(九稿:太远回不去卡半路):>150pt 加力,封顶 ×3
                    //(松手态 ×2.2 排位增益已按用户要求回滚)
                    let dLen = simd_length(delta)
                    let boost = min(1 + dLen / 150, 3)
                    V[i] += delta * (k * boost)
                    // 穿透(十稿):回流途中(>24pt)对碰撞免疫,近终点实体化;
                    // 生成态不穿(绽放本来就要靠碰撞摊开)
                    nodeTransit[i] = !carrying && dLen > 24
                    if nodeTransit[i] { transitAny = true }
                }
            }}
            beltTransitAny = transitAny
            for s in 0..<nh { hubPrev[s] = beltTmpNow[s] }
            // 到位判定("找到位置")= 布局整体定型:hub 全静 && 冷透 &&
            // 净位移窗静止(quietFlag 自带穿透飞行/残余叠压一票否决,陨石
            // 还在飞不会误揭)—— 即"即将 park"的前置条件,结构性保证两条
            // 开局路(init/explode)对称且必然触发。⚠️ 别改回"离目标距离
            // <阈值"判(07-08 首版 15pt 翻车:599 颗挤弧的碰撞平衡位随
            // 种子离几何槽位 12~23pt,阈值内外纯看运气 → 同机开局/刷新
            // 一快一慢;实测 22.4pt 永冻在阈值外只能等超时兜底 9s+)。
            // 单向闩,启动后顶部逻辑每 tick 拉高
            if measureArrive, allStatic,
               alpha < GraphConstants.alphaMin, quietFlag {
                beltRevealGo = true
            }
        }
    }

    /// 重建影子(07-08 影子引擎):同场景新建完整引擎实例,克隆主引擎
    /// 当刻状态,再一次性 warmup 快放 —— 同物理+同初始态 ⇒ 影子终局 =
    /// 真实终局("预判最终隐形圆能到哪"彻底准,取代 12 体幽灵近似)。
    /// 克隆完整性:tick 轨迹由 pos/vel/alpha(target 恒 0,克隆点都在
    /// 松手/开场边沿)/beltForming/nodeTransit/环几何完全决定;
    /// hubPrev/famPrev/quietRef/hubQuietRef 等携带与静止参考让影子自建
    /// (各自有首帧防护,只差一个 tick 的携带,可忽略);brake/quietFlag
    /// 不拷(克隆点都在 reheat 边沿,下 tick 必回 1/false)。tick 路径
    /// 无 Date/random(随机只在 init/explode 播种)⇒ 确定性快放。
    /// 开场(ringDirty)顺带把环直接钉在影子 warmup 后的终局几何上
    /// (一次成型,无过渡)。调用方须持 simLock,只在物理线程调。
    private func spawnShadow(releasedSim: Int = -1) {
        // nh=0 时影子无任何消费方(钉环/carve/beltPredPos 全空转)
        guard !isShadow, !hubIndices.isEmpty else { return }
        let sh = GraphPhysicsEngine(scene: sceneRef, isShadow: true)
        sh.pos = pos
        sh.vel = vel
        if releasedSim >= 0 {
            sh.vel[releasedSim] = .zero   // 预热:模拟"此刻静置松手"
        }
        shadowClonePosPending = releasedSim >= 0 ? pos[releasedSim] : nil
        sh.alpha = alpha
        sh.alphaTarget = 0
        sh.beltForming = beltForming
        sh.nodeTransit = nodeTransit
        sh.ringC = ringC; sh.ringRad = ringRad
        sh.ringTargetC = ringTargetC; sh.ringTargetRad = ringTargetRad
        sh.ringDirty = ringDirty
        // 选段黏滞记忆也克隆(对抗审查:影子从 0 起步时黏滞加分缺失,
        // 两段得分接近的家可能选中与主引擎不同的弧段 —— 离散分叉)
        sh.beltFamSel = beltFamSel
        sh.beltFamBase = beltFamBase
        sh.beltFamSlope = beltFamSlope
        shadowLock.lock()
        shadowGen &+= 1
        let myGen = shadowGen
        shadowReady = false
        shadowLock.unlock()
        shadowDone = false
        // 挡板/弧方位占位:ready 前用**当刻实时位置**(几帧窗口)。
        // 无条件刷新 —— 不能留拖拽前的旧终局,混合帧的弧方位会朝旧
        // 方向飞一两帧(实测首帧毛刺 pol 偏 2+rad)
        beltPredPos = hubIndices.map { pos[Int($0)] }
        // (临时环已删 —— 开场陨石待命到 ready,环只在消费处钉一次
        // = 一跳成型;同时省掉开场同步小跑的物理线程停顿)
        // 后台**全速一口气**跑到 hub 全静(07-08 用户实机"还是卡顿,
        // 隐形图 tick 再快一点":分帧快进每帧仍挤占物理 tick 预算 ——
        // 挪出物理线程零挤占;92~600 步 × ~0.2ms 后台几十 ms 完成)。
        // 实例移交任务线程独占(GCD 派发自带内存屏障),结果经
        // shadowLock 交接;gen 不匹配 = 已被废弃(拖拽/新场景),丢弃。
        // done 判据 = hub 全静(只消费 hub;等全场停会陪 599 颗慢陨石
        // 耗几千步)/冷透+缓停完/步数封顶
        let hubIdx = hubIndices
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let nhh = hubIdx.count
            var steps = 0
            while steps < GraphConstants.shadowTickCap {
                sh.tick()
                steps += 1
                // 交卷判据 = 冷透+静止(quietFlag;07-08 用户"影子再快
                // 一点,延迟变小":等 brake 缓停滑完要多耗 100~200 步,
                // 而那段位移被 brake 缩到几 pt —— 提前交卷,终局差被
                // 死区 35pt 缓冲吸收)。含爬行终点 ≈ 真实停位,ready
                // 锁定后停稳校验几乎必然零动。影子陨石冻结 ⇒ quietFlag
                // 不被陨石阻塞;brake==0/cap 兜底
                if sh.alpha < GraphConstants.alphaMin
                    && (sh.quietFlag || sh.brake == 0) {
                    break
                }
            }
            guard let eng = self else { return }
            var result = [SIMD2<Float>](repeating: .zero, count: nhh)
            for s in 0..<nhh { result[s] = sh.pos[Int(hubIdx[s])] }
            eng.shadowLock.lock()
            if eng.shadowGen == myGen {
                eng.shadowResult = result
                eng.shadowReady = true
            }
            eng.shadowLock.unlock()
        }
    }

    /// 环覆盖死区判断(提前定环与停稳校验共用):以**目标环**测圆集,
    /// 罩得住(≥15pt 余)且不太松(富余 ≤ margin+slack)→ true 环不动;
    /// false = 调用方一次性调到该圆集的最小包围圆。调用方须持 simLock。
    /// ⚠️ 下限必须与 carve 触发线拉开实缓冲:挡板够到环带的条件是余量
    /// <4pt(bLo=ringRad+4、bT=bubbleR+8),下限取 5 时只隔 1pt —— 校验
    /// 以薄余量判"罩得住"零动后,hub 慢爬 1~2pt 即越线触发最大家自挖,
    /// 弧偏 90°+(after-drag F0 实测 −1.64rad)。15 = 慢爬幅度 + lerp
    /// 未收敛瞬态的实缓冲;开场幽灵误差 −2~+19 → 余量 16~37 仍全落
    /// 死区 = 零跳行为不变。
    private func ringCovered(_ cs: [SIMD2<Float>], _ rs: [Float]) -> Bool {
        var need: Float = 0
        for i in 0..<cs.count {
            need = max(need, simd_length(cs[i] - ringTargetC) + rs[i])
        }
        return need <= ringTargetRad - 10
            && ringTargetRad - need <= GraphConstants.ringPredMargin
                + GraphConstants.ringSlack
    }

    /// 环的包围对象集合:主球圆(原点,mainRadius)+ 全部 folder 隐形圆
    /// (hub 位置由 hubAt 给出 —— 实时/幽灵终局两用,半径 hubBubbleR;
    /// 无气泡的 hub 用球半径兜底)。调用方须持 simLock。
    private func enclosureCircles(hubAt: (Int) -> SIMD2<Float>)
        -> ([SIMD2<Float>], [Float]) {
        var cs: [SIMD2<Float>] = [.zero]
        var rs: [Float] = [nodeRadius[0]]
        for s in 0..<hubIndices.count {
            cs.append(hubAt(s))
            rs.append(hubBubbleR[s] > 0 ? hubBubbleR[s]
                                        : nodeRadius[Int(hubIndices[s])])
        }
        return (cs, rs)
    }

    /// 最小包围圆(罩住一组圆,确定性,O(n³) 枚举;n ≤ 12 微秒级)。
    /// 候选 = 单圆 / 圆对张成的跨圆(直径圆)/ 三圆 Apollonius 外包圆
    /// (|c−cᵢ|+rᵢ=R 三式两两相减线性化 → x,y 是 d₁ 的线性函数,回代得
    /// 二次方程);取覆盖全部输入圆的最小候选。internal:harness 复用。
    static func minEnclosingCircle(centers: [SIMD2<Float>], radii: [Float])
        -> (center: SIMD2<Float>, radius: Float) {
        let n = centers.count
        guard n > 0 else { return (.zero, 0) }
        let cx = centers.map { Double($0.x) }
        let cy = centers.map { Double($0.y) }
        let r = radii.map(Double.init)
        var bestC = SIMD2<Double>(cx[0], cy[0])
        var bestR = Double.greatestFiniteMagnitude
        func covers(_ c: SIMD2<Double>, _ R: Double) -> Bool {
            let eps = R * 1e-4 + 1e-3
            for i in 0..<n {
                let dx = cx[i] - c.x, dy = cy[i] - c.y
                if (dx * dx + dy * dy).squareRoot() + r[i] > R + eps { return false }
            }
            return true
        }
        func consider(_ c: SIMD2<Double>, _ R: Double) {
            if R < bestR, R.isFinite, covers(c, R) { bestC = c; bestR = R }
        }
        // 单圆(某圆已罩住其余全部)
        for i in 0..<n { consider(SIMD2<Double>(cx[i], cy[i]), r[i]) }
        // 圆对:两圆的公共外包圆(圆心在连线上,直径 = d + rᵢ + rⱼ)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = cx[j] - cx[i], dy = cy[j] - cy[i]
                let d = (dx * dx + dy * dy).squareRoot()
                let R = (d + r[i] + r[j]) / 2
                if d < 1e-9 { continue }   // 同心:单圆候选已覆盖
                let t = (R - r[i]) / d
                consider(SIMD2<Double>(cx[i] + dx * t, cy[i] + dy * t), R)
            }
        }
        // 三圆:解 |c−cᵢ| + rᵢ = R(i = p,q,w)。以 p 为基准,q/w 两式减
        // p 式消去二次项:2(xₘ−xₚ)x + 2(yₘ−yₚ)y + 2(rₚ−rₘ)d₁ = Kₘ,
        // 其中 d₁ = |c−cₚ|,Kₘ = xₘ²+yₘ²−xₚ²−yₚ² − (rₚ−rₘ)²。
        // 2×2 解出 x,y 为 d₁ 的线性式,回代 (x−xₚ)²+(y−yₚ)² = d₁²。
        for p in 0..<n {
            for q in (p + 1)..<n {
                for w in (q + 1)..<n {
                    let a11 = 2 * (cx[q] - cx[p]), a12 = 2 * (cy[q] - cy[p])
                    let a21 = 2 * (cx[w] - cx[p]), a22 = 2 * (cy[w] - cy[p])
                    let det = a11 * a22 - a12 * a21
                    if abs(det) < 1e-9 { continue }   // 共线:圆对候选兜底
                    let dq = r[p] - r[q], dw = r[p] - r[w]
                    let kq = cx[q] * cx[q] + cy[q] * cy[q]
                        - cx[p] * cx[p] - cy[p] * cy[p] - dq * dq
                    let kw = cx[w] * cx[w] + cy[w] * cy[w]
                        - cx[p] * cx[p] - cy[p] * cy[p] - dw * dw
                    // x = X0 + X1·d₁, y = Y0 + Y1·d₁(Cramer,右端拆常数/d₁ 项)
                    let x0 = (kq * a22 - kw * a12) / det
                    let x1 = (-2 * dq * a22 + 2 * dw * a12) / det
                    let y0 = (a11 * kw - a21 * kq) / det
                    let y1 = (-a11 * 2 * dw + a21 * 2 * dq) / det
                    let ex = x0 - cx[p], ey = y0 - cy[p]
                    let qa = x1 * x1 + y1 * y1 - 1
                    let qb = 2 * (ex * x1 + ey * y1)
                    let qc = ex * ex + ey * ey
                    if abs(qa) < 1e-12 {
                        if abs(qb) > 1e-12 {
                            let d1 = -qc / qb
                            if d1 >= 0 {
                                consider(SIMD2<Double>(x0 + x1 * d1, y0 + y1 * d1),
                                         d1 + r[p])
                            }
                        }
                        continue
                    }
                    let disc = qb * qb - 4 * qa * qc
                    if disc < 0 { continue }
                    let sq = disc.squareRoot()
                    for d1 in [(-qb - sq) / (2 * qa), (-qb + sq) / (2 * qa)]
                    where d1 >= 0 {
                        consider(SIMD2<Double>(x0 + x1 * d1, y0 + y1 * d1),
                                 d1 + r[p])
                    }
                }
            }
        }
        if bestR == Double.greatestFiniteMagnitude {
            // 数值极端兜底(理论上不可达:MEC 由 ≤3 个支撑圆决定,候选必含)
            var c = SIMD2<Double>.zero
            for i in 0..<n { c += SIMD2<Double>(cx[i], cy[i]) }
            c /= Double(n)
            var R = 0.0
            for i in 0..<n {
                let dx = cx[i] - c.x, dy = cy[i] - c.y
                R = max(R, (dx * dx + dy * dy).squareRoot() + r[i])
            }
            bestC = c; bestR = R
        }
        return (SIMD2<Float>(Float(bestC.x), Float(bestC.y)), Float(bestR))
    }

    /// 预加载隐形环(07-09 用户"随机种子预加载:打开界面前就知道该去哪"):
    /// 给定种子,起一个**不带线程、不发影子**的 headless 影子实例,自身
    /// 全速 tick 到收敛,按主引擎 explode 后钉环的**同一公式**算出隐形环
    /// (encR + beltGap + ringPredMargin)。reload 在后台 Task 里显示界面
    /// 前调用(几十 ms),相机开局即按此取景 —— 保留随机布局的变化,又
    /// 因"提前知道终局"不闪。
    ///
    /// 一致性:isShadow init 的初态(explosionPositions(seed) + seedPhase +
    /// seedLeafAngles)与主引擎 explode(seed) 完全相同,确定性 tick ⇒ 收敛
    /// 到同一 hub 布局 ⇒ 同一 MEC ⇒ 预加载环 == 可见引擎最终钉的环。
    /// 无 belt(portrait)返回 nil(无环可框)。收敛判据同 spawnShadow。
    public static func preloadRing(scene: GraphScene, seed: UInt64)
        -> (center: SIMD2<Float>, radius: Float)? {
        guard scene.nodes.contains(where: { $0.beltTier != nil }) else { return nil }
        let sh = GraphPhysicsEngine(scene: scene, seed: seed, isShadow: true)
        guard !sh.hubIndices.isEmpty else { return nil }
        var steps = 0
        while steps < GraphConstants.shadowTickCap {
            sh.tick(); steps += 1
            if sh.alpha < GraphConstants.alphaMin && (sh.quietFlag || sh.brake == 0) {
                break
            }
        }
        let (cs, rs) = sh.enclosureCircles(hubAt: { sh.pos[Int(sh.hubIndices[$0])] })
        let (c, encR) = minEnclosingCircle(centers: cs, radii: rs)
        return (c, encR + Float(GraphConstants.beltGap) + GraphConstants.ringPredMargin)
    }

    /// 每 tick 动态弧裁剪(单环重构:参考系 = 环心)。每家占环上一段弧,
    /// 弧中心 = 自家 hub 绕环心的实时极角;挡板 = **真正与环带相交**的圆
    /// (全部气泡 + 主球圆):|dist(挡板心,环心) − 环带中径| 落在带内才
    /// 裁,余弦定理算相交角挖洞 —— 稳态环罩住一切时没有圆碰得到带,
    /// 不裁 = 干净整圆;只有被拖出/罩不住的圆才裁那个扇区。
    /// 挡板位置按静动选帧(保留):**静止(准静态)hub 用实时位置**,
    /// **移动中 hub 用影子当前位置**(快进领先 = 计划位;开场全员疾飞
    /// = 纯预判仍"一次变好",预判失准会在该 hub 停下时被实时位置自动
    /// 纠正)。
    /// rel 一律相对**实时自家绕环心极角**(与放置同帧)。自家气泡照样
    /// 算挡板:被拖出环外时自家弧位被自家圆吞掉,挖洞让弧绕开。
    /// nh² 三角/tick ≤144 忽略不计。
    private func carveBeltSegs() {
        let nh = hubIndices.count
        guard nh > 0 else { return }
        if beltPredSegs.count != nh {
            beltPredSegs = .init(repeating: [(-2.98, 2.98)], count: nh)
        }
        let havePred = beltPredPos.count == nh
        let rc = ringC
        let gapF = Float(GraphConstants.beltGap)
        for s in 0..<nh {
            guard beltFamReach[s] > 0 else { continue }   // 无陨石家不用
            let polar = beltTmpPol[s]   // 实时自家绕环心极角(与放置同帧)
            // 环带(绕环心):内缘 ringR+gap(层基线从 beltGap 起)、
            // 外缘 ringR+最大偏移,中径取范围中值
            let bLo = ringRad + gapF - 6
            let bHi = ringRad + beltFamReach[s] + 20
            let rB = ringRad + (gapF + beltFamReach[s]) * 0.5
            var segs: [(Float, Float)] = [(-2.98, 2.98)]
            // 挡板 = 主球圆(t = -1,恒静钉原点)+ 全部气泡圆
            for t in -1..<nh {
                let pt: SIMD2<Float>
                let bT: Float
                if t < 0 {
                    pt = .zero
                    bT = nodeRadius[0] + 8
                } else {
                    guard hubBubbleR[t] > 0 else { continue }
                    // 一律锁影子终局(07-08"一步到位":静 hub 用实时会随
                    // 慢爬微调 segs → base 波动;锁定后 carve 输入恒定 →
                    // 弧稳定。真实停位与终局差>缓冲时由投影/滑出硬保证兜底
                    pt = havePred ? beltPredPos[t] : beltTmpNow[t]
                    bT = hubBubbleR[t] + 8
                }
                let relP = pt - rc
                let dT = max(simd_length(relP), 1)
                // 径向带门控:挡板圆够不着环带 → 不裁(稳态全员如此)
                if dT + bT < bLo || dT - bT > bHi { continue }
                // 洞宽 = 挡板圆与环带中径的真实相交角半宽(余弦定理)。
                // 中径够不着但带边够得着(只擦内/外层)→ 在挡板触及的
                // 带边 rEff = clamp(dT, 内缘, 外缘) 完整挖洞,弧提前绕开
                let cosRB = (dT * dT + rB * rB - bT * bT) / (2 * dT * rB)
                let w: Float
                if cosRB >= 1 {
                    let rEff = min(max(dT, bLo), bHi)
                    let cosE = (dT * dT + rEff * rEff - bT * bT) / (2 * dT * rEff)
                    if cosE >= 1 { continue }   // rEff 也够不着 = 真没挡,不裁
                    w = acos(max(cosE, -1))
                } else {
                    w = acos(max(cosRB, -1))
                }
                var rel = atan2(relP.y, relP.x) - polar
                while rel > .pi { rel -= 2 * .pi }
                while rel < -.pi { rel += 2 * .pi }
                // 区间减法:从自由段里挖掉 [rel-w, rel+w]
                var out: [(Float, Float)] = []
                for (l, h) in segs {
                    if rel + w <= l || rel - w >= h { out.append((l, h)); continue }
                    if rel - w - l >= 0.1 { out.append((l, rel - w)) }
                    if h - (rel + w) >= 0.1 { out.append((rel + w, h)) }
                }
                segs = out
                if segs.isEmpty { break }
            }
            if segs.isEmpty { segs = [(-0.15, 0.15)] }   // 全堵:留最小窗
            beltPredSegs[s] = segs
        }
    }

    /// 气泡碰撞(07-02 气泡重构):每个 hub 携带一个隐形圆(半径=builder
    /// 按内容面积算出),圆与圆、圆与主球在速度域互相推开 —— 「圆间零
    /// 重叠」的物理表达;硬解算在 centerAndIntegrate 兜底。角度排布由
    /// 碰撞平衡涌现。h ≤ ~11,O(h²) 忽略不计。碰撞型力不乘 alpha。
    private func bubblePass() {
        let h = hubIndices.count
        guard h > 0 else { return }
        let k = GraphConstants.bubbleCollideStrength
        let mainR = nodeRadius[0]
        dragLock.lock()
        let di = draggedIndex
        dragLock.unlock()
        for ii in 0..<h {
            guard hubBubbleR[ii] > 0 else { continue }
            let i = Int(hubIndices[ii])
            // 拖拽中被拖 hub 碰撞箱=球本身(07-08 用户:"想玩拖动时蓝球
            // 穿插在灰球丛中"):隐形圆对它全关(不推别家、不被推、不挡
            // 主球),球级碰撞(forceCollide+扫掠胶囊)让它在别家叶丛里
            // 排开穿行;松手 di 消失即恢复圆级,重叠由硬解算平滑分开
            // 圆 vs 主球(主球钉死,只推 hub)
            if i != di {
                let p = pos[i]
                let d = simd_length(p)
                let minD = mainR + hubBubbleR[ii] + hubMainClear[ii]
                if d < minD, d > 1e-4 {
                    // 缓分限速(07-08"松手慢慢移开"):成型后**深**重叠(只可能
                    // 来自拖拽)的推出速度封顶,不再按重叠深度全量踹开;
                    // 浅重叠走原全量(常态接触平衡,限了会永动微振静不下来)
                    var ov = minD - d
                    if !beltForming, ov > GraphConstants.bubbleEaseDeepOverlap {
                        ov = GraphConstants.bubbleEaseVelCap
                        // 杀闭合速度:弹簧(冷却地板 0.1 恒在)把 hub 压向
                        // 主球的分量若不消,~20pt/tick 碾过封顶推出,分离
                        // 卡死在半路(实测 112pt 定格等 restless 兜底)
                        let u = p / d
                        let closing = simd_dot(vel[i], u)
                        if closing < 0 { vel[i] -= u * closing }
                    }
                    vel[i] += p / d * (ov * k)
                }
            }
            // 圆 vs 圆(重的动得少)
            for jj in (ii + 1)..<h {
                guard hubBubbleR[jj] > 0 else { continue }
                let j = Int(hubIndices[jj])
                if i == di || j == di { continue }
                var dv = pos[j] - pos[i]
                var dist = simd_length(dv)
                if dist < 1e-4 { dv = SIMD2<Float>(1e-3, 0); dist = 1e-3 }
                let need = hubBubbleR[ii] + hubBubbleR[jj] + 2
                if dist < need {
                    // 缓分限速(同上):深重叠封顶,浅重叠全量
                    var ov = need - dist
                    let wi = hubMass[jj] / (hubMass[ii] + hubMass[jj])
                    if !beltForming, ov > GraphConstants.bubbleEaseDeepOverlap {
                        ov = GraphConstants.bubbleEaseVelCap
                        // 杀闭合相对速度(按质量权重分摊):否则弹簧压入
                        // 碾过封顶推出,分离半路卡死(见圆-主球分支注释)
                        let u = dv / dist
                        let rv = simd_dot(vel[j] - vel[i], u)
                        if rv < 0 {
                            vel[i] += u * (rv * wi)
                            vel[j] -= u * (rv * (1 - wi))
                        }
                    }
                    let push = ov / dist * k
                    vel[i] -= dv * (push * wi)
                    vel[j] += dv * (push * (1 - wi))
                }
            }
        }
    }

    // MARK: - Barnes-Hut 四叉树(P0 spike 验证:vs O(n²) 暴力误差中位 0.79%)

    private func allocateTree() {
        let cap = 4 * max(n, 1) + 64
        qChild = .init(repeating: -1, count: 4 * cap)
        qMass = .init(repeating: 0, count: cap)
        qCom = .init(repeating: .zero, count: cap)
        qWidth = .init(repeating: 0, count: cap)
        qMaxR = .init(repeating: 0, count: cap)
        nextPoint = .init(repeating: -1, count: max(n, 1))
    }

    private func buildTree() {
        var lo = pos[0], hi = pos[0]
        for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let side = max(hi.x - lo.x, hi.y - lo.y) + 1e-3
        let rootCenter = (lo + hi) * 0.5
        self.rootCenter = rootCenter
        self.rootHalf = side * 0.5
        qCount = 1
        for i in 0..<4 { qChild[i] = -1 }
        qWidth[0] = side
        for i in 0..<n { nextPoint[i] = -1 }

        pos.withUnsafeBufferPointer { P in
        qChild.withUnsafeMutableBufferPointer { ch in
        qWidth.withUnsafeMutableBufferPointer { wid in
            for pi in 0..<n {
                // 影子瘦身(07-08"松手后巨卡"):陨石(599/962)对 hub 终局
                // 影响微乎其微,却占 BH/碰撞大头 —— 影子里不进树(manyBody
                // /collide 都走树,一刀两断),单 tick 成本 −60%
                if isShadow && nodeBelt[pi] { continue }
                let p = P[pi]
                var node = 0
                var center = rootCenter
                var half = side * 0.5
                var depth = 0
                while true {
                    let q = (p.x >= center.x ? 1 : 0) | (p.y >= center.y ? 2 : 0)
                    let slot = node * 4 + q
                    let c = ch[slot]
                    if c == -1 {                       // 空位 → 放叶子
                        ch[slot] = Int32(-pi - 2)
                        break
                    } else if c >= 0 {                 // 内部节点 → 下潜
                        node = Int(c)
                        center.x += (p.x >= center.x ? half : -half) * 0.5
                        center.y += (p.y >= center.y ? half : -half) * 0.5
                        half *= 0.5
                        depth += 1
                    } else {                           // 已有叶子 → 分裂或串链
                        let other = Int(-c - 2)
                        if depth >= 26 || P[other] == p {
                            nextPoint[pi] = nextPoint[other]   // 重合点串链
                            nextPoint[other] = Int32(pi)
                            break
                        }
                        let newNode = qCount; qCount += 1
                        for k in 0..<4 { ch[newNode * 4 + k] = -1 }
                        wid[newNode] = half
                        ch[slot] = Int32(newNode)
                        let subCenter = SIMD2<Float>(
                            center.x + (p.x >= center.x ? half : -half) * 0.5,
                            center.y + (p.y >= center.y ? half : -half) * 0.5)
                        let oq = (P[other].x >= subCenter.x ? 1 : 0)
                            | (P[other].y >= subCenter.y ? 2 : 0)
                        ch[newNode * 4 + oq] = Int32(-other - 2)
                        node = newNode
                        center = subCenter
                        half *= 0.5
                        depth += 1
                    }
                }
            }
        }}}

        // 自底向上聚合电荷/质心/子树最大球半径(子节点 index 恒大于父,倒序扫)
        qChild.withUnsafeBufferPointer { ch in
        qMass.withUnsafeMutableBufferPointer { M in
        qCom.withUnsafeMutableBufferPointer { C in
        qMaxR.withUnsafeMutableBufferPointer { MR in
        nodeRadius.withUnsafeBufferPointer { R in
        nodeCharge.withUnsafeBufferPointer { NC in
        pos.withUnsafeBufferPointer { P in
            for node in stride(from: qCount - 1, through: 0, by: -1) {
                var m: Float = 0
                var com = SIMD2<Float>.zero
                var mr: Float = 0
                for k in 0..<4 {
                    let c = ch[node * 4 + k]
                    if c == -1 { continue }
                    if c >= 0 {
                        let cm = M[Int(c)]
                        m += cm
                        com += C[Int(c)] * cm
                        mr = max(mr, MR[Int(c)])
                    } else {
                        var pi = Int(-c - 2)
                        while pi >= 0 {
                            let q = NC[pi]
                            m += q
                            com += P[pi] * q
                            mr = max(mr, R[pi])
                            pi = Int(nextPoint[pi])
                        }
                    }
                }
                M[node] = m
                C[node] = m != 0 ? com / m : .zero
                MR[node] = mr
            }
        }}}}}}}
    }

    /// ⚠️ 只有 hub 接收斥力(07-02 用户定稿:"小球不应受主球和其他
    /// folder 球引力影响,这是关键点")—— 叶子的一切定位来自自家系统
    ///(径向弹簧/家内碰撞/家内匀布/圈内夹钳),隔空电荷只会把整团云
    /// 拽偏(F1/F2 质心偏移 23~27% 的最后来源)。接收方 962→~11,
    /// 顺带物理大幅降载。叶子仍作为电荷源参与树(推开 hub 无妨)。
    private func manyBodyPass() {
        let a = alpha
        let theta2 = GraphConstants.bhTheta2
        let dMin2 = GraphConstants.bhDistanceMin2
        var stack = [Int32](repeating: 0, count: 256)
        nodeCharge.withUnsafeBufferPointer { NC in
        pos.withUnsafeBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        qChild.withUnsafeBufferPointer { ch in
        qMass.withUnsafeBufferPointer { M in
        qCom.withUnsafeBufferPointer { C in
        qWidth.withUnsafeBufferPointer { W in
        nextPoint.withUnsafeBufferPointer { NP in
        stack.withUnsafeMutableBufferPointer { S in
            for hi in 0..<hubIndices.count {
                let i = Int(hubIndices[hi])
                let p = P[i]
                var f = SIMD2<Float>.zero
                var sp = 0
                S[0] = 0; sp = 1
                while sp > 0 {
                    sp -= 1
                    let node = Int(S[sp])
                    let d = C[node] - p
                    let dist2 = max(simd_length_squared(d), 1e-9)
                    let w = W[node]
                    if w * w < theta2 * dist2 {        // 足够远 → 整簇当一个质点
                        let d2 = max(dist2, dMin2)
                        f += d * (M[node] * a / d2)
                        continue
                    }
                    for k in 0..<4 {
                        let c = ch[node * 4 + k]
                        if c == -1 { continue }
                        if c >= 0 { S[sp] = c; sp += 1 }
                        else {
                            var pi = Int(-c - 2)
                            while pi >= 0 {
                                if pi != i {
                                    let dd = P[pi] - p
                                    let dl2 = max(simd_length_squared(dd), dMin2)
                                    f += dd * (NC[pi] * a / dl2)
                                }
                                pi = Int(NP[pi])
                            }
                        }
                    }
                }
                V[i] += f
            }
        }}}}}}}}}
    }

    private func linkPass() {
        // ⚠️ alpha 下限必须与 sector/angular 诸力一致:那些定位力在冷却尾声
        // 仍存在(floor 0.1),弹簧若纯 alpha 缩放会先睡着 → 叶子被持续推出
        // rest 距离,fan 半径失控(07-02 实机确诊)。力系统要么都睡要么都醒。
        let a = max(alpha, 0.1)
        let e = edgesA.count
        pos.withUnsafeBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        edgesA.withUnsafeBufferPointer { EA in
        edgesB.withUnsafeBufferPointer { EB in
        linkStrength.withUnsafeBufferPointer { LS in
        linkBias.withUnsafeBufferPointer { LB in
        linkRest.withUnsafeBufferPointer { LR in
            for i in 0..<e {
                let s = Int(EA[i]), t = Int(EB[i])
                var d = P[t] + V[t] - P[s] - V[s]
                if d.x == 0 && d.y == 0 { d = SIMD2<Float>(1e-3, 1e-3) }
                let l = simd_length(d)
                let k = (l - LR[i]) / l * a * LS[i]
                let b = LB[i]
                V[t] -= d * (k * b)
                V[s] += d * (k * (1 - b))
            }
        }}}}}}}
    }

    private func centerAndIntegrate() {
        let a = alpha
        let cs = GraphConstants.centerStrength
        let damping = GraphConstants.velocityDamping
        let bk = brake
        pos.withUnsafeMutableBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        nodeCenterScale.withUnsafeBufferPointer { CS in
            for i in 0..<n {
                V[i] += (SIMD2<Float>.zero - P[i]) * (cs * a * CS[i])
                V[i] *= damping
                P[i] += V[i] * bk   // bk = 缓停比例(常态 1,入睡前滑向 0)
            }
        }}}
        // 钉住:主球恒原点;被拖球跟指针(d3 fx/fy 语义)
        pos[0] = .zero
        vel[0] = .zero
        dragLock.lock()
        let di = draggedIndex
        let dt = draggedTo
        dragLock.unlock()
        if let di, di > 0, di < n {
            pos[di] = dt
            vel[di] = .zero
        }
        // 主球碰撞硬约束:斥力是点电荷不认半径,低 weight 小球会在中心区
        // 平衡叠在主球上(2026-07-01 用户实测反馈)。径向推出,含被拖球。
        if n > 1 {
            let mainR = nodeRadius[0]
            let pad = GraphConstants.mainCollisionPadding
            pos.withUnsafeMutableBufferPointer { P in
                for i in 1..<n {
                    let d = simd_length(P[i])
                    let minD = mainR + nodeRadius[i] + pad
                    if d < minD {
                        let dir = d > 1e-4 ? P[i] / d : SIMD2<Float>(1, 0)
                        P[i] = dir * minD
                    }
                }
            }
        }
        // 气泡硬解算(07-02 气泡重构,取代等距钉/角向解算):圆与主球、
        // 圆与圆绝不重叠 —— bubblePass 的速度推开是柔化,这里一锤定音。
        // 3 轮:三圆相切时单轮有 ~4pt 残余(跨家叶碰撞垫子删除后暴露)。
        // 被拖 hub 豁免圆-圆(指针优先),但仍被推出主球。
        if !hubIndices.isEmpty {
            for _ in 0..<3 {
            pos.withUnsafeMutableBufferPointer { P in
                let mainR = nodeRadius[0]
                for ii in 0..<hubIndices.count {
                    guard hubBubbleR[ii] > 0 else { continue }
                    let i = Int(hubIndices[ii])
                    if i == di { continue }   // 拖拽碰撞箱=球本身:主球侧有球级硬约束兜底
                    let d = simd_length(P[i])
                    let minD = mainR + hubBubbleR[ii] + hubMainClear[ii]
                    if d < minD {
                        let dir = d > 1e-4 ? P[i] / d : SIMD2<Float>(1, 0)
                        // 缓分限速(07-08"松手慢慢移开"):成型后深重叠每轮
                        // 纠正封顶,浅重叠全量(见常量注释:限浅会永动微振)
                        var step = minD - d
                        if !beltForming, step > GraphConstants.bubbleEaseDeepOverlap {
                            step = GraphConstants.bubbleEasePosCap
                        }
                        P[i] = dir * (d + step)
                    }
                }
                for ii in 0..<max(hubIndices.count - 1, 0) {
                    guard hubBubbleR[ii] > 0 else { continue }
                    for jj in (ii + 1)..<hubIndices.count {
                        guard hubBubbleR[jj] > 0 else { continue }
                        let i = Int(hubIndices[ii]), j = Int(hubIndices[jj])
                        // 拖拽碰撞箱=球本身(07-08):被拖 hub 的圆不解算 ——
                        // 推土机改球级穿行;松手恢复,重叠对称推开
                        if i == di || j == di { continue }
                        let d = P[j] - P[i]
                        let dist = simd_length(d)
                        let minD = hubBubbleR[ii] + hubBubbleR[jj]
                        if dist < minD {
                            let dir = dist > 1e-4 ? d / dist : SIMD2<Float>(1, 0)
                            // 缓分限速(同上):深重叠每轮纠正封顶慢慢滑开,
                            // 浅重叠全量对称推开
                            var push = (minD - dist) * 0.5
                            if !beltForming,
                               minD - dist > GraphConstants.bubbleEaseDeepOverlap {
                                push = GraphConstants.bubbleEasePosCap
                            }
                            P[i] -= dir * push
                            P[j] += dir * push
                        }
                    }
                }
            }
            }
        }
        // 末端球与**自家** hub 硬碰撞(07-02 定稿:排除外部影响 —— 外家
        // hub 由气泡隔离保证够不着,不再对叶施加任何力)。推叶不推 hub。
        if !leafIndices.isEmpty {
            let pad = GraphConstants.mainCollisionPadding
            pos.withUnsafeMutableBufferPointer { P in
                for li in 0..<leafIndices.count {
                    let leaf = Int(leafIndices[li])
                    let hub = Int(leafOwnHub[li])
                    guard hub > 0 else { continue }
                    let d = P[leaf] - P[hub]
                    let dist = simd_length(d)
                    let minD = nodeRadius[leaf] + nodeRadius[hub] + pad
                    if dist < minD {
                        let dir = dist > 1e-4 ? d / dist : SIMD2<Float>(1, 0)
                        P[leaf] = P[hub] + dir * minD
                    }
                }
            }
        }

        // 圈内夹钳(07-02 气泡重构):dist(leaf, 自家hub) ≤ 气泡半径−叶径
        // —— 叶子绝不出自家隐形圆。⚠️ 放在全部硬约束**之后**:气泡硬
        // 解算会挪 hub,先夹后挪叶子就相对新圆心出圈(实测 +3.3pt 逃逸)。
        // 夹回圈内不会侵入主球/hub 壳:气泡对主球留了「最大叶径+pad」
        // 净空,圆径下限装得下 hub 壳 + 一圈叶。被拖球豁免。
        if !leafIndices.isEmpty {
            pos.withUnsafeMutableBufferPointer { P in
                for li in 0..<leafIndices.count {
                    let leaf = Int(leafIndices[li])
                    if leaf == di { continue }
                    let hub = Int(leafOwnHub[li])
                    // 自家 hub 被拖时豁免(否则追不上的叶被硬按到圆后缘
                    // 挤成一撮);此间重叠由拖拽期全局碰撞阻力兜底
                    if hub == di { continue }
                    let maxD = leafMaxDist[li]
                    guard maxD > 0 else { continue }
                    let d = P[leaf] - P[hub]
                    let dist = simd_length(d)
                    if dist > maxD, dist > 1e-4 {
                        P[leaf] = P[hub] + d / dist * maxD
                    }
                }
            }
        }
        // 陨石滑出隐形圆(07-03 终稿硬要求:"穿过了隐形圆要能滑动到不
        // 穿过的地方")。与九稿"三态无圆力场"的调和:**拖拽期**边界仍 =
        // 球个体(无圆力场)、**穿透回流中**不受阻(否则又卡半路);只有
        // 非拖拽且已实体化的陨石,停在任何气泡里时以每 tick ≤2.5pt
        // 缓速推出 —— 叠加回位弹簧的切向分量 = 贴着圆边"滑"到圈外,
        // 不瞬移。O(陨石×hub)。
        if !beltIdx.isEmpty, !hubIndices.isEmpty, di == nil {
            pos.withUnsafeMutableBufferPointer { P in
                for bi in 0..<beltIdx.count {
                    let i = Int(beltIdx[bi])
                    if nodeTransit[i] { continue }
                    for jj in 0..<hubIndices.count {
                        guard hubBubbleR[jj] > 0 else { continue }
                        let h = Int(hubIndices[jj])
                        let d = P[i] - P[h]
                        let dist = simd_length(d)
                        let minD = hubBubbleR[jj] + nodeRadius[i] + 1
                        if dist < minD {
                            let dir = dist > 1e-4 ? d / dist : SIMD2<Float>(1, 0)
                            P[i] += dir * min(minD - dist, 2.5)
                        }
                    }
                }
            }
        }
        // 家族帧携带(07-03 全局化,用户:"连接线刚度被推动时会失效,
        // 需要全局生效"):任何 hub 本 tick 的净位移 —— 拖/被推土机推开/
        // 气泡碰撞挤走/回弹/反推力,不问来源 —— 都按 familyCarry 直接
        // 带给自家圈内叶,残余由弹簧回弹。被拖 hub 走同一条路(原拖拽
        // 特例已删,避免双重携带)。陨石不带(三态另有携带/弹簧机制)。
        familyCarryPass()
        // 拖拽硬清障 v2(07-02:速度再快也不叠):
        //   ① 扫掠胶囊 —— 沿「上 tick 钉位 → 本 tick 钉位」线段全程清障,
        //     高速时一 tick 跳几十 pt,点清障会隧穿跳过中间的球;
        //   ② 邻域堆积松解 —— 被推出的球压进旁边球里,速度域阻力追不上,
        //     对胶囊邻域做 2 轮位置级两两推开,当场解干净。
        // O(n) 扫 + 邻域 k²(k≈几十~百),忽略不计。
        if let di, di > 0, di < n {
            let pd = pos[di]
            let rd = nodeRadius[di]
            let pad = GraphConstants.collidePadding
            let prev = dragPrevPos ?? pd
            let seg = pd - prev
            let segLen2 = simd_length_squared(seg)
            dragNbr.removeAll(keepingCapacity: true)
            pos.withUnsafeMutableBufferPointer { P in
                for j in 1..<n where j != di {
                    var t: Float = 0
                    if segLen2 > 1e-8 {
                        t = max(0, min(1, simd_dot(P[j] - prev, seg) / segLen2))
                    }
                    let c = prev + seg * t
                    let d = P[j] - c
                    let dist = simd_length(d)
                    let minD = rd + nodeRadius[j] + pad
                    if dist < minD {
                        let dir = dist > 1e-4 ? d / dist : SIMD2<Float>(1, 0)
                        P[j] = c + dir * minD
                    }
                    if dist < minD + 24 { dragNbr.append(Int32(j)) }
                }
                for _ in 0..<2 {
                    for a in 0..<max(dragNbr.count, 1) - 1 {
                        for b in (a + 1)..<dragNbr.count {
                            let i = Int(dragNbr[a]), j = Int(dragNbr[b])
                            let d = P[j] - P[i]
                            let dist = simd_length(d)
                            let minD = nodeRadius[i] + nodeRadius[j] + pad
                            if dist < minD {
                                let dir = dist > 1e-4 ? d / dist : SIMD2<Float>(1, 0)
                                let push = (minD - dist) * 0.5
                                P[i] -= dir * push
                                P[j] += dir * push
                            }
                        }
                    }
                }
            }
            dragPrevPos = pd
        } else {
            dragPrevPos = nil
        }
    }

    /// 家族帧携带(07-03 全局化):每个 hub 本 tick 的净位移 × familyCarry
    /// 直接加到自家圈内叶位置上,弹簧只收拾剩下的 10% —— 连接线"刚度"
    /// 对拖/推/回弹全部生效。位置域携带,无速度累积,松手无过冲。
    /// 被拖的叶不带(拖拽钉住,带了下 tick 也被钉位覆盖,还会抖一下)。
    private func familyCarryPass() {
        let nh = hubIndices.count
        guard nh > 0, !leafIndices.isEmpty else { return }
        if famPrev.count != nh || famDelta.count != n {
            famPrev = (0..<nh).map { pos[Int(hubIndices[$0])] }
            famDelta = .init(repeating: .zero, count: n)
            return
        }
        let c = GraphConstants.familyCarry
        var any = false
        for s in 0..<nh {
            let h = Int(hubIndices[s])
            let d = pos[h] - famPrev[s]
            famPrev[s] = pos[h]
            // 死区 0.2pt/tick:家级慢环流(~0.13pt/tick)不携带 —— 全量
            // 携带会把家变成准刚体,环流失去叶内阻尼衰减不掉,净位移窗
            // 永不静止,加载 park 13s→40.5s(实测回归);拖/推位移远大于
            // 死区,刚性跟随不受影响
            if simd_length_squared(d) > 0.04 {
                famDelta[h] = d * c
                any = true
            } else {
                famDelta[h] = .zero
            }
        }
        // 生成期不携带(famPrev 照常刷新):开场没有"被推"——第一次拖球
        // 才结束生成态;开场携带只有一个效果 = 叶跟紧后 hub 失去弹簧反拉
        // 阻尼,环流振幅涨过静止阈值,加载 park 13s→39s(实测回归)
        guard any, !beltForming else { return }
        dragLock.lock()
        let di = draggedIndex ?? -1
        dragLock.unlock()
        for li in 0..<leafIndices.count {
            let i = Int(leafIndices[li])
            if i == di { continue }
            let d = famDelta[Int(leafOwnHub[li])]
            if d != .zero { pos[i] += d }
        }
    }

    // MARK: - 静态助手

    private static func linkArrays(scene: GraphScene)
        -> ([Int32], [Int32], [Float], [Float], [Float]) {
        var degree = [Int32](repeating: 0, count: scene.nodes.count)
        for e in scene.edges { degree[e.a] += 1; degree[e.b] += 1 }
        var ea: [Int32] = [], eb: [Int32] = []
        var ls: [Float] = [], lb: [Float] = [], lr: [Float] = []
        ea.reserveCapacity(scene.edges.count); eb.reserveCapacity(scene.edges.count)
        for e in scene.edges {
            ea.append(Int32(e.a)); eb.append(Int32(e.b))
            let da = Float(degree[e.a]), db = Float(degree[e.b])
            // d3 默认:刚度 = 1/min(度数) —— hub 度数大,弹簧软,不被叶子拽爆。
            // hub→主球带 override(1.0):否则 folder 度数几百刚度趋零,被斥力推飞。
            ls.append(e.springStrength.map(Float.init)
                      ?? (1 / min(max(da, 1), max(db, 1))))
            lb.append(da / (da + db))
            lr.append(Float(e.restLength))
        }
        return (ea, eb, ls, lb, lr)
    }

    /// 家内角向匀布 v2(07-02 密度偏半边反馈):按当前极角排序,每叶向
    /// 两侧邻居的角向**中点**回正 —— 左右间隙相等时力归零,局部弛豫
    /// 链式传导,挤的一侧流向疏的一侧,质心自动回到 hub(纯涌现,无
    /// 目标角)。全家适用,排序 O(Σk log k) ≈ 千级,忽略不计。
    private func familySpreadPass() {
        guard !familyRange.isEmpty else { return }
        // 不乘 alpha(07-02 拖后偏斜确诊):它本质是角向空间的碰撞力,
        // 冷却尾声若被 alpha 压小,全力的 forceCollide 会把挤住的球
        // "堵"在原地,拖拽扰动后的偏斜被冻结(实测质心偏移 27~37%)。
        let a: Float = 1
        let k = GraphConstants.familySpreadStrength
        for fam in familyRange {
            let count = fam.hi - fam.lo
            guard count >= 3 else { continue }
            let hp = pos[Int(fam.hub)]
            var items: [(t: Float, leaf: Int32)] = []
            items.reserveCapacity(count)
            var cVec = SIMD2<Float>.zero          // 角向质心(单位向量和)
            for x in fam.lo..<fam.hi {
                let leaf = familyLeaf[x]
                let p = pos[Int(leaf)] - hp
                let t = atan2(p.y, p.x)
                items.append((t, leaf))
                cVec += SIMD2<Float>(cos(t), sin(t))
            }
            items.sort { $0.t < $1.t }
            cVec /= Float(count)
            let cMag = simd_length(cVec)          // 0=角向均匀,→1=全挤一边
            let cAng = atan2(cVec.y, cVec.x)
            let evenGap = 2 * Float.pi / Float(count)
            // 大家(07-02 反馈:叶多的 folder 反而铺不匀):均分角随叶数
            // 变小,邻居间隙差同步变小 → 力趋零。改按**相对失衡**放大
            //(除以均分角,封顶 8×),大家的失衡与小家同力度回正。
            let relBoost = min(1 + 0.03 / evenGap, 8)
            for i in 0..<count {
                let tL = items[(i + count - 1) % count].t
                let tC = items[i].t
                let tR = items[(i + 1) % count].t
                var gapL = tC - tL
                if gapL < 0 { gapL += 2 * .pi }
                var gapR = tR - tC
                if gapR < 0 { gapR += 2 * .pi }
                let delta = (gapR - gapL) * 0.5 * relBoost
                let leaf = Int(items[i].leaf)
                let p = pos[leaf] - hp
                let r = simd_length(p)
                guard r > 1 else { continue }
                let tangent = SIMD2<Float>(-p.y, p.x) / r
                // 局部弛豫(邻居中点) + 全局一阶均衡(从拥挤方向切向散开,
                // sin(φ−质心角) 定方向,质心归零时整项归零)。
                // 只给大家(叶数渐入):小家会被推到对跖点堆成新团(188° 缺口实测)
                let m1w = 0.4 * min(max(Float(count) - 16, 0) / 32, 1)
                let mode1 = cMag * sin(tC - cAng) * m1w
                // 限速 ±0.1 rad:防大家爆冲即可 —— 0.03 会把小家的大步
                // 回正砍没(7 叶家转 90° 需 300+ tick,park 前转不完,189° 缺口实测)
                let push = max(min(delta + mode1, 0.1), -0.1)
                vel[leaf] += tangent * (push * r * k * a)
            }
        }
    }

    /// 家分组 → **径向分层**(07-02 用户定稿:长线球堆一边、短线球堆
    /// 另一边时,角向再均匀整体也显得偏 —— 每一段长度各自做均匀分布):
    /// 每家按线长分位切 1~5 层(≥16 叶才分层),familyRange 的每条 =
    /// 一层,匀布力在层内独立生效 → 每一圈各自均匀。
    private static func familyArrays(scene: GraphScene)
        -> ([Int32], [(hub: Int32, lo: Int, hi: Int)]) {
        var restOf: [Int32: Float] = [:]
        for e in scene.edges where !scene.nodes[e.a].kind.isHub {
            restOf[Int32(e.a)] = Float(e.restLength)
        }
        var byHub: [Int32: [Int32]] = [:]
        // 陨石不参与匀布(07-03):弧带槽位由 beltPass 弹簧管
        for node in scene.nodes
        where !node.kind.isHub && node.hubIndex > 0 && node.beltTier == nil {
            byHub[Int32(node.hubIndex), default: []].append(Int32(node.id))
        }
        var leaf: [Int32] = []
        var ranges: [(hub: Int32, lo: Int, hi: Int)] = []
        for (hub, leaves) in byHub.sorted(by: { $0.key < $1.key })
        where leaves.count >= 3 {
            let sorted = leaves.sorted {
                (restOf[$0] ?? 0, $0) < (restOf[$1] ?? 0, $1)
            }
            let bands = max(1, min(sorted.count / 16, 5))
            let per = sorted.count / bands
            var i = 0
            for b in 0..<bands {
                let hi = b == bands - 1 ? sorted.count : (b + 1) * per
                if hi - i >= 3 {
                    let lo = leaf.count
                    leaf.append(contentsOf: sorted[i..<hi])
                    ranges.append((hub: hub, lo: lo, hi: leaf.count))
                }
                i = hi
            }
        }
        return (leaf, ranges)
    }

    /// 半径感知碰撞力(d3 forceCollide 的零依赖移植,07-02 物理化的核心
    /// 新力):任意两球圆心距 < r_i+r_j+缝 时按重叠深度推开(速度域,
    /// 权重 = 对方半径² 占比,大球稳)。复用 manyBody 的四叉树 + qMaxR
    /// 剪枝,O(n log n);d3 语义:不乘 alpha,重叠永远解算。
    private func collidePass() {
        guard n > 1 else { return }
        let strength = GraphConstants.collideStrength
        let pad = GraphConstants.collidePadding
        var beltPen: Float = 0   // 本 tick 陨石×陨石最大真实穿深(不含 pad)
        // 拖拽中(alphaTarget>0)降到 1 轮:布局本来就在被扰动,多轮解算
        // 白费 tick 预算 —— tick 慢会让被拖球掉帧(07-02 卡顿反馈)。
        let iters = alphaTarget > 0 ? 1 : GraphConstants.collideIterations
        for _ in 0..<iters {
            pos.withUnsafeBufferPointer { P in
            vel.withUnsafeMutableBufferPointer { V in
            nodeRadius.withUnsafeBufferPointer { R in
            nodeFamily.withUnsafeBufferPointer { FAM in
            nodeBelt.withUnsafeBufferPointer { BELT in
            nodeTransit.withUnsafeBufferPointer { TR in
            qChild.withUnsafeBufferPointer { ch in
            qMaxR.withUnsafeBufferPointer { MR in
            nextPoint.withUnsafeBufferPointer { NP in
            cStackNode.withUnsafeMutableBufferPointer { SN in
            cStackCX.withUnsafeMutableBufferPointer { SX in
            cStackCY.withUnsafeMutableBufferPointer { SY in
            cStackHalf.withUnsafeMutableBufferPointer { SH in
                // 家隔离只在**常态**(07-02 用户定稿:重叠必须被阻力挡住,
                // 拖拽扰动期跨家也互为阻力;常态下气泡不相交,隔离无损)
                let isolate = alphaTarget == 0
                for i in 0..<n {
                    let fi = FAM[i]
                    guard fi >= 0 else { continue }   // 只有叶参与(hub 归气泡/硬约束管)
                    if isShadow && BELT[i] { continue }   // 影子瘦身:陨石冻结不碰撞
                    if TR[i] { continue }             // 穿透中(回流陨石)不碰撞
                    let pi = P[i] + V[i]           // 预测位置(d3 语义)
                    let ri = R[i] + pad
                    let ri2 = ri * ri
                    SN[0] = 0; SX[0] = rootCenter.x; SY[0] = rootCenter.y
                    SH[0] = rootHalf
                    var sp = 1
                    while sp > 0 {
                        sp -= 1
                        let node = Int(SN[sp])
                        let cx = SX[sp], cy = SY[sp], h = SH[sp]
                        let reach = ri + MR[node] + pad
                        if pi.x < cx - h - reach || pi.x > cx + h + reach
                            || pi.y < cy - h - reach || pi.y > cy + h + reach { continue }
                        for k in 0..<4 {
                            let c = ch[node * 4 + k]
                            if c == -1 { continue }
                            if c >= 0 {
                                SN[sp] = c
                                SX[sp] = cx + ((k & 1) == 1 ? h : -h) * 0.5
                                SY[sp] = cy + ((k & 2) == 2 ? h : -h) * 0.5
                                SH[sp] = h * 0.5
                                sp += 1
                            } else {
                                var pj = Int(-c - 2)
                                while pj >= 0 {
                                    // 每对一次 + 常态同家隔离(拖拽期全局阻力);
                                    // 陨石×任何叶跨家常开(八稿:拖拽期陨石的
                                    // 边界 = 球个体,靠这条排开;平弧交界同理);
                                    // 穿透中(TR)不碰撞
                                    if pj > i, !TR[pj], FAM[pj] == fi || (!isolate && FAM[pj] >= 0)
                                        || ((BELT[i] || BELT[pj]) && FAM[pj] >= 0) {
                                        let rj = R[pj] + pad
                                        let rsum = ri + rj
                                        var d = pi - (P[pj] + V[pj])
                                        var l2 = simd_length_squared(d)
                                        if l2 < rsum * rsum {
                                            if l2 < 1e-6 {   // 重合:确定性微扰
                                                d = SIMD2<Float>(1e-3, 1e-3)
                                                l2 = simd_length_squared(d)
                                            }
                                            let l = l2.squareRoot()
                                            let push = (rsum - l) / l * strength
                                            let wj = rj * rj / (ri2 + rj * rj)
                                            V[i] += d * (push * wj)
                                            V[pj] -= d * (push * (1 - wj))
                                            if BELT[i], BELT[pj] {
                                                beltPen = max(beltPen, rsum - l - 2 * pad)
                                            }
                                        }
                                    }
                                    pj = Int(NP[pj])
                                }
                            }
                        }
                    }
                }
            }}}}}}}}}}}}}
        }
        beltPenMax = beltPen
    }

    /// 分角色斥力电荷:主球小(硬碰撞管不叠)、hub 中、叶小(圈内间距
    /// 归碰撞力管)—— 07-02 确诊:主球/跨圆叶叶电荷太大把整家叶子压到
    /// 背面半圆。
    private static func chargeArray(scene: GraphScene) -> [Float] {
        scene.nodes.map { node in
            switch node.kind {
            case .main: return GraphConstants.mainBodyStrength
            case .folder, .category: return GraphConstants.manyBodyStrength
            case .eventLeaf, .portraitLeaf: return GraphConstants.leafBodyStrength
            }
        }
    }

    /// 家籍数组:叶 = 自家 hub 下标,主球/hub = -1(跨家碰撞隔离用)。
    private static func familyIdArray(scene: GraphScene) -> [Int32] {
        scene.nodes.map { $0.kind.isHub ? -1 : Int32(max($0.hubIndex, 0)) }
    }

    /// 向心力开关:只有 hub 受向心(把孤岛气泡拉回主球方向);叶=0
    ///(被向心会压成朝主球的半月),主球=0(钉死原点,无所谓)。
    private static func centerScaleArray(scene: GraphScene) -> [Float] {
        scene.nodes.map { $0.kind.isHub && $0.id != 0 ? 1 : 0 }
    }

    /// 非主球 hub 的物理参数(builder 赋值):气泡半径(≤0 = 无)/
    /// 质量(叶数+1)/ 对主球净空(家内最大叶径+pad)。四数组同序对齐。
    private static func hubArrays(scene: GraphScene)
        -> ([Int32], [Float], [Float], [Float]) {
        var leafCount: [Int: Int] = [:]
        var maxLeafR: [Int: Float] = [:]
        for node in scene.nodes where !node.kind.isHub {
            leafCount[node.hubIndex, default: 0] += 1
            maxLeafR[node.hubIndex] = max(maxLeafR[node.hubIndex] ?? 0, Float(node.radius))
        }
        var idx: [Int32] = [], bubble: [Float] = [], mass: [Float] = [], clear: [Float] = []
        for node in scene.nodes where node.kind.isHub && node.id != 0 {
            idx.append(Int32(node.id))
            bubble.append(node.hubBubbleRadius.map(Float.init) ?? -1)
            mass.append(Float(leafCount[node.id] ?? 0) + 1)
            clear.append((maxLeafR[node.id] ?? 0) + GraphConstants.mainCollisionPadding)
        }
        return (idx, bubble, mass, clear)
    }

    /// 陨石带四数组(单环重构,同序对齐):节点下标 / 自家 hub / 径向
    /// 偏移(距环基准 ringR,builder 排好的层距+抖动)/ 槽位角(相对
    /// 自家 hub 绕环心极角)。famW = 每家 max|槽位角|,famReach = 每家
    /// max 偏移(0 = 无陨石)。
    private static func beltArrays(scene: GraphScene)
        -> ([Int32], [Int32], [Float], [Float], [Int32], [Float], [Float]) {
        var i: [Int32] = [], h: [Int32] = [], r: [Float] = [], a: [Float] = []
        var slot: [Int32] = []
        // hubIndices 的枚举序(hubArrays 同款):hub 节点下标 → 槽号
        var slotOf: [Int: Int32] = [:]
        var s: Int32 = 0
        for node in scene.nodes where node.kind.isHub && node.id != 0 {
            slotOf[node.id] = s; s += 1
        }
        var famW = [Float](repeating: 0.2, count: Int(s))
        var famReach = [Float](repeating: 0, count: Int(s))
        for node in scene.nodes {
            guard node.beltTier != nil else { continue }
            let hub = max(node.hubIndex, 0)
            i.append(Int32(node.id))
            h.append(Int32(hub))
            let sl = slotOf[hub] ?? 0
            slot.append(sl)
            let off = Float(node.beltRadialOffset)
            r.append(off)
            a.append(Float(node.beltAngle))
            famW[Int(sl)] = max(famW[Int(sl)], abs(Float(node.beltAngle)))
            famReach[Int(sl)] = max(famReach[Int(sl)], off)
        }
        return (i, h, r, a, slot, famW, famReach)
    }

    /// 全部末端球 + 各自所属 hub(主球=0)+ 圈内硬上限
    ///(= 自家气泡半径 − 叶半径 − 1;自家 hub 无气泡时 ≤0 = 不夹)。
    /// 陨石不算(07-03):它们在圈外,圈内夹钳/叶-hub 硬碰撞都不适用。
    private static func leafArrays(scene: GraphScene) -> ([Int32], [Int32], [Float]) {
        var l: [Int32] = [], h: [Int32] = [], m: [Float] = []
        for node in scene.nodes where !node.kind.isHub && node.beltTier == nil {
            l.append(Int32(node.id))
            let hub = max(node.hubIndex, 0)
            h.append(Int32(hub))
            if let br = scene.nodes[hub].hubBubbleRadius {
                m.append(Float(br - node.radius - 1))
            } else {
                m.append(-1)
            }
        }
        return (l, h, m)
    }

    private static func explosionPositions(n: Int, rng: inout SplitMix64) -> [SIMD2<Float>] {
        let r = GraphConstants.explosionRadius
        var out = (0..<n).map { _ in
            SIMD2<Float>(Float.random(in: -r...r, using: &rng),
                         Float.random(in: -r...r, using: &rng))
        }
        if !out.isEmpty { out[0] = .zero }
        return out
    }
}

/// 确定性 RNG(SplitMix64):同 seed → 同炸开轨迹,布局可复现。
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
