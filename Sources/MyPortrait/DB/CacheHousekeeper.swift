import Foundation
import os.log

/// 自动回收 —— 后台清掉确定没用的东西,**不给用户任何开关**。
///
/// 只做一件没有歧义的事:`bun/install/cache` —— bun 装 npm 包时的下载
/// 缓存,装完就没用了。
///
/// ⚠️ **绝不碰**这几个,它们看着像缓存其实不是:
///   - `bun/bin/` —— Bun 运行时本体,删了 AI 直接不能跑,要重新联网下载
///   - `pi-agent/` —— agent 的 node_modules,同上
///   - `models/` —— Downloads 页那些本地模型(说话人 / VAD / 语音分割),
///     删了那页会从 "Installed 5/5" 悄悄变回未安装
///
/// 每一步都可以在任何时刻安全地放弃:拿不准就什么都不删,下一轮(24h 后)
/// 再试。宁可多占几百 MB,不可误删用户唯一的一份文件。
enum CacheHousekeeper {

    private static let log = Logger(subsystem: "com.myportrait.db", category: "housekeeper")

    /// bun 缓存的静默期:目录在这个时间内被写过 → 多半正在装包,让开。
    private static let bunCacheQuietSeconds: TimeInterval = 600

    /// 跑一轮。挂在 RetentionWorker 的 24h 节拍上,**不受 auto-delete 模式
    /// 影响** —— 这里清的不是用户数据,是垃圾,用户选哪档都照清。
    static func run() async {
        let t = await reclaimable()
        let fm = FileManager.default
        if !t.bunCache.isEmpty {
            let freed = t.bunCache.reduce(0) { $0 + size(of: $1) }
            for u in t.bunCache { try? fm.removeItem(at: u) }
            log.notice("bun cache: freed \(freed / 1_048_576) MB")
        }
    }

    /// Settings → Storage 的 Cache 磁贴读这个。**和 `run()` 走同一份判据** ——
    /// 磁贴上的数字就是"现在点一下会腾出多少",两边不可能对不上。
    static func reclaimableBytes() async -> Int64 {
        await reclaimable().all.reduce(0) { $0 + size(of: $1) }
    }

    /// 此刻可以安全删掉的东西。**只列不删**,`run()` 和磁贴共用。
    struct Reclaimable {
        var bunCache: [URL] = []
        var all: [URL] { bunCache }
    }

    static func reclaimable() async -> Reclaimable {
        var r = Reclaimable()
        r.bunCache = bunInstallCacheTargets()
        return r
    }

    // MARK: - 1. bun 的 npm 下载缓存

    /// `BUN_INSTALL` 指到 `~/.portrait/bun`,所以 bun 的包缓存落在
    /// `bun/install/cache`。它只在装 / 升级包时用得上,`pi-agent` 装好之后
    /// 就是纯粹的历史包袱。
    private static func bunInstallCacheTargets() -> [URL] {
        let fm = FileManager.default
        let cache = AIPaths.bunDir.appendingPathComponent("install/cache", isDirectory: true)
        guard fm.fileExists(atPath: cache.path) else { return [] }

        // 两样都装好了 = 缓存已经完成它的使命。任何一样没装好都别动 ——
        // 接下来很可能就要装,留着能省一次下载。
        guard BunInstaller.isInstalled, PiInstaller.isInstalled else {
            log.info("bun cache: install not complete — skip")
            return []
        }
        // 正在 bun install 的话缓存目录会被持续写入。刚动过就让开,
        // 下一轮再说(这比给两个 installer 加运行标记省事,也更难出错:
        // 崩溃留下的 stale 标记不会让回收永久失效)。
        if let m = modifiedAt(cache), Date().timeIntervalSince(m) < bunCacheQuietSeconds {
            log.info("bun cache: touched recently — skip")
            return []
        }
        // 删内容不删目录本身 —— bun 自己会重建,但少一次目录创建少一个出错点。
        return (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - 小工具

    private static func modifiedAt(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 文件就是文件大小,目录就递归求和 —— bun 缓存的 target 文件、目录都有。
    private static func size(of url: URL) -> Int64 {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDir ? directorySize(url) : fileSize(url)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize ?? 0)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                     options: [.skipsHiddenFiles], errorHandler: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let u as URL in it {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
