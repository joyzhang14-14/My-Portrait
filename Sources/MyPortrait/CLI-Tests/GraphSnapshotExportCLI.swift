import Foundation
import GraphPhysics

/// 导出某一天的 Events 图谱场景为 JSON(给个人网站的互动图用)。
///
/// 只导出几何与权重(半径 / 颜色 / 连线 / 陨石带参数),**不导出任何标题、
/// 路径、folder 名** —— 场景按 `buildEventsTimeline` 生成,与 app 时间线同一套规则。
/// hub 对照表(index → folder 名 / 成员数)只打印到终端,供人工挑选要公开的名字。
///
/// 用法:`swift run MyPortrait --graph-snapshot-export 2026-09-21 out.json`
enum GraphSnapshotExportCLI {

    static func run(args: [String]) {
        guard let i = args.firstIndex(of: "--graph-snapshot-export"), i + 2 < args.count else {
            fputs("usage: --graph-snapshot-export <yyyy-MM-dd> <out.json>\n", stderr); exit(2)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"
        guard let day = fmt.date(from: args[i + 1]) else {
            fputs("bad date: \(args[i + 1])\n", stderr); exit(2)
        }
        guard let idx = EventTimeline.load() else { fputs("no events\n", stderr); exit(1) }
        let scene = GraphSceneBuilder.buildEventsTimeline(index: idx, on: day, userName: "Me")

        func kindName(_ k: GraphNodeKind) -> String {
            switch k {
            case .main: return "main"
            case .folder: return "folder"
            case .category: return "category"
            case .eventLeaf: return "eventLeaf"
            case .portraitLeaf: return "portraitLeaf"
            }
        }
        let nodes: [[String: Any]] = scene.nodes.map { n in
            [
                "id": n.id, "kind": kindName(n.kind), "radius": n.radius,
                "color": [n.colorRGB.x, n.colorRGB.y, n.colorRGB.z],
                "hubIndex": n.hubIndex,
                "hubBubbleRadius": n.hubBubbleRadius as Any? ?? NSNull(),
                "beltTier": n.beltTier as Any? ?? NSNull(),
                "beltAngle": n.beltAngle, "beltRadialOffset": n.beltRadialOffset,
            ]
        }
        let edges: [[String: Any]] = scene.edges.map { e in
            [
                "a": e.a, "b": e.b, "strength": e.strength, "restLength": e.restLength,
                "halfWidthA": e.halfWidthA, "halfWidthB": e.halfWidthB,
                "springStrength": e.springStrength as Any? ?? NSNull(),
            ]
        }
        let payload: [String: Any] = [
            "zone": "events", "date": args[i + 1], "nodes": nodes, "edges": edges,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: args[i + 2]))
        } catch {
            fputs("write failed: \(error.localizedDescription)\n", stderr); exit(1)
        }

        // hub 对照表:只打印,不进 JSON
        print("nodes \(scene.nodes.count), edges \(scene.edges.count)")
        print("index  members  name")
        for n in scene.nodes {
            let name: String
            switch n.kind {
            case .folder(let slug):
                name = slug == GraphSceneBuilder.unclassifiedSlug
                    ? "Unclassified" : (idx.folders[slug]?.name ?? slug)
            default: continue
            }
            let members = scene.nodes.filter { $0.hubIndex == n.id }.count
            print(String(format: "%5d  %7d  %@", n.id, members, name))
        }
        exit(0)
    }
}
