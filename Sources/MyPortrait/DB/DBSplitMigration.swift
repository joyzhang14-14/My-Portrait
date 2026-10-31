import AppKit
import Foundation
import GRDB

/// 一次性拆库:把 `~/.portrait/portrait.sqlite` 拆成 `metadata/{screen,audio,input}.sqlite`
/// 和 `pipeline/workflow.sqlite`,`clipboard.sqlite` 并进 input,媒体目录挪进 `metadata/`。
///
/// 帧数据(十几 GB)不拷贝:主文件直接改名成 `screen.sqlite`,只把别的表拷进新库,
/// 核对无误后再从 screen 里删掉。进度记在 `.staging/db-split.json` 的 `stage` 里,
/// 中断后从断点接着跑。实验室脚本只在 `stage == "done"` 时才打开新库。
///
/// 每个进程(app、Premium 辅助进程、命令行工具)启动时都先调 `runIfNeeded()`:
/// 拿共享锁,标记是 done 就继续持有共享锁直到进程退出;不是 done 就换独占锁做迁移。
/// 迁移进行中别的进程会在共享锁上等着,不会打开半拆的库。
enum DBSplitMigration {

    enum Stage: String, CaseIterable {
        case started, renamed, copied, verified, dropped, media_moved, done
        var order: Int { Stage.allCases.firstIndex(of: self)! }
    }

    struct SplitError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - 入口

    /// 启动时调一次,在任何开库之前。
    static func runIfNeeded() {
        guard lock(LOCK_SH) else { fail(SplitError("another My Portrait process is splitting the database; timed out waiting")) }
        if stage() == .done { return }
        flock(lockFD, LOCK_UN)
        guard lock(LOCK_EX) else { fail(SplitError("timed out waiting for other My Portrait processes to close the database")) }
        defer { flock(lockFD, LOCK_SH) }   // 做完降回共享锁,一直持有到进程退出
        if stage() == .done { return }
        do {
            try migrate()
        } catch {
            var marker = readMarker()
            marker["error"] = error.localizedDescription
            writeMarker(marker)
            fail(error)
        }
    }

    /// 开库前的检查:拆库没完成就报错,不让任何代码打开半拆的库。
    static func requireDone() throws {
        guard stage() == .done else {
            throw SplitError("database split not finished (\(Storage.dbSplitMarkerPath)); restart My Portrait")
        }
    }

    // MARK: - 锁和进度标记

    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// 等锁最多 10 分钟(拆库本身一两分钟)。
    private static func lock(_ op: Int32) -> Bool {
        if lockFD < 0 {
            try? FileManager.default.createDirectory(at: Storage.stagingDir, withIntermediateDirectories: true)
            lockFD = open(Storage.dbSplitLockPath, O_CREAT | O_RDWR, 0o644)
            guard lockFD >= 0 else { return false }
        }
        let deadline = Date().addingTimeInterval(600)
        while flock(lockFD, op | LOCK_NB) != 0 {
            if Date() > deadline { return false }
            usleep(200_000)
        }
        return true
    }

    static func stage() -> Stage? {
        (readMarker()["stage"] as? String).flatMap(Stage.init(rawValue:))
    }

