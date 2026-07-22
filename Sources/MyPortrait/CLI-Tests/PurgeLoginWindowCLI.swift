import Foundation
import GRDB

/// 一次性 CLI:清掉库里全部 loginwindow(锁屏 / login window)帧。
///
/// 07-21 配套:`capture.screen.pauseWhenLocked` gate 上线后锁屏帧不再产生,
/// 存量(~17k 行,2026-05-20 起)由本 CLI 清一次。可重复跑(幂等)。
///
/// 三步:
///   1. 找「帧全为 loginwindow」的纯锁屏 video_chunks(锁屏画面不动,去重后
///      一个 chunk 常只剩一两帧)→ 记下 id + 文件路径
///   2. 同一写事务:DELETE 全部 loginwindow 帧行 + 纯锁屏 chunk 行。
///      frames 挂 foundation_icu 分词器的 FTS5 触发器,必须走注册了
///      FoundationTokenizer 的 GRDB 连接 —— 裸 sqlite3 会触发器报错整体回滚
///      (同 TimelineDB.withTokenizerWrite 的约束)。
///   3. 事务提交后把纯锁屏 MP4 **移进隔离目录**(不直接 rm,可反悔);
///      混合 chunk(还含其他 app 帧)只删行,MP4 保留(无法部分重编码)。
///
/// 用法:`MyPortrait --purge-loginwindow <隔离目录>`
/// 与正在运行的 GUI app 共存:WAL + busyMode .timeout(5),同 withTokenizerWrite。
enum PurgeLoginWindowCLI {

    static func run(quarantineDir: String) {
        do {
            try purge(quarantineDir: quarantineDir)
            exit(0)
        } catch {
            fputs("[purge-loginwindow] ERROR: \(String(describing: error))\n", stderr)
            exit(1)
        }
    }

    private static func purge(quarantineDir: String) throws {
        let dbPath = Storage.rootURL.appendingPathComponent("portrait.sqlite").path
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let queue = try DatabaseQueue(path: dbPath, configuration: config)

        var pureFiles: [String] = []
        var deletedFrames = 0
        var deletedChunks = 0

        try queue.write { db in
            // 纯锁屏 chunk:有帧,且不存在任何非 loginwindow 帧。
            // ⚠️ 必须在删帧**之前**收集 —— 删完后纯锁屏 chunk 变成 0 帧,
            // 会跟"帧早被 retention 清掉的历史空 chunk"混在一起分不开。
            let pure = try Row.fetchAll(db, sql: """
                SELECT vc.id AS id, vc.file_path AS fp FROM video_chunks vc
                WHERE (SELECT COUNT(*) FROM frames f WHERE f.video_chunk_id = vc.id) > 0
                  AND (SELECT COUNT(*) FROM frames f
                       WHERE f.video_chunk_id = vc.id AND f.app_name != 'loginwindow') = 0
                """)
            let pureIds: [Int64] = pure.map { $0["id"] }
            pureFiles = pure.compactMap { AssetPath.resolve($0["fp"]) }

            try db.execute(sql: "DELETE FROM frames WHERE app_name = 'loginwindow'")
            deletedFrames = db.changesCount

            // 动态变长 IN:分批 500 防参数上限;显式 StatementArguments 包装
            // (CLAUDE.md 规约:不走数组字面量隐式转换)。
            for batch in stride(from: 0, to: pureIds.count, by: 500) {
                let ids = Array(pureIds[batch..<min(batch + 500, pureIds.count)])
                let marks = repeatElement("?", count: ids.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM video_chunks WHERE id IN (\(marks))",
                    arguments: StatementArguments(ids)
                )
                deletedChunks += db.changesCount
            }
        }

        // 事务已提交,搬文件(文件操作无法回滚,不进事务)。
        // 硬护栏同 TimelineDB.deleteAfter:只动 ~/.portrait 树内的文件。
        let fm = FileManager.default
        try fm.createDirectory(atPath: quarantineDir, withIntermediateDirectories: true)
        let rootPrefix = Storage.rootURL.path.hasSuffix("/")
            ? Storage.rootURL.path : Storage.rootURL.path + "/"
        var moved = 0
        for abs in pureFiles {
            guard abs.hasPrefix(rootPrefix) else { continue }   // 树外(如 screenpipe)绝不碰
            let dest = (quarantineDir as NSString)
                .appendingPathComponent((abs as NSString).lastPathComponent)
            do {
                try fm.moveItem(atPath: abs, toPath: dest)
                moved += 1
            } catch {
                fputs("[purge-loginwindow] move failed: \(abs) — \(error.localizedDescription)\n", stderr)
            }
        }

        print("[purge-loginwindow] deleted \(deletedFrames) frame row(s), " +
              "\(deletedChunks) pure-lockscreen chunk row(s); " +
              "moved \(moved) mp4 file(s) → \(quarantineDir)")
    }
}
