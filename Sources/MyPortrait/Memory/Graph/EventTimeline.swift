import Foundation

/// 图谱时间线的历史重建(07-11 用户:给 neural graph 做时间线,看每天的变化)。
///
/// **零新增存储** —— 任意一天的图谱状态都能从现有 event 文件算出来。三条依据
/// 都已用真实数据(1375 条 event / 112 天 / 13 个 folder)验证过:
///
/// ① **某天有哪些 event**:frontmatter 的 `created`(与 `events/<day>/` 路径同源)。
///
/// ② **某天的 weight**:`WeightCalculator` 本就是纯函数且自带 `now:` 参数 ——
///    `weight = impact × (1+距上次发生天数)^-α × (1+ln(1+发生天数))`,
///    三个输入全部可按日回放(occurrences 是完整日期数组,筛 ≤ 当日即可)。
///    实测 400 条随机样本:重算值与文件里存的 weight **平均差 0.0001、最大
///    0.0005**,等于精确复现。
///
/// ③ **某天的 folder 归属**:folder JSON 的 `events[]` 是**按加入顺序追加**的
///    (见 EventFolder.events 注释),配合 `createdAtMs` 得到加入日的单调下界:
///
///        joinDate = max(event 诞生日, folder 创建日, 数组中前一个成员的 joinDate)
///
///    ⚠️ **不能**直接拿今天的归属往回投影。实测 **13/13 个 folder 都有成员的
///    event 日期早于 folder 创建日**(claude-codex-access 建于 07-20,最早成员
///    却是 05-05,早 76 天)—— 分类器是**追溯性**的,新建 folder 时会把一直躺在
///    Unclassified 里的存量 event 一次性收编。直接回投影会让 event 假装一出生
///    就在 folder 里,把这段历史抹掉。按上面的规则重建,还原的是真实发生过的
///    「先堆在 Unclassified → folder 结晶那天成批迁徙过去」。
enum EventTimeline {

    /// 一条 event 的重建输入(解析一次,之后按日重算全在内存里)。
    struct Entry {
        let relPath: String
        let url: URL
        let title: String
        let impact: Double
        /// 全部发生日(升序,已按天截断)。weight 的两个输入都来自它。
        let occurrenceDays: [Date]
        /// 诞生日 = created(取 occurrences 首日兜底)。
        let born: Date
        /// 归入哪个 folder slug,以及**加入那天**;nil = 从未被分类。
        var join: (slug: String, day: Date)?
    }

    /// 某一天的图谱状态(纯数据,不含布局)。
    struct DayState {
        let day: Date
        /// relPath → 那天的 weight(只含已诞生的)。
        let weight: [String: Double]
        /// relPath → 那天所属 folder slug;不在表里 = Unclassified。
        let folderOf: [String: String]
        /// 那天已存在的 folder slug(已过创建日;是否够 3 个核心球由 builder 判)。
        let liveFolders: Set<String>
    }

    /// 解析一次的索引。拖动日期时只用它,不再碰磁盘。
    struct Index {
        let entries: [Entry]
        /// folder slug → (显示名, 颜色 hex, 创建日)
        let folders: [String: (name: String, colorHex: String?, created: Date)]
        /// 数据覆盖的日期范围(按天)。
        let range: ClosedRange<Date>
        /// 每天新诞生的 event 数(时间轴柱状图用)。
        let birthsPerDay: [Date: Int]
    }

    // MARK: - 载入

