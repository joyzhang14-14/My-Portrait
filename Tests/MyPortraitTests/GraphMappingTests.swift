import XCTest
import simd
@testable import GraphPhysics
@testable import MyPortrait

/// 图谱数据映射公式的单测(强度/线宽/命中网格)。
final class GraphMappingTests: XCTestCase {

    // MARK: folder → 主球 连接强度:Σw²/Σw + 5(自加权平均)

    func testFolderStrengthSelfWeighted() {
        // 均匀权重退化为普通平均:w=[2,2] → Σw²/Σw = 8/4 = 2 → 7
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: [2, 2]), 7, accuracy: 1e-9)
        // 高 weight 话语权大:[1,1,1,9] 普通均值 3,自加权 = 84/12 = 7 → 12
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: [1, 1, 1, 9]), 12, accuracy: 1e-9)
    }

    func testFolderStrengthEmptyIsBase() {
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: []),
                       GraphConstants.folderStrengthBase, accuracy: 1e-9)
        // 全 0 权重也不能除零
        XCTAssertEqual(GraphConstants.folderStrength(memberWeights: [0, 0]),
                       GraphConstants.folderStrengthBase, accuracy: 1e-9)
    }

    // MARK: 端点线宽 = 球半径,上限 7

    func testEdgeEndWidthFollowsRadiusCapped() {
        XCTAssertEqual(GraphConstants.edgeEndWidth(ballRadius: 6), 6, accuracy: 1e-9)
        XCTAssertEqual(GraphConstants.edgeEndWidth(ballRadius: 14.9), 7, accuracy: 1e-9)
        // 主球 44 / 分区球 30 → 全部截断到 7
        XCTAssertEqual(GraphConstants.edgeEndWidth(ballRadius: 30), 7, accuracy: 1e-9)
        XCTAssertEqual(GraphConstants.edgeEndWidth(ballRadius: 44), 7, accuracy: 1e-9)
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
            GraphEdge(a: 1, b: 0, strength: 12, restLength: 300, halfWidthA: 4, halfWidthB: 15),
            GraphEdge(a: 2, b: 1, strength: 3, restLength: 100, halfWidthA: 1, halfWidthB: 4),
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

    // MARK: Portrait 叶圈整体自转阻尼

    func testFamilyRotationDampingRemovesOnlyCoherentSpin() {
        let positions: [SIMD2<Float>] = [
            SIMD2(10, 20),
            SIMD2(110, 20), SIMD2(10, 120), SIMD2(-90, 20), SIMD2(10, -80),
        ]
        let hubVelocity = SIMD2<Float>(2, -1)
        let radial: [Float] = [0.3, -0.2, 0.4, -0.1]
        var velocities = [hubVelocity]
        for (index, position) in positions.dropFirst().enumerated() {
            let r = position - positions[0]
            let unit = r / simd_length(r)
            let rotation = SIMD2<Float>(-r.y, r.x) * 0.08
            velocities.append(hubVelocity + rotation + unit * radial[index])
        }
        let radialBefore = zip(positions.dropFirst(), velocities.dropFirst()).map {
            let r = $0.0 - positions[0]
            return simd_dot($0.1 - hubVelocity, r / simd_length(r))
        }

        GraphPhysicsEngine.dampCoherentFamilyRotation(
            positions: positions, velocities: &velocities,
            leaves: [1, 2, 3, 4], ranges: [(hub: 0, lo: 0, hi: 4)],
            strength: 1
        )

        var angular: Float = 0
        var inertia: Float = 0
        for i in 1..<positions.count {
            let r = positions[i] - positions[0]
            let relativeVelocity = velocities[i] - hubVelocity
            angular += r.x * relativeVelocity.y - r.y * relativeVelocity.x
            inertia += simd_length_squared(r)
            XCTAssertEqual(simd_dot(relativeVelocity, r / simd_length(r)),
                           radialBefore[i - 1], accuracy: 1e-5)
        }
        XCTAssertEqual(angular / inertia, 0, accuracy: 1e-6)
        XCTAssertEqual(velocities[0], hubVelocity)
    }

    func testFamilyRotationDampingIsGradual() {
        let positions: [SIMD2<Float>] = [
            .zero, SIMD2(100, 0), SIMD2(0, 100), SIMD2(-100, 0),
        ]
        var velocities: [SIMD2<Float>] = [
            .zero, SIMD2(0, 10), SIMD2(-10, 0), SIMD2(0, -10),
        ]
        GraphPhysicsEngine.dampCoherentFamilyRotation(
            positions: positions, velocities: &velocities,
            leaves: [1, 2, 3], ranges: [(hub: 0, lo: 0, hi: 3)],
            strength: 0.25
        )
        XCTAssertEqual(velocities[1].y, 7.5, accuracy: 1e-5)
        XCTAssertEqual(velocities[2].x, -7.5, accuracy: 1e-5)
        XCTAssertEqual(velocities[3].y, -7.5, accuracy: 1e-5)
    }
}
