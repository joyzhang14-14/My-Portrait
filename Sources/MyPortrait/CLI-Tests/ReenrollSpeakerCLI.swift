import Foundation
import GRDB

/// `--reenroll-speaker <name> [--channel mic|system|any] [--hours N] [--threshold 0.5] [--apply]`
///
/// **域对齐重登记。** 用真实采集音(尤其通话音)给已知说话人补充多条件声纹,治"库的
/// 域不匹配"(实测撞旧库 61% → 域对齐 74%)。
///
/// 做法:从指定声道 + 时段的 wav 段(≥2s)提声纹 → 用 **medoid 提取主导说话人**
/// (1对1 通话里:系统声道主导=对方,麦克风主导=本人)→ 清洗(去离群)→ **补进**
/// 该人的 speaker_embeddings,重算质心。
///
/// 默认 **dry-run**:打印主导簇大小/内聚/**样本文本**(供你肉眼确认是对的人)+ 跟库里
/// 另一个人的可分度。`--apply` 才写库,写前自动备份 speaker_embeddings_bak_reenroll。
/// ⚠️ 用 `--channel`+`--hours` 把范围卡到一段你确定是该人主导的录音上。
enum ReenrollSpeakerCLI {

    private final class ExitState: @unchecked Sendable { var code: Int32 = 0; var done = false }

