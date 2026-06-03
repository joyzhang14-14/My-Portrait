import Foundation
import GRDB

/// 维护 CLI：`--rematch-speakers [--apply] [--limit N]`
///
/// 用新的 **best-of-N** 说话人匹配,对已有 **wav-backed** 转录段重新判定「谁说的」,
/// 替换 `speaker_id`。**文字不动**(只重算说话人)。
///
/// 流程(用户选定:先合并同名簇再重跑):
///   1. 把同名的多个簇合并成一个(Joy×3→1, Stan×2→1):survivor = 存的声纹最多者,
///      合并各簇全部样本、重算质心、转录重指向、删多余簇。
///   2. 对每个 wav-backed 段提 512-dim 声纹,best-of-N 匹配合并后的声纹库,得新 speaker。
///      ambiguous / 无匹配 → 留空(NULL),如实反映新逻辑判定。
///
/// 默认 **dry-run**:打印合并计划 + 重匹配后「按名字」分布对照(OLD vs NEW),不写库。
/// 加 `--apply`:执行合并 + 写回 speaker_id。全程经 GRDB pool(已注册 FoundationTokenizer,
/// 避开 audio_transcriptions 的 FTS5 触发器地雷)。
///
/// ⚠️ `--apply` 前建议先退出正在运行的 app(避免 WAL 写冲突)。
enum RematchSpeakersCLI {

    private final class ExitState: @unchecked Sendable { var code: Int32 = 0; var done = false }

    /// 阈值与裕度 **镜像 `PortraitDBImpl.matchSpeaker`**(0.45 / 0.10)。改那边时同步这里。
    private static let threshold: Float = 0.45
    private static let margin: Float = 0.10

    /// 合并后的候选说话人:survivor id + 名字 + 全部匹配目标(各簇样本 + 质心)。
    private struct Cand { let id: Int64; let name: String?; let embeddings: [[Float]] }
    private struct Seg {
        let id: Int64; let chunkId: Int64; let path: String
        let startS: Double; let endS: Double; let text: String; let oldSpeaker: Int64?
    }
    private struct Res { let seg: Seg; let newSpeaker: Int64? }

