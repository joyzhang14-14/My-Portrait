import Foundation
import GRDB
import MLX

/// 维护 CLI：`--retranscribe-qwen [--apply]`
///
/// 用 config 里的 Qwen 模型，对已有 **wav-backed** 音频段逐段重转，并用当前声纹库
/// 重新匹配 speaker（只读评估）。默认 **dry-run** —— 出对照报告（OLD/NEW 文本 +
/// OLD/NEW speaker），不写库。加 `--apply` 才**只替换 text**（speaker_id 不动），
/// 写前自动备份 DB，经 GRDB 走（避开 audio_transcriptions 的 FTS5 触发器地雷）。
///
/// ⚠️ `swift build` 不编 mlx metallib，CLI 跑 Qwen 前需先生成 `.build/<cfg>/mlx.metallib`。
/// ⚠️ `--apply` 前建议先退出正在运行的 app（避免 WAL 写冲突）。
enum RetranscribeQwenCLI {

    private final class ExitState: @unchecked Sendable { var code: Int32 = 0; var done = false }

    private struct Seg {
        let id: Int64; let chunkId: Int64; let path: String
        let startS: Double; let endS: Double; let oldText: String; let oldSpeaker: Int64?
    }

    static func run(apply: Bool, limit: Int? = nil, speakerOnly: Bool = false) {
        let state = ExitState()
        let doApply = apply && !speakerOnly   // speaker-only 是只读重匹配,不写库
        print("=== retranscribe-qwen (\(speakerOnly ? "speaker-only" : (doApply ? "APPLY — 只替换 text" : "dry-run")))\(limit.map { " limit=\($0)" } ?? "") ===")
        fflush(stdout)

        let dbImpl: PortraitDBImpl
        do { dbImpl = try PortraitDBImpl() } catch { print("ERROR: open DB: \(error)"); exit(1) }
        let pool = dbImpl.dbPool
        let base = Storage.rootURL

        Task.detached {
            defer { state.done = true }
            do {
                // 1. 读 config（MainActor）
                let audio = await MainActor.run { ConfigStore.shared.current.capture.audio }
                let qwenLangs = audio.qwenLanguages.filter { !$0.isEmpty }
                let lang: String? = qwenLangs.count == 1 ? qwenLangs[0] : nil
                let filterMusic = audio.filterMusic
                let vocabulary = audio.customVocabulary
                let modelId = audio.qwenModel
                print("model: \(modelId)  lang: \(lang ?? "auto")  filterMusic: \(filterMusic)")
                fflush(stdout)

                // speakerOnly = 只重匹配 speaker,跳过 Qwen(不需要 metallib,ONNX 嵌入很快)。
                let qwen: Qwen3ASRWrapper?
                if speakerOnly {
                    qwen = nil
                    print("(speaker-only：跳过 Qwen,只重匹配 speaker)")
                } else {
                    guard Qwen3ASRWrapper.isOnDisk(modelId: modelId) else {
                        print("ERROR: Qwen 模型未下载: \(modelId) —— 先去 AI models 页下载")
                        state.code = 1; return
                    }
                    // 紧凑循环跑几百段时 MLX 的 Metal buffer 缓存会按 shape 累积到 10G+。
                    // 给缓存上限压到 512MB —— 峰值降到 ~4GB(模型 3.3G + 临时 + ≤512M)。
                    MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
                    qwen = Qwen3ASRWrapper(modelId: modelId)
                }

                // 2. speaker 模型（只读匹配用）+ 名字映射
                let extractor: SpeakerEmbeddingExtractor? = await {
                    do {
                        let p = try await SpeakerModelStore.shared.path(for: .embedding)
                        return try SpeakerEmbeddingExtractor(modelPath: p.path, fbank: FbankExtractor())
                    } catch { print("(speaker embedding 模型加载失败，跳过 speaker 测试: \(error))"); return nil }
                }()
                let names: [Int64: String] = (try? await pool.read { db in
                    var m: [Int64: String] = [:]
                    for r in try Row.fetchAll(db, sql: "SELECT id, name FROM speakers") {
                        if let n: String = r["name"], !n.isEmpty { m[r["id"]] = n }
                    }
                    return m
                }) ?? [:]
                func spk(_ id: Int64?) -> String {
                    guard let id else { return "—" }
                    return names[id].map { "\($0)#\(id)" } ?? "#\(id)"
                }

                // 3. 拉所有 wav-backed 段
                let allSegs: [Seg] = try await pool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT t.id AS id, t.audio_chunk_id AS cid, ac.file_path AS path,
                               t.start_s AS s, t.end_s AS e, t.text AS txt, t.speaker_id AS sp
                        FROM audio_transcriptions t
                        JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
                        WHERE ac.file_path LIKE '%.wav'
                        ORDER BY t.audio_chunk_id, t.start_s
                        """).map { r in
                        Seg(id: r["id"], chunkId: r["cid"], path: r["path"],
                            startS: r["s"], endS: r["e"], oldText: r["txt"], oldSpeaker: r["sp"])
                    }
                }
                // --limit N: 只跑前 N 段(小批验内存)。注意 apply 模式带 limit 只会改这 N 段。
                let segs = limit.map { Array(allSegs.prefix($0)) } ?? allSegs
                print("待重跑段: \(segs.count)（按 chunk 分组，每 chunk 只读一次 wav）")
                fflush(stdout)

                var byChunk: [Int64: [Seg]] = [:]
                for s in segs { byChunk[s.chunkId, default: []].append(s) }

                struct Res { let seg: Seg; let newText: String; let newSpeaker: Int64? }
                var results: [Res] = []
                var done = 0, missing = 0
                for (_, chunkSegs) in byChunk.sorted(by: { $0.key < $1.key }) {
                    let path = chunkSegs[0].path
                    let abs = path.hasPrefix("/") ? path : base.appendingPathComponent(path).path
                    // autoreleasepool 放掉 AVAudioPCMBuffer 等 ObjC 临时对象。
                    guard let all = autoreleasepool(invoking: { AudioWAV.readSamples(path: abs) }) else {
                        missing += chunkSegs.count; continue
                    }
                    let n = all.count
                    for s in chunkSegs {
                        let a = max(0, Int(s.startS * 16000)), b = min(n, Int(s.endS * 16000))
                        let slice = (a < b) ? Array(all[a..<b]) : []
                        let newText: String
                        if let qwen {
                            newText = ((try? await qwen.transcribe(
                                samples: slice, language: lang, vocabulary: vocabulary, filterMusic: filterMusic)) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            newText = s.oldText.trimmingCharacters(in: .whitespacesAndNewlines)  // speaker-only: 文本不变
                        }
                        var newSpeaker: Int64? = nil
                        if let ex = extractor, var v = ex.embed(slice) {
                            VectorMath.l2Normalize(&v)
                            newSpeaker = try? await dbImpl.matchSpeaker(embedding: v)
                        }
                        results.append(Res(seg: s, newText: newText, newSpeaker: newSpeaker))
                        done += 1
                        if done % 25 == 0 {
                            if qwen != nil { MLX.GPU.clearCache() }   // 清 MLX 缓存防 RSS 累积
                            print("  \(done)/\(segs.count)… (RSS \(rssGB()) GB)"); fflush(stdout)
                        }
                    }
                }
                qwen?.unload()
                if qwen != nil { MLX.GPU.clearCache() }

                // 4. 报告
                let reportPath = "/tmp/retranscribe_qwen_report.txt"
                var report = "retranscribe-qwen report — \(results.count) segments\nmodel: \(modelId)  lang: \(lang ?? "auto")\n\n"
                var textChanged = 0, spkChanged = 0
                for r in results {
                    let td = r.newText != r.seg.oldText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sd = r.newSpeaker != r.seg.oldSpeaker
                    if td { textChanged += 1 }
                    if sd { spkChanged += 1 }
                    report += "chunk \(r.seg.chunkId) [\(String(format: "%.1f-%.1f", r.seg.startS, r.seg.endS))s]"
                        + " spk \(spk(r.seg.oldSpeaker)) → \(spk(r.newSpeaker))\(sd ? " *" : "")\n"
                        + "  OLD: \(r.seg.oldText)\n  NEW: \(r.newText)\(td ? "  *" : "")\n\n"
                }
                try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
                print("\n报告: \(reportPath)")
                print("文本有变: \(textChanged)/\(results.count)  |  speaker 有变: \(spkChanged)/\(results.count)  |  wav 读失败: \(missing)")

                // speaker 分布汇总(评估"我 vs 别人")
                func dist(_ pick: (Res) -> Int64?) -> [(String, Int)] {
                    var c: [Int64: Int] = [:]; var none = 0
                    for r in results { if let id = pick(r) { c[id, default: 0] += 1 } else { none += 1 } }
                    var out = c.sorted { $0.value > $1.value }.map { (spk($0.key), $0.value) }
                    if none > 0 { out.append(("无匹配", none)) }
                    return out
                }
                print("\n--- speaker 分布 OLD（库里旧值，bug 版本）---")
                for (k, v) in dist({ $0.seg.oldSpeaker }) { print("  \(k): \(v)") }
                print("--- speaker 分布 NEW（当前声纹库重新匹配）---")
                for (k, v) in dist({ $0.newSpeaker }) { print("  \(k): \(v)") }

                // 终端样本(文本或 speaker 有变化的前 20 条)
                let sample = results.filter {
                    $0.newText != $0.seg.oldText.trimmingCharacters(in: .whitespacesAndNewlines) || $0.newSpeaker != $0.seg.oldSpeaker
                }.prefix(20)
                print("\n--- 样本（前 20 条有变化的）---")
                for r in sample {
                    print("• [\(spk(r.seg.oldSpeaker)) → \(spk(r.newSpeaker))]")
                    print("  OLD: \(r.seg.oldText)")
                    print("  NEW: \(r.newText)")
                }
                fflush(stdout)

                if !doApply {
                    let hint = speakerOnly
                        ? "[speaker-only] 只读重匹配,没写库。"
                        : "[dry-run] 没写库。看着行就 --apply 重跑（只替换 text，先备份 DB）。speaker_id 始终不动。"
                    print("\n\(hint)")
                    return
                }

                // 5. APPLY:默认跳过 2GB+ 全库备份(用户原话:bak 占空间)。
                // 真要回滚开 MYPORTRAIT_KEEP_BAK=1。
                try await pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
                if ProcessInfo.processInfo.environment["MYPORTRAIT_KEEP_BAK"] == "1" {
                    let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let src = base.appendingPathComponent("portrait.sqlite")
                    let bak = base.appendingPathComponent("portrait.sqlite.bak-\(ts)")
                    do { try FileManager.default.copyItem(at: src, to: bak); print("DB 备份: \(bak.path)") }
                    catch { print("ERROR: 备份失败,中止 apply: \(error)"); state.code = 1; return }
                }

                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                // 空转录(近静音)不覆盖，避免清空原文本 —— 先过滤成自包含的 let 数组，
                // 这样 GRDB @Sendable write 闭包不捕获/改外层 var。
                let toUpdate: [(id: Int64, text: String)] = results.compactMap {
                    $0.newText.isEmpty ? nil : (id: $0.seg.id, text: $0.newText)
                }
                let skippedEmpty = results.count - toUpdate.count
                let updated = try await pool.write { db -> Int in
                    for u in toUpdate {
                        try db.execute(sql: """
                            UPDATE audio_transcriptions
                            SET text = :t, engine = 'qwen', transcribed_at_ms = :ts
                            WHERE id = :id
                            """, arguments: ["t": u.text, "ts": nowMs, "id": u.id])
                    }
                    return toUpdate.count
                }
                print("✅ 已替换 \(updated) 段 text（engine=qwen）；空结果跳过 \(skippedEmpty) 段。speaker_id 未动。")
                print("   FTS 已随 GRDB 触发器同步。")
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        exit(state.code)
    }

    /// 当前进程 resident memory，单位 GB（一位小数）。
    private static func rssGB() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "?" }
        return String(format: "%.1f", Double(info.resident_size) / 1024 / 1024 / 1024)
    }
}
