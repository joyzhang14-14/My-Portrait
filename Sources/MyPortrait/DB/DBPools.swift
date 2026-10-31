import Foundation
import GRDB

/// 四个库的连接池。`Services` 建一份,每个组件只拿自己领域的那个:
/// 屏幕采集 → `screen`,音频 → `audio`,击键 / 鼠标 / 打字 / 剪贴板 → `input`,
/// 事件区间、处理台账、写作风格 → `workflow`。
///
/// 每个池:WAL、5 秒忙等待(Premium 辅助进程会和 app 抢写锁)、外键全开。
/// 分词器只在 screen、audio 上注册(只有 frames_fts / transcriptions_fts 用)。
struct DBPools: Sendable {
    let screen: DatabasePool
    let audio: DatabasePool
    let input: DatabasePool
    let workflow: DatabasePool

    var all: [DatabasePool] { [screen, audio, input, workflow] }

    /// 打开 `~/.portrait` 下的四个库并跑迁移。要求拆库已经完成(见 `DBSplitMigration`)。
    static func open() throws -> DBPools {
        try DBSplitMigration.requireDone()
        return try open(screen: Storage.screenDBPath, audio: Storage.audioDBPath,
                        input: Storage.inputDBPath, workflow: Storage.workflowDBPath)
    }

    /// 自测用:四个库平铺在一个临时目录里。
    static func open(in dir: URL) throws -> DBPools {
        try open(screen: dir.appendingPathComponent("screen.sqlite").path,
                 audio: dir.appendingPathComponent("audio.sqlite").path,
                 input: dir.appendingPathComponent("input.sqlite").path,
                 workflow: dir.appendingPathComponent("workflow.sqlite").path)
    }

    static func open(screen: String, audio: String, input: String, workflow: String) throws -> DBPools {
        DBPools(
            screen: try openPool(path: screen, kind: .screen),
            audio: try openPool(path: audio, kind: .audio),
            input: try openPool(path: input, kind: .input),
            workflow: try openPool(path: workflow, kind: .workflow))
    }

    enum Kind {
        case screen, audio, input, workflow

        var migrator: DatabaseMigrator {
            switch self {
            case .screen: DBSchema.screenMigrator()
            case .audio: DBSchema.audioMigrator()
            case .input: DBSchema.inputMigrator()
            case .workflow: DBSchema.workflowMigrator()
            }
        }
        /// 帧库几个 GB、转录要全文搜,给大的 mmap 和页缓存;input、workflow 用默认值,
        /// 不然 4 个池各占 256MB mmap + 64MB 缓存。
        var large: Bool { self == .screen || self == .audio }
        var tokenizer: Bool { self == .screen || self == .audio }
    }

    /// 建一个池并迁移到最新。父目录不存在就建(首启时 metadata/、pipeline/ 可能还没有)。
    static func openPool(path: String, kind: Kind) throws -> DatabasePool {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: path, configuration: configuration(kind))
        try kind.migrator.migrate(pool)
        return pool
    }

    static func configuration(_ kind: Kind) -> Configuration {
        var config = Configuration()
        // 夜间 seal-check helper 是另一个进程,会和 app 抢同一把 WAL 写锁;
        // 默认 .immediateError 会让采集写入直接失败,改成最多等 5 秒。
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // WAL:写不阻塞读,崩溃恢复用 .wal 文件
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // NORMAL:WAL 下足够安全(FULL 慢 10×),系统/电源故障最多丢最近一次提交
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // 默认 SQLite 不强制外键,必须显式开
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            if kind.large {
                // mmap 256MB:读 query 直接读映射页,免去 read syscall + buffer copy。
                // 虚拟地址空间,物理内存按需 page-in。
                try db.execute(sql: "PRAGMA mmap_size = 268435456")
                // 64MB 页缓存(负值 = KB)。默认 ~2MB 对几百 MB 大表不够,JOIN / FTS5 重排反复 page-in。
                try db.execute(sql: "PRAGMA cache_size = -65536")
            }
            // Foundation 后端的 ICU 分词器,FTS5 表才能识别 tokenizer="foundation_icu"。
            if kind.tokenizer { db.add(tokenizer: FoundationTokenizer.self) }
        }
        return config
    }
}
