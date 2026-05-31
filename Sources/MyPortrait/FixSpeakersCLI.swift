import Foundation
import GRDB

/// 一次性数据修复 CLI：`--fix-speakers`。按声纹 cosine 分析整理被 bug 版本打乱的
/// 说话人簇（这些 id 来自人工 cosine 分析 + 用户确认，hardcode）。
///
///   真 Joy = {#10, #13(训练), #18, #19}（彼此 cosine 0.75–0.92）→ 合进训练的 #13
///   Stan   = {#15, #20}（#20 被误标 Joy，实为 Stan：#20↔#15 = 0.82，#20↔真Joy ≈ 0.24）
///            → 取消 #15 hallucination，#20 合进 #15
///   #17    = 污染/混音簇（质心对谁都 ~0.4）→ 标 hallucination 排除匹配池
///
/// 走 GRDB（注册 FoundationTokenizer），所以 UPDATE audio_transcriptions.speaker_id
/// 触发的 FTS5 同步触发器能正常跑。写前自动备份。⚠️ 跑前先退出 app（避免 WAL 写冲突）。
enum FixSpeakersCLI {

    private enum FixError: Error { case noTrainedKeep }

    static func run() {
        let base = Storage.rootURL
        let src = base.appendingPathComponent("portrait.sqlite")

        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: src.path, configuration: config) }
        catch { print("ERROR: open DB: \(error)"); exit(1) }

        func printState(_ label: String) {
            print("--- \(label) ---")
            do {
                let rows = try queue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT s.id AS id, COALESCE(s.name,'?') AS name, s.hallucination AS h,
                               (s.trained_at_ms IS NOT NULL) AS tr, COUNT(se.id) AS n
                        FROM speakers s LEFT JOIN speaker_embeddings se ON se.speaker_id = s.id
                        GROUP BY s.id ORDER BY s.id
                        """)
                }
                for r in rows {
                    let id: Int64 = r["id"]; let name: String = r["name"]
                    let h: Int = r["h"]; let tr: Int = r["tr"]; let n: Int = r["n"]
                    print("  #\(id) \(name)  hall=\(h) trained=\(tr) samples=\(n)")
                }
            } catch { print("  (read err: \(error))") }
        }

        /// keep ← merge：把 merge 的转录段 + 样本向量改到 keep，再删 merge。
        /// UPDATE audio_transcriptions 触发 FTS5 触发器 —— 必须走带 tokenizer 的连接。
        func mergeOne(keep: Int64, merge: Int64) throws -> Int {
            guard keep != merge else { return 0 }
            return try queue.write { db -> Int in
                try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = :k WHERE speaker_id = :m",
                               arguments: ["k": keep, "m": merge])
                let moved = db.changesCount
                try db.execute(sql: "UPDATE speaker_embeddings SET speaker_id = :k WHERE speaker_id = :m",
                               arguments: ["k": keep, "m": merge])
                try db.execute(sql: "DELETE FROM speakers WHERE id = :m", arguments: ["m": merge])
                return moved
            }
        }
        func setHallucination(_ id: Int64, _ v: Int) throws {
            try queue.write { db in
                try db.execute(sql: "UPDATE speakers SET hallucination = :v, updated_at_ms = :u WHERE id = :id",
                               arguments: ["v": v, "u": Int64(Date().timeIntervalSince1970 * 1000), "id": id])
            }
        }

        do {
            // 备份
            try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let bak = base.appendingPathComponent("portrait.sqlite.bak-speakers-\(ts)")
            try FileManager.default.copyItem(at: src, to: bak)
            print("DB 备份: \(bak.lastPathComponent)\n")

            printState("BEFORE")
            print("")

            // 1. 真 Joy 合进训练的 #13
            var moved = 0
            for m in [Int64(10), 18, 19] { moved += try mergeOne(keep: 13, merge: m) }
            print("真 Joy {10,18,19} → #13：移动 \(moved) 段转录")
            // 2. Stan：取消 #15 hallucination，#20(误标Joy) 合进 #15
            try setHallucination(15, 0)
            let stanMoved = try mergeOne(keep: 15, merge: 20)
            print("Stan：#15 取消 hallucination；#20 → #15：移动 \(stanMoved) 段")
            // 3. #17 污染簇 → 排除
            try setHallucination(17, 1)
            print("#17 污染簇 → 标 hallucination（排除匹配池）")
            print("")

            printState("AFTER")
            print("\n✅ 完成。匹配池(hall=0)现在应为 Joy#13 + Stan#15。备份: \(bak.lastPathComponent)")
        } catch {
            FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }

    /// 后续纠正(`--consolidate-joy`):试听确认那些被聚成"别人"的簇其实都是 Joy
    /// (只是嘈杂/远场)。把所有非训练、非噪声测试的簇**合并进训练的 Joy#13**(转录 +
    /// 样本向量都搬过去,样本进 Joy 的 fallback 池让它更耐噪、减少将来再碎),删掉这些簇。
    /// matchSpeaker 是质心优先,Joy 的干净质心不被这些样本带偏(质心 merge 时不重算)。
    /// 动态扫描当前所有 hall=0 且非训练的簇(不再 hardcode id),稳健。
    static func consolidateNoisyJoy() {
        let base = Storage.rootURL
        let src = base.appendingPathComponent("portrait.sqlite")
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: src.path, configuration: config) }
        catch { print("ERROR: open DB: \(error)"); exit(1) }

        func printState(_ label: String) {
            print("--- \(label) ---")
            if let rows = try? queue.read({ db in try Row.fetchAll(db, sql: """
                SELECT s.id AS id, COALESCE(s.name,'?') AS name, s.hallucination AS h,
                       (s.trained_at_ms IS NOT NULL) AS tr, COUNT(se.id) AS n
                FROM speakers s LEFT JOIN speaker_embeddings se ON se.speaker_id = s.id
                GROUP BY s.id ORDER BY s.id
                """) }) {
                for r in rows {
                    let id: Int64 = r["id"]; let name: String = r["name"]
                    let h: Int = r["h"]; let tr: Int = r["tr"]; let n: Int = r["n"]
                    print("  #\(id) \(name)  hall=\(h) trained=\(tr) samples=\(n)")
                }
            }
        }
        do {
            try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let bak = base.appendingPathComponent("portrait.sqlite.bak-consolidate-\(ts)")
            try FileManager.default.copyItem(at: src, to: bak)
            print("DB 备份: \(bak.lastPathComponent)\n")
            printState("BEFORE"); print("")

            // keep = 训练过的 speaker(应只有一个 = Joy);targets = 其余所有 hall=0 非训练簇。
            // 动态扫描,不 hardcode id(app 会不断重聚出新的嘈杂簇)。
            let keepId: Int64
            let targets: [(Int64, String)]
            (keepId, targets) = try queue.read { db -> (Int64, [(Int64, String)]) in
                guard let kid: Int64 = try Row.fetchOne(db, sql:
                    "SELECT id FROM speakers WHERE trained_at_ms IS NOT NULL AND hallucination = 0 ORDER BY id LIMIT 1")?["id"]
                else { throw FixError.noTrainedKeep }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, COALESCE(name,'?') AS name FROM speakers
                    WHERE hallucination = 0 AND trained_at_ms IS NULL AND id != :k ORDER BY id
                    """, arguments: ["k": kid])
                return (kid, rows.map { ($0["id"], $0["name"]) })
            }
            print("keep(训练) = #\(keepId);把 \(targets.count) 个检测簇合并进它(样本一并搬入)\n")
            for (mid, name) in targets {
                let moved = try queue.write { db -> Int in
                    try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = :k WHERE speaker_id = :m",
                                   arguments: ["k": keepId, "m": mid])
                    let m = db.changesCount
                    try db.execute(sql: "UPDATE speaker_embeddings SET speaker_id = :k WHERE speaker_id = :m",
                                   arguments: ["k": keepId, "m": mid])
                    try db.execute(sql: "DELETE FROM speakers WHERE id = :m", arguments: ["m": mid])
                    return m
                }
                print("  #\(mid) \(name) → #\(keepId):归并 \(moved) 段")
            }
            print(""); printState("AFTER")
            print("\n✅ 纠正完成。匹配池(hall=0)现在应只剩干净的 Joy#13。备份: \(bak.lastPathComponent)")
        } catch {
            FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }
}
