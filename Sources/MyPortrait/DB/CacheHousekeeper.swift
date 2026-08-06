import Foundation
import os.log

/// 自动回收 —— 后台清掉确定没用的东西,**不给用户任何开关**。
///
/// 只做两件没有歧义的事:
///   1. `bun/install/cache` —— bun 装 npm 包时的下载缓存,装完就没用了
///   2. `attachments/` 里没有任何**还活着的对话**再引用的孤儿文件
///
/// ⚠️ **绝不碰**这几个,它们看着像缓存其实不是:
///   - `bun/bin/` —— Bun 运行时本体,删了 AI 直接不能跑,要重新联网下载
///   - `pi-agent/` —— agent 的 node_modules,同上
///   - `models/` —— Downloads 页那些本地模型(说话人 / VAD / 语音分割),
///     删了那页会从 "Installed 5/5" 悄悄变回未安装
///   - `agent_sessions/` —— 对话删除时 `ChatStore.deleteConversation` 已经
///     跟着删了,这里再插一手只会跟它打架
///
/// 每一步都可以在任何时刻安全地放弃:拿不准就什么都不删,下一轮(24h 后)
/// 再试。宁可多占几百 MB,不可误删用户唯一的一份文件。
enum CacheHousekeeper {

    private static let log = Logger(subsystem: "com.myportrait.db", category: "housekeeper")

    /// 附件的年龄闸:只有**这么久没动过**的才进入孤儿判定。
    /// 刚粘上还没发出去的、正在聊的,一律不碰。
    private static let attachmentMinAgeDays: Double = 30

    /// bun 缓存的静默期:目录在这个时间内被写过 → 多半正在装包,让开。
    private static let bunCacheQuietSeconds: TimeInterval = 600

    /// 单个 session 文件的读取上限。超过就当"读不了"处理(见 sweep 里的
    /// fail-safe)—— 不为了回收几十 MB 附件去把几百 MB 的 jsonl 读进内存。
    private static let maxSessionFileBytes: Int = 64 * 1024 * 1024

    /// 跑一轮。挂在 RetentionWorker 的 24h 节拍上,**不受 auto-delete 模式
    /// 影响** —— 这里清的不是用户数据,是垃圾,用户选 Off 也照清。
    static func run() async {
        sweepBunInstallCache()
        await sweepOrphanAttachments()
    }

    // MARK: - 1. bun 的 npm 下载缓存

    /// `BUN_INSTALL` 指到 `~/.portrait/bun`,所以 bun 的包缓存落在
    /// `bun/install/cache`。它只在装 / 升级包时用得上,`pi-agent` 装好之后
    /// 就是纯粹的历史包袱。
    private static func sweepBunInstallCache() {
        let fm = FileManager.default
        let cache = AIPaths.bunDir.appendingPathComponent("install/cache", isDirectory: true)
        guard fm.fileExists(atPath: cache.path) else { return }

        // 两样都装好了 = 缓存已经完成它的使命。任何一样没装好都别动 ——
        // 接下来很可能就要装,留着能省一次下载。
        guard BunInstaller.isInstalled, PiInstaller.isInstalled else {
            log.info("bun cache: install not complete — skip")
            return
        }
        // 正在 bun install 的话缓存目录会被持续写入。刚动过就让开,
        // 下一轮再说(这比给两个 installer 加运行标记省事,也更难出错:
        // 崩溃留下的 stale 标记不会让回收永久失效)。
        if let m = modifiedAt(cache), Date().timeIntervalSince(m) < bunCacheQuietSeconds {
            log.info("bun cache: touched recently — skip")
            return
        }

        let before = directorySize(cache)
        // 删内容不删目录本身 —— bun 自己会重建,但少一次目录创建少一个出错点。
        guard let children = try? fm.contentsOfDirectory(at: cache,
                                                        includingPropertiesForKeys: nil) else { return }
        for u in children { try? fm.removeItem(at: u) }
        log.notice("bun cache: freed \(before / 1_048_576) MB")
    }