    static func load(eventsDir: URL = Storage.uiEventsDir) -> Index? {
        let cal = Calendar(identifier: .gregorian)
        let folderList = EventFolderStore.loadAll(in: eventsDir)

        // folder 元数据(加入日在解析完 event 后再算 —— 要用 frontmatter 的
        // created 当诞生日,与路径目录名可能不一致)
        var folders: [String: (name: String, colorHex: String?, created: Date)] = [:]
        for f in folderList {
            let fCreated = cal.startOfDay(
                for: Date(timeIntervalSince1970: Double(f.createdAtMs) / 1000))
            folders[f.slug] = (f.name, f.colorHex, fCreated)
        }

        // 扫全部 event 文件
        var entries: [Entry] = []
        var births: [Date: Int] = [:]
        let fm = FileManager.default
        guard fm.fileExists(atPath: eventsDir.path),
              let en = fm.enumerator(at: eventsDir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles])
        else { return nil }
        let prefix = eventsDir.path + "/"
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
            if url.pathComponents.contains("_archive") { continue }
            if url.pathComponents.contains("_quarantine") { continue }
            if url.pathComponents.contains("_folders") { continue }
            guard let file = try? PortraitFileIO.read(from: url) else { continue }
            let rel = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            let days = file.occurrences.map { cal.startOfDay(for: $0) }.sorted()
            let born = cal.startOfDay(for: file.created)
            let title = file.eventTitle.isEmpty
                ? url.deletingPathExtension().lastPathComponent : file.eventTitle
            entries.append(Entry(relPath: rel, url: url, title: title,
                                 impact: file.impact ?? 0,
                                 occurrenceDays: days, born: born, join: nil))
            births[born, default: 0] += 1
        }
        guard !entries.isEmpty else { return nil }
        entries.sort { $0.relPath < $1.relPath }   // 规范顺序(节点身份跨天恒定)

        // 加入日(见类型注释③):沿 folder.events 数组单调不减,且不早于
        // event 诞生日与 folder 创建日。
        var bornOf: [String: Date] = [:]
        for e in entries { bornOf[e.relPath] = e.born }
        var joinOf: [String: (slug: String, day: Date)] = [:]
        for f in folderList {
            guard let fCreated = folders[f.slug]?.created else { continue }
            var prev: Date? = nil
            for rel in f.events {
                guard let evBorn = bornOf[rel] else { continue }   // 已删除的成员
                var j = max(evBorn, fCreated)
                if let p = prev, j < p { j = p }
                prev = j
                if joinOf[rel] == nil { joinOf[rel] = (f.slug, j) }
            }
        }
        for i in entries.indices { entries[i].join = joinOf[entries[i].relPath] }

        let lo = entries.map(\.born).min()!
        let hi = max(entries.map(\.born).max()!, cal.startOfDay(for: Date()))
        return Index(entries: entries, folders: folders, range: lo...hi,
                     birthsPerDay: births)
    }

    // MARK: - 按日重算

    /// 某一天的状态。纯内存计算,拖动时每帧调都不心疼。
    static func state(_ idx: Index, on day: Date,
                      params: WeightCalculator.Params = .default) -> DayState {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.startOfDay(for: day)
        var weight: [String: Double] = [:]
        var folderOf: [String: String] = [:]
        weight.reserveCapacity(idx.entries.count)
        for e in idx.entries {
            guard e.born <= d else { continue }          // 还没诞生
            weight[e.relPath] = weightAt(e, day: d, params: params)
            if let j = e.join, j.day <= d { folderOf[e.relPath] = j.slug }
        }
        let live = Set(idx.folders.filter { $0.value.created <= d }.map(\.key))
        return DayState(day: d, weight: weight, folderOf: folderOf, liveFolders: live)
    }

    /// 某条 event 在某天的 weight —— 与 WeightCalculator 同一公式,只是把
    /// occurrences 截断到当天(那天还没发生的次数当然不能算进去)。
    static func weightAt(_ e: Entry, day: Date,
                         params: WeightCalculator.Params = .default) -> Double {
        let occ = e.occurrenceDays.filter { $0 <= day }
        guard let last = occ.last else { return params.minWeight }
        let days = max(0.0, day.timeIntervalSince(last) / 86_400)
        let decay = pow(1.0 + days, -params.alpha)
        let freq = log(1.0 + Double(occ.count))
        return max(params.minWeight, e.impact * decay * (1.0 + freq))
    }

    // MARK: - 工具

    nonisolated(unsafe) private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - 校验 CLI(`--graph-timeline-dump`)

    /// 不开 GUI 打印逐日重建结果,用来核对重建是否合理(dev tool)。
    static func dumpCLI() {
        guard let idx = load() else { print("no events"); exit(1) }
        let fmt = dayFmt
        print("=== Neural Graph 时间线重建 ===")
        print("event \(idx.entries.count) 条,folder \(idx.folders.count) 个,"
              + "范围 \(fmt.string(from: idx.range.lowerBound))"
              + " … \(fmt.string(from: idx.range.upperBound))")
        let classified = idx.entries.filter { $0.join != nil }.count
        print("被分类 \(classified),从未分类 \(idx.entries.count - classified)")
        print("")
        print("日期          已诞生   已分类  Unclassified  活跃folder   最大weight")
        let cal = Calendar(identifier: .gregorian)
        var d = idx.range.lowerBound
        var step = 0
        while d <= idx.range.upperBound {
            if step % 10 == 0 || d == idx.range.upperBound {
                let st = state(idx, on: d)
                let born = st.weight.count
                let cls = st.folderOf.count
                let mx = st.weight.values.max() ?? 0
                print(String(format: "%@ %8d %8d %13d %11d %11.2f",
                             fmt.string(from: d), born, cls, born - cls,
                             st.liveFolders.count, mx))
            }
            guard let nx = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = nx; step += 1
        }
        print("")
        print("=== 按日建场景(节点/边/hub/陨石)===")
        print("日期            节点     边    hub   核心球   陨石")
        var d2 = idx.range.lowerBound
        var st2 = 0
        while d2 <= idx.range.upperBound {
            if st2 % 20 == 0 || d2 == idx.range.upperBound {
                let sc = GraphSceneBuilder.buildEventsTimeline(index: idx, on: d2, userName: "Me")
                let hubs = sc.nodes.filter { $0.kind.isHub }.count
                let belt = sc.nodes.filter { $0.beltTier != nil }.count
                let core = sc.nodes.count - hubs - belt - 1
                print(String(format: "%@ %8d %6d %6d %8d %6d",
                             fmt.string(from: d2), sc.nodes.count, sc.edges.count,
                             hubs, core, belt))
            }
            guard let nx = cal.date(byAdding: .day, value: 1, to: d2) else { break }
            d2 = nx; st2 += 1
        }
        print("")
        print("=== folder 诞生日收编的存量 event ===")
        for (slug, meta) in idx.folders.sorted(by: { $0.value.created < $1.value.created }) {
            let n = idx.entries.filter { $0.join?.slug == slug && $0.join?.day == meta.created }.count
            if n > 0 { print("  \(fmt.string(from: meta.created))  \(slug) — 一次性收编 \(n) 条") }
        }
        exit(0)
    }
}
