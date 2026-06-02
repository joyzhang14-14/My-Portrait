import Foundation

/// 所有 portrait 文件(包括 writing_style)共享的 weight 计算 + 衰减刷新。
///
/// 公式:weight = ref_count × exp(-Δt / τ),τ = halfLifeDays / ln(2)
/// 半衰期 30 天 = 一个月没新 ref → 权重砍半,180 天 ≈ 1.5%,永不归零。
///
/// 不覆盖 personality —— 那条链路由 PersonalityAgent / PersonalityMerger
/// 自管 weight,跟这套不互通。
enum PortraitWeight {

    /// 半衰期(天)。所有 portrait 类目共用同一档。
    static let halfLifeDays: Double = 30.0

    /// 纯算法,无副作用。
    static func compute(refCount: Int, lastModified: Date, now: Date = Date()) -> Double {
        let count = Double(max(0, refCount))
        let dtDays = max(0.0, now.timeIntervalSince(lastModified) / 86_400.0)
        let tau = halfLifeDays / log(2.0)
        return count * exp(-dtDays / tau)
    }

    /// 在某 dir 下所有 .md 上重算 weight(INDEX.md 跳过)。**只动 weight,
    /// 不动 lastModified**,让没被 distill update 的 entry 也随时间淡出。
    /// 浮点容差 1e-6 避免无变化文件被反复写盘(脏 mtime / git diff)。
    ///
    /// - Parameter extractRefCount: 从 body 抽 ref count 的回调。不同类目的
    ///   link 格式不同(`- [[id]]` vs `[[wr:id]]`),由调用方传具体抽法。
    static func refresh(in dir: URL, extractRefCount: (String) -> Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let now = Date()
        for name in items where name.hasSuffix(".md") && name != "INDEX.md" {
            let url = dir.appendingPathComponent(name)
            guard var file = try? PortraitFileIO.read(from: url) else { continue }
            let refCount = extractRefCount(file.body)
            let anchor = file.lastModified ?? file.created
            let newWeight = compute(refCount: refCount, lastModified: anchor, now: now)
            if abs(file.weight - newWeight) < 1e-6 { continue }
            file.weight = newWeight
            try? PortraitFileIO.write(file, to: url)
        }
    }

    // MARK: - Link extractors

    /// PortraitDistiller 的 link 格式 —— body 末尾 `**Derived from events:**`
    /// 块下逐行 `- [[<event-id>]]`。render 时 cap 在 20 条,所以这里也封顶 20。
    static func extractDistillRefCount(from body: String) -> Int {
        var count = 0
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [[") && line.hasSuffix("]]") {
                count += 1
            }
        }
        return count
    }

    /// WritingStyleDistiller 的 link 格式 —— body 末尾 inline
    /// `[[wr:<id>]], [[wr:<id>]], ...`。不 cap(writing_style render 也不 cap)。
    /// `[[wr:<id>]]` 正则只编译一次 —— refresh 时每个文件都调,别每次重编译
    /// (正则编译比 DateFormatter 分配贵得多)。
    private static let writingStyleRefRegex =
        try? NSRegularExpression(pattern: #"\[\[wr:(\d+)\]\]"#)

    static func extractWritingStyleRefCount(from body: String) -> Int {
        guard let regex = Self.writingStyleRefRegex else { return 0 }
        let ns = body as NSString
        return regex.numberOfMatches(in: body, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: - 顶层 refresh 入口

    /// 刷 PortraitPaths.distillCategories 下所有目录的 weight。
    /// PortraitDistiller.distill() 入口调一次。
    static func refreshDistillCategories() {
        for cat in PortraitPaths.distillCategories {
            refresh(in: PortraitPaths.categoryDir(cat), extractRefCount: extractDistillRefCount)
        }
    }

    /// 刷 portrait/writing_style/ 下的 weight。WritingStyleDistiller 入口调。
    static func refreshWritingStyle() {
        refresh(in: PortraitPaths.categoryDir("writing_style"),
                extractRefCount: extractWritingStyleRefCount)
    }
}