    private static func readMarker() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: Storage.dbSplitMarkerPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func writeMarker(_ marker: [String: Any]) {
        var m = marker
        m["updated_at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Storage.stagingDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Storage.dbSplitMarkerPath), options: .atomic)
    }

    private static func advance(_ marker: inout [String: Any], to stage: Stage) {
        marker["stage"] = stage.rawValue
        marker.removeValue(forKey: "error")
        writeMarker(marker)
        DiagLog.event("db.split.stage", ctx: ["stage": stage.rawValue])
    }

    private static func fail(_ error: Error) -> Never {
        let msg = "Database split failed: \(error.localizedDescription)"
        DiagLog.error("db.split.failed", ctx: ["err": error.localizedDescription])
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        // 只有 GUI 启动(没带命令行参数,或只带 --background)才弹窗,命令行工具只打到 stderr。
        let args = ProcessInfo.processInfo.arguments.dropFirst().filter { $0 != "--background" }
        if !args.contains(where: { $0.hasPrefix("--") }) {
            let alert = NSAlert()
            alert.messageText = "My Portrait couldn't upgrade its database"
            alert.informativeText = "\(error.localizedDescription)\n\nYour data is unchanged. Details: \(Storage.dbSplitMarkerPath)"
            alert.runModal()
        }
        exit(1)
    }

    // MARK: - 迁移

    /// 搬进新库的表,父表在前。
    private static let moves: [(schema: String, tables: [String])] = [
        ("audio", ["audio_chunks", "audio_transcriptions", "speakers", "speaker_embeddings"]),
        ("input", ["keystroke_log", "mouse_log", "typing_events"]),
        ("workflow", ["event_intervals", "personality_days", "processing_log", "pipeline_runs",
                      "distill_changelog", "writing_records", "writing_style_runs", "writing_style_staged"]),
    ]
    /// 修数据工具留下的声纹备份表,建表语句照抄,跟着声纹进 audio。
    private static let audioBackupTables = ["speaker_embeddings_bak_clean", "speaker_embeddings_bak_reenroll"]

    private static var newDBs: [(schema: String, path: String, kind: DBPools.Kind)] {
        [("audio", Storage.audioDBPath, .audio),
         ("input", Storage.inputDBPath, .input),
         ("workflow", Storage.workflowDBPath, .workflow)]
    }

    private static func migrate() throws {
        let fm = FileManager.default
        var marker = readMarker()
        var current = stage()

        if current == nil {
            let hasLegacy = isSQLite(Storage.legacyPortraitDBPath)
            if !hasLegacy && !fm.fileExists(atPath: Storage.screenDBPath) {
                // 新装:没有旧库,四个库由 DBPools 按基线新建。
                marker["fresh_install"] = true
                advance(&marker, to: .done)
                return
            }
            guard hasLegacy else {
                throw SplitError("found \(Storage.screenDBPath) but no split progress marker")
            }
            advance(&marker, to: .started)
            current = .started
        }
        guard var stage = current else { return }
        DiagLog.event("db.split.resume", ctx: ["stage": stage.rawValue])

        if stage == .started {
            try renameLegacy()
            advance(&marker, to: .renamed); stage = .renamed
        }
        if stage == .renamed {
            try copyTables()
            advance(&marker, to: .copied); stage = .copied
        }
        if stage == .copied {
            marker["verify"] = try verify()
            advance(&marker, to: .verified); stage = .verified
        }
        if stage == .verified {
            try dropMovedTables()
            advance(&marker, to: .dropped); stage = .dropped
        }
        if stage == .dropped {
            marker["media"] = try moveMedia()
            advance(&marker, to: .media_moved); stage = .media_moved
        }
        if stage == .media_moved {
            advance(&marker, to: .done)
        }
    }

    /// 第 2 步:checkpoint 后把主文件改名成 screen.sqlite,原位置放一个 SQLite 打不开的占位文件,
    /// 让漏改的路径直接报错,而不是悄悄建一个空库。
    private static func renameLegacy() throws {
        let fm = FileManager.default
        let legacy = Storage.legacyPortraitDBPath, screen = Storage.screenDBPath
        if isSQLite(legacy) {
            guard !fm.fileExists(atPath: screen) else { throw SplitError("both \(legacy) and \(screen) exist") }
            try checkpointTruncate(legacy)
            try fm.createDirectory(at: Storage.metadataDir, withIntermediateDirectories: true)
            try fm.moveItem(atPath: legacy, toPath: screen)
            // checkpoint 后关库时 SQLite 已删掉 -wal;万一还在,跟着主文件改名,里面的内容不丢。
            if fm.fileExists(atPath: legacy + "-wal") { try fm.moveItem(atPath: legacy + "-wal", toPath: screen + "-wal") }
            if fm.fileExists(atPath: legacy + "-shm") { try fm.removeItem(atPath: legacy + "-shm") }
            let note = "My Portrait moved this database to metadata/screen.sqlite, metadata/audio.sqlite, "
                + "metadata/input.sqlite and pipeline/workflow.sqlite.\n"
            try note.write(toFile: legacy, atomically: true, encoding: .utf8)
        } else {
            guard fm.fileExists(atPath: screen) else { throw SplitError("\(screen) missing") }
        }
    }

    /// TRUNCATE checkpoint 要求没有别的连接(返回 busy=0),最多等 2 分钟。
    private static func checkpointTruncate(_ path: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            let busy: Int = try {
                var config = Configuration()
                config.busyMode = .timeout(5)
                let q = try DatabaseQueue(path: path, configuration: config)
                return try q.inDatabase { db in
                    try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")?[0] ?? 1
                }
            }()
            if busy == 0 { return }
            if Date() > deadline {
                throw SplitError("\(path) is still open in another program (lab scripts / sqlite3); close it and restart")
            }
            sleep(2)
        }
    }