    // MARK: - 2. attachments 孤儿回收

    /// 附件(用户往聊天里粘的图 / 拖的文件)存成 `attachments/<UUID>.<ext>`。
    ///
    /// **引用只存在于 agent 的 session 文件里** —— 消息正文存的是用户打的字,
    /// 附件路径只进了发给 agent 的 prompt(`ChatController.send`),而
    /// `attachmentsByMessage` 明确不持久化。所以判定就是:还活着的对话,
    /// 它自己那个 session 文件里有没有提到这个 UUID。
    ///
    /// **只查活对话自己的那一个文件,不扫目录。** Claude Code 的
    /// `~/.claude/projects` 在开发机上能有 8 GB / 两万多个 jsonl,全扫是灾难。
    private static func sweepOrphanAttachments() async {
        let fm = FileManager.default
        let dir = AIPaths.supportDir.appendingPathComponent("attachments", isDirectory: true)
        guard fm.fileExists(atPath: dir.path),
              let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        let cutoff = Date().addingTimeInterval(-attachmentMinAgeDays * 86400)
        let candidates = files.filter { u in
            guard let m = modifiedAt(u) else { return false }   // 读不到日期 → 不碰
            return m < cutoff
        }
        guard !candidates.isEmpty else { return }

        // 活对话的 session 文件清单。conv 被删时 pi 的 jsonl 会跟着删,
        // 所以"对话没了"天然等于"它的附件成了孤儿"。
        let convs = await MainActor.run {
            ChatStore.shared.conversations.map { ($0.piSessionPath, $0.claudeSessionId) }
        }

        var sessionFiles: [URL] = []
        for (piPath, claudeSid) in convs {
            if let p = piPath, fm.fileExists(atPath: p) {
                sessionFiles.append(URL(fileURLWithPath: p))
            }
            if let sid = claudeSid, let u = claudeSessionFile(sid: sid) {
                sessionFiles.append(u)
            }
        }

        // UUID(不含扩展名)出现在任何一个 session 文本里 = 还被引用。
        var referenced = Set<String>()
        for f in sessionFiles {
            guard let text = readIfSmallEnough(f) else {
                // 有文件但读不出来 → 我们不知道它引用了什么。**整轮放弃**,
                // 一个都不删。宁可这次白跑,不可猜。
                log.notice("attachments: session unreadable — abort this pass")
                return
            }
            for u in candidates {
                let stem = u.deletingPathExtension().lastPathComponent
                if !referenced.contains(stem), text.contains(stem) {
                    referenced.insert(stem)
                }
            }
        }

        var freed: Int64 = 0
        var n = 0
        for u in candidates {
            let stem = u.deletingPathExtension().lastPathComponent
            guard !referenced.contains(stem) else { continue }
            freed += fileSize(u)
            try? fm.removeItem(at: u)
            n += 1
        }
        if n > 0 {
            log.notice("attachments: removed \(n) orphan(s), freed \(freed / 1_048_576) MB")
        }
    }

    /// Claude Code 把 session 存在 `~/.claude/projects/<项目目录名>/<sid>.jsonl`。
    /// 那个目录名怎么算是它的内部实现,**不猜** —— 在 projects 下面平铺找一层,
    /// 找到哪个算哪个。找不到 → nil(该 session 已经不在了,它引用的附件也就
    /// 再没人能读到)。
    private static func claudeSessionFile(sid: String) -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return nil }
        for p in projects {
            let f = p.appendingPathComponent("\(sid).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    // MARK: - 小工具

    /// 读文件内容。超过上限 → nil(调用方按"读不了"走 fail-safe)。
    private static func readIfSmallEnough(_ url: URL) -> String? {
        guard fileSize(url) <= Int64(maxSessionFileBytes) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func modifiedAt(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
