import Foundation
import simd

/// 确定性初始布局(P1 静态展示;P2 物理接管后作为炸开前的参考/兜底)。
///   主球原点;hub 均匀分布在等距环上;leaf 以黄金角绕自己的 hub 铺开,
///   半径 = 边的自然长度。确定性:同一份数据两次布局完全一致。
enum GraphStaticLayout {

    static let goldenAngle = 2.399963229728653   // rad

    static func layout(scene: GraphScene) -> [SIMD2<Float>] {
        var pos = [SIMD2<Float>](repeating: .zero, count: scene.nodes.count)
        guard !scene.nodes.isEmpty else { return pos }

        // node index → 它那条连 hub 的边(a == node)
        var edgeOf: [Int: GraphEdge] = [:]
        for e in scene.edges { edgeOf[e.a] = e }

        // hub 环(fallback 距离:完美圆算法的 outer − far,folderRing 已废)
        let hubs = scene.nodes.filter { $0.kind.isHub && $0.id != 0 }
        let fallback = GraphConstants.eventOuterRadius - GraphConstants.eventLeafDistanceFar
        for (k, hub) in hubs.enumerated() {
            let angle = 2 * Double.pi * Double(k) / Double(max(hubs.count, 1)) - .pi / 2
            let r = edgeOf[hub.id]?.restLength ?? fallback
            pos[hub.id] = SIMD2<Float>(Float(cos(angle) * r), Float(sin(angle) * r))
        }

        // leaf:绕各自 hub 黄金角铺开(按 hub 分组的序号决定角度,确定性)
        var leafCountOf: [Int: Int] = [:]
        for node in scene.nodes where !node.kind.isHub {
            let j = leafCountOf[node.hubIndex, default: 0]
            leafCountOf[node.hubIndex] = j + 1
            let angle = goldenAngle * Double(j)
            let r = edgeOf[node.id]?.restLength ?? GraphConstants.eventLeafDistanceFar
            let hubPos = pos[max(node.hubIndex, 0)]
            pos[node.id] = SIMD2<Float>(hubPos.x + Float(cos(angle) * r),
                                        hubPos.y + Float(sin(angle) * r))
        }
        return pos
    }
}
