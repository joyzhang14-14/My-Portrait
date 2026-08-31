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

/// 时间线的方向键监听(只在时间线模式存活)。SwiftUI 的 focusable/onKeyPress
/// 在这个画布上拿不到第一响应者,沿用项目里的本地事件监听惯例。
@MainActor
final class TimelineKeyMonitor {
    private var monitor: Any?

    func start(onLeft: @escaping () -> Void, onRight: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ev in
            // 正在编辑文本(folder 重命名 / 改色输入框)→ 原样放行,
            // 否则方向键被吞掉、光标动不了。
            if let r = NSApp.keyWindow?.firstResponder,
               r is NSTextView || r is NSTextField { return ev }
            // 123 = ←,124 = →(keyCode 与键盘布局无关,比字符可靠)
            switch ev.keyCode {
            case 123: onLeft();  return nil   // 吞掉,免得系统响一声
            case 124: onRight(); return nil
            default:  return ev
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
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
    /// 右键菜单当前作用的 folder / portrait 分区球；渲染器据此画蓝圈。
    @State private var contextNodeId: Int? = nil
    @State private var loading = false
    /// 加载代际 token:快速切 zone 时丢弃过期结果(同 MemoriesView.reload 模式)。
    @State private var loadGen = 0
    @State private var renameFolder: FolderMenuTarget? = nil
    @State private var renameDraft = ""
    @State private var recolorTarget: RecolorTarget? = nil
    @State private var recolorDraft: String? = nil
    @State private var deleteFolder: FolderMenuTarget? = nil
    @State private var graphActionError: String? = nil

    private struct FolderMenuTarget: Identifiable {
        let id: String
        let title: String
    }

    private struct RecolorTarget: Identifiable {
        enum Kind { case folder(String), category(String), unclassified }
        let id: String
        let title: String
        let kind: Kind
    }

    // 浮窗(末端球点击)
    @State private var floatNodeId: Int? = nil
    /// 浮窗渐显(07-10 update):开卡片先隐,等相机取景收官(cameraTracking
    /// 落 false)再 0.22s 淡入;取景等物理沉降太久时 1.5s 兜底先显示。⚠️ 在
    /// **设置 floatNodeId 的入口**同步置 false(onChange 在渲染后才跑,只靠
    /// 它换球时会闪一帧上个状态)。
    @State private var floatRevealed = false
    @State private var floatRevealTask: Task<Void, Never>? = nil
    /// 跨画布跳转目标:portrait 浮窗点 event chip → 切 events 画布后按 relPath
    /// 定位到该球(reload 末尾消费)。
    @State private var pendingFloatEventRel: String? = nil

    // 神经脉冲(hub 点击)
    @State private var pulses: [GraphPulse] = []
    @State private var pulseStart: Date = .distantPast
    /// 当前所有在飞脉冲的最晚结束时刻(相对 pulseStart;叠加清理定时用)。
    @State private var pulseEnd: TimeInterval = 0
    @State private var pulseGen = 0

    // 视角取景(07-09 update):开局固定取景、松手后缓移取景,都对准隐形环
    // 的环心+半径。cameraTask = 当前在跑的取景任务(固定/缓移复用一个
    // 槽,新触发废弃旧的);cameraTracking = 缓移进行中(驱动 renderPaused
    // 保持 TimelineView 活着直到相机到位)。viewSize = 内容区尺寸(取景
    // 算缩放要用),onChange 捕获。
    @State private var viewSize: CGSize = .zero
    @State private var cameraTask: Task<Void, Never>? = nil
    @State private var cameraTracking = false
    /// 相机任务代际:旧任务被取消后可能正从 sleep 返回,只允许最新任务
    /// 收尾/落终点,避免连续点球时旧任务插回旧视角造成一帧卡跳。
    @State private var cameraRunID: UInt64 = 0
    /// 预加载环(07-09 update):reload 在显示前 headless 跑出本轮随机种子的
    /// 最终隐形环,开局固定取景直接用它 —— 保留随机布局的变化又不闪(免掉
    /// 切回时环心乱跳)。nil = portrait 无环 / 尚未加载。松手缓移不用它
    /// (用引擎实时环)。
    @State private var preloadedRing: (center: SIMD2<Float>, radius: Float)? = nil
    /// 主球自定义照片(07-11 update):从磁盘加载,Settings 改了发通知即重载。
    @State private var mainBallImage: NSImage? = nil
    /// 观察 config:脉冲速度档位改了要即时反映到渲染(闪光时长)与下次点击。
    @State private var config = ConfigStore.shared

    // MARK: - 时间线(07-11 用户:看每天的图谱变化)
    /// 非 nil = 在时间线模式。索引一次解析,拖动时零 IO。
    @State private var timelineIndex: EventTimeline.Index? = nil
    /// 当前停在哪一天(仅时间线模式有意义)。
    @State private var timelineDay: Date = .distantPast
    @State private var timelineLoading = false
    @State private var timelinePlaying = false
    /// 方向键监听句柄(只在时间线模式挂着)。
    @State private var timelineKeyMonitor: TimelineKeyMonitor? = nil
    /// 正在淡出(⑤ 不要一下子消失)。淡出期间条还在但不接事件。
    @State private var timelineFading = false

    /// 神经脉冲速度倍率(config;1=中等=现状,>1 更快)。
    private var pulseScale: Double {
        config.current.display.graphPulseSpeed.pulseScale
    }
    /// 抵达点亮的淡出时长(随脉冲档位缩放:快档闪得更干脆)。
    private var pulseFlashSec: Double {
        GraphConstants.pulseArriveFlashSec / pulseScale
    }

    private var zone: GraphZone {
        if case .portrait = scope { return .portrait }
        return .events
    }

    /// 逐帧重绘只在需要时开:物理在动 / hover 白闪中 / 脉冲在跑 /
    /// 浮窗开着(其球持续白闪提示,07-10)。
    /// 全静止 → TimelineView 暂停,重绘只由相机等状态变化触发(CPU≈0)。
    private var renderPaused: Bool {
        physicsParked && hoveredId == nil && pulses.isEmpty && !cameraTracking
            && floatNodeId == nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let engine {
                    GraphRendererView(scene: scene,
                                    engine: engine,
                                    paused: renderPaused,
                                    pulses: pulses,
                                    pulseStart: pulseStart,
                                    pulseFlashSec: pulseFlashSec,
                                    hideLinks: config.current.display.graphHideLinks,
                                    interactive: !timelinePlaying,
                                    camera: $camera,
                                    hoveredId: $hoveredId,
                                    contextNodeId: contextNodeId,
                                    cardNodeId: floatNodeId,
                                    mainBallImage: mainBallImage,
                                    onTapNode: handleTap,
                                    onNodeDragEnded: {
                                        // 拖球松手 = 回总览:先关卡片,再取景。
                                        floatNodeId = nil
                                        frameCameraToRing(animated: true)
                                    },
                                    onCameraInterrupt: cancelCameraTracking,
                                    onContextSelect: handleContextSelect,
                                    onContextDismiss: { contextNodeId = nil },
                                    onContextRename: beginFolderRename,
                                    onContextRecolor: beginRecolor,
                                    onContextDelete: beginFolderDelete)
                        .background(Color.black.opacity(0.001))   // 空白处也接手势
                        // 08-31 用户:播放期间整块画布不可点击、不可 hover。
                        .allowsHitTesting(!timelinePlaying)

                    // 浮窗:锚在球旁,物理在动时跟着球走(同一时钟)。
                    if let fid = floatNodeId, fid < scene.nodes.count {
                        SwiftUI.TimelineView(.animation(minimumInterval: nil,
                                                        paused: renderPaused)) { _ in
                            GraphFloatWindow(
                                node: scene.nodes[fid],
                                loadWhenVisible: zone != .portrait || floatRevealed,
                                onClose: { floatNodeId = nil },
                                onJumpToEvent: jumpToEvent)
                            .id(zone == .portrait ? fid : -1)
                            // 渐显:取景收官前隐着(也不接事件),之后 0.22s 淡入。
                            .opacity(floatRevealed ? 1 : 0)
                            .allowsHitTesting(floatRevealed)
                            .position(floatPosition(for: fid, engine: engine,
                                                    viewSize: geo.size))
                        }
                    }
                } else {
                    Color.clear
                }
                // 播放护盾:画布已 allowsHitTesting(false),这层负责把"任何点击"
                // 变成暂停(08-31 用户)。层级在浮窗/时间线条/HUD 之下 ——
                // 条上的播放键、擦洗与 HUD 按钮不受影响。
                if timelinePlaying {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { timelinePlaying = false }
                }
                if let tidx = timelineIndex {
                    VStack {
                        Spacer()
                        GraphTimelineBar(
                            index: tidx,
                            day: $timelineDay,
                            playing: $timelinePlaying,
                            nodeCount: scene.nodes.count,
                            folderCount: scene.nodes.filter {
                                if case .folder = $0.kind { return true } else { return false }
                            }.count,
                            onExit: { exitTimelineWithFade(thenFocus: nil) })
                            .padding(.bottom, 18)
                            .opacity(timelineFading ? 0 : 1)
                            .allowsHitTesting(!timelineFading)
                            .animation(.easeOut(duration: 0.28), value: timelineFading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                hud
            }
            // 内容区尺寸(取景算缩放要用);initial 捕获首帧,之后随窗变。
            .onChange(of: geo.size, initial: true) { _, s in viewSize = s }
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        // 主窗口是 chromeless + isMovableByWindowBackground=true(全局设计),
        // 但图谱里拖拽 = 平移/拖球,绝不能带动整个窗口(07-01 update)。
        // 垫一个 mouseDownCanMoveWindow=false 的 NSView 局部关掉背景拖窗。
        .background(WindowDragBlocker())
        .task(id: zone) { await reload() }
        // ⚠️ 监听器留着会**全局**吞掉方向键(离开图谱后别处也按不动),
        // 所以视图消失 / 换画布都必须摘掉。
        .onDisappear { leaveTimeline(zone: zone) }
        // 时间线:换日 → 重建那天的场景喂给引擎(按身份迁移位置,不重排)
        .onChange(of: timelineDay) { _, d in
            guard timelineIndex != nil, d != .distantPast else { return }
            applyTimelineDay(d)
            // ③ 逐日图谱规模差很多(几百 → 一千多球),焦点必须跟着重取,
            // 否则停在旧视角上看不全。frameCameraToRing 是**跟随实时目标的
            // lerp**,连续拨动会自然平滑过渡(新的一发取消上一发)。
            frameCameraToRing(animated: true)
        }
        // 播放:逐日推进,到头自停
        .task(id: timelinePlaying) {
            guard timelinePlaying, let tidx = timelineIndex else { return }
            hoveredId = nil
            floatNodeId = nil
            let cal = Calendar(identifier: .gregorian)
            while timelinePlaying, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(220))
                guard timelinePlaying, !Task.isCancelled else { break }
                if timelineDay >= tidx.range.upperBound { timelinePlaying = false; break }
                if let nx = cal.date(byAdding: .day, value: 1, to: timelineDay) {
                    timelineDay = cal.startOfDay(for: nx)
                }
            }
        }
        // 主球照片:进入即加载;Settings 上传/移除发通知 → 立即重载(07-11 update)。
        .task { await loadMainBallImage() }
        .onReceive(NotificationCenter.default.publisher(for: .mainBallPhotoChanged)) { _ in
            Task { await loadMainBallImage() }
        }
        // park 事件 → 记录物理休眠态。engineGen 变化(引擎替换)重订阅。
        .task(id: engineGen) {
            guard let engine else { return }
            physicsParked = engine.isParked
            for await parked in engine.parkEvents { physicsParked = parked }
        }
        // 换画布:相机存回会话;浮窗/脉冲不跨画布。
        .onChange(of: zone) { oldZone, _ in
            // 换画布 → 退出时间线(portrait 没有 event 日期轴)。
            leaveTimeline(zone: oldZone)
            GraphSession.shared.entries[oldZone]?.camera = camera
            floatNodeId = nil
            pulses = []
        }
        // 浮窗渐显调度:开卡片后轮询取景状态,收官即淡入(见 floatRevealed 注释)。
        .onChange(of: floatNodeId) { _, v in
            floatRevealTask?.cancel()
            guard v != nil else { floatRevealed = false; return }
            floatRevealTask = Task { @MainActor in
                for _ in 0..<94 {   // ~1.5s 兜底:取景等物理沉降太久就先显示
                    if Task.isCancelled { return }
                    if !cameraTracking { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.22)) { floatRevealed = true }
            }
        }
        .onDisappear {
            GraphSession.shared.entries[zone]?.camera = camera
            cancelCameraTracking()
        }
        .alert("Rename folder", isPresented: Binding(
            get: { renameFolder != nil },
            set: { if !$0 { renameFolder = nil } }
        )) {
            TextField("Folder name", text: $renameDraft)
            Button("Save") { commitFolderRename() }
            Button("Cancel", role: .cancel) { renameFolder = nil }
        }
        .confirmationDialog(
            deleteFolder.map { "Delete folder “\($0.title)”?" } ?? "Delete folder?",
            isPresented: Binding(
                get: { deleteFolder != nil },
                set: { if !$0 { deleteFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete folder", role: .destructive) { commitFolderDelete() }
            Button("Cancel", role: .cancel) { deleteFolder = nil }
        } message: {
            Text("Removes the grouping only. The connected events are kept and move back to ungrouped.")
        }
        .sheet(item: $recolorTarget) { target in
            GraphRecolorSheet(
                title: target.title,
                hex: $recolorDraft,
                onCancel: { recolorTarget = nil },
                onSave: { commitRecolor(target) }
            )
        }
        .alert("Couldn't update Neural Graph", isPresented: Binding(
            get: { graphActionError != nil },
            set: { if !$0 { graphActionError = nil } }
        )) {
            Button("OK", role: .cancel) { graphActionError = nil }
        } message: {
            Text(graphActionError ?? "Unknown error")
        }
    }

    // MARK: - 视角取景(07-09 update:相机跟隐形环)

    /// 由环心+半径算取景相机:center=环心,zoom=让环基准直径占视口较短边
    /// cameraFrameFill。半径≈0 / 尺寸未知返回 nil。
    /// - Parameter bottomInset: 底部被遮挡的高度(时间线条)。取景改成把内容
    ///   居中到 **[0, H−inset]** 这块真正可见的区域:缩放按缩短后的短边算,
    ///   相机中心再下移 inset/(2·zoom)(世界 y 与屏幕 y 同向)→ 画面整体上抬,
    ///   边缘陨石不会被条盖住(07-11 用户)。
    private func frameFor(_ vs: CGSize, center: SIMD2<Float>, radius: Float,
                          fill: Double = GraphConstants.cameraFrameFill,
                          bottomInset: CGFloat = 0)
        -> GraphCamera? {
        guard radius > 1, vs.width > 1, vs.height > 1 else { return nil }
        let usableH = max(1, vs.height - bottomInset)
        let minDim = min(vs.width, usableH)
        let z = Double(minDim) * fill / (2 * Double(radius))
        var cam = GraphCamera()
        cam.zoom = min(max(z, GraphCamera.zoomRange.lowerBound),
                       GraphCamera.zoomRange.upperBound)
        cam.center = center
        cam.center.y += Float(bottomInset / (2 * cam.zoom))
        return cam
    }

    /// 时间线条占掉的底部高度(条高 ~80 + 底边距 18,留点余量)。
    /// 只影响**总览**取景;folder / 小球视角不动(用户要求)。
    private var timelineBarInset: CGFloat { timelineIndex != nil ? 104 : 0 }

    /// 开局取景目标:**优先预加载环**(界面显示前算好,即时可用,免等引擎
    /// ~50ms 钉环,且切回时不读旧环 → 不闪);portrait 无预加载时回退引擎
    /// 实时环。
    private func openCamera(_ vs: CGSize) -> GraphCamera? {
        if let pr = preloadedRing {
            return frameFor(vs, center: pr.center, radius: pr.radius)
        }
        return overviewCamera(vs)
    }

    /// 总览取景(松手/点空白/开场兜底):events 用引擎**实时**隐形环;
    /// portrait 等**无环**画布用全部节点的包围圆(中心=节点质心,半径=
    /// 罩住全部节点)—— 保证 portrait 也能框住全景。
    private func overviewCamera(_ vs: CGSize) -> GraphCamera? {
        guard let engine else { return nil }
        let ring = engine.readRingSnapshot()
        if ring.radius > 1 {
            return frameFor(vs, center: ring.center, radius: ring.radius,
                            bottomInset: timelineBarInset)
        }
        let snap = engine.readSnapshot()
        guard snap.count == scene.nodes.count, !snap.isEmpty else { return nil }
        var c = SIMD2<Float>.zero
        for p in snap { c += p }
        c /= Float(snap.count)
        var r: Float = 0
        for i in snap.indices {
            r = max(r, simd_length(snap[i] - c) + Float(scene.nodes[i].radius))
        }
        return frameFor(vs, center: c, radius: r, bottomInset: timelineBarInset)
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
        cameraRunID &+= 1
        let runID = cameraRunID
        let gen = engineGen
        // 开局:同步先用预加载环放好首帧(viewSize 就绪时;否则循环里兜底)。
        if !animated, let cam = openCamera(viewSize) { camera = cam }
        cameraTracking = true
        cameraTask = Task { @MainActor in
            defer { if runID == cameraRunID { cameraTracking = false } }
            let k = GraphConstants.cameraTrackLerp
            for i in 0..<900 {   // ~15s 上限兜底(含物理沉降 + 缓移)
                if Task.isCancelled || gen != engineGen || runID != cameraRunID { return }
                // 目标 = 实时总览(events 隐形环精确居中 / portrait 全部节点
                // 包围圆);开局头 ~50ms 引擎环未钉好时用预加载环兜底
                // (免这几帧无目标 → 停在旧相机闪一下)。
                let tgt = overviewCamera(viewSize) ?? (animated ? nil : openCamera(viewSize))
                guard let engine, let tgt else {
                    if animated { return }         // 松手却无环:异常,退出
                    if i > 180 { return }          // 开局 3s 无环(portrait)→ 放弃
                    try? await Task.sleep(for: .milliseconds(16)); continue
                }
                camera.center += (tgt.center - camera.center) * Float(k)
                camera.zoom += (tgt.zoom - camera.zoom) * k
                // ⚠️ 收敛必须**等物理休眠**(isParked)且相机贴合才收官:
                // 松手瞬间环还是拖动前的旧值,提前退出会跟不到环重算后的
                // 新值。保证每次松手都真正跟到最终环;开局同理,跟到真实
                // 环 = 精确居中。
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
        cameraRunID &+= 1
        cameraTracking = false
    }

    /// 点 folder 球聚焦(07-09 update):相机缓移到该 folder 的隐形圆(气泡)
    /// 视图 —— center=气泡心(= hub 位),zoom=气泡直径占视口 cameraFolderFill。
    /// tap 与 drag 由手势系统天然区分(DragGesture 有 2pt 阈值,纯点击不触发)。
    /// - Parameter onDone: 取景走完回调。早返(无引擎/无隐形圆/算不出取景)=
    ///   相机根本没动 → 立即回调,别把脉冲吞掉。
    private func frameCameraToFolder(_ hub: Int, onDone: (() -> Void)? = nil) {
        guard let engine, hub < scene.nodes.count,
              let br = scene.nodes[hub].hubBubbleRadius, br > 0 else { onDone?(); return }
        let snap = engine.readSnapshot()
        guard hub < snap.count,
              let tgt = frameFor(viewSize, center: snap[hub], radius: Float(br),
                                 fill: GraphConstants.cameraFolderFill)
        else { onDone?(); return }
        animateCamera(toCenter: tgt.center, toZoom: tgt.zoom, onDone: onDone)
    }

    /// 平滑聚焦到固定目标 (center, zoom)。**van Wijk & Nuij 2004「平滑高效的
    /// 缩放与平移」**:沿 c0→c1 世界直线,中心与缩放联合参数化,使观感匀速且
    /// **任意方向/缩放比都无过冲**。
    /// w = 世界可视宽度 = minDim/zoom;rho=1.4(缩放/平移权衡,原论文最优值)。
    /// 目标固定(点击时图已 park),t 基定时动画。
    /// - Parameter onDone: 取景**真正走完**才回调(07-11 update)。被取消 /
    ///   被新交互顶替 / 引擎换代 → **不回调**(那一发作废)。退化早返(无
    ///   缩放基准)= 相机瞬时到位,立即回调。
    private func animateCamera(toCenter c1: SIMD2<Float>, toZoom z1raw: Double,
                               onDone: (() -> Void)? = nil) {
        cameraTask?.cancel()
        cameraRunID &+= 1
        let runID = cameraRunID
        let z1 = min(max(z1raw, GraphCamera.zoomRange.lowerBound),
                     GraphCamera.zoomRange.upperBound)
        let c0 = camera.center, z0 = camera.zoom
        guard z0 > 1e-6 else {
            cameraTracking = false; camera.center = c1; camera.zoom = z1
            onDone?(); return
        }
        // 已在目标机位(重复点同一个 hub;图已 park → 目标逐次相同)→ 镜头无事
        // 可做,别跑那 36 帧(~0.6s)**空动画**。否则:①每次重复点击都要白等
        // 一段才发脉冲 ②在这段空动画里再点一次,新的 animateCamera 会 cancel
        // 掉上一个 task,上一发挂在 onDone 上的脉冲**被直接吞掉**。
        // 立即完成 → 连点即连发,新脉冲叠加到在飞的那批上(triggerPulse 本就叠加)。
        if simd_length(c1 - c0) < 0.5, abs(log(z1 / z0)) < 0.005 {
            cameraTracking = false
            camera.center = c1; camera.zoom = z1
            onDone?(); return
        }
        let minDim = Double(min(viewSize.width, viewSize.height))
        guard minDim > 1 else {
            cameraTracking = false; camera.center = c1; camera.zoom = z1
            onDone?(); return
        }
        let w0 = minDim / z0, w1 = minDim / z1   // 世界可视宽度
        let dir = c1 - c0
        let u1 = Double(simd_length(dir))         // 中心间世界距离
        let n = max(GraphConstants.cameraFocusFrames, 1)
        let gen = engineGen
        cameraTracking = true
        cameraTask = Task { @MainActor in
            defer { if runID == cameraRunID { cameraTracking = false } }
            // 中心几乎重合(纯缩放,如已在总览心处点空白):指数插值缩放,
            // 避开 van Wijk 的 1/u1 除零。
            if u1 < 1e-4 {
                for i in 0...n {
                    if Task.isCancelled || gen != engineGen || runID != cameraRunID { return }
                    let u = Double(i) / Double(n)
                    let t = u * u * (3 - 2 * u)
                    camera.center = c1
                    camera.zoom = minDim / (w0 * pow(w1 / w0, t))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard !Task.isCancelled, gen == engineGen, runID == cameraRunID else { return }
                camera.center = c1; camera.zoom = z1
                onDone?(); return
            }
            // 同一气泡里的小球目标倍率相同。van Wijk 路径仍会为了平移
            // 先缩远再放回,周围球看起来像绕着 folder 转,连续换球也更重。
            // 倍率近似不变时直接平移,保持现有时长和缓入缓出。
            if zone == .portrait, abs(log(z1 / z0)) < 0.03 {
                for i in 0...n {
                    if Task.isCancelled || gen != engineGen || runID != cameraRunID { return }
                    let u = Double(i) / Double(n)
                    let t = u * u * (3 - 2 * u)
                    camera.center = c0 + dir * Float(t)
                    camera.zoom = z0 * pow(z1 / z0, t)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard !Task.isCancelled, gen == engineGen, runID == cameraRunID else { return }
                camera.center = c1; camera.zoom = z1
                onDone?(); return
            }
            // 表达式拆成显式 Double 中间量(否则 Swift 类型检查器超时)
            let rho: Double = 1.4
            let rho2: Double = rho * rho
            let rho4: Double = rho2 * rho2
            let dw: Double = w1 * w1 - w0 * w0
            let uu2: Double = u1 * u1
            let b0: Double = (dw + rho4 * uu2) / (2 * w0 * rho2 * u1)
            let b1: Double = (dw - rho4 * uu2) / (2 * w1 * rho2 * u1)
            let r0: Double = log(-b0 + (b0 * b0 + 1).squareRoot())
            let r1: Double = log(-b1 + (b1 * b1 + 1).squareRoot())
            let bigS: Double = (r1 - r0) / rho        // 变换空间总弧长
            let coshR0: Double = cosh(r0)
            let sinhR0: Double = sinh(r0)
            let unit = dir / Float(u1)                // c0→c1 单位方向
            for i in 0...n {
                if Task.isCancelled || gen != engineGen || runID != cameraRunID { return }
                let u = Double(i) / Double(n)
                let t: Double = u * u * (3 - 2 * u)   // 对弧长参数再加缓入缓出
                let s: Double = t * bigS
                let denomW: Double = cosh(rho * s + r0)
                let w: Double = w0 * coshR0 / denomW
                // 沿直线走过的世界距离(s=0 → 0,s=S → u1)
                let uuA: Double = (w0 / rho2) * coshR0 * tanh(rho * s + r0)
                let uuB: Double = (w0 / rho2) * sinhR0
                let uu: Double = uuA - uuB
                camera.center = c0 + unit * Float(uu)
                camera.zoom = minDim / w
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, gen == engineGen, runID == cameraRunID else { return }
            camera.center = c1; camera.zoom = z1
            onDone?()
        }
    }

    // MARK: - 交互路由

    private func handleContextSelect(_ id: Int) {
        guard id < scene.nodes.count else { return }
        contextNodeId = id
        floatNodeId = nil
    }

    private func beginFolderRename(_ id: Int) {
        guard id < scene.nodes.count,
              case .folder(let slug) = scene.nodes[id].kind,
              slug != GraphSceneBuilder.unclassifiedSlug else { return }
        renameFolder = FolderMenuTarget(
            id: slug,
            title: scene.nodes[id].title
        )
        renameDraft = scene.nodes[id].title
    }

    private func beginRecolor(_ id: Int) {
        guard id < scene.nodes.count else { return }
        let node = scene.nodes[id]
        let kind: RecolorTarget.Kind
        let targetID: String
        switch node.kind {
        case .folder(let slug) where slug == GraphSceneBuilder.unclassifiedSlug:
            kind = .unclassified
            targetID = "unclassified"
        case .folder(let slug) where slug != GraphSceneBuilder.unclassifiedSlug:
            kind = .folder(slug)
            targetID = "folder:" + slug
        case .category(let name):
            kind = .category(name)
            targetID = "category:" + name
        default:
            return
        }
        recolorDraft = String(
            format: "#%02X%02X%02X",
            Int(round(node.colorRGB.x * 255)),
            Int(round(node.colorRGB.y * 255)),
            Int(round(node.colorRGB.z * 255))
        )
        recolorTarget = RecolorTarget(id: targetID, title: node.title, kind: kind)
    }

    private func beginFolderDelete(_ id: Int) {
        guard id < scene.nodes.count,
              case .folder(let slug) = scene.nodes[id].kind,
              slug != GraphSceneBuilder.unclassifiedSlug else { return }
        deleteFolder = FolderMenuTarget(
            id: slug,
            title: scene.nodes[id].title
        )
    }

    private func commitFolderRename() {
        guard let target = renameFolder else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        renameFolder = nil
        guard name != target.title else { return }
        Task { @MainActor in
            do {
                try EventFolderStore.rename(slug: target.id, to: name)
                await reload()
            } catch {
                graphActionError = error.localizedDescription
            }
        }
    }

    private func commitRecolor(_ target: RecolorTarget) {
        guard let hex = recolorDraft else { return }
        recolorTarget = nil
        Task { @MainActor in
            do {
                switch target.kind {
                case .folder(let slug):
                    try EventFolderStore.setColor(slug: slug, hex: hex)
                case .category(let name):
                    try PortraitGraphStyleStore.setColor(hex, for: name)
                case .unclassified:
                    try EventGraphStyleStore.setUnclassifiedColor(hex)
                }
                await reload()
            } catch {
                graphActionError = error.localizedDescription
            }
        }
    }

    private func commitFolderDelete() {
        guard let target = deleteFolder else { return }
        deleteFolder = nil
        Task { @MainActor in
            do {
                try EventFolderStore.delete(slug: target.id)
                await reload()
            } catch {
                graphActionError = error.localizedDescription
            }
        }
    }

    /// 点空白 = 关浮窗;点末端球 = 开浮窗;点 hub = 神经脉冲(无浮窗,需求 §5)。
    /// 点 folder 球(有隐形圆的 hub,非主球)额外聚焦该 folder 视图(07-09 update)。
    private func handleTap(_ id: Int?) {
        guard let id, id < scene.nodes.count else {
            floatNodeId = nil
            // 点空白 → 平滑移回开场总览(当前隐形环/全节点包围圆);07-09 update。
            // 与 folder 聚焦同一套平滑动画(直线到中心+几何缩放),消拉回。
            if let tgt = overviewCamera(viewSize) {
                animateCamera(toCenter: tgt.center, toZoom: tgt.zoom)
            }
            return
        }
        if scene.nodes[id].kind.isHub {
            floatNodeId = nil
            // 07-11 update:点 folder/分区球先转视角,**取景转完再发脉冲**。
            // 主球没有取景变换 → 立即发。取景中途被新交互打断 → onDone 不
            // 回调,那一发作废。
            if scene.nodes[id].hubBubbleRadius != nil {
                if timelineIndex != nil {
                    // 时间线模式下点 folder = 进 folder 视图 → 淡出退出,
                    // 取景与淡出同时起步(⑤)。
                    exitTimelineWithFade(thenFocus: id)
                } else {
                    frameCameraToFolder(id) { triggerPulse(from: id) }
                }
            } else {
                triggerPulse(from: id)
            }
        } else {
            // 渐显:先隐,取景收官后淡入(同帧生效)。⚠️ 只在**换球**时置隐:
            // 重复点同一球 floatNodeId 值不变 → onChange 不触发 → 没人再把
            // 它淡回来,会永久隐身。
            if floatNodeId != id { floatRevealed = false }
            floatNodeId = id
            // 点小球 → 与信息面板绑定的取景(07-10,event/portrait 两区
            // 同款):相机聚焦该球,zoom = 所在家气泡占视口 cameraFolderFill
            // —— 与 folder 聚焦同一缩放级,folder 视角转小球视角时只平移不
            // 变焦,不跳。图已静止 → van Wijk(见 frameCameraToLeaf,治拉回)。
            frameCameraToLeaf(id)
        }
    }

    /// folder/分区球的脉冲速度 = 该球连线的平均长度 / 1.5s(07-11 update)。
    /// ⚠️ 只统计**脉冲真正会走的边**(排除 blocked 的主球那条):主球那条边又长
    /// 又不发光,算进均值会把它抬高 —— 叶子少的小 folder 抬得最狠(3 叶时均值
    /// 近 2×)→ 脉冲快一倍,恰好破坏"每个 folder 都 1.5s"的一致性。
    /// 取不到边(理论上不会)→ 回落常量。
    private func hubPulseSpeed(from hub: Int, snap: [SIMD2<Float>],
                               blocked: Set<Int>) -> Double {
        var sum = 0.0
        var cnt = 0
        for e in scene.edges {
            let other: Int
            if e.a == hub { other = e.b } else if e.b == hub { other = e.a } else { continue }
            guard !blocked.contains(other), other < snap.count else { continue }
            sum += Double(simd_length(snap[other] - snap[hub]))
            cnt += 1
        }
        guard cnt > 0, sum > 0 else { return GraphConstants.pulseSpeed }
        return (sum / Double(cnt)) / GraphConstants.pulseHubTravelSeconds
    }

    private func triggerPulse(from hub: Int) {
        guard let engine else { return }
        let snap = engine.readSnapshot()
        guard snap.count == scene.nodes.count else { return }
        // 只有主球级联 2 跳(信号穿过 folder/分区抵达末端);
        // 其它 hub 只传 1 跳到直接相连的球(07-01 update),且**不传主球**
        //(07-03 精修:folder/分区点击只发给自家 event 球)。
        let isMain = scene.nodes[hub].kind == .main
        let depth = isMain ? GraphConstants.pulseMaxDepthMain
                           : GraphConstants.pulseMaxDepthOther
        let blocked: Set<Int> = isMain ? [] : [0]
        // folder/分区球:速度自适应(07-11 update)= 该球连线的**平均长度**
        // / pulseHubTravelSeconds → 脉冲恰好用那么久走完一条平均边,不论
        // folder 大小观感一致。主球仍用常量(它 2 跳级联,自适应会让总时长翻倍)。
        // 两者都再乘用户的脉冲档位倍率(pulseScale,>1 更快)。
        let speed = (isMain ? GraphConstants.pulseSpeed
                            : hubPulseSpeed(from: hub, snap: snap, blocked: blocked))
                    * pulseScale
        let (list, total) = GraphPulseScheduler.schedule(from: hub, scene: scene,
                                                         positions: snap,
                                                         speed: speed,
                                                         maxDepth: depth,
                                                         blocked: blocked)
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
        // ⚠️ 必须再等抵达闪光淡完:pulses 一空,renderPaused 立刻停重绘、
        // drawBalls 也读不到抵达时刻 → 末端球的闪光会被拦腰切断(07-11 update)。
        let wait = pulseEnd - base + pulseFlashSec + 0.2
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
        if floatNodeId != idx { floatRevealed = false }   // 渐显(同上,换球才置隐)
        floatNodeId = idx
        frameCameraToEventBall(idx)
    }

    /// 跳转落地取景(07-10 update):相机 lerp 跟随**目标球实时位置**(跨画布
    /// 跳转时引擎刚炸开,球还要飞几秒,一次定死会对准过期位置),zoom = 该球
    /// 所在家的气泡直径占视口 cameraFolderFill(家上下文可见、球居中)。跟到
    /// 物理定稳且贴合才收官;手动平移/缩放/起拖照常中止(同一 cameraTask 单槽)。
    private func frameCameraToEventBall(_ idx: Int) {
        cameraTask?.cancel()
        cameraRunID &+= 1
        let runID = cameraRunID
        let gen = engineGen
        cameraTracking = true
        cameraTask = Task { @MainActor in
            defer { if runID == cameraRunID { cameraTracking = false } }
            let k = GraphConstants.cameraTrackLerp
            for _ in 0..<900 {   // ~15s 上限兜底(含物理沉降)
                if Task.isCancelled || gen != engineGen || runID != cameraRunID { return }
                guard let engine, idx < scene.nodes.count else { return }
                let snap = engine.readSnapshot()
                guard idx < snap.count else { return }
                let hub = scene.nodes[idx].hubIndex
                let br = (hub >= 0 && hub < scene.nodes.count
                          ? scene.nodes[hub].hubBubbleRadius : nil) ?? 160
                guard let tgt = frameFor(viewSize, center: snap[idx],
                                         radius: Float(br),
                                         fill: GraphConstants.cameraFolderFill)
                else { return }
                camera.center += (tgt.center - camera.center) * Float(k)
                camera.zoom += (tgt.zoom - camera.zoom) * k
                if engine.isParked,
                   simd_length(tgt.center - camera.center) < 0.5,
                   abs(tgt.zoom - camera.zoom) < 0.001 {
                    camera = tgt
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// 点小球取景(07-10 update):图已静止,球不动 → 用 **animateCamera(van Wijk)**
    /// 到固定目标,而非 frameCameraToEventBall 的 lerp 跟随 —— lerp 跟随在大
    /// 放大比(总览级 → 单球家气泡级)下,目标球屏幕位置会先冲离中心再回来,
    /// 视角强拉回;van Wijk 单调无过冲。目标同 EventBall:center = 球位,
    /// zoom = 所在家气泡占视口 cameraFolderFill。
    private func frameCameraToLeaf(_ idx: Int) {
        guard let engine, idx < scene.nodes.count else { return }
        let snap = engine.readSnapshot()
        guard idx < snap.count else { return }
        let hub = scene.nodes[idx].hubIndex
        let br = (hub >= 0 && hub < scene.nodes.count
                  ? scene.nodes[hub].hubBubbleRadius : nil) ?? 160
        guard let tgt = frameFor(viewSize, center: snap[idx], radius: Float(br),
                                 fill: GraphConstants.cameraFolderFill) else { return }
        animateCamera(toCenter: tgt.center, toZoom: tgt.zoom)
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
            // 前端文案一律英文(2026-07-01 update)。
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
            // 时间线入口:只有 events 画布有历史可看(portrait 无 event 日期轴)。
            if zone == .events {
                Button {
                    // ④ 再点一次 = 关闭(与叉掉等价)
                    if timelineIndex != nil { exitTimelineWithFade(thenFocus: nil) }
                    else { Task { await enterTimeline() } }
                } label: {
                    Image(systemName: timelineLoading ? "clock.badge.questionmark"
                          : (timelineIndex != nil ? "clock.fill" : "clock.arrow.circlepath"))
                }
                .buttonStyle(.bouncyIcon)
                .disabled(timelineLoading)
                .help(timelineIndex != nil ? "Close timeline"
                      : "Timeline — watch the graph change day by day")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard()
        .padding(.top, 44)
        .padding(.trailing, 16)
    }

    // MARK: - 加载 / 引擎生命周期

    @MainActor
    /// 主球照片:后台读盘解码(大图别卡主线程),回主线程赋值。文件不在=nil。
    private func loadMainBallImage() async {
        guard MainBallPhoto.exists else { mainBallImage = nil; return }
        let p = MainBallPhoto.url.path
        let img = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOfFile: p)
        }.value
        mainBallImage = img
    }

    // MARK: - 时间线

    /// 进时间线模式:解析一次索引(后台),停在最新一天。
    @MainActor
    private func enterTimeline() async {
        guard timelineIndex == nil, !timelineLoading, zone == .events else { return }
        timelineLoading = true
        defer { timelineLoading = false }
        let idx = await Task.detached(priority: .userInitiated) {
            EventTimeline.load()
        }.value
        guard let idx else { return }
        floatNodeId = nil
        pulses = []
        cancelCameraTracking()
        timelineFading = false
        timelineIndex = idx
        timelineDay = idx.range.upperBound
        applyTimelineDay(idx.range.upperBound)
        startTimelineKeys()
        // ② 进时间线 → 回主视角(顺带按新的底条 inset 重新取景)
        frameCameraToRing(animated: true)
    }

    /// 左右方向键:逐日前后挪一天,夹在数据范围内。按键即停播放
    /// (与拖动擦洗同样的语义:手动介入就不再自动跑)。
    private func stepTimeline(_ delta: Int) {
        guard let idx = timelineIndex else { return }
        timelinePlaying = false
        let cal = Calendar(identifier: .gregorian)
        guard let nx = cal.date(byAdding: .day, value: delta, to: timelineDay) else { return }
        let clamped = min(max(cal.startOfDay(for: nx), idx.range.lowerBound),
                          idx.range.upperBound)
        if clamped != timelineDay { timelineDay = clamped }
    }

    /// 挂方向键监听。**不用 SwiftUI 的 .focusable/.onKeyPress** —— 画布里有
    /// NSViewRepresentable 子视图在抢第一响应者,那套拿不到焦点(实测按键无
    /// 反应)。改用本项目已有的本地事件监听惯例(RightClickHighlight /
    /// GraphRendererView 同款),绕开焦点系统。
    private func startTimelineKeys() {
        timelineKeyMonitor?.stop()
        let m = TimelineKeyMonitor()
        m.start(onLeft: { stepTimeline(-1) }, onRight: { stepTimeline(1) })
        timelineKeyMonitor = m
    }

    private func stopTimelineKeys() {
        timelineKeyMonitor?.stop()
        timelineKeyMonitor = nil
    }

    /// 离开时间线态的统一收口(退出按钮 / 换画布 / 视图消失三个出口共用)。
    /// ⚠️ 必须作废会话缓存的指纹:引擎此刻停在**某一天**的节点集合上,若不作废,
    /// 下次 reload 会走"指纹没变→复用引擎"那条去调 updateScene,而那道
    /// `count == n` 门会因节点数对不上而**静默 return**,留下场景与引擎错位的
    /// 坏状态(画面停在旧的一天且再也不更新)。改掉指纹 → 走重建分支。
    private func leaveTimeline(zone z: GraphZone) {
        guard timelineIndex != nil else { return }
        timelinePlaying = false
        stopTimelineKeys()
        timelineIndex = nil
        timelineDay = .distantPast
        timelineFading = false
        GraphSession.shared.entries[z]?.fingerprint = ["__timeline_exit__"]
    }

    /// 退出 → 回到今天的 live 图,**但不重排布局**(07-11 用户:叉掉或自动消失
    /// 时不要刷新界面种子,可以回到今天但样式别变)。
    ///
    /// 所以这里**不走 reload** —— reload 会新建引擎、换一个新的随机种子、重新
    /// 炸开,整张图的排布全变。改成把 live 场景用 `updateSceneRemapping` 换进去:
    /// 存活的球位置逐字保留,只有"那天还没诞生、现在该出现"的球从自己 folder
    /// 里长出来。顺带把会话缓存同步成 live,后续 reload 才不会又撞上
    /// updateScene 的 `count == n` 门。
    @MainActor
    private func exitTimelineKeepingLayout() async {
        guard timelineIndex != nil else { return }
        timelinePlaying = false
        stopTimelineKeys()
        let z = zone
        let halfLife = Double(ConfigStore.shared.current.memory.weightHalfLifeDays)
        let info = ConfigStore.shared.current.personalInfo
        let name = [info.alias, info.firstName].first { !$0.isEmpty } ?? "Me"
        let built = await Task.detached(priority: .userInitiated) {
            GraphSceneBuilder.build(zone: z, halfLifeDays: halfLife, userName: name)
        }.value
        guard z == zone else { return }   // 期间切了画布 → 丢弃
        applyRemappedScene(built)
        GraphSession.shared.entries[z]?.scene = built
        GraphSession.shared.entries[z]?.fingerprint = GraphSession.fingerprint(of: built)
        // 状态最后才清 —— 淡出期间条要一直在,否则会"啪"地消失(⑤)
        timelineIndex = nil
        timelineDay = .distantPast
        timelineFading = false
    }

    /// ⑤ 淡出式退出:**淡出、取景、换回 live 场景三件事同时开跑**,不排队。
    /// 取景目标用**当前**场景算好后就固定住,而换场景是按身份迁移位置(存活的
    /// 球不动),所以镜头飞到一半把场景换掉也不会跑偏 —— 这是"丝滑"的关键。
    private func exitTimelineWithFade(thenFocus hubId: Int?) {
        guard timelineIndex != nil, !timelineFading else { return }
        timelinePlaying = false
        stopTimelineKeys()
        timelineFading = true
        if let hubId, hubId < scene.nodes.count {
            frameCameraToFolder(hubId) { triggerPulse(from: hubId) }
        } else {
            frameCameraToRing(animated: true)   // 没指定目标 = 回主视角
        }
        Task { await exitTimelineKeepingLayout() }
    }

    /// 把新场景按**节点身份**换进引擎:存活的球位置延续,新生的球从自己 hub
    /// 长出来。时间线换日与退出时间线共用。
    @MainActor
    private func applyRemappedScene(_ newScene: GraphScene) {
        guard let engine else { return }
        let oldFP = GraphSession.fingerprint(of: scene)
        var at: [String: Int] = [:]
        at.reserveCapacity(oldFP.count)
        for (i, f) in oldFP.enumerated() where at[f] == nil { at[f] = i }
        let carry = GraphSession.fingerprint(of: newScene).map { at[$0] ?? -1 }
        scene = newScene
        engine.updateSceneRemapping(newScene, carryOver: carry)
        floatNodeId = nil
        hoveredId = nil
    }

    /// 换到某一天:重建场景 + 按身份把位置迁移过去(存活的球不重排)。
    @MainActor
    private func applyTimelineDay(_ d: Date) {
        guard let idx = timelineIndex else { return }
        let info = ConfigStore.shared.current.personalInfo
        let name = [info.alias, info.firstName].first { !$0.isEmpty } ?? "Me"
        applyRemappedScene(
            GraphSceneBuilder.buildEventsTimeline(index: idx, on: d, userName: name))
    }

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

        // 随机种子(07-09 update):保留每次打开布局有变化;界面显示前先
        // headless 跑出该种子的最终隐形环,相机开局即按此取景 —— 变化 +
        // 不闪。同一 seed 喂给 preload 与真正的引擎,布局一致(preloadRing
        // == 引擎最终环的影子预测)。
        let seed = UInt64.random(in: .min ... .max)
        let ring = await Task.detached(priority: .userInitiated) {
            GraphPhysicsEngine.preloadRing(scene: built, seed: seed)
        }.value
        guard gen == loadGen else { return }   // preload 期间切了 zone → 丢弃
        preloadedRing = ring

        let fp = GraphSession.fingerprint(of: built)
        if let cached = GraphSession.shared.entries[z], cached.fingerprint == fp {
            // 数据没变:复用引擎,刷边参数后**重放展开动画**(07-02
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
        // 陨石滑动速度旋钮(07-11 update):把 config 档位推给引擎(归位 glide +
        // 开局点亮速度)。两分支合流,新建/复用引擎都覆盖;下 tick 生效不重建。
        engine?.setAnimationSpeedScale(
            ConfigStore.shared.current.display.graphAnimationSpeed.animationScale)
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

private struct GraphRecolorSheet: View {
    let title: String
    @Binding var hex: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    private var color: Binding<Color> {
        Binding(
            get: { hex.flatMap(FolderPalette.color(fromHex:)) ?? .blue },
            set: { value in
                if let converted = FolderPalette.hex(from: NSColor(value)) {
                    hex = converted
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change color")
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ColorPicker("Color", selection: color, supportsOpacity: false)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
