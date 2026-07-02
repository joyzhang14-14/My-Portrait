import Foundation

/// 把磁盘上的 memory 数据(events/*.md + _folders/*.json + portrait/<cat>/*.md)
/// 变成一张 GraphScene。纯读盘 + 纯函数,设计为在后台线程跑
/// (调用方先在 MainActor 读好 ConfigStore 的参数传进来)。
///
/// 完美圆·物理化(07-02 终稿,Handoff §二):builder 只产**参数**不产落位:
///   1. hub 等距半径(公式:outer − 全局最深 day-rest,floor 到装箱/碰撞下限)
///   2. 楔形份额 = 叶数占比(hub 间角向碰撞半宽 ×2,亦是扇区墙全角)
///   3. 叶子弹簧 rest = 家内 last_occurred 排名铺 25%~100% 跨度(顶格=外圆)
///   位置全部由力系统涌现(角向碰撞平衡处即扇区边界,外缘自然成圆)。
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

        // 07-02 物理化终稿:builder 只给**参数**(等距半径/楔形份额/弹簧
        // rest),不给落位 —— 位置全部由力系统涌现(Handoff §二)。
        // hub 距主球全体相等(公式不变):
        let hubRadii = specs.map(hubRadius)
        let globalMaxRest = specs.flatMap { $0.members.map(leafRest) }.max()
            ?? (outerRadius - hubDistance)
        let packFloor = (hubRadii.map { $0 * 2 + 10 }.reduce(0, +)) / (2 * .pi)
        let maxHubR = hubRadii.max() ?? 0
        let dist = max(outerRadius - globalMaxRest,
                       packFloor,
                       GraphConstants.mainRadius + maxHubR
                           + Double(GraphConstants.mainCollisionPadding) + 2)
        let span = max(outerRadius - dist, 40)

        // 楔形份额 = 叶数占比(hub 间角向碰撞的直径,扇区墙的全角)。
        // ⚠️ 保底宽(hub 球角尺寸+缝)**不可压缩**,只等比压缩份额富余
        //(过订会让角向碰撞永远解不开,小 hub 被挤到重叠 —— 同 07-02
        // 两遍法的教训,搬到碰撞盘宽度上)。归一化目标留每家 2° 余量:
        // Σ 不必精确 360(用户 07-02 拍板),扇形间**绝不重叠**是硬约束,
        // 满订时叶群扭矩会把相邻盘压到互渗 ~15%,余量吸收它。
        let shares = allocateWedges(counts: specs.map { $0.members.count })
        let floors = specs.indices.map { k in
            (2 * asin(min((hubRadii[k] + 3) / dist, 0.9))) * 180 / .pi + 2
        }
        let excesses = specs.indices.map { max(0, shares[$0] - floors[$0]) }
        let avail = max(0, 360 - 2 * Double(specs.count) - floors.reduce(0, +))
        let exSum = excesses.reduce(0, +)
        let exScale = exSum > 0 ? min(1, avail / exSum) : 1
        for (k, spec) in specs.enumerated() {
            let r = hubRadii[k]
            let hubIdx = nodes.count
            var hubNode = GraphNode(id: hubIdx, kind: hubKind(spec), title: spec.name,
                                    radius: r, colorRGB: spec.colorRGB,
                                    fileURL: nil, hubIndex: 0)
            hubNode.hubWedgeDegrees = floors[k] + excesses[k] * exScale
            hubNode.hubPinRadius = dist
            nodes.append(hubNode)
            let s = GraphConstants.folderStrength(memberWeights: spec.members.map(\.weight))
            edges.append(GraphEdge(a: hubIdx, b: 0, strength: s, restLength: dist,
                                   halfWidthA: GraphConstants.edgeEndWidth(ballRadius: r),
                                   halfWidthB: GraphConstants.edgeEndWidth(
                                       ballRadius: GraphConstants.mainRadius),
                                   springStrength: GraphConstants.hubSpringStrength))

            // 线长 = 排名 + 日期间隔压缩映射(07-02 用户定稿):家内按
            // last_occurred 升序,相邻两条的线长差 = 1 + ln(1+日期差) 个
            // 步进 —— 同日也分开 1 槽(可读);差 1 天 ≈1.7 槽、差 1 个月
            // ≈4.5 槽:日期差大则变化被压缩,但绝不等同(纯排名=太过,
            // 30 天硬窗=超窗全糊,两者都被否)。归一化铺 25%~100% 跨度,
            // 最旧顶格 = span → 外缘成圆。
            // 叶径自适应(取代固定 ×0.72):楔形环带面积装不下全部叶球时
            // 按 √面积比全体等比缩球 —— 「清晰可见不重叠」先保证几何
            // 可行,物理才有解;装得下则不缩。0.6 = 不规则装填经验密度。
            let inner = dist + 0.25 * span
            let areaAvail = (hubNode.hubWedgeDegrees! * .pi / 180) / 2
                * (outerRadius * outerRadius - inner * inner) * 0.6
            let areaNeed = spec.members.reduce(0.0) {
                let lr = leafRadius($1) + 1
                return $0 + .pi * lr * lr
            }
            let mega = min(1, max(0.4, (areaAvail / max(areaNeed, 1)).squareRoot()))
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
            for (rank, mi) in ordered.enumerated() {
                let m = spec.members[mi]
                let idx = nodes.count
                let lr = leafRadius(m) * mega
                let rest = span * (0.25 + 0.75 * cum[rank] / cMax)
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
