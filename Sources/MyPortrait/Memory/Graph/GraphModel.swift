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

/// 一张画布的完整图数据(不含位置 —— 位置归布局/物理层)。
struct GraphScene: Sendable {
    let zone: GraphZone
    let nodes: [GraphNode]
    let edges: [GraphEdge]

    static let empty = GraphScene(zone: .events, nodes: [], edges: [])
}
