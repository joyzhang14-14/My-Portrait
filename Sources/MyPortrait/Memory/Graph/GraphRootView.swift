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

/// 图谱模式的根视图:按 scope 决定画布(Events → event 图,portrait 分类 →
/// portrait 图),负责数据加载、物理引擎生命周期与 HUD。
/// 渲染在主窗口右侧内容区(与 MemoriesView 同位置),不开新窗口。
/// 非图谱 scope(personalInfo/input)不会路由进来 —— ContentView 保证。
struct GraphRootView: View {
    @Binding var scope: MemoryScope

    @State private var scene: GraphScene = .empty
    @State private var engine: GraphPhysicsEngine? = nil
    /// 引擎替换代际:驱动 park 订阅 task 重启(每个引擎的事件流只消费一次)。
    @State private var engineGen = 0
    @State private var paused = false
    @State private var camera = GraphCamera()
    @State private var hoveredId: Int? = nil
    @State private var loading = false
    /// 加载代际 token:快速切 zone 时丢弃过期结果(同 MemoriesView.reload 模式)。
    @State private var loadGen = 0

    private var zone: GraphZone {
        if case .portrait = scope { return .portrait }
        return .events
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let engine {
                GraphCanvasView(scene: scene,
                                engine: engine,
                                paused: paused,
                                camera: $camera,
                                hoveredId: $hoveredId)
                    .background(Color.black.opacity(0.001))   // 空白处也接手势
            } else {
                Color.clear
            }
            hud
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task(id: zone) { await reload() }
        // park 事件 → 暂停/恢复 TimelineView。engineGen 变化(引擎替换)重订阅。
        .task(id: engineGen) {
            guard let engine else { return }
            paused = engine.isParked
            for await parked in engine.parkEvents { paused = parked }
        }
        // 换画布前把相机存回会话,回来还原视角。
        .onChange(of: zone) { oldZone, _ in
            GraphSession.shared.entries[oldZone]?.camera = camera
        }
        .onDisappear {
            GraphSession.shared.entries[zone]?.camera = camera
        }
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

        let fp = GraphSession.fingerprint(of: built)
        if let cached = GraphSession.shared.entries[z], cached.fingerprint == fp {
            // 数据没变:复用引擎(位置/布局保留),只刷边参数(rest 随天数漂移)
            cached.engine.updateScene(built)
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
            let fresh = GraphPhysicsEngine(scene: built)
            GraphSession.shared.entries[z] = .init(scene: built, engine: fresh,
                                                   fingerprint: fp, camera: GraphCamera())
            scene = built
            engine = fresh
            engineGen += 1
            camera = GraphCamera()
        }
        hoveredId = nil
        loading = false
    }
}