    static func run(name: String, channel: String, hours: Double?, threshold: Float, apply: Bool,
                    fromMs: Int64? = nil, toMs: Int64? = nil) {
        let state = ExitState()
        print("=== reenroll-speaker '\(name)' channel=\(channel) \(apply ? "APPLY" : "dry-run") threshold=\(threshold) ===")
        fflush(stdout)
        let dbImpl: PortraitDBImpl
        do { dbImpl = try PortraitDBImpl() } catch { print("ERROR: open DB: \(error)"); exit(1) }
        let pool = dbImpl.dbPool
        let base = Storage.rootURL
        let rangeStartMs: Int64 = fromMs ?? hours.map { Int64(Date().timeIntervalSince1970 * 1000) - Int64($0 * 3600 * 1000) } ?? 0
        let rangeEndMs: Int64 = toMs ?? Int64.max

        Task.detached {
            defer { state.done = true }
            do {
                let embChoice = await MainActor.run { ConfigStore.shared.current.capture.audio.speakerEmbeddingModel }
                // 0. 目标说话人(按名字,非幻听,且**绑定当前模型**)
                let target: (id: Int64, name: String)? = try await pool.read { db in
                    let r = try Row.fetchOne(db, sql: """
                        SELECT id, name FROM speakers
                        WHERE hallucination = 0 AND embedding_model = :model
                          AND LOWER(TRIM(name)) = LOWER(TRIM(:n)) ORDER BY embedding_count DESC LIMIT 1
                        """, arguments: ["n": name, "model": embChoice])
                    return r.map { ($0["id"], $0["name"]) }
                }
                guard let target else { print("ERROR: 当前模型(\(embChoice))下找不到说话人 '\(name)'。先在 app 里训练/命名(用当前模型)。"); state.code = 1; return }

                // 1. 声纹模型
                let ex: SpeakerEmbeddingExtractor
                do {
                    let p = try await SpeakerModelStore.shared.path(for: SpeakerModel.embedding(forChoice: embChoice))
                    ex = try SpeakerEmbeddingExtractor(modelPath: p.path, fbank: FbankExtractor())
                } catch { print("ERROR: 声纹模型加载失败: \(error)"); state.code = 1; return }

                // 2. 候选段:声道 + 时段 + ≥2s
                struct Seg { let chunkId: Int64; let path: String; let startS: Double; let endS: Double; let text: String }
                let chanLike: String
                switch channel { case "mic": chanLike = "%microphone%"; case "system": chanLike = "%loopback%"; default: chanLike = "%" }
                let cands: [Seg] = try await pool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT t.audio_chunk_id AS cid, ac.file_path AS path, t.start_s AS s, t.end_s AS e, t.text AS txt
                        FROM audio_transcriptions t JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
                        WHERE ac.file_path LIKE '%.wav' AND ac.device LIKE :chan
                          AND ac.recorded_at_ms >= :start AND ac.recorded_at_ms <= :end
                          AND (t.end_s - t.start_s) >= 2.0
                        ORDER BY ac.recorded_at_ms, t.start_s
                        """, arguments: ["chan": chanLike, "start": rangeStartMs, "end": rangeEndMs]).map {
                        Seg(chunkId: $0["cid"], path: $0["path"], startS: $0["s"], endS: $0["e"], text: $0["txt"])
                    }
                }
                guard !cands.isEmpty else { print("范围内没有 ≥2s 的候选段(调 --channel/--hours)。"); return }
                print("候选段(\(channel), ≥2s): \(cands.count)")

                // 3. 提声纹
                var byChunk: [Int64: [Int]] = [:]
                for (i, s) in cands.enumerated() { byChunk[s.chunkId, default: []].append(i) }
                var embs = [[Float]?](repeating: nil, count: cands.count)
                for (_, idxs) in byChunk.sorted(by: { $0.key < $1.key }) {
                    let abs = cands[idxs[0]].path.hasPrefix("/") ? cands[idxs[0]].path : base.appendingPathComponent(cands[idxs[0]].path).path
                    guard let all = autoreleasepool(invoking: { AudioWAV.readSamples(path: abs) }) else { continue }
                    for i in idxs {
                        let a = max(0, Int(cands[i].startS * 16000)), b = min(all.count, Int(cands[i].endS * 16000))
                        let slice = (a < b) ? Array(all[a..<b]) : []
                        if !slice.isEmpty, var v = ex.embed(slice) { VectorMath.l2Normalize(&v); embs[i] = v }
                    }
                }
                let validIdx = (0..<cands.count).filter { embs[$0] != nil }
                guard validIdx.count >= 3 else { print("有效声纹太少(\(validIdx.count))。"); return }

                // 4. medoid 提取主导说话人:取最中心样本,保留 cos≥阈值 的
                let vecs = validIdx.map { embs[$0]! }
                let m = medoid(vecs)
                let mv = vecs[m]
                let keptLocal = (0..<validIdx.count).filter { VectorMath.cosineSimilarity(vecs[$0], mv) >= threshold }
                let keptIdx = keptLocal.map { validIdx[$0] }
                let keptVecs = keptIdx.map { embs[$0]! }
                let coh = cohesion(keptVecs)
                print("主导说话人簇: \(keptIdx.count)/\(validIdx.count) 段(内聚 \(coh.map { String(format: "%.3f", $0) } ?? "n/a"))")

                // 5. 跟库里"另一个人"的可分度(撞错风险)
                let others: [(name: String, vecs: [[Float]])] = try await pool.read { db in
                    var m: [Int64: (String, [[Float]])] = [:]
                    for r in try Row.fetchAll(db, sql: """
                        SELECT s.id AS sid, s.name AS name, e.embedding AS emb FROM speaker_embeddings e
                        JOIN speakers s ON s.id = e.speaker_id
                        WHERE s.hallucination = 0 AND s.id <> :tid AND s.name IS NOT NULL AND s.name <> ''
                          AND s.embedding_model = :model
                        """, arguments: ["tid": target.id, "model": embChoice]) {
                        guard let blob: Data = r["emb"], let v = blob.asFloats else { continue }
                        let sid: Int64 = r["sid"]
                        if m[sid] == nil { m[sid] = (r["name"], []) }
                        m[sid]?.1.append(v)
                    }
                    return m.values.map { ($0.0, $0.1) }
                }
                let newCentroid = meanNormalized(keptVecs)
                print("\n新登记簇 vs 库里其他人(质心 cosine,越低越好):")
                for o in others {
                    if let nc = newCentroid, let oc = meanNormalized(o.vecs) {
                        print("  \(target.name) ↔ \(o.name): \(String(format: "%.3f", VectorMath.cosineSimilarity(nc, oc)))")
                    }
                }
                print("\n样本文本(确认这些确实是 \(target.name) 在说):")
                for i in keptIdx.prefix(12) { print("  • \(cands[i].text.prefix(60))") }
                fflush(stdout)

                if !apply {
                    print("\n[dry-run] 没写库。确认样本是 \(target.name) 本人、且跟其他人可分,就加 --apply 补进库(写前备份)。")
                    return
                }

                // 6. APPLY:备份 → 补样本 → 重算质心(over 旧+新)
                let toAdd: [[Float]] = keptVecs
                let tid = target.id
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try await pool.write { db in
                    try db.execute(sql: "DROP TABLE IF EXISTS speaker_embeddings_bak_reenroll")
                    try db.execute(sql: "CREATE TABLE speaker_embeddings_bak_reenroll AS SELECT * FROM speaker_embeddings")
                    for v in toAdd {
                        try db.execute(sql: "INSERT INTO speaker_embeddings (speaker_id, embedding, created_at_ms) VALUES (:sid, :emb, :ts)",
                                       arguments: ["sid": tid, "emb": Data(floats: v), "ts": now])
                    }
                    // 重算质心 = 该人所有样本(旧+新)均值
                    let allV = try Row.fetchAll(db, sql: "SELECT embedding FROM speaker_embeddings WHERE speaker_id = :sid", arguments: ["sid": tid])
                        .compactMap { ($0["embedding"] as Data?)?.asFloats }
                    if let c = meanNormalized(allV) {
                        try db.execute(sql: "UPDATE speakers SET centroid = :c, embedding_count = :n, updated_at_ms = :ts WHERE id = :sid",
                                       arguments: ["c": Data(floats: c), "n": Int64(allV.count), "ts": now, "sid": tid])
                    }
                }
                print("\n✅ 给 '\(target.name)'(#\(tid))补登记 \(toAdd.count) 条域对齐声纹,质心已重算。备份: speaker_embeddings_bak_reenroll。")
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        exit(state.code)
    }

    private static func medoid(_ X: [[Float]]) -> Int {
        var bi = 0; var bs = -Float.greatestFiniteMagnitude
        for i in 0..<X.count { var s: Float = 0; for j in 0..<X.count where j != i { s += VectorMath.cosineSimilarity(X[i], X[j]) }; if s > bs { bs = s; bi = i } }
        return bi
    }
    private static func cohesion(_ X: [[Float]]) -> Float? {
        guard X.count >= 2 else { return nil }
        var ps: [Float] = []
        for i in 0..<X.count { for j in (i+1)..<X.count { ps.append(VectorMath.cosineSimilarity(X[i], X[j])) } }
        ps.sort(); return ps[ps.count/2]
    }
    private static func meanNormalized(_ vecs: [[Float]]) -> [Float]? {
        guard let dim = vecs.first?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim); var n = 0
        for v in vecs where v.count == dim { for i in 0..<dim { sum[i] += v[i] }; n += 1 }
        guard n > 0 else { return nil }
        for i in 0..<dim { sum[i] /= Float(n) }
        VectorMath.l2Normalize(&sum); return sum
    }
}
