import Foundation

/// 把磁盘上的 memory 数据(events/*.md + _folders/*.json + portrait/<cat>/*.md)
/// 变成一张 GraphScene。纯读盘 + 纯函数,设计为在后台线程跑
/// (调用方先在 MainActor 读好 ConfigStore 的参数传进来)。
///
/// 气泡布局(07-02 重构定稿):builder 只产**参数**不产落位:
///   1. 气泡半径 = √(hub球² + Σ叶面积/装填密度) —— 叶多圆大,叶少圆小
///   2. hub→主球线长 = 主球半径 + 气泡半径 + 缝(不重叠的**最小**调整)
///   3. 叶子线长 = 排名+日期间隔压缩映射 × 气泡尺度(整家等比缩放)
///   位置全部由力系统涌现(气泡碰撞定角度;圆间零重叠、叶不出圆)。
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

    // MARK: - Event 画布

    private struct ScannedFile {
        let url: URL
        let relPath: String
        let title: String
        let weight: Double        // currentWeight(EMA 衰减后)
        let occurrences: Int
        let daysAgo: Double       // 距 lastOccurrence ?? created 的天数
    }

    /// 一个待建 hub(真 folder 或虚拟 Unclassified)。
    private struct HubSpec {
        let slug: String
        let name: String
        let colorRGB: SIMD3<Double>
        let members: [ScannedFile]
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
        var membersOf: [String: [ScannedFile]] = [:]
        var unclassifiedMembers: [ScannedFile] = []
        for s in scanned {
            if let slug = folderOf[s.relPath] { membersOf[slug, default: []].append(s) }
            else { unclassifiedMembers.append(s) }
        }

        // hub 列表(真 folder 含空的 + 虚拟 Unclassified),叶数降序定圆弧顺序
        var specs: [HubSpec] = folders.map {
            HubSpec(slug: $0.slug, name: $0.name,
                    colorRGB: rgbFromHex($0.colorHex ?? defaultFolderHex(name: $0.name)),
                    members: membersOf[$0.slug] ?? [])
        }
        if !unclassifiedMembers.isEmpty {
            specs.append(HubSpec(slug: unclassifiedSlug, name: "Unclassified",
                                 colorRGB: ungroupedGray, members: unclassifiedMembers))
        }
        specs.sort { ($0.members.count, $1.slug) > ($1.members.count, $0.slug) }

        return assemble(userName: userName, specs: specs,
                        hubRadius: { spec in
                            min(GraphConstants.folderRadiusBase
                                    + GraphConstants.folderRadiusScale
                                        * Double(spec.members.count).squareRoot(),
                                GraphConstants.folderRadiusMax)
                        },
                        hubKind: { .folder(slug: $0.slug) },
                        leafKind: { .eventLeaf(relPath: $0.relPath) },
                        leafColor: { spec, _ in spec.colorRGB },
                        leafRadius: { s in
                            min(GraphConstants.eventRadiusBase
                                    + GraphConstants.eventRadiusScale * s.weight,
                                GraphConstants.eventRadiusMax)
                        },
                        leafStrength: { s in
                            min(Double(s.occurrences), GraphConstants.eventStrengthMax)
                        },
                        zone: .events)
    }

    // MARK: - Portrait 画布

    private static func buildPortrait(halfLifeDays: Double, userName: String) -> GraphScene {
        var specs: [HubSpec] = portraitCategories.map { (name, hex) in
            let dir = Storage.portraitDir.appendingPathComponent(name, isDirectory: true)
            // 排序保证指纹稳定(同 buildEvents 的 07-02 缓存 bug 修复)。
            let members = scanDir(dir, halfLifeDays: halfLifeDays)
                .sorted { $0.relPath < $1.relPath }
            return HubSpec(slug: name,
                           name: name.replacingOccurrences(of: "_", with: " "),
                           colorRGB: rgbFromHex(hex), members: members)
        }
        specs.sort { ($0.members.count, $1.slug) > ($1.members.count, $0.slug) }

        return assemble(userName: userName, specs: specs,
                        hubRadius: { _ in GraphConstants.categoryRadius },
                        hubKind: { .category(name: $0.slug) },
                        leafKind: { s in
                            // category 从 URL 倒数第二段取(portrait/<cat>/x.md)
                            .portraitLeaf(category: s.url.deletingLastPathComponent()
                                .lastPathComponent)
                        },
                        leafColor: { spec, _ in spec.colorRGB },
                        leafRadius: { s in
                            GraphConstants.portraitRadiusBase
                                + GraphConstants.portraitRadiusScale
                                    * min(s.weight, GraphConstants.portraitStrengthMax)
                        },
                        leafStrength: { s in
                            max(min(s.weight, GraphConstants.portraitStrengthMax), 1)
                        },
                        zone: .portrait)
    }

    // MARK: - 组装(两画布共用:气泡半径 + 线长映射 + 建节点/边)

    private static func assemble(userName: String,
                                 specs: [HubSpec],
                                 hubRadius: (HubSpec) -> Double,
                                 hubKind: (HubSpec) -> GraphNodeKind,
                                 leafKind: (ScannedFile) -> GraphNodeKind,
                                 leafColor: (HubSpec, ScannedFile) -> SIMD3<Double>,
                                 leafRadius: (ScannedFile) -> Double,
                                 leafStrength: (ScannedFile) -> Double,
                                 zone: GraphZone) -> GraphScene {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        nodes.append(GraphNode(id: 0, kind: .main, title: userName,
                               radius: GraphConstants.mainRadius,
                               colorRGB: mainBlue, fileURL: nil, hubIndex: -1))

        // 07-02 气泡重构(用户定稿):每个 hub 的叶子绕它 360° 成圆。
        // 气泡半径由内容面积涌现(10 叶小圆,1000 叶巨圆);线长 =
        // 日期映射 × 气泡尺度(叶少则全家线等比缩短);hub→主球弹簧
        // rest = 主球半径 + 气泡半径 + 缝(气泡贴主球排布,角度由
        // 气泡碰撞涌现);圆间零重叠、叶不出自家圆由物理保证。
        for spec in specs {
            let r = hubRadius(spec)
            let maxLeafR = spec.members.map(leafRadius).max() ?? 0
            // π·气泡半径² ≥ hub 球面积 + Σ叶面积/装填密度(π 约掉);
            // 下限 = hub 球碰撞壳 + 两个最大叶径(圆再小也得装得下
            // "贴着 hub 壳的一圈叶",否则硬碰撞会把叶顶出圈外)。
            let leafArea = spec.members.reduce(0.0) {
                let lr = leafRadius($1) + 1
                return $0 + lr * lr
            }
            let bubbleR = max(
                (r * r + leafArea / GraphConstants.bubbleFill).squareRoot()
                    + GraphConstants.bubblePadding,
                r + Double(GraphConstants.mainCollisionPadding) + 2 * maxLeafR + 3)
            let hubIdx = nodes.count
            var hubNode = GraphNode(id: hubIdx, kind: hubKind(spec), title: spec.name,
                                    radius: r, colorRGB: spec.colorRGB,
                                    fileURL: nil, hubIndex: 0)
            hubNode.hubBubbleRadius = bubbleR
            nodes.append(hubNode)
            let s = GraphConstants.folderStrength(memberWeights: spec.members.map(\.weight))
            // rest 里含「最大叶径+pad」净空:圆的内缘叶不许被主球碰撞壳
            // 顶出圈(engine 的硬约束同款净空)—— 仍是不重叠的最小调整。
            edges.append(GraphEdge(a: hubIdx, b: 0, strength: s,
                                   restLength: GraphConstants.mainRadius + bubbleR
                                       + maxLeafR
                                       + Double(GraphConstants.mainCollisionPadding)
                                       + GraphConstants.bubbleGap,
                                   halfWidthA: GraphConstants.edgeEndWidth(ballRadius: r),
                                   halfWidthB: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.mainRadius),
                                   springStrength: GraphConstants.hubSpringStrength))

            // 线长 = 排名 + 日期间隔压缩映射(07-02 定稿,保留)× 气泡尺度:
            // 家内按 last_occurred 升序,相邻线长差 = 1 + ln(1+日期差) 槽
            //(差 1 天可见,差 1 月更长但压缩,绝不相等);最新贴 hub
            //(floor 比例),最旧顶到气泡边缘 —— 整家等比随气泡缩放。
            let maxRest = max(bubbleR - maxLeafR - 2, r + 4)
            let ordered = spec.members.indices.sorted {
                (spec.members[$0].daysAgo, spec.members[$0].relPath)
                    < (spec.members[$1].daysAgo, spec.members[$1].relPath)
            }
            var cum: [Double] = []
            var c = 0.0, prevDays = 0.0
            for (j, mi) in ordered.enumerated() {
                let d = spec.members[mi].daysAgo
                if j > 0 { c += 1 + log(1 + max(0, d - prevDays)) }
                prevDays = d
                cum.append(c)
            }
            let cMax = max(cum.last ?? 0, 1e-9)
            let floorFrac = GraphConstants.bubbleRestFloor
            for (rank, mi) in ordered.enumerated() {
                let m = spec.members[mi]
                let idx = nodes.count
                let lr = leafRadius(m)
                let rest = maxRest * (floorFrac + (1 - floorFrac) * cum[rank] / cMax)
                nodes.append(GraphNode(id: idx, kind: leafKind(m), title: m.title,
                                       radius: lr, colorRGB: leafColor(spec, m),
                                       fileURL: m.url, hubIndex: hubIdx))
                edges.append(GraphEdge(a: idx, b: hubIdx,
                                       strength: leafStrength(m),
                                       restLength: rest,
                                       halfWidthA: GraphConstants.leafEdgeEndWidth(ballRadius: lr),
                                       halfWidthB: GraphConstants.leafEdgeEndWidth(ballRadius: r)))
            }
        }
        return GraphScene(zone: zone, nodes: nodes, edges: edges)
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
