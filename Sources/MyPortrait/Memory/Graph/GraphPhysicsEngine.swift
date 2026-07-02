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
    private var edgesA: [Int32], edgesB: [Int32]
    private var linkStrength: [Float], linkBias: [Float], linkRest: [Float]
    /// 领地约束对:leaf 必须待在自家 hub 的动态领地内(07-02 定稿:
    /// 范围先算、与邻居比较调整、不进别家地盘 —— 边界每 tick 按 hub
    /// 实际极角重算,见 territoryPass)。
    private var sectorLeaf: [Int32] = [], sectorHub: [Int32] = []
    /// 非主球 hub 的下标(folder/分区):互相硬碰撞不重合(07-01 反馈)。
    private var hubIndices: [Int32] = []
    /// hub 的等距硬钉半径(builder 公式值;≤0 = 无)。07-02:等距必须硬保证,
    /// 弹簧/碰撞的合力会让 hub 半径漂移。
    private var hubPinRadius: [Float] = []
    /// 完美圆·物理化(07-02 终稿):hub 角向碰撞半宽(rad,=楔形份额/2)
    /// 与质量(叶数+1,重的动得少)—— 扇区边界由碰撞平衡涌现。
    private var hubHalfAngle: [Float] = [], hubMass: [Float] = []
    /// 全部末端球下标 + 各自所属 hub(主球=0)+ 各自弹簧 rest:
    /// 扇区间排斥 + 叶距硬上限用。
    private var leafIndices: [Int32] = [], leafOwnHub: [Int32] = []
    private var leafRestArr: [Float] = []
    private var alpha: Float = 1
    private var alphaTarget: Float = 0
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
        snapshot = pos
        (edgesA, edgesB, linkStrength, linkBias, linkRest) = Self.linkArrays(scene: scene)
        (sectorLeaf, sectorHub) = Self.sectorPairs(scene: scene)
        (hubIndices, hubPinRadius, hubHalfAngle, hubMass) = Self.hubArrays(scene: scene)
        (leafIndices, leafOwnHub, leafRestArr) = Self.leafArrays(scene: scene)
        // 07-02 终稿:开场 = 物理收敛(从中心炸开,力系统自然摊成圆)。
        // 目标落位/绽放出生已删 —— 布局不再有"成品位",只有平衡态。

        var continuation: AsyncStream<Bool>.Continuation?
        parkEvents = AsyncStream { continuation = $0 }
        parkContinuation = continuation
        allocateTree()   // 必须在全部存储属性就位后(方法调用要求 self 完整)

        let t = Thread { [weak self] in self?.loop() }
        t.name = "graph-physics"
        t.qualityOfService = .userInteractive
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
        alpha = 1
        publishSnapshot()
        simLock.unlock()
        wake()
    }

    /// 数据轻刷新:节点集合没变(fingerprint 相等),只更新边参数
    /// (rest 每天随 last_occurred 漂移)。**保留位置**,微加热让布局适应。
    func updateScene(_ scene: GraphScene) {
        simLock.lock()
        guard scene.nodes.count == n else { simLock.unlock(); return }   // 防御:调用方保证
        nodeRadius = scene.nodes.map { Float($0.radius) }
        (edgesA, edgesB, linkStrength, linkBias, linkRest) = Self.linkArrays(scene: scene)
        (sectorLeaf, sectorHub) = Self.sectorPairs(scene: scene)
        (hubIndices, hubPinRadius, hubHalfAngle, hubMass) = Self.hubArrays(scene: scene)
        (leafIndices, leafOwnHub, leafRestArr) = Self.leafArrays(scene: scene)
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
        buildTree()
        manyBodyPass()
        linkPass()
        hubAngularPass()
        territoryPass()
        sectorRepelPass()
        collidePass()
        centerAndIntegrate()
        alpha += (alphaTarget - alpha) * GraphConstants.alphaDecay
        // 早停快照已删(07-02 终稿):布局没有"成品位",冷却到 alphaMin
        // 自然 park —— 开场/收敛全程都是物理,本身即丝滑。
    }

    /// hub 间角向碰撞(07-02 物理化,取代固定目标角):每个 hub 占一段角向
    /// "圆盘"(半宽 = 楔形份额/2),按当前极角排序后**相邻**两两查重叠,
    /// 切向推开;权重 ∝ 叶数(大 folder 挤开邻居)。碰撞平衡处即扇区
    /// 边界 —— 扇区宽 ∝ 内容涌现,外圈无缝。h ≤ ~11,O(h log h) 忽略不计。
    private func hubAngularPass() {
        let h = hubIndices.count
        guard h > 1 else { return }
        let a = max(alpha, 0.1)   // 同 sector:冷却尾声定位力仍在(力对称纪律)
        let k = GraphConstants.hubAngularStrength
        var theta = [Float](repeating: 0, count: h)
        for i in 0..<h {
            let p = pos[Int(hubIndices[i])]
            theta[i] = atan2(p.y, p.x)
        }
        var order = Array(0..<h)
        order.sort { theta[$0] < theta[$1] }
        for s in 0..<h {
            let ii = order[s], jj = order[(s + 1) % h]
            let i = Int(hubIndices[ii]), j = Int(hubIndices[jj])
            var d = theta[jj] - theta[ii]
            if d < 0 { d += 2 * .pi }              // j 恒在 i 的逆时针侧
            let overlap = hubHalfAngle[ii] + hubHalfAngle[jj] - d
            guard overlap > 0 else { continue }
            let pi = pos[i], pj = pos[j]
            let ri = simd_length(pi), rj = simd_length(pj)
            guard ri > 1, rj > 1 else { continue }
            let wi = hubMass[jj] / (hubMass[ii] + hubMass[jj])   // 重的动得少
            let tanI = SIMD2<Float>(-pi.y, pi.x) / ri
            let tanJ = SIMD2<Float>(-pj.y, pj.x) / rj
            vel[i] -= tanI * (overlap * ri * k * a * wi)
            vel[j] += tanJ * (overlap * rj * k * a * (1 - wi))
        }
    }

    /// 动态领地墙(07-02 用户定稿:"先算出扇形的范围,和别的扇形比较、
    /// 调整,确保不到别的扇形的地盘"):每 tick 把 hub 按**当前**极角排序,
    /// 相邻两家的地盘边界 = 极角间隙按楔形份额加权的分点(范围先算 →
    /// 与邻居比较 → 调整);叶子的原点极角越过自家边界 → 切向回正力。
    /// 领地角恒定 → 切向宽度随半径变大,fan 近窄远宽 = 花瓣形。
    private func territoryPass() {
        let h = hubIndices.count
        guard h > 1, !sectorLeaf.isEmpty else { return }
        // alpha 下限:冷却尾声回正力仍在,否则被碰撞挤过界的球推不回来
        let a = max(alpha, 0.1)
        let k = GraphConstants.sectorStrength
        let kc = GraphConstants.sectorCenterStrength
        let margin: Float = 2 * .pi / 180
        var theta = [Float](repeating: 0, count: h)
        for i in 0..<h {
            let p = pos[Int(hubIndices[i])]
            theta[i] = atan2(p.y, p.x)
        }
        var order = Array(0..<h)
        order.sort { theta[$0] < theta[$1] }
        // 相对自家 hub 极角的允许区间 [loRel, hiRel](hiRel ≥ 0 ≥ loRel)
        var loRel = [Float](repeating: 0, count: h)
        var hiRel = [Float](repeating: 0, count: h)
        for s in 0..<h {
            let ii = order[s], jj = order[(s + 1) % h]
            var gap = theta[jj] - theta[ii]
            if gap <= 0 { gap += 2 * .pi }
            let wi = hubHalfAngle[ii], wj = hubHalfAngle[jj]
            let frac: Float = (wi + wj) > 0 ? wi / (wi + wj) : 0.5
            let off = gap * frac                 // 边界(相对 ii 的偏移)
            hiRel[ii] = max(off - margin, 0)
            loRel[jj] = min(off - gap + margin, 0)
        }
        var slotOf = [Int32: Int](minimumCapacity: h)
        for i in 0..<h { slotOf[hubIndices[i]] = i }
        pos.withUnsafeBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        sectorLeaf.withUnsafeBufferPointer { L in
        sectorHub.withUnsafeBufferPointer { H in
            for t in 0..<L.count {
                guard let hIdx = slotOf[H[t]] else { continue }
                let leaf = Int(L[t])
                let p = P[leaf]
                let r = simd_length(p)
                guard r > 1 else { continue }
                var d = atan2(p.y, p.x) - theta[hIdx]
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                var excess: Float = 0
                if d > hiRel[hIdx] { excess = d - hiRel[hIdx] }
                else if d < loRel[hIdx] { excess = d - loRel[hIdx] }
                let tangent = SIMD2<Float>(-p.y, p.x) / r
                if excess != 0 {
                    V[leaf] -= tangent * (excess * r * k * a)
                }
                // 花瓣内聚:全程向自家轴线的弱角向弹簧(稀疏家收拢成瓣,
                // 密集家被碰撞力顶开照样铺满楔形)
                V[leaf] -= tangent * (d * r * kc * a)
            }
        }}}}
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

        // 自底向上聚合质量/质心/子树最大球半径(子节点 index 恒大于父,倒序扫)
        let s = GraphConstants.manyBodyStrength
        qChild.withUnsafeBufferPointer { ch in
        qMass.withUnsafeMutableBufferPointer { M in
        qCom.withUnsafeMutableBufferPointer { C in
        qMaxR.withUnsafeMutableBufferPointer { MR in
        nodeRadius.withUnsafeBufferPointer { R in
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
                            m += s
                            com += P[pi] * s
                            mr = max(mr, R[pi])
                            pi = Int(nextPoint[pi])
                        }
                    }
                }
                M[node] = m
                C[node] = m != 0 ? com / m : .zero
                MR[node] = mr
            }
        }}}}}}
    }

    private func manyBodyPass() {
        let a = alpha
        let theta2 = GraphConstants.bhTheta2
        let dMin2 = GraphConstants.bhDistanceMin2
        let strength = GraphConstants.manyBodyStrength
        var stack = [Int32](repeating: 0, count: 256)
        pos.withUnsafeBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        qChild.withUnsafeBufferPointer { ch in
        qMass.withUnsafeBufferPointer { M in
        qCom.withUnsafeBufferPointer { C in
        qWidth.withUnsafeBufferPointer { W in
        nextPoint.withUnsafeBufferPointer { NP in
        stack.withUnsafeMutableBufferPointer { S in
            for i in 0..<n {
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
                                    f += dd * (strength * a / dl2)
                                }
                                pi = Int(NP[pi])
                            }
                        }
                    }
                }
                V[i] += f
            }
        }}}}}}}}
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
            for i in 0..<n {
                V[i] += (SIMD2<Float>.zero - P[i]) * (cs * a)
                V[i] *= damping
                P[i] += V[i]
            }
        }}
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
        // 叶距软夹钳(07-02 完美圆保证):dist(leaf, 自家hub) ≤ rest×1.2。
        // 各种持续定位力会把叶子挤出 rest,fan 半径失控 → 外缘不再成圆。
        // ⚠️ 必须在各硬碰撞**之前**跑(碰撞有最终发言权,否则夹钳会把球
        // 拽回主球/hub 体内);被拖球豁免(d3 语义:指针钉住绝对优先)。
        if !leafIndices.isEmpty {
            let stretch = GraphConstants.leafMaxStretch
            pos.withUnsafeMutableBufferPointer { P in
                for li in 0..<leafIndices.count {
                    let leaf = Int(leafIndices[li])
                    if leaf == di { continue }
                    let hub = Int(leafOwnHub[li])
                    let d = P[leaf] - P[hub]
                    let dist = simd_length(d)
                    let maxD = leafRestArr[li] * stretch
                    if dist > maxD, dist > 1e-4 {
                        P[leaf] = P[hub] + d / dist * maxD
                    }
                }
            }
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
        // hub 间碰撞(07-01 反馈:folder/分区球互不重合)。每画布 hub ≤10,
        // O(h²) 忽略不计;每 tick 一轮对半推开,数帧内收敛。
        if hubIndices.count > 1 {
            let pad = GraphConstants.mainCollisionPadding
            pos.withUnsafeMutableBufferPointer { P in
                for ii in 0..<(hubIndices.count - 1) {
                    for jj in (ii + 1)..<hubIndices.count {
                        let i = Int(hubIndices[ii]), j = Int(hubIndices[jj])
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
        // hub 等距硬钉(07-02):半径投影回公式值,角度不动(角向碰撞管)。
        if !hubIndices.isEmpty {
            pos.withUnsafeMutableBufferPointer { P in
                for hi in 0..<hubIndices.count {
                    let pin = hubPinRadius[hi]
                    guard pin > 0 else { continue }
                    let h = Int(hubIndices[hi])
                    if h == di { continue }            // 拖拽豁免
                    let r = simd_length(P[h])
                    if r > 1 { P[h] = P[h] / r * pin }
                }
            }
        }
        // hub 间角向硬解算(07-02 物理化):等距硬钉后,球体重叠沿切向
        // 旋开(半径不动,等距不破 —— 欧氏推开会被上面的钉重新引入重叠)。
        // 只对成对带钉的 hub;弦长→角距用等半径公式(钉保证等半径)。
        if hubIndices.count > 1 {
            let pad = GraphConstants.mainCollisionPadding
            pos.withUnsafeMutableBufferPointer { P in
                for ii in 0..<(hubIndices.count - 1) {
                    guard hubPinRadius[ii] > 0 else { continue }
                    for jj in (ii + 1)..<hubIndices.count {
                        guard hubPinRadius[jj] > 0 else { continue }
                        let i = Int(hubIndices[ii]), j = Int(hubIndices[jj])
                        if i == di || j == di { continue }
                        let minD = nodeRadius[i] + nodeRadius[j] + pad
                        guard simd_length(P[j] - P[i]) < minD else { continue }
                        let ri = simd_length(P[i]), rj = simd_length(P[j])
                        guard ri > 1, rj > 1 else { continue }
                        var ti = atan2(P[i].y, P[i].x)
                        var tj = atan2(P[j].y, P[j].x)
                        var dth = tj - ti
                        while dth > .pi { dth -= 2 * .pi }
                        while dth < -.pi { dth += 2 * .pi }
                        let need = 2 * asin(min(minD / (ri + rj), 0.99))
                        let deficit = need - abs(dth)
                        guard deficit > 0 else { continue }
                        let sign: Float = dth >= 0 ? 1 : -1
                        ti -= sign * deficit * 0.5
                        tj += sign * deficit * 0.5
                        P[i] = SIMD2<Float>(cos(ti), sin(ti)) * ri
                        P[j] = SIMD2<Float>(cos(tj), sin(tj)) * rj
                    }
                }
            }
        }
        // 末端球与 hub 硬碰撞(07-02 反馈:不许重叠,含自家 hub)。
        // 叶×hub ≈ 万次量级,推叶不推 hub(hub 位置稳)。
        if !leafIndices.isEmpty, !hubIndices.isEmpty {
            let pad = GraphConstants.mainCollisionPadding
            pos.withUnsafeMutableBufferPointer { P in
                for li in 0..<leafIndices.count {
                    let leaf = Int(leafIndices[li])
                    for hi in 0..<hubIndices.count {
                        let hub = Int(hubIndices[hi])
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

    /// 扇区间排斥(07-01 反馈):每个末端球被**别家 hub** 近距线性推开
    /// (自家 hub 不排斥,不然扇形被推散)。让相邻 hub 的扇形不互相渗透。
    /// 叶×hub ≈ 万次量级 simd,忽略不计。alpha 下限同 sectorPass。
    private func sectorRepelPass() {
        guard !leafIndices.isEmpty, !hubIndices.isEmpty else { return }
        let a = max(alpha, 0.1)
        let strength = GraphConstants.sectorRepelStrength
        let radius = GraphConstants.sectorRepelRadius
        pos.withUnsafeBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        leafIndices.withUnsafeBufferPointer { L in
        leafOwnHub.withUnsafeBufferPointer { OWN in
        hubIndices.withUnsafeBufferPointer { H in
            for li in 0..<L.count {
                let leaf = Int(L[li])
                let own = OWN[li]
                var f = SIMD2<Float>.zero
                for hi in 0..<H.count {
                    let hub = H[hi]
                    if hub == own { continue }
                    let d = P[leaf] - P[Int(hub)]
                    let dist = simd_length(d)
                    if dist < radius, dist > 1e-4 {
                        f += (d / dist) * ((radius - dist) / radius * strength)
                    }
                }
                V[leaf] += f * a
            }
        }}}}}
    }

    /// 叶 → 非主球 hub 的约束对(folder 的 event / 分区的 portrait 小球)。
    /// 直连主球的叶没有领地概念,不进这个表。边界每 tick 动态算
    /// (territoryPass),这里只收集配对。
    private static func sectorPairs(scene: GraphScene) -> ([Int32], [Int32]) {
        var l: [Int32] = [], h: [Int32] = []
        for e in scene.edges {
            if e.b != 0, scene.nodes[e.b].kind.isHub, !scene.nodes[e.a].kind.isHub {
                l.append(Int32(e.a)); h.append(Int32(e.b))
            }
        }
        return (l, h)
    }

    /// 半径感知碰撞力(d3 forceCollide 的零依赖移植,07-02 物理化的核心
    /// 新力):任意两球圆心距 < r_i+r_j+缝 时按重叠深度推开(速度域,
    /// 权重 = 对方半径² 占比,大球稳)。复用 manyBody 的四叉树 + qMaxR
    /// 剪枝,O(n log n);d3 语义:不乘 alpha,重叠永远解算。
    private func collidePass() {
        guard n > 1 else { return }
        let strength = GraphConstants.collideStrength
        let pad = GraphConstants.collidePadding
        var sNode = [Int32](repeating: 0, count: 256)
        var sCX = [Float](repeating: 0, count: 256)
        var sCY = [Float](repeating: 0, count: 256)
        var sHalf = [Float](repeating: 0, count: 256)
        for _ in 0..<GraphConstants.collideIterations {
            pos.withUnsafeBufferPointer { P in
            vel.withUnsafeMutableBufferPointer { V in
            nodeRadius.withUnsafeBufferPointer { R in
            qChild.withUnsafeBufferPointer { ch in
            qMaxR.withUnsafeBufferPointer { MR in
            nextPoint.withUnsafeBufferPointer { NP in
            sNode.withUnsafeMutableBufferPointer { SN in
            sCX.withUnsafeMutableBufferPointer { SX in
            sCY.withUnsafeMutableBufferPointer { SY in
            sHalf.withUnsafeMutableBufferPointer { SH in
                for i in 0..<n {
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
                                    if pj > i {    // 每对只解算一次
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
            }}}}}}}}}}
        }
    }

    /// 非主球 hub 的物理参数(builder 赋值):等距硬钉半径 / 角向碰撞
    /// 半宽(=楔形份额一半)/ 质量(叶数+1)。四数组按同一顺序对齐。
    private static func hubArrays(scene: GraphScene)
        -> ([Int32], [Float], [Float], [Float]) {
        var leafCount: [Int: Int] = [:]
        for node in scene.nodes where !node.kind.isHub {
            leafCount[node.hubIndex, default: 0] += 1
        }
        var idx: [Int32] = [], pin: [Float] = [], half: [Float] = [], mass: [Float] = []
        for node in scene.nodes where node.kind.isHub && node.id != 0 {
            idx.append(Int32(node.id))
            pin.append(node.hubPinRadius.map(Float.init) ?? -1)
            half.append(Float((node.hubWedgeDegrees ?? 0) / 2 * .pi / 180))
            mass.append(Float(leafCount[node.id] ?? 0) + 1)
        }
        return (idx, pin, half, mass)
    }

    /// 全部末端球 + 各自所属 hub(主球=0)+ 弹簧 rest(每叶恰一条边)。
    private static func leafArrays(scene: GraphScene) -> ([Int32], [Int32], [Float]) {
        var restOf: [Int: Float] = [:]
        for e in scene.edges { restOf[e.a] = Float(e.restLength) }
        var l: [Int32] = [], h: [Int32] = [], r: [Float] = []
        for node in scene.nodes where !node.kind.isHub {
            l.append(Int32(node.id))
            h.append(Int32(max(node.hubIndex, 0)))
            r.append(restOf[node.id] ?? Float(GraphConstants.eventLeafDistanceFar))
        }
        return (l, h, r)
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
