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
final class GraphPhysicsEngine: @unchecked Sendable {

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
    private var alpha: Float = 1
    private var alphaTarget: Float = 0
    /// tick 计数(拖拽降载:重力学隔 tick 跑)。
    private var tickCount: UInt64 = 0
    /// 拖拽钉住:index → 目标位置(每次 drag move 更新;d3 的 fx/fy 语义)。
    /// 主球恒钉原点,不进这个表(单独处理)。
    /// ⚠️ 由 dragLock(不是 simLock)保护:drag(to:) 在 120Hz 指针事件里跑,
    /// 若抢 simLock 会被整个 tick(Debug 下数 ms)阻塞 → 拖拽卡顿。
    /// 锁序纪律:dragLock 与 simLock 绝不嵌套,顺序获取。
    private var draggedIndex: Int? = nil
    private var draggedTo: SIMD2<Float> = .zero
    private let dragLock = NSLock()

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
    let parkEvents: AsyncStream<Bool>

    // MARK: - 初始化

    /// - Parameter seed: 炸开初始位置的随机种子(定值 → 同数据同布局可复现)。
    init(scene: GraphScene, seed: UInt64 = 7) {
        n = scene.nodes.count
        var rng = SplitMix64(seed: seed)
        pos = Self.explosionPositions(n: n, rng: &rng)
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
        // 07-02 终稿:开场 = 物理收敛(从中心炸开,力系统自然摊成圆)。
        // 目标落位/绽放出生已删 —— 布局不再有"成品位",只有平衡态。

        var continuation: AsyncStream<Bool>.Continuation?
        parkEvents = AsyncStream { continuation = $0 }
        parkContinuation = continuation
        allocateTree()   // 必须在全部存储属性就位后(方法调用要求 self 完整)
        seedLeafAngles()
        snapshot = pos

        let t = Thread { [weak self] in self?.loop() }
        t.name = "graph-physics"
        // .userInitiated(不是 .userInteractive):tick 重载(Debug 30Hz
        // 饱和)时不许抢主线程的渲染/手势 —— 被拖球由渲染端钉指针,
        // 物理慢半拍只影响邻居跟随,主线程掉帧才是"卡"(07-02 实测)。
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// 停线程(被替换 / 会话清理时调)。幂等。
    func shutdown() {
        cond.lock()
        shouldRun = false
        cond.signal()
        cond.unlock()
        parkContinuation?.finish()
    }

    // MARK: - 对外操作(任意线程;内部拿锁)

    /// 渲染每帧读:最新位置快照。只等 snapLock(µs 级),不等 tick。
    func readSnapshot() -> [SIMD2<Float>] {
        snapLock.lock(); defer { snapLock.unlock() }
        return snapshot
    }

    var isParked: Bool {
        cond.lock(); defer { cond.unlock() }
        return parkedFlag
    }

    /// 开始拖某个球(index 0 主球由调用方挡掉)。
    func beginDrag(index: Int, at world: SIMD2<Float>) {
        dragLock.lock()
        draggedIndex = index
        draggedTo = world
        dragLock.unlock()
        simLock.lock()
        alphaTarget = GraphConstants.dragAlphaTarget
        if alpha < GraphConstants.dragAlphaTarget { alpha = GraphConstants.dragAlphaTarget }
        simLock.unlock()
        wake()
    }

    /// 120Hz 指针事件热路径:只碰 dragLock(µs 级),绝不等 tick。
    func drag(to world: SIMD2<Float>) {
        dragLock.lock()
        draggedTo = world
        dragLock.unlock()
    }

    func endDrag() {
        dragLock.lock()
        draggedIndex = nil
        dragLock.unlock()
        simLock.lock()
        alphaTarget = 0
        simLock.unlock()
    }

    /// 重新炸开(手动刷新且数据变了 / 换画布新数据)。
    func explode(seed: UInt64 = 7) {
        simLock.lock()
        var rng = SplitMix64(seed: seed)
        pos = Self.explosionPositions(n: n, rng: &rng)
        vel = .init(repeating: .zero, count: n)
        seedLeafAngles()
        alpha = 1
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
            // 家族错相:不同家的 0 号叶别都朝同一方向
            let a = golden * Float(j) + Float(hubIdx) * 0.7
            let maxD = leafMaxDist[li]
            let r = maxD > 0 ? max(maxD * 0.35, nodeRadius[hubIdx] + 6)
                             : nodeRadius[hubIdx] + 12
            pos[leaf] = pos[hubIdx] + SIMD2<Float>(cos(a), sin(a)) * r
        }
    }

