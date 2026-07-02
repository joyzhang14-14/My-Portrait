import SwiftUI
import simd

/// 图谱模式的根视图:按 scope 决定画布(Events → event 图,portrait 分类 →
/// portrait 图),负责数据加载与 HUD(刷新/计数)。
/// 非图谱 scope(personalInfo/input)不会路由进来 —— ContentView 保证。
struct GraphRootView: View {
    @Binding var scope: MemoryScope

    @State private var scene: GraphScene = .empty
    @State private var positions: [SIMD2<Float>] = []
    @State private var camera = GraphCamera()
    @State private var hoveredId: Int? = nil
    @State private var loading = false
    /// 代际 token:快速切 zone 时丢弃过期的加载结果(同 MemoriesView.reload 模式)。
    @State private var loadGen = 0

    private var zone: GraphZone {
        if case .portrait = scope { return .portrait }
        return .events
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GraphCanvasView(scene: scene,
                            positions: positions,
                            camera: $camera,
                            hoveredId: $hoveredId)
                .background(Color.black.opacity(0.001))   // 让空白处也接手势

            hud
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .task(id: zone) { await reload() }
    }

    // MARK: - HUD

    private var hud: some View {
        HStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            }
            Text("\(scene.nodes.count) 球 · \(scene.edges.count) 线")
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

    // MARK: - 加载

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
        let (builtScene, builtPositions) = await Task.detached(priority: .userInitiated) {
            let s = GraphSceneBuilder.build(zone: z, halfLifeDays: halfLife, userName: name)
            return (s, GraphStaticLayout.layout(scene: s))
        }.value
        guard gen == loadGen else { return }   // 期间切了 zone → 丢弃
        scene = builtScene
        positions = builtPositions
        hoveredId = nil
        loading = false
    }
}
