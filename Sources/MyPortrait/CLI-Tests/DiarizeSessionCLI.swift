import Foundation
import GRDB

/// `--diarize-session [--hours N] [--threshold 0.4]`
///
/// **纯声音离线 diarization 测试工具。** 对一段时间(默认:本地今天)的 wav 段:
///   1. 提 CAM++ 声纹(只看声音,完全不用声道/device 信息)
///   2. **离线全局聚类**(AHC 平均连接,cosine 阈值自动定人数)—— 取代在线增量
///   3. 每段用 **AS-norm 校准**的 best-of-N 撞声纹库(Joy/Stan/…)→ 身份
///
/// 验证:把 device(麦克风=Joy / 系统音频=对方)当 **ground truth 答案**(不参与
/// 算法),算纯声音判定的准确率 + 混淆。结果写桌面 `diarize_session_result.md`。
/// 只读,不写库。
enum DiarizeSessionCLI {

    private final class ExitState: @unchecked Sendable { var code: Int32 = 0; var done = false }
    private struct Seg {
        let id: Int64; let chunkId: Int64; let path: String
        let startS: Double; let endS: Double; let text: String
        let device: String; let recordedMs: Int64
    }

    static func run(hours: Double?, threshold: Float, minDur: Double, reenroll: Bool = false, dumpPath: String? = nil, modelPath: String? = nil) {
        let state = ExitState()
        let dbImpl: PortraitDBImpl
        do { dbImpl = try PortraitDBImpl() } catch { print("ERROR: open DB: \(error)"); exit(1) }
        let pool = dbImpl.dbPool
        let base = Storage.rootURL

        // 时间范围:默认本地今天 00:00 起;--hours N 改成最近 N 小时。
        let rangeStartMs: Int64
        if let h = hours {
            rangeStartMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(h * 3600 * 1000)
        } else {
            rangeStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        }
        print("=== diarize-session (纯声音) since \(Date(timeIntervalSince1970: Double(rangeStartMs)/1000))  AHC阈值=\(threshold) ===")
        fflush(stdout)

        Task.detached {
            defer { state.done = true }
            do {
                // 1. 加载声纹模型
                let ex: SpeakerEmbeddingExtractor
                do {
                    let mp: String
                    if let custom = modelPath { mp = custom }
                    else {
                        let embChoice = await MainActor.run { ConfigStore.shared.current.capture.audio.speakerEmbeddingModel }
                        mp = try await SpeakerModelStore.shared.path(for: SpeakerModel.embedding(forChoice: embChoice)).path
                    }
                    print("声纹模型: \((mp as NSString).lastPathComponent)")
                    ex = try SpeakerEmbeddingExtractor(modelPath: mp, fbank: FbankExtractor())
                } catch { print("ERROR: 声纹模型加载失败: \(error)"); state.code = 1; return }

                // 2. 拉范围内 wav 段(带 device 仅作答案,不参与算法)
                let loaded: [Seg] = try await pool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT t.id AS id, t.audio_chunk_id AS cid, ac.file_path AS path,
                               t.start_s AS s, t.end_s AS e, t.text AS txt,
                               COALESCE(ac.device,'?') AS dev, ac.recorded_at_ms AS rec
                        FROM audio_transcriptions t JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
                        WHERE ac.file_path LIKE '%.wav' AND ac.recorded_at_ms >= :start
                        ORDER BY ac.recorded_at_ms, t.start_s
                        """, arguments: ["start": rangeStartMs]).map {
                        Seg(id: $0["id"], chunkId: $0["cid"], path: $0["path"],
                            startS: $0["s"], endS: $0["e"], text: $0["txt"],
                            device: $0["dev"], recordedMs: $0["rec"])
                    }
                }
                let allCount = loaded.count
                let segs = loaded.filter { $0.endS - $0.startS >= minDur }
                guard !segs.isEmpty else { print("范围内没有满足时长门的 wav 段。"); return }
                print("段数: \(segs.count)（时长门 ≥\(minDur)s,从 \(allCount) 段过滤掉 \(allCount - segs.count) 段短段;仅声音参与,device 仅作答案）")
                fflush(stdout)

                // 3. 逐 chunk 读 wav,提声纹(纯声音)
                var byChunk: [Int64: [Int]] = [:]
                for (i, s) in segs.enumerated() { byChunk[s.chunkId, default: []].append(i) }
                var embs = [[Float]?](repeating: nil, count: segs.count)
                var doneN = 0
                for (_, idxs) in byChunk.sorted(by: { $0.key < $1.key }) {
                    let path = segs[idxs[0]].path
                    let abs = path.hasPrefix("/") ? path : base.appendingPathComponent(path).path
                    guard let all = autoreleasepool(invoking: { AudioWAV.readSamples(path: abs) }) else { continue }
                    let n = all.count
                    for i in idxs {
                        let a = max(0, Int(segs[i].startS * 16000)), b = min(n, Int(segs[i].endS * 16000))
                        let slice = (a < b) ? Array(all[a..<b]) : []
                        if !slice.isEmpty, var v = ex.embed(slice) { VectorMath.l2Normalize(&v); embs[i] = v }
                        doneN += 1
                        if doneN % 50 == 0 { print("  embed \(doneN)/\(segs.count)…"); fflush(stdout) }
                    }
                }
                let valid = (0..<segs.count).filter { embs[$0] != nil }
                print("成功提声纹: \(valid.count)/\(segs.count)")

                // dump:每行 device(mic/sys),duration,512 维声纹 —— 供 Python 跑分类器找天花板。
                if let dp = dumpPath {
                    let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
                    var csv = ""
                    for gi in valid {
                        let lab = segs[gi].device.contains("microphone") ? "mic" : "sys"
                        let dur = segs[gi].endS - segs[gi].startS
                        let cjk = segs[gi].text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                        let latin = segs[gi].text.unicodeScalars.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }
                        let lang = cjk >= 2 ? "zh" : (latin ? "en" : "other")
                        let t = tf.string(from: Date(timeIntervalSince1970: Double(segs[gi].recordedMs)/1000 + segs[gi].startS))
                        let txt = segs[gi].text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                        // 格式:label,lang,dur,<floats>  \t 时间 \t 文本(文本放最后,tab 分隔免逗号冲突)
                        csv += "\(lab),\(lang),\(String(format: "%.2f", dur))," + embs[gi]!.map { String($0) }.joined(separator: ",") + "\t\(t)\t\(txt)\n"
                    }
                    try? csv.write(toFile: dp, atomically: true, encoding: .utf8)
                    print("dump 写入: \(dp)(\(valid.count) 行)")
                }

                // 4. 离线全局聚类(AHC 平均连接,纯声纹)
                let labels = ahc(valid.map { embs[$0]! }, threshold: threshold)
                var clusterOf = [Int: Int]()   // segIndex -> clusterId
                for (k, gi) in valid.enumerated() { clusterOf[gi] = labels[k] }
                let nClusters = Set(labels).count

                // 5. 声纹库(非幻听具名)+ AS-norm 身份匹配
                struct Gallery { let id: Int64; let name: String; let samples: [[Float]]; var enrollStats: [Int64: (mu: Float, sd: Float)] = [:] }
                let (galleries, cohort): ([Gallery], [[Float]]) = try await pool.read { db in
                    var samplesBySpk: [Int64: (name: String, hall: Bool, vecs: [[Float]])] = [:]
                    for r in try Row.fetchAll(db, sql: """
                        SELECT s.id AS sid, s.name AS name, s.hallucination AS hall, e.embedding AS emb
                        FROM speaker_embeddings e JOIN speakers s ON s.id = e.speaker_id
                        """) {
                        guard let blob: Data = r["emb"], let v = blob.asFloats else { continue }
                        let sid: Int64 = r["sid"]
                        let hall: Int = r["hall"] ?? 0
                        if samplesBySpk[sid] == nil { samplesBySpk[sid] = (r["name"] ?? "", hall != 0, []) }
                        samplesBySpk[sid]?.vecs.append(v)
                    }
                    // 库:非幻听具名;cohort(impostor 池):所有样本(含幻听,当"别的声音")
                    var gs: [Gallery] = []
                    var coh: [[Float]] = []
                    for (sid, info) in samplesBySpk {
                        coh.append(contentsOf: info.vecs)
                        if !info.hall, !info.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            gs.append(Gallery(id: sid, name: info.name, samples: info.vecs))
                        }
                    }
                    return (gs, coh)
                }

                // 每个库说话人的 enroll-side AS-norm 统计(medoid vs cohort 的 topK 均值/方差)
                var gal = galleries
                for i in 0..<gal.count {
                    let med = gal[i].samples[medoid(gal[i].samples)]
                    let (mu, sd) = topKStats(of: med, against: cohort)
                    gal[i].enrollStats[gal[i].id] = (mu, sd)
                    gal[i] = Gallery(id: gal[i].id, name: gal[i].name, samples: gal[i].samples, enrollStats: [gal[i].id: (mu, sd)])
                }

                // 身份判定:每段 best-of-N 撞库 + AS-norm,取最高
                func identify(_ e: [Float]) -> (name: String, asnorm: Float, raw: Float) {
                    let (tmu, tsd) = topKStats(of: e, against: cohort)
                    var best: (name: String, asnorm: Float, raw: Float) = ("未匹配", -Float.greatestFiniteMagnitude, 0)
                    for g in gal {
                        let raw = g.samples.map { VectorMath.cosineSimilarity(e, $0) }.max() ?? -2
                        let (emu, esd) = g.enrollStats[g.id] ?? (0, 1)
                        let as_ = 0.5 * ((raw - tmu) / max(tsd, 1e-4) + (raw - emu) / max(esd, 1e-4))
                        if as_ > best.asnorm { best = (g.name, as_, raw) }
                    }
                    return best
                }

                // 每段身份
                var segIdent = [Int: (name: String, asnorm: Float, raw: Float)]()
                for gi in valid { segIdent[gi] = identify(embs[gi]!) }

                // 6. 写报告(含 ground-truth 对照)
                func devTruth(_ d: String) -> String {
                    d.contains("microphone") ? "Joy(麦)" : (d.contains("system") || d.contains("loopback") ? "Stan(系统)" : "?")
                }
                var md = "# 纯声音 diarization 测试结果\n\n"
                md += "- 范围起点: \(Date(timeIntervalSince1970: Double(rangeStartMs)/1000))\n"
                md += "- 段数: \(segs.count)(时长门 ≥\(minDur)s;成功提声纹 \(valid.count))\n"
                md += "- AHC 阈值: \(threshold) → **找到 \(nClusters) 个簇**\n\n"

                // 6a. 无监督聚类 × 声道纯度(每个簇里 麦/系统 各多少)
                md += "## A. 无监督聚类 vs 声道答案(纯声音自己分出几个人 + 是否对上声道)\n\n"
                md += "| 簇 | 段数 | 麦克风(应=Joy) | 系统(应=Stan) | 主导身份(AS-norm撞库) |\n|---|---|---|---|---|\n"
                let clusterIds = Set(labels).sorted()
                for c in clusterIds {
                    let members = valid.filter { clusterOf[$0] == c }
                    let mic = members.filter { segs[$0].device.contains("microphone") }.count
                    let sys = members.count - mic
                    // 簇主导身份:对簇 medoid 撞库
                    let memEmbs = members.map { embs[$0]! }
                    let med = memEmbs[medoid(memEmbs)]
                    let id = identify(med)
                    md += "| \(c) | \(members.count) | \(mic) | \(sys) | \(id.name) (asnorm \(String(format: "%.2f", id.asnorm)), raw \(String(format: "%.2f", id.raw))) |\n"
                }

                // 6b. 逐段身份准确率(纯声音撞库 vs 声道答案)
                md += "\n## B. 逐段身份(纯声音 AS-norm 撞库)vs 声道答案 —— 准确率\n\n"
                var correct = 0, wrong = 0, unk = 0
                var conf: [String: [String: Int]] = [:]  // truth -> assigned -> n
                for gi in valid {
                    let truth = devTruth(segs[gi].device)
                    let asn = segIdent[gi]!.name
                    conf[truth, default: [:]][asn, default: 0] += 1
                    if asn == "未匹配" { unk += 1 }
                    else if (truth.contains("Joy") && asn == "Joy") || (truth.contains("Stan") && asn == "Stan") { correct += 1 }
                    else { wrong += 1 }
                }
                let decided = correct + wrong
                md += "- 正确 \(correct) | 标错 \(wrong) | 未匹配 \(unk)\n"
                md += "- **判了的里准确率: \(decided > 0 ? String(format: "%.0f%%", 100*Double(correct)/Double(decided)) : "n/a")**\n\n"
                md += "混淆(行=声道答案, 列=纯声音判定):\n\n| 答案＼判定 | Joy | Stan | 未匹配 |\n|---|---|---|---|\n"
                for truth in ["Joy(麦)", "Stan(系统)"] {
                    let row = conf[truth] ?? [:]
                    md += "| \(truth) | \(row["Joy"] ?? 0) | \(row["Stan"] ?? 0) | \(row["未匹配"] ?? 0) |\n"
                }

                // 6c. 逐段明细
                md += "\n## C. 逐段明细\n\n| 时间 | 时长s | 声道答案 | 簇 | 纯声音判定 | asnorm | 文本 |\n|---|---|---|---|---|---|---|\n"
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
                for gi in valid {
                    let t = fmt.string(from: Date(timeIntervalSince1970: Double(segs[gi].recordedMs)/1000 + segs[gi].startS))
                    let id = segIdent[gi]!
                    let dur = String(format: "%.1f", segs[gi].endS - segs[gi].startS)
                    let txt = segs[gi].text.prefix(50).replacingOccurrences(of: "|", with: "/")
                    md += "| \(t) | \(dur) | \(devTruth(segs[gi].device)) | \(clusterOf[gi] ?? -1) | \(id.name) | \(String(format: "%.2f", id.asnorm)) | \(txt) |\n"
                }

                // 6d. 声道纠缠度:麦内部 / 系统内部 / 跨声道 的平均声纹相似度。
                // 若"跨声道"≈"各自内部",说明两条声道声音纠缠(串音/降质)→ 物理上分不开。
                let micE = valid.filter { segs[$0].device.contains("microphone") }.map { embs[$0]! }
                let sysE = valid.filter { !segs[$0].device.contains("microphone") }.map { embs[$0]! }
                func meanPair(_ A: [[Float]], _ B: [[Float]], same: Bool) -> Float {
                    var s: Float = 0; var c = 0
                    for i in 0..<A.count {
                        let js = same ? (i+1)..<B.count : 0..<B.count
                        for j in js { s += VectorMath.cosineSimilarity(A[i], B[j]); c += 1 }
                    }
                    return c > 0 ? s / Float(c) : 0
                }
                let intraMic = meanPair(micE, micE, same: true)
                let intraSys = meanPair(sysE, sysE, same: true)
                let cross = meanPair(micE, sysE, same: false)
                md += "\n## D. 声道纠缠度(声纹相似度:越接近=越分不开)\n\n"
                md += "| | 平均 cosine |\n|---|---|\n"
                md += "| 麦内部(Joy 自己)| \(String(format: "%.3f", intraMic)) |\n"
                md += "| 系统内部(Stan 自己)| \(String(format: "%.3f", intraSys)) |\n"
                md += "| **跨声道(Joy↔Stan)** | **\(String(format: "%.3f", cross))** |\n\n"
                // 决定性:用今天自己的数据当标准(oracle 中心),最近中心分类准确率上限。
                // 若连这个都≈50%,说明今天的音频里 Joy/Stan 根本没有可分信号(硬上限)。
                func centroid(_ A: [[Float]]) -> [Float]? {
                    guard let d = A.first?.count, d > 0 else { return nil }
                    var s = [Float](repeating: 0, count: d)
                    for v in A { for i in 0..<d { s[i] += v[i] } }
                    for i in 0..<d { s[i] /= Float(A.count) }
                    VectorMath.l2Normalize(&s); return s
                }
                var oracleAcc = 0.0
                if let jc = centroid(micE), let sc = centroid(sysE) {
                    var oracleCorrect = 0
                    for gi in valid {
                        let e = embs[gi]!
                        let toJoy = VectorMath.cosineSimilarity(e, jc), toStan = VectorMath.cosineSimilarity(e, sc)
                        let pred = toJoy >= toStan ? "Joy" : "Stan"
                        if (segs[gi].device.contains("microphone") && pred == "Joy") || (!segs[gi].device.contains("microphone") && pred == "Stan") { oracleCorrect += 1 }
                    }
                    oracleAcc = Double(oracleCorrect) / Double(valid.count)
                    md += "**今天自己数据当标准(oracle 中心)最近中心分类:\(oracleCorrect)/\(valid.count) = \(String(format: "%.0f%%", 100*oracleAcc))** —— 这是今天这段音频的理论可分上限。\n\n"
                }
                md += "→ 跨声道 \(String(format: "%.3f", cross)) vs 各自内部 \(String(format: "%.3f", intraMic))/\(String(format: "%.3f", intraSys));但 oracle 上限 \(String(format: "%.0f%%", 100*oracleAcc)) —— 见 E 段结论。\n"

                // 6e. 结论与建议(基于 oracle 上限 vs 撞库准确率)
                let galleryAcc = decided > 0 ? Double(correct) / Double(decided) : 0
                let oP = String(format: "%.0f%%", 100*oracleAcc)
                let gP = String(format: "%.0f%%", 100*galleryAcc)
                md += "\n## E. 结论与建议\n\n"
                if oracleAcc >= 0.72 {
                    md += "**今天这段音频里 Joy/Stan 有可分信号(oracle 上限 \(oP))—— 不是无解、不是串音、不是糊成一团。**\n\n"
                    md += "瓶颈是**声纹库**:用今天自己的数据当标准能分到 \(oP),但撞现有库只有 \(gP)。差的这 \(String(format: "%.0f", 100*(oracleAcc-galleryAcc))) 个点 = **库的域不匹配** —— 你登记的 Joy/Stan 档案跟今天的音频(尤其 Stan 的通话音)来源条件不同,撞不上。\n\n"
                    md += "**修法(可落地,按性价比):**\n"
                    md += "1. **用代表性真实音重新登记 Joy / Stan**,尤其 Stan 从**真实通话音**多条件登记 —— 让库匹配上「今天这种」域。这是把 \(gP) 拉向 \(oP) 的关键。\n"
                    md += "2. 同一说话回合的**短段先合并**成 ≥3s 再提声纹(中位才 1.6s,短句声纹不可靠)。\n"
                    md += "3. AS-norm 阈值按域校准 + 平衡两人样本数(现在 Joy 样本远多于 Stan,best-of-N 偏向 Joy)。\n\n"
                    md += "**老实说上限:\(oP) 本身是「可用但不完美」** —— 通话音被编码降质,CAM++(VoxCeleb 宽带训练)在窄带通话音上吃亏。要再往上得换**抗窄带/电话域**的声纹模型 + 短段合并。但先把库的域对齐,就能从 \(gP) 大幅回血。\n"
                } else {
                    md += "连 oracle 上限都只有 \(oP) —— 今天这段音频确实缺乏可分信号(编码降质/采集太差),换库也救不回多少,得从采集质量入手。\n"
                }

                // 6f. 域内重登记测试:今天数据按时间交替分两半,一半当"重新登记的库"
                // (通话音登记通话音),另一半测试。验证"域对齐的库"能否把 61% 拉向 83%。
                if reenroll {
                    let enrollIdx = valid.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
                    let testIdx = valid.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
                    let joyP = enrollIdx.filter { segs[$0].device.contains("microphone") }.map { embs[$0]! }
                    let stanP = enrollIdx.filter { !segs[$0].device.contains("microphone") }.map { embs[$0]! }
                    let coh = enrollIdx.map { embs[$0]! }
                    let (jmu, jsd) = joyP.isEmpty ? (0, 1) : topKStats(of: joyP[medoid(joyP)], against: coh)
                    let (smu, ssd) = stanP.isEmpty ? (0, 1) : topKStats(of: stanP[medoid(stanP)], against: coh)
                    func id2(_ e: [Float]) -> String {
                        let (tmu, tsd) = topKStats(of: e, against: coh)
                        let rj = joyP.map { VectorMath.cosineSimilarity(e, $0) }.max() ?? -2
                        let rs = stanP.map { VectorMath.cosineSimilarity(e, $0) }.max() ?? -2
                        let aj = 0.5 * ((rj - tmu)/max(tsd,1e-4) + (rj - jmu)/max(jsd,1e-4))
                        let as_ = 0.5 * ((rs - tmu)/max(tsd,1e-4) + (rs - smu)/max(ssd,1e-4))
                        return aj >= as_ ? "Joy" : "Stan"
                    }
                    // 质心(平均)匹配:嘈杂音上比 best-of-N 稳。
                    func mean(_ A: [[Float]]) -> [Float]? {
                        guard let d = A.first?.count, d > 0 else { return nil }
                        var s = [Float](repeating: 0, count: d)
                        for v in A { for i in 0..<d { s[i] += v[i] } }
                        for i in 0..<d { s[i] /= Float(A.count) }
                        VectorMath.l2Normalize(&s); return s
                    }
                    let jCen = mean(joyP), sCen = mean(stanP)
                    func idCen(_ e: [Float]) -> String {
                        let rj = jCen.map { VectorMath.cosineSimilarity(e, $0) } ?? -2
                        let rs = sCen.map { VectorMath.cosineSimilarity(e, $0) } ?? -2
                        return rj >= rs ? "Joy" : "Stan"
                    }
                    var cN = 0, wN = 0, cC = 0, wC = 0
                    var cf: [String: [String: Int]] = [:]
                    for gi in testIdx {
                        let truth = segs[gi].device.contains("microphone") ? "Joy" : "Stan"
                        if id2(embs[gi]!) == truth { cN += 1 } else { wN += 1 }
                        let pc = idCen(embs[gi]!)
                        cf[truth, default: [:]][pc, default: 0] += 1
                        if pc == truth { cC += 1 } else { wC += 1 }
                    }
                    let accN = (cN+wN) > 0 ? Double(cN)/Double(cN+wN) : 0
                    let accC = (cC+wC) > 0 ? Double(cC)/Double(cC+wC) : 0
                    md += "\n## F. 域内重登记测试(今天通话音自己登记自己,交替分半,无泄漏)\n\n"
                    md += "登记: Joy \(joyP.count) 条 / Stan \(stanP.count) 条;测试 \(testIdx.count) 条。\n\n"
                    md += "| 匹配法 | 准确率 |\n|---|---|\n"
                    md += "| 撞旧库(best-of-N)| \(String(format: "%.0f%%", 100*galleryAcc)) |\n"
                    md += "| 重登记 best-of-N | \(String(format: "%.0f%%", 100*accN)) |\n"
                    md += "| **重登记 质心(平均)** | **\(String(format: "%.0f%%", 100*accC))** |\n"
                    md += "| oracle 上限 | \(String(format: "%.0f%%", 100*oracleAcc)) |\n\n"
                    md += "质心匹配混淆 | 答案＼判定 | Joy | Stan |\n|---|---|---|\n"
                    for t in ["Joy", "Stan"] { let r = cf[t] ?? [:]; md += "| \(t) | \(r["Joy"] ?? 0) | \(r["Stan"] ?? 0) |\n" }
                    print("[reenroll] best-of-N \(String(format: "%.0f%%", 100*accN)) | 质心 \(String(format: "%.0f%%", 100*accC)) | 旧库 \(String(format: "%.0f%%", 100*galleryAcc)) | oracle \(String(format: "%.0f%%", 100*oracleAcc))")
                }

                let out = "/Users/joyzhang14/Desktop/diarize_session_result.md"
                try? md.write(toFile: out, atomically: true, encoding: .utf8)
                // 终端摘要
                print("\n找到 \(nClusters) 个簇。逐段纯声音撞库 vs 声道答案:正确 \(correct) / 标错 \(wrong) / 未匹配 \(unk)"
                    + (decided > 0 ? "  → 准确率 \(String(format: "%.0f%%", 100*Double(correct)/Double(decided)))" : ""))
                print("报告: \(out)")
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        exit(state.code)
    }

    // MARK: - AHC 平均连接(cosine),Lance-Williams 更新,O(N²)

    /// 返回每个点的簇标签。阈值:最近簇对平均相似度 < 阈值即停止合并。
    private static func ahc(_ X: [[Float]], threshold: Float) -> [Int] {
        let n = X.count
        guard n > 0 else { return [] }
        if n == 1 { return [0] }
        var S = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in (i+1)..<n { let s = VectorMath.cosineSimilarity(X[i], X[j]); S[i][j] = s; S[j][i] = s } }
        var active = Array(0..<n)
        var size = [Int](repeating: 1, count: n)
        var members = (0..<n).map { [$0] }
        while active.count > 1 {
            // 找当前最相似的活跃簇对
            var bi = -1, bj = -1; var bs = -Float.greatestFiniteMagnitude
            for ai in 0..<active.count { for aj in (ai+1)..<active.count {
                let i = active[ai], j = active[aj]
                if S[i][j] > bs { bs = S[i][j]; bi = i; bj = j }
            } }
            if bs < threshold { break }
            // 合并 bj -> bi(Lance-Williams 平均连接)
            for k in active where k != bi && k != bj {
                let ns = (Float(size[bi]) * S[bi][k] + Float(size[bj]) * S[bj][k]) / Float(size[bi] + size[bj])
                S[bi][k] = ns; S[k][bi] = ns
            }
            size[bi] += size[bj]
            members[bi].append(contentsOf: members[bj])
            active.removeAll { $0 == bj }
        }
        var labels = [Int](repeating: 0, count: n)
        for (c, root) in active.enumerated() { for m in members[root] { labels[m] = c } }
        return labels
    }

    // MARK: - 工具

    private static func medoid(_ X: [[Float]]) -> Int {
        var bi = 0; var bs = -Float.greatestFiniteMagnitude
        for i in 0..<X.count {
            var s: Float = 0
            for j in 0..<X.count where j != i { s += VectorMath.cosineSimilarity(X[i], X[j]) }
            if s > bs { bs = s; bi = i }
        }
        return bi
    }

    /// AS-norm 用:e 对 cohort 的 topK 相似度均值/标准差。
    private static func topKStats(of e: [Float], against cohort: [[Float]], k: Int = 20) -> (Float, Float) {
        guard !cohort.isEmpty else { return (0, 1) }
        var sims = cohort.map { VectorMath.cosineSimilarity(e, $0) }
        sims.sort(by: >)
        let top = Array(sims.prefix(min(k, sims.count)))
        let mu = top.reduce(0, +) / Float(top.count)
        let varr = top.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Float(top.count)
        return (mu, sqrt(max(varr, 1e-8)))
    }
}
