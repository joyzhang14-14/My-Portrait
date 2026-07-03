import Foundation
import simd

/// 一段沿边传播的神经信号。时间都是**相对点击时刻**的秒数 ——
/// 点击瞬间把整个级联的时间表一次算好,渲染每帧只按当前时刻查表画亮斑,
/// 不在渲染循环里改状态。
struct GraphPulse: Sendable {
    let edgeIndex: Int
    /// 本段脉冲的出发端节点(决定沿边方向;可能是 edge.a 也可能是 edge.b)。
    let fromNode: Int
    let start: TimeInterval
    let duration: TimeInterval
}

enum GraphPulseScheduler {

    /// 从被点击的 hub 出发 BFS,级联最多 maxDepth 跳(visited 去重),
    /// 常速(speed pt/s)沿边传播:下一跳在上一跳到达时刻起跑。
    /// 返回脉冲表 + 整场动画总时长(清理定时用)。
    /// - Parameter blocked: 信号不进入的节点(07-03 精修:folder/分区球
    ///   点击只传给 event 球,不传主球 → 传 [0])。
    static func schedule(from origin: Int,
                         scene: GraphScene,
                         positions: [SIMD2<Float>],
                         speed: Double = GraphConstants.pulseSpeed,
                         maxDepth: Int,
                         blocked: Set<Int> = [])
        -> (pulses: [GraphPulse], total: TimeInterval) {
        guard origin >= 0, origin < scene.nodes.count, speed > 0 else { return ([], 0) }

        // 邻接表:node → [(edgeIndex, otherNode)]
        var adjacency: [[(edge: Int, other: Int)]] = .init(repeating: [], count: scene.nodes.count)
        for (i, e) in scene.edges.enumerated() {
            adjacency[e.a].append((i, e.b))
            adjacency[e.b].append((i, e.a))
        }

        var pulses: [GraphPulse] = []
        var total: TimeInterval = 0
        var visited = Set<Int>([origin]).union(blocked)
        // (节点, 信号到达该节点的时刻, 已走跳数)
        var frontier: [(node: Int, arrival: TimeInterval, depth: Int)] = [(origin, 0, 0)]

        while let (node, arrival, depth) = frontier.first {
            frontier.removeFirst()
            guard depth < maxDepth else { continue }
            for (edgeIndex, other) in adjacency[node] where !visited.contains(other) {
                visited.insert(other)
                let len = Double(simd_length(positions[other] - positions[node]))
                let duration = max(len / speed, 0.05)
                pulses.append(GraphPulse(edgeIndex: edgeIndex, fromNode: node,
                                         start: arrival, duration: duration))
                total = max(total, arrival + duration)
                frontier.append((other, arrival + duration, depth + 1))
            }
        }
        return (pulses, total)
    }
}
