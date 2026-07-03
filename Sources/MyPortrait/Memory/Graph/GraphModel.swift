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
    /// 挂在自家气泡外侧、背主球方向的弧带上。0=最内层(1~1.5)/
    /// 1=中层(0.5~1)/2=最外层(0~0.5);nil=普通节点。无连接线。
    var beltTier: Int? = nil
    /// 陨石在弧带内的槽位角(相对「背主球方向」的偏角,rad;builder
    /// 排好:均匀 + 路径哈希抖动,确定性)。
    var beltAngle: Double = 0
    /// 陨石环半径 = 自家气泡半径 + 此偏移(builder 排好:层内超出单排
    /// 容量自动加排,每球一个可达槽位 —— 靠碰撞挤双排物理上不收敛,
    /// 2.5 倍超载实测喷泉式流散)。
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

/// 陨石带排位(07-03,builder 与独立自检共用的**纯函数**,保证零漂移):
/// 给一层陨石的球半径列表,产出每球的 (径向偏移, 槽位角)。层内超出
/// 单排容量自动往外加排(排距=槽宽,邻排错半槽);每球一个可达槽位。
enum BeltLayout {
    /// - Parameters:
    ///   - radii: 该层每球半径(已按稳定序排好)
    ///   - jitters: 每球 [-0.5, 0.5) 的确定性抖动(路径哈希)
    ///   - bubbleR: 自家气泡半径(环半径 = bubbleR + offset,决定弧容量)
    ///   - baseOffset: 该层第一排的径向偏移(层间由调用方累进)
    /// - Returns: offsets/angles 与 radii 同序;nextOffset = 下一层基线
    static func slots(radii: [Double], jitters: [Double],
                      bubbleR: Double, baseOffset: Double)
        -> (offsets: [Double], angles: [Double], nextOffset: Double) {
        guard !radii.isEmpty else { return ([], [], baseOffset) }
        let slotW = 2 * ((radii.max() ?? 1) + 1)
        var offsets = [Double](repeating: 0, count: radii.count)
        var angles = [Double](repeating: 0, count: radii.count)
        var k = 0, row = 0
        var rowOffset = baseOffset
        while k < radii.count {
            let ringR = bubbleR + rowOffset
            let cap = max(1, Int(2 * GraphConstants.beltMaxHalfArc * ringR / slotW))
            let rowCount = min(cap, radii.count - k)
            let halfArc = Double(rowCount) * slotW / (2 * ringR)
            let slot = 2 * halfArc / Double(rowCount)
            let stagger = row % 2 == 1 ? 0.5 : 0.0
            for j in 0..<rowCount {
                offsets[k] = rowOffset
                angles[k] = -halfArc
                    + (Double(j) + 0.5 + stagger
                       + jitters[k] * GraphConstants.beltJitter) * slot
                k += 1
            }
            rowOffset += slotW
            row += 1
        }
        return (offsets, angles, rowOffset)
    }
}

/// 一张画布的完整图数据(不含位置 —— 位置归布局/物理层)。
struct GraphScene: Sendable {
    let zone: GraphZone
    let nodes: [GraphNode]
    let edges: [GraphEdge]

    static let empty = GraphScene(zone: .events, nodes: [], edges: [])
}
