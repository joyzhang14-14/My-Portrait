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
    /// 扇区约束对:leaf 必须待在 hub 背向主球的楔形扇区里(07-01/02 反馈)。
    /// cosLimit = cos(楔形半角),按 hub 叶数取档(30°~220°,装不下自动升档)。
    private var sectorLeaf: [Int32] = [], sectorHub: [Int32] = []
    private var sectorCosLimit: [Float] = []
    /// 非主球 hub 的下标(folder/分区):互相硬碰撞不重合(07-01 反馈)。
    private var hubIndices: [Int32] = []
    /// 全部末端球下标 + 各自所属 hub(主球=0):扇区间排斥用(07-01 反馈)。
    private var leafIndices: [Int32] = [], leafOwnHub: [Int32] = []
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
    private var qCount = 0
    private var nextPoint: [Int32] = []

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
        (sectorLeaf, sectorHub, sectorCosLimit) = Self.sectorPairs(scene: scene)
        hubIndices = scene.nodes.filter { $0.kind.isHub && $0.id != 0 }.map { Int32($0.id) }
        (leafIndices, leafOwnHub) = Self.leafArrays(scene: scene)

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
        (sectorLeaf, sectorHub, sectorCosLimit) = Self.sectorPairs(scene: scene)
        hubIndices = scene.nodes.filter { $0.kind.isHub && $0.id != 0 }.map { Int32($0.id) }
        (leafIndices, leafOwnHub) = Self.leafArrays(scene: scene)
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
        sectorPass()
        sectorRepelPass()
        centerAndIntegrate()
        alpha += (alphaTarget - alpha) * GraphConstants.alphaDecay
    }

    /// 楔形扇区软阻力(07-01/02 反馈):每个 leaf 应待在「hub 背向主球、
    /// 全角按叶数取档(30°~220°)」的楔形里。角度越界时施加**角向**回正力
    /// (朝外向轴转) —— 是阻力不是硬墙,布局仍是有机的。
    private func sectorPass() {
        guard !sectorLeaf.isEmpty else { return }
        // alpha 设下限:别的力冷却趋零后,扇区回正力仍温和存在 —— 否则
        // 收敛尾声被斥力挤过界的球推不回来(实测 14/80 漏网)。
        let a = max(alpha, 0.1)
        let strength = GraphConstants.sectorStrength
        pos.withUnsafeBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
        sectorLeaf.withUnsafeBufferPointer { L in
        sectorHub.withUnsafeBufferPointer { H in
        sectorCosLimit.withUnsafeBufferPointer { COS in
            for i in 0..<L.count {
                let hub = Int(H[i])
                let hubPos = P[hub]
                let d2 = simd_length_squared(hubPos)
                guard d2 > 1 else { continue }          // hub 挤在原点,方向未定义
                let outward = hubPos / d2.squareRoot()  // 主球(原点)→hub 的外向
                let leaf = Int(L[i])
                let rel = P[leaf] - hubPos
                let rlen = simd_length(rel)
                guard rlen > 1e-4 else { continue }
                let rhat = rel / rlen
                let cosA = simd_dot(rhat, outward)
                let lim = COS[i]
                if cosA < lim {
                    // 回正方向 = 外向轴在 rhat 垂面上的分量(角向转回楔形);
                    // 正对背面(t≈0)时任选切向打破对称。
                    var t = outward - rhat * cosA
                    let tl = simd_length(t)
                    t = tl > 1e-5 ? t / tl : SIMD2<Float>(-rhat.y, rhat.x)
                    V[leaf] += t * ((lim - cosA) * rlen * strength * a)
                }
            }
        }}}}}
    }

    // MARK: - Barnes-Hut 四叉树(P0 spike 验证:vs O(n²) 暴力误差中位 0.79%)

    private func allocateTree() {
        let cap = 4 * max(n, 1) + 64
        qChild = .init(repeating: -1, count: 4 * cap)
        qMass = .init(repeating: 0, count: cap)
        qCom = .init(repeating: .zero, count: cap)
        qWidth = .init(repeating: 0, count: cap)
        nextPoint = .init(repeating: -1, count: max(n, 1))
    }

    private func buildTree() {
        var lo = pos[0], hi = pos[0]
        for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let side = max(hi.x - lo.x, hi.y - lo.y) + 1e-3
        let rootCenter = (lo + hi) * 0.5
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

        // 自底向上聚合质量与质心(子节点 index 恒大于父,倒序扫即可)
        let s = GraphConstants.manyBodyStrength
        qChild.withUnsafeBufferPointer { ch in
        qMass.withUnsafeMutableBufferPointer { M in
        qCom.withUnsafeMutableBufferPointer { C in
        pos.withUnsafeBufferPointer { P in
            for node in stride(from: qCount - 1, through: 0, by: -1) {
                var m: Float = 0
                var com = SIMD2<Float>.zero
                for k in 0..<4 {
                    let c = ch[node * 4 + k]
                    if c == -1 { continue }
                    if c >= 0 {
                        let cm = M[Int(c)]
                        m += cm
                        com += C[Int(c)] * cm
                    } else {
                        var pi = Int(-c - 2)
                        while pi >= 0 {
                            m += s
                            com += P[pi] * s
                            pi = Int(nextPoint[pi])
                        }
                    }
                }
                M[node] = m
                C[node] = m != 0 ? com / m : .zero
            }
        }}}}
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
        let a = alpha
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
    /// 直连主球的叶没有扇区概念,不进这个表。cosLimit = cos(该 hub 楔形半角),
    /// 楔形全角按叶数取档(30°~220°,GraphConstants.sectorWedgeDegrees)。
    private static func sectorPairs(scene: GraphScene) -> ([Int32], [Int32], [Float]) {
        var countOf: [Int: Int] = [:]
        for e in scene.edges
        where e.b != 0 && scene.nodes[e.b].kind.isHub && !scene.nodes[e.a].kind.isHub {
            countOf[e.b, default: 0] += 1
        }
        var l: [Int32] = [], h: [Int32] = [], cos: [Float] = []
        for e in scene.edges {
            if e.b != 0, scene.nodes[e.b].kind.isHub, !scene.nodes[e.a].kind.isHub {
                l.append(Int32(e.a)); h.append(Int32(e.b))
                let wedge = GraphConstants.sectorWedgeDegrees(leafCount: countOf[e.b] ?? 0)
                cos.append(Float(Foundation.cos(wedge / 2 * .pi / 180)))
            }
        }
        return (l, h, cos)
    }

    /// 全部末端球 + 各自所属 hub(主球=0)。扇区间排斥用。
    private static func leafArrays(scene: GraphScene) -> ([Int32], [Int32]) {
        var l: [Int32] = [], h: [Int32] = []
        for node in scene.nodes where !node.kind.isHub {
            l.append(Int32(node.id))
            h.append(Int32(max(node.hubIndex, 0)))
        }
        return (l, h)
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
