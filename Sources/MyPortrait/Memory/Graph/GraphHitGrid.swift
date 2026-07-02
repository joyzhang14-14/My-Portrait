import Foundation
import simd

/// 空间哈希网格:120Hz 指针事件下 O(1) 查「点落在哪个球上」。
/// 每次位置快照变化后重建(5000 节点 ~O(n),微秒级)。
struct GraphHitGrid {
    private let cell: Float
    private var buckets: [SIMD2<Int32>: [Int]] = [:]
    private let positions: [SIMD2<Float>]
    private let radii: [Float]

    init(positions: [SIMD2<Float>], radii: [Double], cellSize: Float = 64) {
        self.cell = cellSize
        self.positions = positions
        self.radii = radii.map(Float.init)
        buckets.reserveCapacity(positions.count)
        for i in positions.indices {
            buckets[key(positions[i]), default: []].append(i)
        }
    }

    private func key(_ p: SIMD2<Float>) -> SIMD2<Int32> {
        SIMD2<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)))
    }

    /// 世界坐标命中的节点(命中半径 = 球半径 + slop;多个命中取最近球心)。
    /// slop 给小球加一点容差,末端球才好点。
    func hit(world: SIMD2<Float>, slop: Float = 4) -> Int? {
        let k = key(world)
        var best: Int? = nil
        var bestD: Float = .greatestFiniteMagnitude
        // 球半径可能大于 cell(主球 44),按最大半径扩搜索圈
        let reach = Int32(((radii.max() ?? 0) + slop) / cell) + 1
        for dx in -reach...reach {
            for dy in -reach...reach {
                guard let bucket = buckets[SIMD2<Int32>(k.x + dx, k.y + dy)] else { continue }
                for i in bucket {
                    let d = simd_length(positions[i] - world)
                    if d <= radii[i] + slop && d < bestD {
                        bestD = d; best = i
                    }
                }
            }
        }
        return best
    }
}
