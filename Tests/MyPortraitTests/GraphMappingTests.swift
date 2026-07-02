import XCTest
import simd
@testable import MyPortrait

/// 需求 §4 数据映射公式的单测(强度/距离/线宽/命中网格)。
final class GraphMappingTests: XCTestCase {

    // MARK: folder → 主球 连接强度:Σw²/Σw + 10(自加权平均)

    func testFolderStrengthSelfWeighted() {
        // 均匀权重退化为普通平均:w=[2,2] → 4+... Σw²/Σw = 8/4 = 2 → 12
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: [2, 2]), 12, accuracy: 1e-9)
        // 高 weight 话语权大:[1,1,1,9] 普通均值 3,自加权 = 84/12 = 7 → 17
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: [1, 1, 1, 9]), 17, accuracy: 1e-9)
    }

    func testFolderStrengthEmptyIsBase() {
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: []),
                       GraphConstants.folderStrengthBase, accuracy: 1e-9)
        // 全 0 权重也不能除零
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: [0, 0]),
                       GraphConstants.folderStrengthBase, accuracy: 1e-9)
    }

    // MARK: last_occurred → 距离:对数,30 天封顶

    func testLeafDistanceEndpoints() {
        let near = GraphConstants.eventLeafDistanceNear
        let far = GraphConstants.eventLeafDistanceFar
        // 0 天 = 最近端
        XCTAssertEqual(GraphConstants.leafDistance(daysAgo: 0, near: near, far: far),
                       near, accuracy: 1e-9)
        // 30 天 = 最远端;>30 天不再变
        XCTAssertEqual(GraphConstants.leafDistance(daysAgo: 30, near: near, far: far),
                       far, accuracy: 1e-9)
        XCTAssertEqual(GraphConstants.leafDistance(daysAgo: 365, near: near, far: far),
                       far, accuracy: 1e-9)
    }

    /// 对数平缓:第 1→2 天的增量远小于线性均摊(差一天不明显,用户要求)。
    func testLeafDistanceLogGentle() {
        let near = GraphConstants.eventLeafDistanceNear
        let far = GraphConstants.eventLeafDistanceFar
        let d1 = GraphConstants.leafDistance(daysAgo: 1, near: near, far: far)
        let d2 = GraphConstants.leafDistance(daysAgo: 2, near: near, far: far)
        let d29 = GraphConstants.leafDistance(daysAgo: 29, near: near, far: far)
        let d30 = GraphConstants.leafDistance(daysAgo: 30, near: near, far: far)
        // 单调递增
        XCTAssertLessThan(d1, d2)
        XCTAssertLessThan(d29, d30)
        // 尾端(29→30 天)的日增量应远小于头部(1→2 天):对数曲线越走越平
        XCTAssertLessThan(d30 - d29, d2 - d1)
    }

    // MARK: 连接强度 → 线宽:clamp

    func testEdgeWidthClamp() {
        XCTAssertEqual(GraphConstants.edgeWidth(strength: 0),
                       GraphConstants.widthMin, accuracy: 1e-9)
        XCTAssertEqual(GraphConstants.edgeWidth(strength: 1000),
                       GraphConstants.widthMax, accuracy: 1e-9)
        // 中段线性:S=10 → 3.5
        XCTAssertEqual(GraphConstants.edgeWidth(strength: 10), 3.5, accuracy: 1e-9)
    }

    // MARK: 命中网格

    func testHitGridFindsBallAndRespectsRadius() {
        // 三个球:大球(0,0,r=44)、小球(200,0,r=5)、远球(-300,-300,r=10)
        let positions: [SIMD2<Float>] = [.zero, SIMD2(200, 0), SIMD2(-300, -300)]
        let radii: [Double] = [44, 5, 10]
        let grid = GraphHitGrid(positions: positions, radii: radii)
        // 球心命中
        XCTAssertEqual(grid.hit(world: .zero), 0)
        XCTAssertEqual(grid.hit(world: SIMD2(200, 0)), 1)
        // 半径边缘内(含 slop=4)命中,远超出不命中
        XCTAssertEqual(grid.hit(world: SIMD2(42, 0)), 0)
        XCTAssertEqual(grid.hit(world: SIMD2(200, 8), slop: 4), 1)
        XCTAssertNil(grid.hit(world: SIMD2(200, 30)))
        XCTAssertNil(grid.hit(world: SIMD2(500, 500)))
        // 跨 cell 边界(命中点和球心不在同一 cell)也要命中
        XCTAssertEqual(grid.hit(world: SIMD2(-300 + 9, -300 + 4), slop: 4), 2)
    }

    // MARK: 静态布局确定性

    func testStaticLayoutDeterministic() {
        let nodes = [
            GraphNode(id: 0, kind: .main, title: "Me", radius: 44,
                      colorRGB: GraphSceneBuilder.mainBlue, fileURL: nil, hubIndex: -1),
            GraphNode(id: 1, kind: .folder(slug: "a"), title: "A", radius: 20,
                      colorRGB: .init(0.5, 0.5, 0.5), fileURL: nil, hubIndex: 0),
            GraphNode(id: 2, kind: .eventLeaf(relPath: "d/x.md"), title: "x", radius: 6,
                      colorRGB: .init(0.5, 0.5, 0.5), fileURL: nil, hubIndex: 1),
        ]
        let edges = [
            GraphEdge(a: 1, b: 0, strength: 12, restLength: 300, halfWidth: 4),
            GraphEdge(a: 2, b: 1, strength: 3, restLength: 100, halfWidth: 1),
        ]
        let scene = GraphScene(zone: .events, nodes: nodes, edges: edges)
        let p1 = GraphStaticLayout.layout(scene: scene)
        let p2 = GraphStaticLayout.layout(scene: scene)
        XCTAssertEqual(p1, p2, "同一输入两次布局必须完全一致")
        // 主球在原点;hub 距主球 = restLength;leaf 距 hub = restLength
        XCTAssertEqual(p1[0], .zero)
        XCTAssertEqual(Double(simd_length(p1[1])), 300, accuracy: 0.5)
        XCTAssertEqual(Double(simd_length(p1[2] - p1[1])), 100, accuracy: 0.5)
    }
}
