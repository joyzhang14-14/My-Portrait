import SwiftUI

/// 图谱的两张独立画布。
enum GraphZone: String, Sendable {
    case events
    case portrait
}

/// 节点种类。hub(主球/folder/分区)常驻标题、点击触发神经脉冲;
/// leaf(event/portrait 小球)hover 出标题、点击开浮窗。
enum GraphNodeKind: Equatable, Sendable {
    case main
    case folder(slug: String)
    case category(name: String)          // portrait 分区
    case eventLeaf(relPath: String)      // "yyyy-MM-dd/foo.md"(相对 eventsDir)
    case portraitLeaf(category: String)

    var isHub: Bool {
        switch self {
        case .main, .folder, .category: return true
        case .eventLeaf, .portraitLeaf: return false
        }
    }
}

/// 一个小球。渲染/物理都按 index(数组下标)引用,主球恒为 index 0。
struct GraphNode: Identifiable, Sendable {
    let id: Int
    let kind: GraphNodeKind
    let title: String
    let radius: Double
    /// sRGB 颜色分量(不直接存 SwiftUI Color —— builder 在后台线程跑,
    /// 保持 Sendable + 让渲染端自行决定深浅色变体)。
    let colorRGB: SIMD3<Double>
    /// leaf 的数据源 .md(浮窗读全文);hub 为 nil。
    let fileURL: URL?
    /// 所连接的 hub 的 index(主球为 -1)。
    let hubIndex: Int
    /// 气泡半径(07-02 气泡重构,用户定稿):该 hub 的全部叶子绕它 360°
    /// 成圆,圆径由内容面积决定 —— 叶多圆大、叶少圆小。仅非主球 hub
    /// 有值。物理保证:气泡间/气泡与主球绝不重叠,叶子不出自家圆。
    var hubBubbleRadius: Double? = nil
    /// 陨石带层号(07-03 用户新需求):weight<1.5 的 event 不进气泡,
    /// 松散漂在自家气泡外围(偏背主球侧)。0=最内层(1~1.5)/
    /// 1=中层(0.5~1)/2=最外层(0~0.5);nil=普通节点。无连接线。
    /// 07-03 二稿:不绑定隐形圈 —— 圈只施加吸引力,拖拽可冲散,
    /// 冲散后慢慢跟回自家(新)位置;不进任何隐形圈是硬性要求。
    var beltTier: Int? = nil
    /// 出生散布角(相对「背主球方向」,rad;路径哈希,确定性)。
    /// 只用于绽放播种 —— 稳态角向分布由碰撞挤开涌现(模糊感)。
    var beltAngle: Double = 0
    /// 环带吸引的目标半径偏移(相对自家气泡半径):层基准 + 径向模糊
    /// 抖动 —— 层界互相渗透,"模模糊糊"是要求不是缺陷。
    var beltRadialOffset: Double = 0

    var color: Color {
        Color(red: colorRGB.x, green: colorRGB.y, blue: colorRGB.z)
    }
}

/// 一条橡皮筋边:a = 子端(folder/leaf),b = hub 端(主球/folder/分区)。
struct GraphEdge: Sendable {
    let a: Int
    let b: Int
    /// 连接强度(占位:物理弹簧刚度全局统一;线宽 2026-07-01 起改由球半径决定)。
    let strength: Double
    /// 弹簧自然长度(= §4.4 的距离映射结果)。
    let restLength: Double
    /// 端点半宽,逐端各自 = min(所连球半径, 上限) —— 神经末梢从球上「长」出来。
    /// hub↔主球上限 15;连末端球的边整条上限 7。
    let halfWidthA: Double
    let halfWidthB: Double
    /// 弹簧刚度 override。nil = d3 默认(1/min(两端度数))。
    /// hub→主球设 1.0:folder 度数几百导致默认刚度趋零,会被斥力推飞。
    var springStrength: Double? = nil
}

/// 陨石散布(07-03 五稿,builder 与独立自检共用的**纯函数**,保证零漂移):
/// 输入一家全部陨石(按层内→外串接:高 weight 在前),输出每球"模糊家位"。
/// ⚠️ 五稿坐标系换成**主球极坐标**(用户画黄线:"弧度更平,和隐形圆没
/// 太大关系了"——绕自家气泡排的弧曲率太大,改绕全图中心排,半径大弧
/// 自然平):家位 = (径向偏移相对气泡远端, 角度相对 hub 的主球极角)。
/// 弧宽先随数量展开(上限 ∝ 自家气泡的角footprint),装满一排往外延长;
/// 大幅哈希模糊,层间无空隙,小(低 weight)球偏外。
enum BeltLayout {
    /// - Parameters:
    ///   - radii: 全家陨石球半径(层内→外串接,高 weight 在前)
    ///   - hashA/hashB: 每球两个独立的 [0,1) 确定性哈希(路径加盐)
    ///   - bubbleR: 自家气泡半径
    ///   - mainDist: hub→主球弹簧自然长度(≈ hub 到全图中心的距离)
    /// - Returns: (径向偏移「相对气泡远端 mainDist+bubbleR」,
    ///            家位角「相对 hub 的主球极角」) 同序
    static func homes(radii: [Double], hashA: [Double], hashB: [Double],
                      bubbleR: Double, mainDist: Double)
        -> (offsets: [Double], angles: [Double]) {
        let n = radii.count
        guard n > 0 else { return ([], []) }
        let slotW = 2 * ((radii.max() ?? 1) + 1)
        // 气泡远端到全图中心的半径:弧容量按这个大半径算 → 平弧
        let baseR = mainDist + bubbleR
        // 弧宽上限 ∝ 自家气泡的角 footprint(×2.4):大家平铺一大片,
        // 小家不越权抢邻居的方位;真实可用弧仍由引擎动态裁剪
        let ownHalf = asin(min(0.95, bubbleR / max(mainDist, bubbleR + 1)))
        let arcCap = min(GraphConstants.beltMaxHalfArc, ownHalf * 2.4 + 0.1)
        var offsets = [Double](repeating: 0, count: n)
        var angles = [Double](repeating: 0, count: n)
        var cursor = GraphConstants.beltGap
        var k = 0
        var row = 0
        while k < n {
            let ringR = baseR + cursor
            // 每排只装理论容量的 55%(装满才外溢 = 贴边薄壳;稀装深铺)
            let cap = max(1, Int(2 * arcCap * ringR / slotW * 0.55))
            let rowCount = min(cap, n - k)
            // 先展开:不足一排时弧宽 ∝ 数量,airy 系数同 55%
            let halfArc = min(arcCap,
                              Double(rowCount) * slotW / (2 * ringR * 0.55))
            let slot = 2 * halfArc / Double(rowCount)
            for j in 0..<rowCount {
                // 模糊:径向 ±0.7 排距、角向 ±0.8 槽 —— 边缘不刻意
                offsets[k] = cursor + (hashA[k] - 0.5) * slotW * 1.4
                angles[k] = -halfArc + (Double(j) + 0.5) * slot
                    + (hashB[k] - 0.5) * slot * 1.6
                k += 1
            }
            // 排距随排数递增:外缘渐稀,收尾像彗尾不像切边
            cursor += slotW * (0.9 + 0.35 * Double(row))
            row += 1
        }
        return (offsets, angles)
    }
}

/// 一张画布的完整图数据(不含位置 —— 位置归布局/物理层)。
struct GraphScene: Sendable {
    let zone: GraphZone
    let nodes: [GraphNode]
    let edges: [GraphEdge]

    static let empty = GraphScene(zone: .events, nodes: [], edges: [])
}