    /// 数据轻刷新:节点集合没变(fingerprint 相等),只更新边参数
    /// (rest 每天随 last_occurred 漂移)。**保留位置**,微加热让布局适应。
    func updateScene(_ scene: GraphScene) {
        simLock.lock()
        guard scene.nodes.count == n else { simLock.unlock(); return }   // 防御:调用方保证
        nodeRadius = scene.nodes.map { Float($0.radius) }
        nodeCharge = Self.chargeArray(scene: scene)
        nodeCenterScale = Self.centerScaleArray(scene: scene)
        nodeFamily = Self.familyIdArray(scene: scene)
        (edgesA, edgesB, linkStrength, linkBias, linkRest) = Self.linkArrays(scene: scene)
        (hubIndices, hubBubbleR, hubMass, hubMainClear) = Self.hubArrays(scene: scene)
        (leafIndices, leafOwnHub, leafMaxDist) = Self.leafArrays(scene: scene)
        (familyLeaf, familyRange) = Self.familyArrays(scene: scene)
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
            simLock.lock()
            let cooled = alpha < GraphConstants.alphaMin && alphaTarget == 0
            simLock.unlock()
            dragLock.lock()
            let sleeping = cooled && draggedIndex == nil
            dragLock.unlock()
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
        bubblePass()
        if heavy { familySpreadPass() }   // 匀布是慢整形力,拖拽中隔 tick 足够
        if heavy { collidePass() }
        centerAndIntegrate()
        alpha += (alphaTarget - alpha) * GraphConstants.alphaDecay
        // 早停快照已删(07-02 终稿):布局没有"成品位",冷却到 alphaMin
        // 自然 park —— 开场/收敛全程都是物理,本身即丝滑。
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
        for ii in 0..<h {
            guard hubBubbleR[ii] > 0 else { continue }
            let i = Int(hubIndices[ii])
            // 圆 vs 主球(主球钉死,只推 hub)
            let p = pos[i]
            let d = simd_length(p)
            let minD = mainR + hubBubbleR[ii] + hubMainClear[ii]
            if d < minD, d > 1e-4 {
                vel[i] += p / d * ((minD - d) * k)
            }
            // 圆 vs 圆(重的动得少)
            for jj in (ii + 1)..<h {
                guard hubBubbleR[jj] > 0 else { continue }
                let j = Int(hubIndices[jj])
                var dv = pos[j] - pos[i]
                var dist = simd_length(dv)
                if dist < 1e-4 { dv = SIMD2<Float>(1e-3, 0); dist = 1e-3 }
                let need = hubBubbleR[ii] + hubBubbleR[jj] + 2
                if dist < need {
                    let push = (need - dist) / dist * k
                    let wi = hubMass[jj] / (hubMass[ii] + hubMass[jj])
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
        pos.withUnsafeMutableBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        nodeCenterScale.withUnsafeBufferPointer { CS in
            for i in 0..<n {
                V[i] += (SIMD2<Float>.zero - P[i]) * (cs * a * CS[i])
                V[i] *= damping
                P[i] += V[i]
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
                    let d = simd_length(P[i])
                    let minD = mainR + hubBubbleR[ii] + hubMainClear[ii]
                    if d < minD {
                        let dir = d > 1e-4 ? P[i] / d : SIMD2<Float>(1, 0)
                        P[i] = dir * minD
                    }
                }
                for ii in 0..<max(hubIndices.count - 1, 0) {
                    guard hubBubbleR[ii] > 0 else { continue }
                    for jj in (ii + 1)..<hubIndices.count {
                        guard hubBubbleR[jj] > 0 else { continue }
                        let i = Int(hubIndices[ii]), j = Int(hubIndices[jj])
                        if i == di || j == di { continue }
                        let d = P[j] - P[i]
                        let dist = simd_length(d)
                        let minD = hubBubbleR[ii] + hubBubbleR[jj]
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
                    let maxD = leafMaxDist[li]
                    guard maxD > 0 else { continue }
                    let hub = Int(leafOwnHub[li])
                    let d = P[leaf] - P[hub]
                    let dist = simd_length(d)
                    if dist > maxD, dist > 1e-4 {
                        P[leaf] = P[hub] + d / dist * maxD
                    }
                }
            }
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
            for x in fam.lo..<fam.hi {
                let leaf = familyLeaf[x]
                let p = pos[Int(leaf)] - hp
                items.append((atan2(p.y, p.x), leaf))
            }
            items.sort { $0.t < $1.t }
            for i in 0..<count {
                let tL = items[(i + count - 1) % count].t
                let tC = items[i].t
                let tR = items[(i + 1) % count].t
                var gapL = tC - tL
                if gapL < 0 { gapL += 2 * .pi }
                var gapR = tR - tC
                if gapR < 0 { gapR += 2 * .pi }
                let delta = (gapR - gapL) * 0.5
                let leaf = Int(items[i].leaf)
                let p = pos[leaf] - hp
                let r = simd_length(p)
                guard r > 1 else { continue }
                let tangent = SIMD2<Float>(-p.y, p.x) / r
                vel[leaf] += tangent * (delta * r * k * a)
            }
        }
    }

    /// 家分组(≥3 叶):familyLeaf 连续段 + 每家 (hub, 区间)。
    private static func familyArrays(scene: GraphScene)
        -> ([Int32], [(hub: Int32, lo: Int, hi: Int)]) {
        var byHub: [Int32: [Int32]] = [:]
        for node in scene.nodes where !node.kind.isHub && node.hubIndex > 0 {
            byHub[Int32(node.hubIndex), default: []].append(Int32(node.id))
        }
        var leaf: [Int32] = []
        var ranges: [(hub: Int32, lo: Int, hi: Int)] = []
        for (hub, leaves) in byHub.sorted(by: { $0.key < $1.key })
        where leaves.count >= 3 {
            let lo = leaf.count
            leaf.append(contentsOf: leaves)
            ranges.append((hub: hub, lo: lo, hi: leaf.count))
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
        // 拖拽中(alphaTarget>0)降到 1 轮:布局本来就在被扰动,多轮解算
        // 白费 tick 预算 —— tick 慢会让被拖球掉帧(07-02 卡顿反馈)。
        let iters = alphaTarget > 0 ? 1 : GraphConstants.collideIterations
        for _ in 0..<iters {
            pos.withUnsafeBufferPointer { P in
            vel.withUnsafeMutableBufferPointer { V in
            nodeRadius.withUnsafeBufferPointer { R in
            nodeFamily.withUnsafeBufferPointer { FAM in
            qChild.withUnsafeBufferPointer { ch in
            qMaxR.withUnsafeBufferPointer { MR in
            nextPoint.withUnsafeBufferPointer { NP in
            cStackNode.withUnsafeMutableBufferPointer { SN in
            cStackCX.withUnsafeMutableBufferPointer { SX in
            cStackCY.withUnsafeMutableBufferPointer { SY in
            cStackHalf.withUnsafeMutableBufferPointer { SH in
                for i in 0..<n {
                    let fi = FAM[i]
                    guard fi >= 0 else { continue }   // 只有叶参与(hub 归气泡/硬约束管)
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
                                    // 每对一次 + 同家隔离(07-02:排除外部影响)
                                    if pj > i, FAM[pj] == fi {
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
                                        }
                                    }
                                    pj = Int(NP[pj])
                                }
                            }
                        }
                    }
                }
            }}}}}}}}}}}
        }
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

    /// 全部末端球 + 各自所属 hub(主球=0)+ 圈内硬上限
    ///(= 自家气泡半径 − 叶半径 − 1;自家 hub 无气泡时 ≤0 = 不夹)。
    private static func leafArrays(scene: GraphScene) -> ([Int32], [Int32], [Float]) {
        var l: [Int32] = [], h: [Int32] = [], m: [Float] = []
        for node in scene.nodes where !node.kind.isHub {
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
