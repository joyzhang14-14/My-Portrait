import Foundation
import GRDB

/// 命名 / 改名 / 合并后,**重扫「今天」的 wav 段** —— 用当前 embedding 模型的 gallery
/// 重新匹配、更新 speaker_id。让"刚命名的人"把当天散落 / 未匹配的同人段重新归拢
/// (尤其当面多人:同一个人因房间音 vs 通话音被拆成多簇,命名其中一簇后,重扫能把
/// 另一簇 / 未匹配的同人段也认回来)。
///
/// 自包含:自己开 GRDB 连接(注册 FoundationTokenizer,才能安全 UPDATE 触发 FTS5
/// 同步的 audio_transcriptions)+ 自己加载声纹模型。跟 app 主 pool 走 WAL 并发。
/// best-of-N 匹配镜像 `PortraitDBImpl.matchSpeaker`(阈值 0.45 / 裕度 0.10 / 按模型隔离)。
actor SpeakerReidentifier {
    static let shared = SpeakerReidentifier()

    private static let threshold: Float = 0.45
    private static let margin: Float = 0.10
    private var running = false

    struct Outcome: Sendable { let updated: Int; let total: Int }
    private struct Cand { let id: Int64; let name: String?; var embs: [[Float]] }

    /// 重扫今天(本地午夜起)的 wav 段。返回(改动数,总数)。并发保护:已在跑直接返回。
    func reidentifyToday() async -> Outcome {
        if running { return Outcome(updated: 0, total: 0) }
        running = true
        defer { running = false }

        let model = await MainActor.run { ConfigStore.shared.current.capture.audio.speakerEmbeddingModel }
        let sinceMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        do {
            // 1. 声纹模型 + 带 tokenizer 的 DB 连接
            let mp = try await SpeakerModelStore.shared.path(for: SpeakerModel.embedding(forChoice: model))
            let ex = try SpeakerEmbeddingExtractor(modelPath: mp.path, fbank: FbankExtractor())
            var dbCfg = Configuration()
            dbCfg.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
            let q = try DatabaseQueue(path: Storage.portraitDBPath, configuration: dbCfg)

            // 2. gallery(当前模型,非幻听):每人 centroid + 存的样本
            let cands: [Cand] = try await q.read { db in
                var m: [Int64: Cand] = [:]
                for r in try Row.fetchAll(db, sql: """
                    SELECT id, name, centroid FROM speakers
                    WHERE hallucination = 0 AND embedding_model = :model AND centroid IS NOT NULL
                    """, arguments: ["model": model]) {
                    let id: Int64 = r["id"]
                    var c = Cand(id: id, name: r["name"], embs: [])
                    if let blob: Data = r["centroid"], let v = blob.asFloats { c.embs.append(v) }
                    m[id] = c
                }
                for r in try Row.fetchAll(db, sql: """
                    SELECT e.speaker_id AS sid, e.embedding AS emb FROM speaker_embeddings e
                    JOIN speakers s ON s.id = e.speaker_id
                    WHERE s.hallucination = 0 AND s.embedding_model = :model
                    """, arguments: ["model": model]) {
                    let sid: Int64 = r["sid"]
                    if let blob: Data = r["emb"], let v = blob.asFloats { m[sid]?.embs.append(v) }
                }
                return Array(m.values)
            }
            guard !cands.isEmpty else { return Outcome(updated: 0, total: 0) }

            // 3. 今天的 wav 段
            struct Seg { let id: Int64; let chunkId: Int64; let path: String; let startS: Double; let endS: Double; let oldSp: Int64? }
            let segs: [Seg] = try await q.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT t.id AS id, t.audio_chunk_id AS cid, ac.file_path AS path,
                           t.start_s AS s, t.end_s AS e, t.speaker_id AS sp
                    FROM audio_transcriptions t JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
                    WHERE ac.file_path LIKE '%.wav' AND ac.recorded_at_ms >= :since
                    ORDER BY t.audio_chunk_id, t.start_s
                    """, arguments: ["since": sinceMs]).map {
                    Seg(id: $0["id"], chunkId: $0["cid"], path: $0["path"], startS: $0["s"], endS: $0["e"], oldSp: $0["sp"])
                }
            }
            guard !segs.isEmpty else { return Outcome(updated: 0, total: 0) }

            // 4. 逐 chunk 读 wav,提声纹 + best-of-N 匹配
            let base = Storage.rootURL
            var byChunk: [Int64: [Seg]] = [:]
            for s in segs { byChunk[s.chunkId, default: []].append(s) }
            var changes: [(id: Int64, sp: Int64?)] = []   // 只收有变化的
            for (_, cs) in byChunk {
                let abs = cs[0].path.hasPrefix("/") ? cs[0].path : base.appendingPathComponent(cs[0].path).path
                guard let all = autoreleasepool(invoking: { AudioWAV.readSamples(path: abs) }) else { continue }
                let n = all.count
                for s in cs {
                    let a = max(0, Int(s.startS * 16000)), b = min(n, Int(s.endS * 16000))
                    let slice = (a < b) ? Array(all[a..<b]) : []
                    var sp: Int64? = nil
                    if !slice.isEmpty, var v = ex.embed(slice) {
                        VectorMath.l2Normalize(&v)
                        sp = Self.match(v, cands)
                    }
                    if sp != s.oldSp { changes.append((s.id, sp)) }
                }
            }

            // 5. 写回(FTS 安全)
            guard !changes.isEmpty else { return Outcome(updated: 0, total: segs.count) }
            let toWrite = changes
            try await q.write { db in
                for w in toWrite {
                    if let sp = w.sp {
                        try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = :sp WHERE id = :id",
                                       arguments: ["sp": sp, "id": w.id])
                    } else {
                        try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = NULL WHERE id = :id",
                                       arguments: ["id": w.id])
                    }
                }
            }
            return Outcome(updated: toWrite.count, total: segs.count)
        } catch {
            return Outcome(updated: 0, total: 0)
        }
    }

    /// best-of-N + 判别裕度,镜像 matchSpeaker。
    private static func match(_ e: [Float], _ cands: [Cand]) -> Int64? {
        var best: [(id: Int64, name: String?, sim: Float)] = []
        for c in cands {
            var top: Float = -2
            for v in c.embs where v.count == e.count {
                let s = VectorMath.cosineSimilarity(e, v)
                if s > top { top = s }
            }
            if top > threshold { best.append((c.id, c.name, top)) }
        }
        guard let w = best.max(by: { $0.sim < $1.sim }) else { return nil }
        let rival = best.filter { $0.id != w.id && !sameName($0.name, w.name) }.map(\.sim).max()
        if let rival, w.sim - rival < margin { return nil }
        return w.id
    }
    private static func sameName(_ a: String?, _ b: String?) -> Bool {
        guard let x = a?.trimmingCharacters(in: .whitespaces).lowercased(), !x.isEmpty,
              let y = b?.trimmingCharacters(in: .whitespaces).lowercased(), !y.isEmpty else { return false }
        return x == y
    }
}
