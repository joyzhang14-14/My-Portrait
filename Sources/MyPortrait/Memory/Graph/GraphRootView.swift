import GraphPhysics
import SwiftUI
import simd

/// 会话级图谱缓存:zone → (场景, 物理引擎, 指纹, 相机)。
/// 需求待确认#6:布局**会话内保留** —— 切去 text / 换画布再回来不重新炸开,
/// 重启 app 才重新布局。数据变了(指纹不同)才重建引擎重新炸开。
@MainActor
final class GraphSession {
    static let shared = GraphSession()

    struct Entry {
        var scene: GraphScene
        var engine: GraphPhysicsEngine
        var fingerprint: [String]
        var camera: GraphCamera
    }

    var entries: [GraphZone: Entry] = [:]

    /// 节点集合的稳定指纹(顺序敏感)。相等 → 复用引擎保位置。
    static func fingerprint(of scene: GraphScene) -> [String] {
        scene.nodes.map { node in
            switch node.kind {
            case .main:                     return "main"
            case .folder(let slug):         return "f:" + slug
            case .category(let name):       return "c:" + name
            case .eventLeaf(let relPath):   return "e:" + relPath
            case .portraitLeaf:             return "p:" + (node.fileURL?.path ?? node.title)
            }
        }
    }
}

/// 图谱区域的「拖背景移动窗口」拦截器:AppKit 的窗口拖动机制会 hitTest 到
/// 光标下最深的 NSView 并查它的 mouseDownCanMoveWindow —— 这里返回 false,
/// SwiftUI 手势(平移/拖球)不受影响(走 hosting view 的手势识别)。
private struct WindowDragBlocker: NSViewRepresentable {
    final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ nsView: BlockerView, context: Context) {}
}

/// 图谱模式的根视图:按 scope 决定画布(Events → event 图,portrait → portrait
/// 图),负责数据加载、物理引擎生命周期、浮窗与神经脉冲、HUD。
/// 渲染在主窗口右侧内容区(与 MemoriesView 同位置),不开新窗口。
/// 非图谱 scope(personalInfo/input)不会路由进来 —— ContentView 保证。
struct GraphRootView: View {
    @Binding var scope: MemoryScope

    @State private var scene: GraphScene = .empty
    @State private var engine: GraphPhysicsEngine? = nil
    /// 引擎替换代际:驱动 park 订阅 task 重启(每个引擎的事件流只消费一次)。
    @State private var engineGen = 0
    /// 物理是否休眠(park 事件同步)。
    @State private var physicsParked = false
    @State private var camera = GraphCamera()
    @State private var hoveredId: Int? = nil
    @State private var loading = false
    /// 加载代际 token:快速切 zone 时丢弃过期结果(同 MemoriesView.reload 模式)。
    @State private var loadGen = 0

    // 浮窗(末端球点击)
    @State private var floatNodeId: Int? = nil
    /// 跨画布跳转目标:portrait 浮窗点 event chip → 切 events 画布后按 relPath
    /// 定位到该球(reload 末尾消费)。
    @State private var pendingFloatEventRel: String? = nil

    // 神经脉冲(hub 点击)
    @State private var pulses: [GraphPulse] = []
    @State private var pulseStart: Date = .distantPast
    /// 当前所有在飞脉冲的最晚结束时刻(相对 pulseStart;叠加清理定时用)。
    @State private var pulseEnd: TimeInterval = 0
    @State private var pulseGen = 0

    // 视角取景(07-09):开局固定取景、松手后缓移取景,都对准隐形环
    // 的环心+半径。cameraTask = 当前在跑的取景任务(固定/缓移复用一个
    // 槽,新触发废弃旧的);cameraTracking = 缓移进行中(驱动 renderPaused
    // 保持 TimelineView 活着直到相机到位)。viewSize = 内容区尺寸(取景
    // 算缩放要用),onChange 捕获。
    @State private var viewSize: CGSize = .zero
    @State private var cameraTask: Task<Void, Never>? = nil
    @State private var cameraTracking = false
    /// 预加载环(07-09 用户"随机种子预加载:打开界面前就知道该去哪"):
    /// reload 在显示前 headless 跑出本轮随机种子的最终隐形环,开局固定
    /// 取景直接用它 —— 保留随机布局的变化又不闪(免掉切回时环心乱跳)。
    /// nil = portrait 无环 / 尚未加载。松手缓移不用它(用引擎实时环)。
    @State private var preloadedRing: (center: SIMD2<Float>, radius: Float)? = nil