    /// 第 3 步:建三个新库的基线,在 screen 的连接上 ATTACH 后按显式列名拷表。
    private static func copyTables() throws {
        let fm = FileManager.default
        // 上次没拷完留下的新库从头来。
        for db in newDBs {
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: db.path + suffix) {
                try fm.removeItem(atPath: db.path + suffix)
            }
            _ = try DBPools.openPool(path: db.path, kind: db.kind)
        }
        let hasClipboard = isSQLite(Storage.legacyClipboardDBPath)

        try withScreenConnection(foreignKeys: true) { db in
            try attachAll(db, clipboard: hasClipboard)
            try db.inTransaction {
                for move in moves {
                    for table in move.tables {
                        let cols = try columnList(db, schema: move.schema, table: table, source: "main")
                        try db.execute(sql: "INSERT INTO \(move.schema).\"\(table)\" (\(cols)) SELECT \(cols) FROM main.\"\(table)\" ORDER BY rowid")
                    }
                    // 自增计数照抄旧库(线上同名有重复行,取最大)。
                    try db.execute(sql: "DELETE FROM \(move.schema).sqlite_sequence")
                    let names = move.tables.map { "'\($0)'" }.joined(separator: ",")
                    try db.execute(sql: """
                        INSERT INTO \(move.schema).sqlite_sequence(name, seq)
                        SELECT name, MAX(seq) FROM main.sqlite_sequence WHERE name IN (\(names)) GROUP BY name
                        """)
                }
                for table in audioBackupTables {
                    guard let sql = try String.fetchOne(db, sql: "SELECT sql FROM main.sqlite_master WHERE type = 'table' AND name = :t",
                                                        arguments: ["t": table]) else { continue }
                    try db.execute(sql: sql.replacingOccurrences(of: "CREATE TABLE \(table)", with: "CREATE TABLE audio.\(table)"))
                    try db.execute(sql: "INSERT INTO audio.\"\(table)\" SELECT * FROM main.\"\(table)\"")
                }
                if hasClipboard {
                    let cols = try columnList(db, schema: "input", table: "clipboard_log", source: "clip")
                    try db.execute(sql: "INSERT INTO input.clipboard_log (\(cols)) SELECT \(cols) FROM clip.clipboard_log ORDER BY rowid")
                    try db.execute(sql: """
                        INSERT INTO input.sqlite_sequence(name, seq)
                        SELECT name, MAX(seq) FROM clip.sqlite_sequence WHERE name = 'clipboard_log' GROUP BY name
                        """)
                }
                return .commit
            }
            // 转录全文索引在新库里重建一遍再自检。
            try db.execute(sql: "INSERT INTO audio.transcriptions_fts(transcriptions_fts) VALUES('rebuild')")
            try db.execute(sql: "INSERT INTO audio.transcriptions_fts(transcriptions_fts) VALUES('integrity-check')")
            // 新库落盘之后才进下一步(删旧表之前它们必须已经在磁盘上)。
            for db0 in newDBs { try db.execute(sql: "PRAGMA \(db0.schema).wal_checkpoint(TRUNCATE)") }
            try detachAll(db, clipboard: hasClipboard)
        }
    }

    /// 第 4 步:逐表核对行数、最大 id、逐行内容(EXCEPT 双向为空)、自增计数,再跑 quick_check
    /// 和外键检查。核对通过前,原数据都完整地留在 screen.sqlite 里。
    private static func verify() throws -> [String: Int] {
        let hasClipboard = isSQLite(Storage.legacyClipboardDBPath)
        var counts: [String: Int] = [:]
        try withScreenConnection(foreignKeys: true) { db in
            try attachAll(db, clipboard: hasClipboard)
            var checks: [(schema: String, table: String, source: String)] = []
            for move in moves { for t in move.tables { checks.append((move.schema, t, "main")) } }
            for t in audioBackupTables where try tableExists(db, schema: "main", table: t) {
                checks.append(("audio", t, "main"))
            }
            if hasClipboard { checks.append(("input", "clipboard_log", "clip")) }

            for c in checks {
                let src = "\(c.source).\"\(c.table)\"", dst = "\(c.schema).\"\(c.table)\""
                let srcCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(src)") ?? -1
                let dstCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(dst)") ?? -2
                guard srcCount == dstCount else { throw SplitError("\(c.table): \(srcCount) rows → \(dstCount)") }
                let srcMax = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM \(src)")
                let dstMax = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM \(dst)")
                guard srcMax == dstMax else { throw SplitError("\(c.table): max id differs") }
                let cols = try columnList(db, schema: c.schema, table: c.table, source: c.source)
                for (a, b) in [(src, dst), (dst, src)] {
                    let diff = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT \(cols) FROM \(a) EXCEPT SELECT \(cols) FROM \(b))") ?? -1
                    guard diff == 0 else { throw SplitError("\(c.table): \(diff) rows differ") }
                }
                let srcSeq = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM \(c.source).sqlite_sequence WHERE name = :t", arguments: ["t": c.table])
                let dstSeq = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM \(c.schema).sqlite_sequence WHERE name = :t", arguments: ["t": c.table])
                guard srcSeq == dstSeq else { throw SplitError("\(c.table): autoincrement counter differs") }
                counts[c.table] = dstCount
            }
            for s in newDBs.map(\.schema) {
                let quick = try String.fetchAll(db, sql: "PRAGMA \(s).quick_check")
                guard quick == ["ok"] else { throw SplitError("\(s).sqlite quick_check: \(quick.prefix(3))") }
                let fk = try Row.fetchAll(db, sql: "PRAGMA \(s).foreign_key_check")
                guard fk.isEmpty else { throw SplitError("\(s).sqlite has \(fk.count) foreign key violations") }
            }
            let ftsDocs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio.transcriptions_fts_docsize") ?? -1
            guard ftsDocs == counts["audio_transcriptions"] else {
                throw SplitError("transcriptions_fts has \(ftsDocs) docs, expected \(counts["audio_transcriptions"] ?? -1)")
            }
            counts["transcriptions_fts"] = ftsDocs
            try detachAll(db, clipboard: hasClipboard)
        }
        return counts
    }

    /// 第 5、6 步:从 screen 删掉搬走的表(子表在前,关外键),迁移记录换成 screen_v1;
    /// 旧剪贴板库挪进废纸篓。不做 VACUUM:空出来的页留给帧以后复用。
    private static func dropMovedTables() throws {
        try withScreenConnection(foreignKeys: false) { db in
            try db.inTransaction {
                let tables = moves.flatMap(\.tables).reversed() + audioBackupTables
                for t in tables { try db.execute(sql: "DROP TABLE IF EXISTS main.\"\(t)\"") }
                // 转录全文索引的虚拟表(连同影子表);触发器随 audio_transcriptions 一起删了。
                try db.execute(sql: "DROP TABLE IF EXISTS main.transcriptions_fts")
                let names = moves.flatMap(\.tables).map { "'\($0)'" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM main.sqlite_sequence WHERE name IN (\(names))")
                try db.execute(sql: "DELETE FROM grdb_migrations")
                try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('screen_v1')")
                return .commit
            }
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let p = Storage.legacyClipboardDBPath + suffix
            if fm.fileExists(atPath: p) { try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
        }
    }

    /// 第 6.5 步:raw_data/{frames,video,audio} 和 audio_queue/ 挪进 metadata/,库里的相对路径改前缀。
    /// 改名和改前缀都可以重做(源目录不在就跳过,改前缀只改还是旧前缀的行),中断后接着跑。
    private static func moveMedia() throws -> [String: Int] {
        let fm = FileManager.default
        let root = Storage.rootURL
        let rawData = root.appendingPathComponent("raw_data", isDirectory: true)
        let pairs: [(URL, URL)] = [
            (rawData.appendingPathComponent("frames"), Storage.framesDir),
            (rawData.appendingPathComponent("video"), Storage.videoDir),
            (rawData.appendingPathComponent("audio"), Storage.audioDir),
            (root.appendingPathComponent("audio_queue"), Storage.audioQueueDir),
        ]
        for (src, dst) in pairs { try mergeMove(src, into: dst) }
        if fm.fileExists(atPath: rawData.path),
           (try? fm.contentsOfDirectory(atPath: rawData.path).filter { $0 != ".DS_Store" }.isEmpty) == true {
            try fm.removeItem(at: rawData)
        }

        var stats: [String: Int] = [:]
        try withScreenConnection(foreignKeys: true) { db in
            try db.execute(sql: """
                UPDATE frames SET snapshot_path = 'metadata/' || substr(snapshot_path, 10)
                WHERE snapshot_path LIKE 'raw\\_data/%' ESCAPE '\\'
                """)
            stats["frames_paths"] = db.changesCount
            try db.execute(sql: """
                UPDATE video_chunks SET file_path = 'metadata/' || substr(file_path, 10)
                WHERE file_path LIKE 'raw\\_data/%' ESCAPE '\\'
                """)
            stats["video_paths"] = db.changesCount
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            let sample = try String.fetchAll(db, sql: """
                SELECT file_path FROM video_chunks WHERE file_path LIKE 'metadata/%' ORDER BY id DESC LIMIT 50
                """)
            stats["video_sample"] = sample.count
            stats["video_sample_found"] = sample.filter { AssetPath.resolve($0) != nil }.count
        }
        let audio = try DatabaseQueue(path: Storage.audioDBPath, configuration: DBPools.configuration(.audio))
        try audio.write { db in
            try db.execute(sql: """
                UPDATE audio_chunks SET file_path = 'metadata/' || substr(file_path, 10)
                WHERE file_path LIKE 'raw\\_data/%' ESCAPE '\\'
                """)
            stats["audio_paths"] = db.changesCount
            try db.execute(sql: """
                UPDATE audio_chunks SET file_path = 'metadata/' || file_path
                WHERE file_path LIKE 'audio\\_queue/%' ESCAPE '\\'
                """)
            stats["audio_queue_paths"] = db.changesCount
        }
        try audio.read { db in
            let sample = try String.fetchAll(db, sql: """
                SELECT file_path FROM audio_chunks WHERE file_path LIKE 'metadata/%' ORDER BY id DESC LIMIT 50
                """)
            stats["audio_sample"] = sample.count
            stats["audio_sample_found"] = sample.filter { AssetPath.resolve($0) != nil }.count
        }
        return stats
    }

    /// 目录改名;目标已存在就把里面的东西逐个挪过去(同名子目录递归合并)。
    private static func mergeMove(_ src: URL, into dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: dst.path) {
            try fm.moveItem(at: src, to: dst)
            return
        }
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: d.path, isDirectory: &isDir) {
                if isDir.boolValue { try mergeMove(s, into: d) }
                else if name == ".DS_Store" { continue }
                else { throw SplitError("\(d.path) already exists") }
            } else {
                try fm.moveItem(at: s, to: d)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: src.path).filter { $0 != ".DS_Store" }.isEmpty) == true {
            try fm.removeItem(at: src)
        }
    }

    // MARK: - 工具

    /// screen.sqlite 上的单连接:注册分词器(帧和转录的全文索引触发器要用),同步写盘。
    private static func withScreenConnection(foreignKeys: Bool, _ body: (Database) throws -> Void) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            db.add(tokenizer: FoundationTokenizer.self)
            try db.execute(sql: "PRAGMA foreign_keys = \(foreignKeys ? "ON" : "OFF")")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        let q = try DatabaseQueue(path: Storage.screenDBPath, configuration: config)
        try q.inDatabase(body)
    }

    private static func attachAll(_ db: Database, clipboard: Bool) throws {
        for n in newDBs {
            try db.execute(sql: "ATTACH DATABASE :p AS \(n.schema)", arguments: ["p": n.path])
            try db.execute(sql: "PRAGMA \(n.schema).synchronous = FULL")
        }
        if clipboard {
            try db.execute(sql: "ATTACH DATABASE :p AS clip", arguments: ["p": Storage.legacyClipboardDBPath])
        }
    }

    private static func detachAll(_ db: Database, clipboard: Bool) throws {
        for n in newDBs { try db.execute(sql: "DETACH DATABASE \(n.schema)") }
        if clipboard { try db.execute(sql: "DETACH DATABASE clip") }
    }

    /// 目标表的列名(按新库基线),并核对源表列一致。
    private static func columnList(_ db: Database, schema: String, table: String, source: String) throws -> String {
        let dst = try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\"\(table)\")").map { $0["name"] as String }
        let src = try Row.fetchAll(db, sql: "PRAGMA \(source).table_info(\"\(table)\")").map { $0["name"] as String }
        guard !dst.isEmpty, Set(dst) == Set(src) else {
            throw SplitError("\(table): columns differ (\(src) vs \(dst))")
        }
        return dst.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private static func tableExists(_ db: Database, schema: String, table: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(schema).sqlite_master WHERE type = 'table' AND name = :t",
                         arguments: ["t": table]) == 1
    }

    /// 文件头是 `SQLite format 3\0`(占位文件、不存在的文件都返回 false)。
    private static func isSQLite(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 16)) ?? Data()
        return head == Data("SQLite format 3\u{0}".utf8)
    }
}
