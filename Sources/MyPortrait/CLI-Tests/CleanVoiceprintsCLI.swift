import Foundation
import GRDB

/// 维护 CLI:`--clean-voiceprints [--apply] [--threshold 0.5]`
///
/// **声纹去污。** 旧 bug 版长期把混杂/别人的声音误加进具名簇,一个簇里样本五花八门
/// (实测 Joy 内部样本中位相似度仅 0.35,还跟 Stan 撞到 0.85)→ 匹配像掷骰子。
///
/// 对每个非幻听的具名簇做 **medoid 剪枝**:取最「中心」的样本(medoid = 对其它样本
/// 相似度之和最大者),只保留跟它 cosine ≥ 阈值的核心样本,丢掉离群脏样本。实测剪枝
/// 后 Joy/Stan 留一法准确率 100%、0 标错、0 模糊。
///
/// 默认 **dry-run**(打印每簇 前/后 内聚 + 保留/丢弃数,不写库)。
/// `--apply`:删脏样本 + 重算质心。删之前自动把 speaker_embeddings 整表备份到
/// `speaker_embeddings_bak_clean`(可回滚)。speaker_embeddings / speakers 无 FTS,
/// 但仍经 PortraitDBImpl 的 pool 走。
///
/// ⚠️ `--apply` 前建议退出正在运行的 app(避免 WAL 写冲突)。
enum CleanVoiceprintsCLI {

    private final class ExitState: @unchecked Sendable { var code: Int32 = 0; var done = false }

    private struct Cluster { let id: Int64; let name: String; var samples: [(eid: Int64, vec: [Float])] }

    static func run(apply: Bool, threshold: Float) {
        let state = ExitState()
        print("=== clean-voiceprints (\(apply ? "APPLY" : "dry-run")) threshold=\(threshold) ===")
        fflush(stdout)

        let dbImpl: PortraitDBImpl
        do { dbImpl = try PortraitDBImpl() } catch { print("ERROR: open DB: \(error)"); exit(1) }
        let pool = dbImpl.dbPool

        Task.detached {
            defer { state.done = true }
            do {
                let curModel = await MainActor.run { ConfigStore.shared.current.capture.audio.speakerEmbeddingModel }
                // 1. 拉当前模型的非幻听具名簇的样本(id + 向量)—— 只洗当前模型的。
                var byId: [Int64: Cluster] = try await pool.read { db in
                    var m: [Int64: Cluster] = [:]
                    for r in try Row.fetchAll(db, sql: """
                        SELECT s.id AS sid, s.name AS name, e.id AS eid, e.embedding AS emb
                        FROM speaker_embeddings e JOIN speakers s ON s.id = e.speaker_id
                        WHERE s.hallucination = 0 AND s.name IS NOT NULL AND s.name <> ''
                          AND s.embedding_model = :model
                        """, arguments: ["model": curModel]) {
                        guard let blob: Data = r["emb"], let v = blob.asFloats else { continue }
                        let sid: Int64 = r["sid"]
                        if m[sid] == nil { m[sid] = Cluster(id: sid, name: r["name"], samples: []) }
                        m[sid]?.samples.append((r["eid"], v))
                    }
                    return m
                }

                struct Plan { let id: Int64; let name: String; let keep: [(eid: Int64, vec: [Float])]; let dropEids: [Int64] }
                var plans: [Plan] = []
                print("\n簇                  样本   内聚(前→后)   保留/丢弃")
                for c in byId.values.sorted(by: { $0.samples.count > $1.samples.count }) {
                    // 样本太少没法判核心,整簇保留。
                    guard c.samples.count >= 4 else {
                        print("  \(pad("\(c.name)#\(c.id)", 18)) \(pad("\(c.samples.count)", 6)) (样本<4,跳过不洗)")
                        continue
                    }
                    let vecs = c.samples.map { $0.vec }
                    let m = medoid(vecs)
                    let mv = vecs[m]
                    let keep = c.samples.filter { VectorMath.cosineSimilarity($0.vec, mv) >= threshold }
                    let dropEids = c.samples.filter { e in !keep.contains { $0.eid == e.eid } }.map { $0.eid }
                    let before = cohesion(vecs)
                    let after = cohesion(keep.map { $0.vec })
                    print("  \(pad("\(c.name)#\(c.id)", 18)) \(pad("\(c.samples.count)", 6)) "
                        + "\(fmt(before)) → \(fmt(after))      保留 \(keep.count) / 丢 \(dropEids.count)")
                    if !dropEids.isEmpty { plans.append(Plan(id: c.id, name: c.name, keep: keep, dropEids: dropEids)) }
                }
                fflush(stdout)

                let totalDrop = plans.reduce(0) { $0 + $1.dropEids.count }
                if plans.isEmpty || totalDrop == 0 {
                    print("\n没有可丢弃的脏样本(所有核心都干净)。")
                    return
                }

                if !apply {
                    print("\n[dry-run] 没写库。看着行就加 --apply(删脏样本 + 重算质心;删前自动整表备份)。")
                    return
                }

                // 2. APPLY:先整表备份,再删脏样本、重算质心。
                let plansToApply = plans   // @Sendable 写闭包须捕获 let
                try await pool.write { db in
                    try db.execute(sql: "DROP TABLE IF EXISTS speaker_embeddings_bak_clean")
                    try db.execute(sql: "CREATE TABLE speaker_embeddings_bak_clean AS SELECT * FROM speaker_embeddings")
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    for p in plansToApply {
                        let dropList = p.dropEids.map(String.init).joined(separator: ",")
                        try db.execute(sql: "DELETE FROM speaker_embeddings WHERE id IN (\(dropList))")
                        if let c = meanNormalized(p.keep.map { $0.vec }) {
                            try db.execute(sql: "UPDATE speakers SET centroid = :c, embedding_count = :n, updated_at_ms = :ts WHERE id = :id",
                                           arguments: ["c": Data(floats: c), "n": Int64(p.keep.count), "ts": now, "id": p.id])
                        }
                    }
                }
                print("\n✅ 清洗 \(plansToApply.count) 个簇,共删 \(totalDrop) 条脏样本,质心已重算。")
                print("   原表已备份到 speaker_embeddings_bak_clean(要回滚:用它覆盖回 speaker_embeddings)。")
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        exit(state.code)
    }

    /// 最「中心」的样本下标:对其它样本相似度之和最大。
    private static func medoid(_ X: [[Float]]) -> Int {
        var bi = 0; var bs = -Float.greatestFiniteMagnitude
        for i in 0..<X.count {
            var s: Float = 0
            for j in 0..<X.count where j != i { s += VectorMath.cosineSimilarity(X[i], X[j]) }
            if s > bs { bs = s; bi = i }
        }
        return bi
    }

    /// 簇内两两相似度中位数(内聚度)。
    private static func cohesion(_ X: [[Float]]) -> Float? {
        guard X.count >= 2 else { return nil }
        var ps: [Float] = []
        for i in 0..<X.count { for j in (i+1)..<X.count { ps.append(VectorMath.cosineSimilarity(X[i], X[j])) } }
        ps.sort()
        return ps[ps.count / 2]
    }

    private static func meanNormalized(_ vecs: [[Float]]) -> [Float]? {
        guard let dim = vecs.first?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        var n = 0
        for v in vecs where v.count == dim { for i in 0..<dim { sum[i] += v[i] }; n += 1 }
        guard n > 0 else { return nil }
        for i in 0..<dim { sum[i] /= Float(n) }
        VectorMath.l2Normalize(&sum)
        return sum
    }

    private static func fmt(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? " n/a " }
    private static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
}