    static func run(apply: Bool, limit: Int? = nil) {
        let state = ExitState()
        print("=== rematch-speakers (\(apply ? "APPLY — 合并同名簇 + 写回 speaker_id" : "dry-run"))\(limit.map { " limit=\($0)" } ?? "") ===")
        fflush(stdout)

        let dbImpl: PortraitDBImpl
        do { dbImpl = try PortraitDBImpl() } catch { print("ERROR: open DB: \(error)"); exit(1) }
        let pool = dbImpl.dbPool
        let base = Storage.rootURL

        Task.detached {
            defer { state.done = true }
            do {
                // 1. 加载所有 speakers + 各自 stored 声纹
                struct Spk { let id: Int64; let name: String?; let hall: Bool; let centroid: [Float]?; var stored: [[Float]] }
                var spkById: [Int64: Spk] = try await pool.read { db in
                    var m: [Int64: Spk] = [:]
                    for r in try Row.fetchAll(db, sql: "SELECT id, name, hallucination, centroid FROM speakers") {
                        let id: Int64 = r["id"]
                        let cen: Data? = r["centroid"]
                        let hall: Int = r["hallucination"] ?? 0
                        m[id] = Spk(id: id, name: r["name"], hall: hall != 0, centroid: cen?.asFloats, stored: [])
                    }
                    for r in try Row.fetchAll(db, sql: "SELECT speaker_id, embedding FROM speaker_embeddings") {
                        let sid: Int64 = r["speaker_id"]
                        if let blob: Data = r["embedding"], let v = blob.asFloats { m[sid]?.stored.append(v) }
                    }
                    return m
                }
                func nameOf(_ id: Int64?) -> String {
                    guard let id else { return "未匹配" }
                    guard let s = spkById[id] else { return "#\(id)(已删)" }
                    if let n = s.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
                    return "(未命名#\(id))"
                }

                // 2. 合并计划:hallucination=0 且具名 → 按小写名分组,>1 簇合并。
                //    survivor = stored 最多(并列 → id 小)。无名 active 簇各自独立候选。
                let active = spkById.values.filter { !$0.hall }
                var groups: [String: [Spk]] = [:]
                var standalone: [Spk] = []
                for s in active {
                    if let n = s.name?.trimmingCharacters(in: .whitespaces).lowercased(), !n.isEmpty {
                        groups[n, default: []].append(s)
                    } else { standalone.append(s) }
                }
                struct Plan { let survivor: Int64; let losers: [Int64]; let centroid: [Float] }
                var plans: [Plan] = []
                var cands: [Cand] = []
                print("\n=== 合并计划 ===")
                for (_, members) in groups.sorted(by: { $0.value.count > $1.value.count }) {
                    let sorted = members.sorted { $0.stored.count != $1.stored.count ? $0.stored.count > $1.stored.count : $0.id < $1.id }
                    let survivor = sorted[0]
                    let losers = Array(sorted.dropFirst())
                    var allStored = survivor.stored
                    for l in losers { allStored += l.stored }
                    let mergedCentroid = meanNormalized(allStored) ?? survivor.centroid
                    var embs = allStored
                    if let c = mergedCentroid { embs.append(c) }
                    cands.append(Cand(id: survivor.id, name: survivor.name, embeddings: embs))
                    if losers.isEmpty {
                        print("  \(survivor.name ?? "?"): #\(survivor.id) 单簇,无需合并")
                    } else {
                        if let c = mergedCentroid {
                            plans.append(Plan(survivor: survivor.id, losers: losers.map { $0.id }, centroid: c))
                        }
                        print("  \(survivor.name ?? "?"): survivor #\(survivor.id)(\(survivor.stored.count) 声纹)← 合并 "
                            + losers.map { "#\($0.id)(\($0.stored.count))" }.joined(separator: ", ")
                            + "  → 合并后 \(allStored.count) 条样本")
                    }
                }
                for s in standalone {
                    var embs = s.stored
                    if let c = s.centroid { embs.append(c) }
                    cands.append(Cand(id: s.id, name: s.name, embeddings: embs))
                }
                if plans.isEmpty { print("  (没有需要合并的同名簇)") }
                fflush(stdout)

                // 3. 加载 speaker 声纹模型
                let extractor: SpeakerEmbeddingExtractor
                do {
                    let p = try await SpeakerModelStore.shared.path(for: .embedding)
                    extractor = try SpeakerEmbeddingExtractor(modelPath: p.path, fbank: FbankExtractor())
                } catch { print("ERROR: speaker 模型加载失败: \(error)"); state.code = 1; return }

                // 4. 拉所有 wav-backed 段
                let allSegs: [Seg] = try await pool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT t.id AS id, t.audio_chunk_id AS cid, ac.file_path AS path,
                               t.start_s AS s, t.end_s AS e, t.text AS txt, t.speaker_id AS sp
                        FROM audio_transcriptions t JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
                        WHERE ac.file_path LIKE '%.wav'
                        ORDER BY t.audio_chunk_id, t.start_s
                        """).map { Seg(id: $0["id"], chunkId: $0["cid"], path: $0["path"],
                                       startS: $0["s"], endS: $0["e"], text: $0["txt"], oldSpeaker: $0["sp"]) }
                }
                let segs = limit.map { Array(allSegs.prefix($0)) } ?? allSegs
                print("\n=== 重匹配 \(segs.count) 段(wav-backed,按 chunk 分组每 chunk 只读一次 wav)===")
                fflush(stdout)

                // 5. 逐 chunk 读 wav,逐段提声纹 + best-of-N 匹配(镜像 matchSpeaker)
                var byChunk: [Int64: [Seg]] = [:]
                for s in segs { byChunk[s.chunkId, default: []].append(s) }
                var results: [Res] = []
                var done = 0, missing = 0
                for (_, chunkSegs) in byChunk.sorted(by: { $0.key < $1.key }) {
                    let path = chunkSegs[0].path
                    let abs = path.hasPrefix("/") ? path : base.appendingPathComponent(path).path
                    guard let all = autoreleasepool(invoking: { AudioWAV.readSamples(path: abs) }) else {
                        missing += chunkSegs.count; continue
                    }
                    let n = all.count
                    for s in chunkSegs {
                        let a = max(0, Int(s.startS * 16000)), b = min(n, Int(s.endS * 16000))
                        let slice = (a < b) ? Array(all[a..<b]) : []
                        var newSpeaker: Int64? = nil
                        if !slice.isEmpty, var v = extractor.embed(slice) {
                            VectorMath.l2Normalize(&v)
                            newSpeaker = matchAgainst(v, cands: cands)
                        }
                        results.append(Res(seg: s, newSpeaker: newSpeaker))
                        done += 1
                        if done % 100 == 0 { print("  \(done)/\(segs.count)…"); fflush(stdout) }
                    }
                }
                print("  完成。wav 读失败: \(missing) 段")

                // 6. 报告:按名字分布 OLD vs NEW
                func distDict(_ pick: (Res) -> Int64?) -> [String: Int] {
                    var c: [String: Int] = [:]
                    for r in results { c[nameOf(pick(r)), default: 0] += 1 }
                    return c
                }
                let oldD = distDict { $0.seg.oldSpeaker }
                let newD = distDict { $0.newSpeaker }
                let allNames = Set(oldD.keys).union(newD.keys).sorted { (newD[$0] ?? 0) > (newD[$1] ?? 0) }
                print("\n--- 说话人分布(按名字)---")
                for nm in allNames {
                    let o = oldD[nm] ?? 0, nw = newD[nm] ?? 0
                    let delta = nw - o
                    let tag = delta == 0 ? "" : "  (\(delta > 0 ? "+" : "")\(delta))"
                    print("  \(nm.padding(toLength: 18, withPad: " ", startingAt: 0))OLD \(o)\t→ NEW \(nw)\(tag)")
                }
                let changed = results.filter { nameOf($0.seg.oldSpeaker) != nameOf($0.newSpeaker) }
                print("\nspeaker 名字有变: \(changed.count)/\(results.count)")

                // 全量对照写 /tmp,终端只放前 30 条有变的
                var report = "rematch-speakers report — \(results.count) segments\n\n"
                for r in results {
                    let od = nameOf(r.seg.oldSpeaker), nd = nameOf(r.newSpeaker)
                    report += "chunk \(r.seg.chunkId) [\(String(format: "%.1f-%.1f", r.seg.startS, r.seg.endS))s]  "
                        + "\(od) → \(nd)\(od != nd ? " *" : "")\n  \(r.seg.text)\n\n"
                }
                let reportPath = "/tmp/rematch_speakers_report.txt"
                try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
                print("完整对照: \(reportPath)")
                print("\n--- 样本(前 30 条名字有变的)---")
                for r in changed.prefix(30) {
                    print("• [\(nameOf(r.seg.oldSpeaker)) → \(nameOf(r.newSpeaker))]  \(r.seg.text.prefix(60))")
                }
                fflush(stdout)

                if !apply {
                    print("\n[dry-run] 没写库。看着行就加 --apply(合并同名簇 + 写回 speaker_id;文字不动)。")
                    return
                }

                // 7. APPLY
                // 7a. 合并持久化:移声纹 → 重算质心 → 转录重指向 → 删多余簇。
                //     loser id 是自库查出的可信 Int64,直接内联进 IN(避开数组 arguments 地雷)。
                let plansToApply = plans   // @Sendable 写闭包须捕获 let
                try await pool.write { db in
                    for p in plansToApply {
                        let loserList = p.losers.map(String.init).joined(separator: ",")
                        try db.execute(sql: "UPDATE speaker_embeddings SET speaker_id = :s WHERE speaker_id IN (\(loserList))",
                                       arguments: ["s": p.survivor])
                        try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = :s WHERE speaker_id IN (\(loserList))",
                                       arguments: ["s": p.survivor])
                        try db.execute(sql: "UPDATE speakers SET centroid = :c, updated_at_ms = :ts WHERE id = :s",
                                       arguments: ["c": Data(floats: p.centroid), "ts": Int64(Date().timeIntervalSince1970 * 1000), "s": p.survivor])
                        try db.execute(sql: "DELETE FROM speakers WHERE id IN (\(loserList))")
                    }
                }
                // 7b. 写回重匹配的 speaker_id(只动我们重跑过的 wav-backed 段)。
                let writes: [(id: Int64, sp: Int64?)] = results.map { ($0.seg.id, $0.newSpeaker) }
                let written = try await pool.write { db -> Int in
                    for w in writes {
                        if let sp = w.sp {
                            try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = :sp WHERE id = :id",
                                           arguments: ["sp": sp, "id": w.id])
                        } else {
                            try db.execute(sql: "UPDATE audio_transcriptions SET speaker_id = NULL WHERE id = :id",
                                           arguments: ["id": w.id])
                        }
                    }
                    return writes.count
                }
                print("\n✅ 合并 \(plans.count) 组同名簇;重写 \(written) 段 speaker_id(文字未动)。FTS 已随 GRDB 触发器同步。")
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        exit(state.code)
    }

    /// best-of-N 匹配,**镜像 `PortraitDBImpl.matchSpeaker`**:每候选取最接近样本相似度,
    /// 过阈值入选;winner 须比「异名最强候选」高出 margin,否则 ambiguous → nil。
    private static func matchAgainst(_ emb: [Float], cands: [Cand]) -> Int64? {
        var best: [(id: Int64, name: String?, sim: Float)] = []
        for c in cands {
            var top: Float = -2
            for v in c.embeddings where v.count == emb.count {
                let sim = VectorMath.cosineSimilarity(emb, v)
                if sim > top { top = sim }
            }
            if top > threshold { best.append((c.id, c.name, top)) }
        }
        guard let winner = best.max(by: { $0.sim < $1.sim }) else { return nil }
        let rival = best.filter { $0.id != winner.id && !sameName($0.name, winner.name) }.map(\.sim).max()
        if let rival, winner.sim - rival < margin { return nil }
        return winner.id
    }

    private static func sameName(_ a: String?, _ b: String?) -> Bool {
        guard let x = a?.trimmingCharacters(in: .whitespaces).lowercased(), !x.isEmpty,
              let y = b?.trimmingCharacters(in: .whitespaces).lowercased(), !y.isEmpty else { return false }
        return x == y
    }

    /// 多条向量的均值并 L2 归一(合并后质心)。空 → nil。
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
}
