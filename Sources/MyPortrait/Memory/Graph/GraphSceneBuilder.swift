import Foundation

/// 把磁盘上的 memory 数据(events/*.md + _folders/*.json + portrait/<cat>/*.md)
/// 变成一张 GraphScene。纯读盘 + 纯函数,设计为在后台线程跑
/// (调用方先在 MainActor 读好 ConfigStore 的参数传进来)。
///
/// 完美圆算法(07-02 定稿):
///   1. 每个 hub 按叶数占比分得一段圆弧(30° 保底/220° 封顶,水填归一 360°)
///      → 相邻扇区角度上不重叠,分区/folder 分明
///   2. hub 距主球 = outerRadius − 该 hub 最远叶的弹簧长(floor 到碰撞下限)
///      → 每家 fan 的外缘落在同一大圆上,末端球形成完美外圆
///   3. 物理用角度弹簧把 hub 拉到目标角,楔形扇区角 = 份额
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

    // MARK: - 楔形份额分配

    /// 纯按叶数占比分 360°(07-02 定稿:档位/保底/封顶全部删除 ——
    /// 它们让份额和内容脱节,扇区间出缝隙,拼不成完整的圆)。
    /// 空 folder 占 0°(hub 球本身仍由碰撞保证物理空间)。Σ=360。
    static func allocateWedges(counts: [Int]) -> [Double] {
        guard !counts.isEmpty else { return [] }
        let total = max(counts.reduce(0, +), 1)
        return counts.map { Double($0) / Double(total) * 360 }
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
                        outerRadius: GraphConstants.eventOuterRadius,
                        hubDistance: GraphConstants.eventHubDistance,
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
                        leafRest: { s in
                            GraphConstants.leafDistance(
                                daysAgo: s.daysAgo,
                                near: GraphConstants.eventLeafDistanceNear,
                                far: GraphConstants.eventLeafDistanceFar)
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
                        outerRadius: GraphConstants.portraitOuterRadius,
                        hubDistance: GraphConstants.portraitHubDistance,
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
                        leafRest: { s in
                            GraphConstants.leafDistance(
                                daysAgo: s.daysAgo,
                                near: GraphConstants.portraitLeafDistanceNear,
                                far: GraphConstants.portraitLeafDistanceFar)
                        },
                        leafStrength: { s in
                            max(min(s.weight, GraphConstants.portraitStrengthMax), 1)
                        },
                        zone: .portrait)
    }

    // MARK: - 组装(两画布共用:份额分配 + 半径补偿 + 建节点/边)

    private static func assemble(userName: String,
                                 specs: [HubSpec],
                                 outerRadius: Double,
                                 hubDistance: Double,
                                 hubRadius: (HubSpec) -> Double,
                                 hubKind: (HubSpec) -> GraphNodeKind,
                                 leafKind: (ScannedFile) -> GraphNodeKind,
                                 leafColor: (HubSpec, ScannedFile) -> SIMD3<Double>,
                                 leafRadius: (ScannedFile) -> Double,
                                 leafRest: (ScannedFile) -> Double,
                                 leafStrength: (ScannedFile) -> Double,
                                 zone: GraphZone) -> GraphScene {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        nodes.append(GraphNode(id: 0, kind: .main, title: userName,
                               radius: GraphConstants.mainRadius,
                               colorRGB: mainBlue, fileURL: nil, hubIndex: -1))

        // 07-02 终稿(两遍法):先在局部坐标把每把扇子装填好、量出实际
        // 角宽,再按「实宽 + 2° 缝」把 hub 沿圆排开 —— 扇形相接无大缝。
        // hub 距主球全体相等(公式):
        let hubRadii = specs.map(hubRadius)
        let globalMaxRest = specs.flatMap { $0.members.map(leafRest) }.max()
            ?? (outerRadius - hubDistance)
        let packFloor = (hubRadii.map { $0 * 2 + 10 }.reduce(0, +)) / (2 * .pi)
        let maxHubR = hubRadii.max() ?? 0
        let dist = max(outerRadius - globalMaxRest,
                       packFloor,
                       GraphConstants.mainRadius + maxHubR
                           + Double(GraphConstants.mainCollisionPadding) + 2)

        // 遍1:局部装填。每叶得 (ψ 绕hub角, arcR 距hub半径);层内居中排。
        struct Packed { let member: Int; let psi: Double; let arcR: Double }
        var megaOf: [Double] = []
        let psiCap = 115.0 * .pi / 180
        var packedAll: [[Packed]] = []
        var mainHalfAll: [Double] = []
        for spec in specs {
            let ordered = spec.members.indices.sorted {
                (leafRest(spec.members[$0]), spec.members[$0].relPath)
                    < (leafRest(spec.members[$1]), spec.members[$1].relPath)
            }
            // 超大 folder(Unclassified 类,>100 叶)单独逻辑:球缩 0.72、
            // 装填更密 —— 不霸屏(07-02 反馈)。
            let mega = spec.members.count > 100 ? 0.72 : 1.0
            let avgR = (spec.members.isEmpty ? 6.0
                : spec.members.map(leafRadius).reduce(0, +) / Double(spec.members.count)) * mega
            let slotW = avgR * 2 + GraphConstants.packSlotGap
            let layerStep = avgR * 2 + GraphConstants.packRingGap
            var packed: [Packed] = []
            // 半宽下限 = hub 球自身的角尺寸+缝(07-02 bug:小扇子比 hub 球窄,
            // 排位宽度没算球本身 → 相邻 hub 目标位重叠且被快照钉死)
            var mainHalf = asin(min((hubRadius(spec)
                + GraphConstants.packSlotGap + 2) / dist, 0.9))
            // 线长 = 天数**排名**映射(07-02 定稿):真实数据大多 >30 天全贴
            // 映射上限,长短失去区分度;按家内排名铺 25%~100% 跨度,
            // 最新最短、最旧顶到外圆,长短永远可读。
            let span = max(outerRadius - dist, 40)
            let denom = Double(max(ordered.count - 1, 1))
            var i = 0
            var arcR = 0.0
            while i < ordered.count {
                let rankRest = span * (0.25 + 0.75 * Double(i) / denom)
                arcR = max(arcR + (i == 0 ? 0 : layerStep), rankRest)
                let cap = max(1, Int((2 * psiCap * arcR) / slotW))
                let m = min(ordered.count - i, cap)
                for k in 0..<m {
                    let psi = (Double(k) - Double(m - 1) / 2) * slotW / arcR
                    packed.append(Packed(member: ordered[i + k], psi: psi, arcR: arcR))
                }
                // 该层的主角半宽(绕主球):层最宽处换算
                let psiHalf = Double(m) / 2 * slotW / arcR
                let mh = atan2(arcR * sin(psiHalf), dist + arcR * cos(psiHalf))
                mainHalf = max(mainHalf, mh)
                i += m
            }
            packedAll.append(packed)
            mainHalfAll.append(mainHalf)
            megaOf.append(mega)
        }

        // 遍2:按实宽排开(缝 2°)。⚠️ 保底宽(hub 球角尺寸+缝)**不可压缩**,
        // 只压缩扇子富余 —— 统一 scale 会把保底也压没,相邻 hub 重叠
        //(07-02 自检 PNG 确诊,min gap -8.8 → +12.2)。
        let gapRad = 2.0 * .pi / 180
        let floors = hubRadii.map { 2 * asin(min(($0 + 3) / dist, 0.9)) + gapRad }
        let excesses = specs.indices.map { max(0, 2 * mainHalfAll[$0] + gapRad - floors[$0]) }
        let avail = 2 * .pi - floors.reduce(0, +)
        let exSum = excesses.reduce(0, +)
        let exScale = exSum > 0 ? min(1, avail / exSum) : 1
        var cursor = -Double.pi / 2
        for (k, spec) in specs.enumerated() {
            let width = floors[k] + excesses[k] * exScale
            let centerRad = cursor + width / 2
            cursor += width
            let r = hubRadii[k]
            let hubIdx = nodes.count
            var hubNode = GraphNode(id: hubIdx, kind: hubKind(spec), title: spec.name,
                                    radius: r, colorRGB: spec.colorRGB,
                                    fileURL: nil, hubIndex: 0)
            hubNode.hubTargetAngle = centerRad
            hubNode.hubWedgeDegrees = width * 180 / .pi
            hubNode.targetPosition = SIMD2<Float>(Float(cos(centerRad) * dist),
                                                  Float(sin(centerRad) * dist))
            nodes.append(hubNode)
            let s = GraphConstants.folderStrength(memberWeights: spec.members.map(\.weight))
            edges.append(GraphEdge(a: hubIdx, b: 0, strength: s, restLength: dist,
                                   halfWidthA: GraphConstants.edgeEndWidth(ballRadius: r),
                                   halfWidthB: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.mainRadius),
                                   springStrength: GraphConstants.hubSpringStrength))

            let hubPos = SIMD2<Double>(cos(centerRad) * dist, sin(centerRad) * dist)
            let psiScale = mainHalfAll[k] > 0
                ? min(1, (width - gapRad) / 2 / mainHalfAll[k]) : 1
            for pk in packedAll[k] {
                let m = spec.members[pk.member]
                let idx = nodes.count
                let lr = leafRadius(m) * megaOf[k]
                // ψ 按本家实际获得宽度压缩,相邻扇子不打架
                let dirA = centerRad + pk.psi * psiScale
                let target = SIMD2<Double>(hubPos.x + cos(dirA) * pk.arcR,
                                           hubPos.y + sin(dirA) * pk.arcR)
                var leafNode = GraphNode(id: idx, kind: leafKind(m), title: m.title,
                                         radius: lr, colorRGB: leafColor(spec, m),
                                         fileURL: m.url, hubIndex: hubIdx)
                leafNode.targetPosition = SIMD2<Float>(Float(target.x), Float(target.y))
                nodes.append(leafNode)
                edges.append(GraphEdge(a: idx, b: hubIdx,
                                       strength: leafStrength(m),
                                       restLength: pk.arcR,
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
