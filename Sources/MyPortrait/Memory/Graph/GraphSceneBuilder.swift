import Foundation

/// 把磁盘上的 memory 数据(events/*.md + _folders/*.json + portrait/<cat>/*.md)
/// 变成一张 GraphScene。纯读盘 + 纯函数,设计为在后台线程跑
/// (调用方先在 MainActor 读好 ConfigStore 的参数传进来)。
enum GraphSceneBuilder {

    /// portrait 画布的 7 个分区(emotions 用户拍板不做)+ 各自颜色。
    /// 色系沿用 FolderPalette 预设(需求 §4.3)。
    static let portraitCategories: [(name: String, hex: String)] = [
        ("personality",   "#B87BDC"),
        ("social",        "#EB7390"),
        ("background",    "#DBBC5C"),
        ("experiences",   "#E6944D"),
        ("interests",     "#57B5C7"),
        ("writing_style", "#5C8DE8"),
        ("skills",        "#76BD80"),
    ]

    /// 主球蓝(≈ Theme.accent 的 sRGB)。
    static let mainBlue = SIMD3<Double>(0.29, 0.57, 0.98)
    /// 未归组 event 的中性灰。
    static let ungroupedGray = SIMD3<Double>(0.58, 0.60, 0.63)
    /// 虚拟 Unclassified folder 的保留 slug(不落盘,仅图谱内部标识)。
    static let unclassifiedSlug = "__unclassified__"

    // MARK: - 入口

    static func build(zone: GraphZone, halfLifeDays: Double, userName: String) -> GraphScene {
        switch zone {
        case .events:   return buildEvents(halfLifeDays: halfLifeDays, userName: userName)
        case .portrait: return buildPortrait(halfLifeDays: halfLifeDays, userName: userName)
        }
    }

    // MARK: - Event 画布(需求 §4.2)

    private struct ScannedFile {
        let url: URL
        let relPath: String
        let title: String
        let weight: Double        // currentWeight(EMA 衰减后)
        let occurrences: Int
        let daysAgo: Double       // 距 lastOccurrence ?? created 的天数
    }

    private static func buildEvents(halfLifeDays: Double, userName: String) -> GraphScene {
        // ⚠️ 必须排序:FileManager 枚举 / loadAll 的顺序不保证稳定,顺序一变
        // 节点指纹就变 → 会话缓存永远 miss → 每次切换都重新炸开(07-02 bug)。
        let scanned = scanDir(Storage.eventsDir, halfLifeDays: halfLifeDays)
            .sorted { $0.relPath < $1.relPath }
        let folders = EventFolderStore.loadAll().sorted { $0.slug < $1.slug }

        // relPath → folder slug(一个 event 只归一个 folder;数据层保证不重叠)
        var folderOf: [String: String] = [:]
        for f in folders {
            for rel in f.events where folderOf[rel] == nil { folderOf[rel] = f.slug }
        }

        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        nodes.append(GraphNode(id: 0, kind: .main, title: userName,
                               radius: GraphConstants.mainRadius,
                               colorRGB: mainBlue, fileURL: nil, hubIndex: -1))

        // folder 球:含空 folder(用户建的实体,消失会困惑;空的就是最小号)
        var hubIndexOf: [String: Int] = [:]
        let memberWeights: [String: [Double]] = {
            var m: [String: [Double]] = [:]
            for s in scanned {
                if let slug = folderOf[s.relPath] { m[slug, default: []].append(s.weight) }
            }
            return m
        }()
        for f in folders {
            let idx = nodes.count
            hubIndexOf[f.slug] = idx
            let count = memberWeights[f.slug]?.count ?? 0
            let r = min(GraphConstants.folderRadiusBase
                            + GraphConstants.folderRadiusScale * Double(count).squareRoot(),
                        GraphConstants.folderRadiusMax)
            let rgb = rgbFromHex(f.colorHex ?? defaultFolderHex(name: f.name))
            nodes.append(GraphNode(id: idx, kind: .folder(slug: f.slug), title: f.name,
                                   radius: r, colorRGB: rgb, fileURL: nil, hubIndex: 0))
            let s = GraphConstants.folderStrength(memberWeights: memberWeights[f.slug] ?? [])
            edges.append(GraphEdge(a: idx, b: 0, strength: s,
                                   restLength: GraphConstants.folderRingDistance,
                                   halfWidthA: GraphConstants.edgeEndWidth(ballRadius: r),
                                   halfWidthB: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.mainRadius),
                                   springStrength: GraphConstants.hubSpringStrength))
        }