    private var zone: GraphZone {
        if case .portrait = scope { return .portrait }
        return .events
    }

    /// 逐帧重绘只在需要时开:物理在动 / hover 白闪中 / 脉冲在跑。
    /// 全静止 → TimelineView 暂停,重绘只由相机等状态变化触发(CPU≈0)。
    private var renderPaused: Bool {
        physicsParked && hoveredId == nil && pulses.isEmpty && !cameraTracking
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let engine {
                    GraphCanvasView(scene: scene,
                                    engine: engine,
                                    paused: renderPaused,
                                    pulses: pulses,
                                    pulseStart: pulseStart,
                                    camera: $camera,
                                    hoveredId: $hoveredId,
                                    onTapNode: handleTap,
                                    onNodeDragEnded: { frameCameraToRing(animated: true) },
                                    onCameraInterrupt: cancelCameraTracking)
                        .background(Color.black.opacity(0.001))   // 空白处也接手势

                    // 浮窗:锚在球旁,物理在动时跟着球走(同一时钟)。
                    if let fid = floatNodeId, fid < scene.nodes.count {
                        SwiftUI.TimelineView(.animation(minimumInterval: nil,
                                                        paused: renderPaused)) { _ in
                            GraphFloatWindow(
                                node: scene.nodes[fid],
                                onClose: { floatNodeId = nil },
                                onJumpToEvent: jumpToEvent)
                            .position(floatPosition(for: fid, engine: engine,
                                                    viewSize: geo.size))
                        }
                    }
                } else {
                    Color.clear
                }
                hud
            }
            // 内容区尺寸(取景算缩放要用);initial 捕获首帧,之后随窗变。
            .onChange(of: geo.size, initial: true) { _, s in viewSize = s }
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        // 主窗口是 chromeless + isMovableByWindowBackground=true(全局设计),
        // 但图谱里拖拽 = 平移/拖球,绝不能带动整个窗口(07-01 用户反馈)。
        // 垫一个 mouseDownCanMoveWindow=false 的 NSView 局部关掉背景拖窗。
        .background(WindowDragBlocker())
        .task(id: zone) { await reload() }
        // park 事件 → 记录物理休眠态。engineGen 变化(引擎替换)重订阅。
        .task(id: engineGen) {
            guard let engine else { return }
            physicsParked = engine.isParked
            for await parked in engine.parkEvents { physicsParked = parked }
        }
        // 换画布:相机存回会话;浮窗/脉冲不跨画布。
        .onChange(of: zone) { oldZone, _ in
            GraphSession.shared.entries[oldZone]?.camera = camera
            floatNodeId = nil
            pulses = []
        }
        .onDisappear {
            GraphSession.shared.entries[zone]?.camera = camera
            cancelCameraTracking()
        }
    }

    // MARK: - 视角取景(07-09:相机跟隐形环)

    /// 由环心+半径算取景相机:center=环心,zoom=让环基准直径占视口较短边
    /// cameraFrameFill。半径≈0 / 尺寸未知返回 nil。
    private func frameFor(_ vs: CGSize, center: SIMD2<Float>, radius: Float,
                          fill: Double = GraphConstants.cameraFrameFill)
        -> GraphCamera? {
        guard radius > 1, vs.width > 1, vs.height > 1 else { return nil }
        let minDim = min(vs.width, vs.height)
        let z = Double(minDim) * fill / (2 * Double(radius))
        var cam = GraphCamera()
        cam.center = center
        cam.zoom = min(max(z, GraphCamera.zoomRange.lowerBound),
                       GraphCamera.zoomRange.upperBound)
        return cam
    }

    /// 开局取景目标:**优先预加载环**(界面显示前算好,即时可用,免等引擎
    /// ~50ms 钉环,且切回时不读旧环 → 不闪);portrait 无预加载时回退引擎
    /// 实时环。
    private func openCamera(_ vs: CGSize) -> GraphCamera? {
        if let pr = preloadedRing {
            return frameFor(vs, center: pr.center, radius: pr.radius)
        }
        guard let engine, engine.ringR > 1 else { return nil }
        return frameFor(vs, center: engine.ringCenter, radius: engine.ringR)
    }

    /// 松手缓移目标:引擎**实时**环(拖动后环已重算,预加载环已过时)。
    private func liveCamera(_ vs: CGSize) -> GraphCamera? {
        guard let engine, engine.ringR > 1 else { return nil }
        return frameFor(vs, center: engine.ringCenter, radius: engine.ringR)
    }

    /// 取景到隐形环。两态共用"lerp 跟随引擎实时环、跟到物理定稳"的收敛
    /// 循环 —— **终点都是引擎真实环 = 精确居中**(预加载只是影子预测,
    /// 个别种子偏 30~60px,不能当终点)。区别只在起点:
    /// - animated=false(开局):先同步把相机放到**预加载环**(首帧即大致
    ///   就位,切回不闪),再缓缓收敛到真实环。这段漂移落在陨石隐藏 + hub
    ///   绽放的开局期,被绽放掩盖;贝壳淡入时相机已稳定在精确中心。
    /// - animated=true(松手):不重置起点(停在松手处),缓移到真实环。
    /// 任一时刻只有一个取景任务(新触发废弃旧的);引擎换代/手动操作中止。
    private func frameCameraToRing(animated: Bool) {
        cameraTask?.cancel()
        let gen = engineGen
        // 开局:同步先用预加载环放好首帧(viewSize 就绪时;否则循环里兜底)。
        if !animated, let cam = openCamera(viewSize) { camera = cam }
        cameraTracking = true
        cameraTask = Task { @MainActor in
            defer { cameraTracking = false }
            let k = GraphConstants.cameraTrackLerp
            for i in 0..<900 {   // ~15s 上限兜底(含物理沉降 + 缓移)
                if Task.isCancelled || gen != engineGen { return }
                // 目标 = 引擎实时环(精确居中);开局头 ~50ms 引擎环未钉好时
                // 用预加载环兜底(免这几帧无目标 → 停在旧相机闪一下)。
                let tgt = liveCamera(viewSize) ?? (animated ? nil : openCamera(viewSize))
                guard let engine, let tgt else {
                    if animated { return }         // 松手却无环:异常,退出
                    if i > 180 { return }          // 开局 3s 无环(portrait)→ 放弃
                    try? await Task.sleep(for: .milliseconds(16)); continue
                }
                camera.center += (tgt.center - camera.center) * Float(k)
                camera.zoom += (tgt.zoom - camera.zoom) * k
                // ⚠️ 收敛必须**等物理休眠**:松手瞬间环还是拖动前的旧值
                //(设计"拖动整环不变"),相机一读就对齐旧环 → 若此刻退出,
                // 几十毫秒后环重算成新值时已无任务跟随 = "没调整"。改为跟着
                // 环走到物理定稳(isParked)且相机贴合才收官,保证每次松手
                // 都真正跟到最终环;开局同理,跟到真实环 = 精确居中。
                if engine.isParked,
                   simd_length(tgt.center - camera.center) < 0.5,
                   abs(tgt.zoom - camera.zoom) < 0.001 {
                    camera = tgt; return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// 用户手动平移/缩放 / 起拖 → 中止自动取景,交还控制权。
    private func cancelCameraTracking() {
        cameraTask?.cancel()
        cameraTracking = false
    }

    /// 点 folder 球聚焦(07-09 用户):相机缓移到该 folder 的隐形圆(气泡)
    /// 视图 —— center=气泡心(= hub 位),zoom=气泡直径占视口 cameraFolderFill。
    /// tap 与 drag 由手势系统天然区分(DragGesture 有 2pt 阈值,纯点击不触发)。
    private func frameCameraToFolder(_ hub: Int) {
        guard let engine, hub < scene.nodes.count,
              let br = scene.nodes[hub].hubBubbleRadius, br > 0 else { return }
        cameraTask?.cancel()
        cameraTracking = true
        let gen = engineGen
        let radius = Float(br)
        cameraTask = Task { @MainActor in
            defer { cameraTracking = false }
            let k = GraphConstants.cameraTrackLerp
            for _ in 0..<300 {   // ~5s 上限兜底
                if Task.isCancelled || gen != engineGen { return }
                let snap = engine.readSnapshot()
                guard hub < snap.count,
                      let tgt = frameFor(viewSize, center: snap[hub], radius: radius,
                                         fill: GraphConstants.cameraFolderFill)
                else { return }
                camera.center += (tgt.center - camera.center) * Float(k)
                camera.zoom += (tgt.zoom - camera.zoom) * k
                if simd_length(tgt.center - camera.center) < 0.5,
                   abs(tgt.zoom - camera.zoom) < 0.0005 {
                    camera = tgt; return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: - 交互路由

    /// 点空白 = 关浮窗;点末端球 = 开浮窗;点 hub = 神经脉冲(无浮窗,需求 §5)。
    /// 点 folder 球(有隐形圆的 hub,非主球)额外聚焦该 folder 视图(07-09)。
    private func handleTap(_ id: Int?) {
        guard let id, id < scene.nodes.count else {
            floatNodeId = nil
            // 点空白 → 视角缓移回开场总览(当前隐形环全景);07-09 用户。
            // animated 分支跟随引擎实时环、park 收敛;portrait 无环则空转返回。
            frameCameraToRing(animated: true)
            return
        }
        if scene.nodes[id].kind.isHub {
            floatNodeId = nil
            triggerPulse(from: id)
            if scene.nodes[id].hubBubbleRadius != nil { frameCameraToFolder(id) }
        } else {
            floatNodeId = id
        }
    }

    private func triggerPulse(from hub: Int) {
        guard let engine else { return }
        let snap = engine.readSnapshot()
        guard snap.count == scene.nodes.count else { return }
        // 只有主球级联 2 跳(信号穿过 folder/分区抵达末端);
        // 其它 hub 只传 1 跳到直接相连的球(07-01 反馈),且**不传主球**
        //(07-03 精修:folder/分区点击只发给自家 event 球)。
        let isMain = scene.nodes[hub].kind == .main
        let depth = isMain ? GraphConstants.pulseMaxDepthMain
                           : GraphConstants.pulseMaxDepthOther
        let (list, total) = GraphPulseScheduler.schedule(from: hub, scene: scene,
                                                         positions: snap,
                                                         maxDepth: depth,
                                                         blocked: isMain ? [] : [0])
        // 叠加不清除(07-03 精修:连点时上一发信号不许中途消失):新一批
        // 脉冲按公共时间轴平移后**追加**;时间轴锚在最早一批的起点。
        let now = Date()
        if pulses.isEmpty { pulseStart = now; pulseEnd = 0 }
        let base = now.timeIntervalSince(pulseStart)
        pulses.append(contentsOf: list.map {
            GraphPulse(edgeIndex: $0.edgeIndex, fromNode: $0.fromNode,
                       start: base + $0.start, duration: $0.duration)
        })
        pulseEnd = max(pulseEnd, base + total)
        pulseGen += 1
        let gen = pulseGen
        // 动画走完自动清空(按**全场最晚结束**定时,早批长级联不被
        // 晚批短级联提前清掉;清空后 renderPaused 恢复休眠判定)。
        let wait = pulseEnd - base + 0.2
        Task {
            try? await Task.sleep(for: .seconds(wait))
            if gen == pulseGen { pulses = [] }
        }
    }

    /// portrait 浮窗 event chip → 切 Event 画布 + 相机对准 + 打开该 event 浮窗。
    private func jumpToEvent(_ relPath: String) {
        floatNodeId = nil
        pendingFloatEventRel = relPath
        if zone == .events {
            resolvePendingEventJump()
        } else {
            scope = .events   // 触发 .task(id: zone) → reload 末尾消费 pending
        }
    }

    private func resolvePendingEventJump() {
        guard let rel = pendingFloatEventRel else { return }
        pendingFloatEventRel = nil
        guard let idx = scene.nodes.firstIndex(where: {
            if case .eventLeaf(let r) = $0.kind { return r == rel }
            return false
        }) else { return }
        if let engine {
            let snap = engine.readSnapshot()
            if idx < snap.count { camera.center = snap[idx] }
        }
        floatNodeId = idx
    }

    /// 浮窗中心位置:球右侧偏移,clamp 进视口。
    private func floatPosition(for id: Int, engine: GraphPhysicsEngine,
                               viewSize: CGSize) -> CGPoint {
        let snap = engine.readSnapshot()
        guard id < snap.count, id < scene.nodes.count else {
            return CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        }
        let ball = camera.worldToScreen(snap[id], viewSize: viewSize)
        let r = scene.nodes[id].radius * camera.zoom
        let halfW = 190.0, halfH = 230.0
        // 优先放球右侧;放不下换左侧。
        var x = ball.x + r + 20 + halfW
        if x + halfW > viewSize.width { x = ball.x - r - 20 - halfW }
        var y = ball.y
        x = min(max(x, halfW + 8), viewSize.width - halfW - 8)
        y = min(max(y, halfH + 8), viewSize.height - halfH - 8)
        return CGPoint(x: x, y: y)
    }

    // MARK: - HUD

    private var hud: some View {
        HStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            }
            // 前端文案一律英文(用户 2026-07-01 定稿)。
            Text("\(scene.nodes.count) nodes · \(scene.edges.count) links")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bouncyIcon)
            .help("Reload from disk")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard()
        .padding(.top, 44)
        .padding(.trailing, 16)
    }

    // MARK: - 加载 / 引擎生命周期

    @MainActor
    private func reload() async {
        loadGen += 1
        let gen = loadGen
        loading = true
        let z = zone
        // ConfigStore 只能在 MainActor 读,参数先取好再丢后台。
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let info = ConfigStore.shared.current.personalInfo
        let name = [info.alias, info.firstName].first { !$0.isEmpty } ?? "Me"
        let built = await Task.detached(priority: .userInitiated) {
            GraphSceneBuilder.build(zone: z, halfLifeDays: halfLife, userName: name)
        }.value
        guard gen == loadGen else { return }   // 期间切了 zone → 丢弃

        // 随机种子(07-09 用户"随机种子预加载"):保留每次打开布局有变化;
        // 界面显示前先 headless 跑出该种子的最终隐形环,相机开局即按此
        // 取景 —— 变化 + 不闪。同一 seed 喂给 preload 与真正的引擎,布局
        // 一致(preloadRing == 引擎最终环的影子预测)。
        let seed = UInt64.random(in: .min ... .max)
        let ring = await Task.detached(priority: .userInitiated) {
            GraphPhysicsEngine.preloadRing(scene: built, seed: seed)
        }.value
        guard gen == loadGen else { return }   // preload 期间切了 zone → 丢弃
        preloadedRing = ring

        let fp = GraphSession.fingerprint(of: built)
        if let cached = GraphSession.shared.entries[z], cached.fingerprint == fp {
            // 数据没变:复用引擎,刷边参数后**重放展开动画**(07-02 用户
            // 定稿:每次打开都要展开效果;确定性物理 → 每次收敛到同一布局)
            cached.engine.updateScene(built)
            cached.engine.explode(seed: seed)
            GraphSession.shared.entries[z]?.scene = built
            scene = built
            if engine !== cached.engine {
                engine = cached.engine
                engineGen += 1
                camera = cached.camera
            }
        } else {
            // 数据变了 / 首次:新引擎,开场炸开(init 即高温挤中心态)
            GraphSession.shared.entries[z]?.engine.shutdown()
            let fresh = GraphPhysicsEngine(scene: built, seed: seed)
            GraphSession.shared.entries[z] = .init(scene: built, engine: fresh,
                                                   fingerprint: fp, camera: GraphCamera())
            scene = built
            engine = fresh
            engineGen += 1
            camera = GraphCamera()
        }
        hoveredId = nil
        if floatNodeId.map({ $0 >= scene.nodes.count }) == true { floatNodeId = nil }
        loading = false
        // 跨画布跳转会自设 camera 对准目标球,此时不抢镜(须在 resolve
        // 前捕获 —— resolve 内部会清空 pending)。
        let hadJump = pendingFloatEventRel != nil
        resolvePendingEventJump()   // 跨画布跳转:落到目标 event 球 + 开浮窗
        // 开局固定取景:环一钉好即对准(portrait 无环则轮询超时无操作,
        // 保持默认视角)。
        if !hadJump { frameCameraToRing(animated: false) }
    }
}
