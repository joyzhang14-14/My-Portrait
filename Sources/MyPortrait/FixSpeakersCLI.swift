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
}