        // 虚拟 "Unclassified" folder 球(07-02 反馈):未分组 event 不再直连
        // 主球到处散,统一挂到这个灰色 hub 下 —— 自动获得扇区约束/hub 碰撞/
        // 按数量定大小。纯渲染实体,不写 EventFolderStore。
        let unclassified = scanned.filter { folderOf[$0.relPath] == nil }
        var unclassifiedIdx = 0
        if !unclassified.isEmpty {
            let idx = nodes.count
            unclassifiedIdx = idx
            let r = min(GraphConstants.folderRadiusBase
                            + GraphConstants.folderRadiusScale
                                * Double(unclassified.count).squareRoot(),
                        GraphConstants.folderRadiusMax)
            nodes.append(GraphNode(id: idx, kind: .folder(slug: unclassifiedSlug),
                                   title: "Unclassified", radius: r,
                                   colorRGB: ungroupedGray, fileURL: nil, hubIndex: 0))
            let s = GraphConstants.folderStrength(memberWeights: unclassified.map(\.weight))
            edges.append(GraphEdge(a: idx, b: 0, strength: s,
                                   restLength: GraphConstants.folderRingDistance,
                                   halfWidthA: GraphConstants.edgeEndWidth(ballRadius: r),
                                   halfWidthB: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.mainRadius),
                                   springStrength: GraphConstants.hubSpringStrength))
        }

        // event 球:归组的连 folder(继承 folder 色),未归组连 Unclassified(灰)
        for s in scanned {
            let idx = nodes.count
            let hub = folderOf[s.relPath].flatMap { hubIndexOf[$0] } ?? unclassifiedIdx
            let rgb = hub == unclassifiedIdx ? ungroupedGray : nodes[hub].colorRGB
            let r = min(GraphConstants.eventRadiusBase
                            + GraphConstants.eventRadiusScale * s.weight,
                        GraphConstants.eventRadiusMax)
            nodes.append(GraphNode(id: idx, kind: .eventLeaf(relPath: s.relPath), title: s.title,
                                   radius: r, colorRGB: rgb, fileURL: s.url, hubIndex: hub))
            let strength = min(Double(s.occurrences), GraphConstants.eventStrengthMax)
            let rest = GraphConstants.leafDistance(
                daysAgo: s.daysAgo,
                near: GraphConstants.eventLeafDistanceNear,
                far: GraphConstants.eventLeafDistanceFar)
            edges.append(GraphEdge(a: idx, b: hub, strength: strength, restLength: rest,
                                   halfWidthA: GraphConstants.leafEdgeEndWidth(ballRadius: r),
                                   halfWidthB: GraphConstants.leafEdgeEndWidth(
                                       ballRadius: nodes[hub].radius)))
        }
        return GraphScene(zone: .events, nodes: nodes, edges: edges)
    }

    // MARK: - Portrait 画布(需求 §4.3)

    private static func buildPortrait(halfLifeDays: Double, userName: String) -> GraphScene {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        nodes.append(GraphNode(id: 0, kind: .main, title: userName,
                               radius: GraphConstants.mainRadius,
                               colorRGB: mainBlue, fileURL: nil, hubIndex: -1))

        for (name, hex) in portraitCategories {
            let hubIdx = nodes.count
            let rgb = rgbFromHex(hex)
            nodes.append(GraphNode(id: hubIdx, kind: .category(name: name),
                                   title: name.replacingOccurrences(of: "_", with: " "),
                                   radius: GraphConstants.categoryRadius,
                                   colorRGB: rgb, fileURL: nil, hubIndex: 0))
            edges.append(GraphEdge(a: hubIdx, b: 0,
                                   strength: GraphConstants.categoryStrength,
                                   restLength: GraphConstants.categoryRingDistance,
                                   halfWidthA: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.categoryRadius),
                                   halfWidthB: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.mainRadius),
                                   springStrength: GraphConstants.hubSpringStrength))

            let dir = Storage.portraitDir.appendingPathComponent(name, isDirectory: true)
            // 排序保证指纹稳定(同 buildEvents 的 07-02 缓存 bug 修复)。
            for s in scanDir(dir, halfLifeDays: halfLifeDays)
                .sorted(by: { $0.relPath < $1.relPath }) {
                let idx = nodes.count
                let capped = min(s.weight, GraphConstants.portraitStrengthMax)
                let r = GraphConstants.portraitRadiusBase
                    + GraphConstants.portraitRadiusScale * capped
                nodes.append(GraphNode(id: idx, kind: .portraitLeaf(category: name),
                                       title: s.title, radius: r, colorRGB: rgb,
                                       fileURL: s.url, hubIndex: hubIdx))
                let rest = GraphConstants.leafDistance(
                    daysAgo: s.daysAgo,
                    near: GraphConstants.portraitLeafDistanceNear,
                    far: GraphConstants.portraitLeafDistanceFar)
                edges.append(GraphEdge(a: idx, b: hubIdx, strength: max(capped, 1),
                                       restLength: rest,
                                       halfWidthA: GraphConstants.leafEdgeEndWidth(ballRadius: r),
                                       halfWidthB: GraphConstants.leafEdgeEndWidth(
                                           ballRadius: GraphConstants.categoryRadius)))
            }
        }
        return GraphScene(zone: .portrait, nodes: nodes, edges: edges)
    }

    // MARK: - 目录扫描(与 MemoriesView.scan 同口径:跳 INDEX/_archive/_quarantine)

    private static func scanDir(_ root: URL, halfLifeDays: Double) -> [ScannedFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles])
        else { return [] }
        let prefix = root.path + "/"
        let ema = WeightEMA(halfLifeDays: halfLifeDays)
        var out: [ScannedFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            guard let file = try? PortraitFileIO.read(from: url) else { continue }
            let title = file.eventTitle.isEmpty
                ? (firstHeading(in: file.body) ?? url.deletingPathExtension().lastPathComponent)
                : file.eventTitle
            let anchor = file.lastOccurrence ?? file.created
            let daysAgo = max(0, Date().timeIntervalSince(anchor) / 86_400)
            let rel = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            out.append(ScannedFile(
                url: url, relPath: rel, title: title,
                weight: ema.currentWeight(stored: file.weight,
                                          daysSinceModified: file.daysSinceModified()),
                occurrences: file.occurrences.count,
                daysAgo: daysAgo))
        }
        return out
    }

    private static func firstHeading(in body: String) -> String? {
        for line in body.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - 颜色

    /// "#RRGGBB" → sRGB 分量。非法输入退灰。
    static func rgbFromHex(_ hex: String) -> SIMD3<Double> {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return ungroupedGray }
        return SIMD3<Double>(Double((v >> 16) & 0xFF) / 255,
                             Double((v >> 8) & 0xFF) / 255,
                             Double(v & 0xFF) / 255)
    }

    /// 没设过颜色的 folder:按 name hash 稳定取 FolderPalette 预设
    /// (与列表视图 FolderPalette.defaultTint 同逻辑,同一会话内颜色一致)。
    private static func defaultFolderHex(name: String) -> String {
        let idx = abs(name.hashValue) % FolderPalette.swatches.count
        return FolderPalette.swatches[idx].hex
    }
}
