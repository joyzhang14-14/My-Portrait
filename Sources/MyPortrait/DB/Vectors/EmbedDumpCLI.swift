import Darwin
import Foundation
import GRDB
import MLX

/// CLI 入口：`MyPortrait --embed-dump "some text"`。
///
/// 用途：跟 Python FlagEmbedding 做数值对齐验证。
///   ```bash
///   ./MyPortrait --embed-dump "我感冒了，需要去医院"
///   ```
/// 输出格式（每个 case 一段）：
///   ```
///   === FIXED CASE ===
///   text: The quick brown fox jumps over the lazy dog
///   token_ids: 0 581 8408 24800 26222 21925 645 583 38715 13651 2
///   dim: 1024
///   norm: 1.0000
///   vector: 0.0123,0.0456,...,-0.0789
///   ```
///
/// 数值对齐要求：跟 Python 端同一句话的 dense_vec cosine ≥ 0.999。
/// token_ids 序列也会打印，方便 mismatch 时定位是 tokenizer 出错还是 forward 出错。
///
/// **设计**：完全旁路 Services / AppDelegate / SwiftUI。只起 MLX + BGEM3VectorEmbedder。
/// 跑完 exit。不动 DB、不动捕获子系统。
enum EmbedDumpCLI {

    /// 跑固定 case + 可选用户文本，写到 stdout，exit。
    /// 在主线程（MyPortraitApp.init 同步阶段）调用 —— MLX scheduler 必须主线程预热。
    static func run(userText: String?) {
        // 1. 主线程预热 MLX（必须）
        eval(MLXArray(0))

        let state = ExitState()

        // 2. 进推理 task。Task.detached 默认非 main thread，MLX 已主线程预热。
        //    完事 state.done = true，主 RunLoop 看到就 exit。
        //    **不能用 DispatchSemaphore.wait()** —— 会 block 主线程让 Task 内的
        //    某些回调（HubApi URLSession completion，可能 dispatch 到 main queue）
        //    永远拿不到执行机会，造成死锁。
        Task.detached {
            defer { state.done = true }
            do {
                let reporter = await UnimplementedReporter()
                let embedder = BGEM3VectorEmbedder(reporter: reporter)

                // 固定 case —— 用户每次跑都对比这个，不用输参数也能验证。
                let fixed = "The quick brown fox jumps over the lazy dog"
                try await Self.dumpCase(label: "FIXED CASE", text: fixed, embedder: embedder)

                if let user = userText, !user.isEmpty {
                    try await Self.dumpCase(label: "USER TEXT", text: user, embedder: embedder)
                }
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }

        // 主线程 pump RunLoop 等异步任务跑完。这就是 NSApp.run 内部干的事，
        // 但我们不想起 NSApp（会拉 Dock icon / status item / window）。
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }

    private final class ExitState: @unchecked Sendable {
        var code: Int32 = 0
        var done: Bool = false
    }

    /// dump 单个 case：text → token ids → embed → 写 stdout。
    /// Token ids 用 `BGEM3VectorEmbedder.debugTokenize` 拿到（用同一个 tokenizer，
    /// 不重新加载）。
    /// 跑 batch 一致性验证：对 A/B/C 三句，分别 dump
    ///   - 单条 embed(text) → vector_single
    ///   - 把 text 塞进 32 句 batch 的 index 16，filler 长度各异强制 padding 生效 →
    ///     embedBatch(...)[16] → vector_batched
    /// 同时输出，供外部比 cosine。阈值 ≥ 0.9999（同 backend 同 model，应数值一致）。
    static func runBatchTest() {
        eval(MLXArray(0))
        let state = ExitState()

        Task.detached {
            defer { state.done = true }
            do {
                let reporter = await UnimplementedReporter()
                let embedder = BGEM3VectorEmbedder(reporter: reporter)

                let cases: [(String, String)] = [
                    ("A", "The quick brown fox jumps over the lazy dog"),
                    ("B", "我感冒了，需要去医院"),
                    ("C", "Hello world"),
                ]
                // 31 个长度差异大的 filler，让 batch 里 padding 真的生效。
                let fillers: [String] = [
                    "Hi.",
                    "OK.",
                    "你好。",
                    "Lorem ipsum dolor sit amet.",
                    "Short text.",
                    "今天天气真好。",
                    "A.",
                    "The cat sat on the mat watching the rain fall outside the window all afternoon.",
                    "短句。",
                    "Hello.",
                    "Bonjour.",
                    "こんにちは。",
                    "Привет.",
                    "Pneumonoultramicroscopicsilicovolcanoconiosis is a long English word.",
                    "好。",
                    "Yes.",
                    "她去了医院做检查并领了一些药物。",
                    "Coffee.",
                    "The art of programming requires patience, discipline, and a willingness to learn from constant failure.",
                    "嗯。",
                    "Maybe.",
                    "猫咪在沙发上睡觉，发出轻轻的呼噜声，整个下午都没有醒来。",
                    "Wow.",
                    "Okay.",
                    "下雨了。",
                    "Tomatoes grow best in full sunlight with regular watering and well-drained soil rich in organic matter.",
                    "再见。",
                    "Bye.",
                    "Reading books expands the mind.",
                    "感冒。",
                    "End."
                ]
                precondition(fillers.count == 31)

                for (label, text) in cases {
                    print("=== CASE \(label) ===")
                    print("text: \(text)")
                    fflush(stdout)

                    // 单条
                    let single = try await embedder.embed(text)
                    print("dim: \(single.count)")
                    print("single_vector: " + single.map { String(format: "%.6f", $0) }.joined(separator: ","))
                    fflush(stdout)

                    // batch=32, 测试句在 index 16
                    var batch = Array(fillers.prefix(16))
                    batch.append(text)
                    batch.append(contentsOf: fillers.suffix(15))
                    precondition(batch.count == 32)
                    precondition(batch[16] == text)

                    let batched = try await embedder.embedBatch(batch)
                    let targetVec = batched[16]
                    print("batched_vector: " + targetVec.map { String(format: "%.6f", $0) }.joined(separator: ","))
                    print("")
                    fflush(stdout)
                }
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }

        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }

    /// 内存 profile：跑 N 个 batch=32 forward，1/10/100 batch 节点打印 RSS。
    /// 用于判定是否有内存泄漏。
    ///   - 5GB → 5GB → 5GB：无泄漏，cache 被 MLX 自己回收
    ///   - 5GB → 7GB → 12GB：线性泄漏
    ///   - 5GB → 8GB → 8GB：cache 有上限，可接受
    static func runProfile() {
        eval(MLXArray(0))
        let state = ExitState()

        Task.detached {
            defer { state.done = true }
            do {
                let reporter = await UnimplementedReporter()
                let embedder = BGEM3VectorEmbedder(reporter: reporter)

                // 32 句样本：用 batch test 里的混合 filler + 三句目标。长度差异强制 padding。
                let samples: [String] = [
                    "The quick brown fox jumps over the lazy dog",
                    "我感冒了，需要去医院",
                    "Hello world",
                    "Hi.", "OK.", "你好。",
                    "Lorem ipsum dolor sit amet.",
                    "Short text.", "今天天气真好。", "A.",
                    "The cat sat on the mat watching the rain fall outside the window all afternoon.",
                    "短句。", "Hello.", "Bonjour.", "こんにちは。", "Привет.",
                    "Pneumonoultramicroscopicsilicovolcanoconiosis is a long English word.",
                    "好。", "Yes.",
                    "她去了医院做检查并领了一些药物。",
                    "Coffee.",
                    "The art of programming requires patience, discipline, and a willingness to learn from constant failure.",
                    "嗯。", "Maybe.",
                    "猫咪在沙发上睡觉，发出轻轻的呼噜声，整个下午都没有醒来。",
                    "Wow.", "Okay.", "下雨了。",
                    "Tomatoes grow best in full sunlight with regular watering and well-drained soil rich in organic matter.",
                    "再见。", "Bye.", "End.",
                ]
                precondition(samples.count == 32, "got \(samples.count)")

                let totalBatches = 100
                let snapshotPoints: Set<Int> = [1, 10, 100]
                print("=== embed memory profile ===")
                print("baseline RSS (after model load): \(rssMB()) MB")
                print(String(format: "MLX cache limit: %.1f GB", Double(MLX.GPU.cacheLimit) / 1024 / 1024 / 1024))
                print(String(format: "MLX memory limit: %.1f GB", Double(MLX.GPU.memoryLimit) / 1024 / 1024 / 1024))
                fflush(stdout)

                for n in 1...totalBatches {
                    _ = try await embedder.embedBatch(samples)
                    if snapshotPoints.contains(n) {
                        let rss = rssMB()
                        let active = Double(MLX.GPU.activeMemory) / 1024 / 1024
                        let cache = Double(MLX.GPU.cacheMemory) / 1024 / 1024
                        print(String(format: "after %3d batches:  RSS=%.0f MB   mlx.active=%.0f MB   mlx.cache=%.0f MB", n, Double(rss), active, cache))
                        fflush(stdout)
                    }
                    if Task.isCancelled { break }
                }
                print("done")
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }

        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }

    /// 真实路径 profile：起完整 Services（DB / Capture / Compaction / Transcribe /
    /// Retention 全跑空载），停 EmbeddingWorker 避免并发抢帧，然后从 DB 拉 100×32
    /// 真实帧文本，手动喂 embedder.embedBatch + db.setFrameEmbedding。
    /// 每 10 个 batch 打 RSS + MLX active + MLX cache + 当 batch 最长文本字符数。
    @MainActor
    static func runProfileFromDB(services: Services) {
        eval(MLXArray(0))
        let state = ExitState()

        // 从 main 抓出 Sendable handle
        let db: PortraitDB = services.db
        let embedder = services.embedder
        let worker = services.embeddingWorker

        print("=== embed-profile-from-db ===")
        print("RSS (Services started, before worker stop): \(rssMB()) MB")
        print(String(format: "MLX cache limit: %.0f MB", Double(MLX.GPU.cacheLimit) / 1024 / 1024))
        print(String(format: "MLX memory limit: %.0f MB", Double(MLX.GPU.memoryLimit) / 1024 / 1024))
        fflush(stdout)

        Task.detached {
            defer { state.done = true }
            // 关掉自动 worker，避免它跟我们的 profile loop 抢帧 + 抢 GPU
            await worker.stop()

            // 拉一批真实需要 embed 的 frame id（用一个临时 model 标签拉，免抢真实状态）
            // 直接读 DB 里现成的 frames + full_text 即可，model 字段我们不在乎
            let model = embedder.modelIdentifier
            let ids: [Int64]
            do {
                ids = try await db.framesNeedingEmbedding(model: model, limit: 3200)
            } catch {
                FileHandle.standardError.write("framesNeedingEmbedding failed: \(error)\n".data(using: .utf8)!)
                state.code = 1
                return
            }
            print("pulled \(ids.count) frames needing embedding")
            fflush(stdout)
            guard ids.count >= 32 else {
                FileHandle.standardError.write("only \(ids.count) frames available, need ≥32\n".data(using: .utf8)!)
                state.code = 1
                return
            }

            let metas: [FrameMetadata]
            do {
                metas = try await db.framesByIds(ids)
            } catch {
                FileHandle.standardError.write("framesByIds failed: \(error)\n".data(using: .utf8)!)
                state.code = 1
                return
            }
            // 过滤掉没文本的
            let work: [(Int64, String)] = metas.compactMap {
                guard let t = $0.fullText, !t.isEmpty else { return nil }
                return ($0.id, t)
            }
            print("usable frames (full_text non-empty): \(work.count)")
            fflush(stdout)

            let totalBatches = 100
            let chunkSize = 32
            let needed = totalBatches * chunkSize
            if work.count < needed {
                print("warning: only \(work.count) frames, will wrap")
            }

            // 找出最长文本所属的那个 batch index，给 peak profile 用
            var maxLen = 0
            var maxBatchIdx = 0
            for b in 0..<totalBatches {
                var batchMax = 0
                for j in 0..<chunkSize {
                    let idx = (b * chunkSize + j) % work.count
                    batchMax = max(batchMax, work[idx].1.count)
                }
                if batchMax > maxLen {
                    maxLen = batchMax
                    maxBatchIdx = b
                }
            }
            print("longest text batch: idx=\(maxBatchIdx) (char count=\(maxLen))")
            fflush(stdout)

            print("")
            print("batch  | RSS    | mlx.active | mlx.cache | max_chars_in_batch")
            print("-------+--------+------------+-----------+-------------------")
            fflush(stdout)

            for b in 0..<totalBatches {
                var chunk: [(Int64, String)] = []
                var batchMaxChars = 0
                for j in 0..<chunkSize {
                    let idx = (b * chunkSize + j) % work.count
                    chunk.append(work[idx])
                    batchMaxChars = max(batchMaxChars, work[idx].1.count)
                }

                let vectors: [[Float]]
                do {
                    vectors = try await embedder.embedBatch(chunk.map(\.1))
                } catch {
                    FileHandle.standardError.write("embedBatch failed batch \(b): \(error)\n".data(using: .utf8)!)
                    state.code = 1
                    return
                }
                // 不 setFrameEmbedding（避免污染 DB；profile 只测内存）
                _ = vectors

                let nth = b + 1
                if nth == 1 || nth % 10 == 0 || nth == maxBatchIdx + 1 {
                    let rss = rssMB()
                    let act = Double(MLX.GPU.activeMemory) / 1024 / 1024
                    let cac = Double(MLX.GPU.cacheMemory) / 1024 / 1024
                    let tag = (nth == maxBatchIdx + 1) ? " ← peak chars" : ""
                    print(String(format: "%5d  | %4d MB | %6.0f MB  | %5.0f MB  | %d chars%@", nth, rss, act, cac, batchMaxChars, tag))
                    fflush(stdout)
                }
                if Task.isCancelled { break }
            }

            print("")
            print("done. final RSS: \(rssMB()) MB")
        }

        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(state.code)
    }

    /// 全速回灌：从 DB 把所有没 embed（或 embedding_model 不匹配）的帧拉出，
    /// batch=32 喂 embedder，写 DB。每 1000 帧打 progress + RSS。
    /// 完事跑 sanity check：embedded count / model_id 唯一 / blob 长度恒 4096。
    @MainActor
    static func runBackfill(services: Services) {
        eval(MLXArray(0))
        let state = ExitState()

        let db: PortraitDB = services.db
        let embedder = services.embedder
        let worker = services.embeddingWorker

        print("=== embed-backfill ===")
        print("RSS: \(rssMB()) MB    MLX cache limit: \(MLX.GPU.cacheLimit / 1024 / 1024) MB")
        fflush(stdout)

        Task.detached {
            defer { state.done = true }
            await worker.stop()  // 关自动 worker

            let model = embedder.modelIdentifier
            let started = Date()
            var totalEmbedded = 0
            var totalWritten = 0
            var lastReportFrames = 0

            // 内层循环：每轮拉 256 个 id，处理完再拉下一轮，直到拉不到为止。
            outer: while !Task.isCancelled {
                let ids: [Int64]
                do {
                    ids = try await db.framesNeedingEmbedding(model: model, limit: 256)
                } catch {
                    FileHandle.standardError.write("framesNeedingEmbedding failed: \(error)\n".data(using: .utf8)!)
                    state.code = 1
                    return
                }
                if ids.isEmpty { break }

                let metas: [FrameMetadata]
                do {
                    metas = try await db.framesByIds(ids)
                } catch {
                    FileHandle.standardError.write("framesByIds failed: \(error)\n".data(using: .utf8)!)
                    state.code = 1
                    return
                }
                let work: [(Int64, String)] = metas.compactMap {
                    guard let t = $0.fullText, !t.isEmpty else { return nil }
                    return ($0.id, t)
                }
                if work.isEmpty { continue }

                let chunkSize = 32
                var i = 0
                while i < work.count {
                    let end = min(i + chunkSize, work.count)
                    let chunk = Array(work[i..<end])
                    let vectors: [[Float]]
                    do {
                        vectors = try await embedder.embedBatch(chunk.map(\.1))
                    } catch {
                        FileHandle.standardError.write("embedBatch failed at total=\(totalEmbedded): \(error)\n".data(using: .utf8)!)
                        state.code = 1
                        return
                    }
                    for (j, pair) in chunk.enumerated() {
                        guard j < vectors.count else { break }
                        var v = vectors[j]
                        VectorMath.l2Normalize(&v)
                        do {
                            try await db.setFrameEmbedding(frameId: pair.0, vector: v, model: model)
                            totalWritten += 1
                        } catch {
                            FileHandle.standardError.write("setFrameEmbedding(\(pair.0)) failed: \(error)\n".data(using: .utf8)!)
                        }
                        totalEmbedded += 1
                    }
                    i = end

                    // 每 1000 帧打 progress
                    if totalEmbedded - lastReportFrames >= 1000 {
                        lastReportFrames = totalEmbedded
                        let el = Date().timeIntervalSince(started)
                        let rate = Double(totalEmbedded) / max(el, 0.001)
                        let rss = rssMB()
                        let cache = Int(Double(MLX.GPU.cacheMemory) / 1024 / 1024)
                        print(String(format: "[%6.0fs] embedded %d frames (%5.1f fr/s)   RSS=%d MB  mlx.cache=%d MB",
                                     el, totalEmbedded, rate, rss, cache))
                        fflush(stdout)
                    }
                    if Task.isCancelled { break outer }
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            print("")
            print(String(format: "=== backfill done: %d embedded (%d written) in %.0fs (avg %.1f fr/s) ===",
                         totalEmbedded, totalWritten, elapsed, Double(totalEmbedded) / max(elapsed, 0.001)))
            fflush(stdout)

            // === Sanity checks ===
            print("")
            print("=== sanity checks ===")
            fflush(stdout)
            await runSanityChecks(db: db, model: model)
        }

        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
        exit(state.code)
    }

    /// Sanity check 用 raw SQL（PortraitDB protocol 没暴露这些字段）—— 直接读
    /// PortraitDBImpl.dbPool。
    private static func runSanityChecks(db: PortraitDB, model: String) async {
        guard let impl = db as? PortraitDBImpl else {
            print("(skip: db is not PortraitDBImpl)")
            return
        }
        do {
            let stats: (Int, Int, Int, Int, Int) = try await impl.dbPool.read { db in
                let totalFrames = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames") ?? 0
                let withEmbed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames WHERE embedding IS NOT NULL") ?? 0
                let distinctModels = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT embedding_model) FROM frames WHERE embedding IS NOT NULL") ?? 0
                let badLength = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames WHERE embedding IS NOT NULL AND length(embedding) != 4096") ?? 0
                let nullModel = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames WHERE embedding IS NOT NULL AND embedding_model IS NULL") ?? 0
                return (totalFrames, withEmbed, distinctModels, badLength, nullModel)
            }
            print("total frames in DB: \(stats.0)")
            print("frames with embedding: \(stats.1)")
            print("distinct embedding_model values: \(stats.2)  (expected 1)")
            print("frames with wrong blob length (!= 4096): \(stats.3)  (expected 0)")
            print("frames with embedding but null model: \(stats.4)  (expected 0)")
            let pass = stats.2 == 1 && stats.3 == 0 && stats.4 == 0
            print(pass ? "SANITY: PASS ✓" : "SANITY: FAIL ✗")
        } catch {
            print("sanity query failed: \(error)")
        }
    }

    /// Capture profile：跟 13.77 GB 那次环境对齐 —— Services 全启 + capture
    /// 子系统打开 + embedder 跑 50 batch。
    /// `scenario` 决定打哪几个开关：
    ///   "A" = 纯 embedder（baseline）
    ///   "B" = + screenCaptureEnabled
    ///   "C" = + audioCaptureEnabled
    ///   "D" = + screenCapture + audioCapture
    ///
    /// 注意：screen / audio 真正启动需要 macOS 权限。CLI 模式没有用户授权弹窗
    /// → CaptureCoordinator.start() 会被系统拒，记 reporter，但相关子系统初始化
    /// 仍可能分配 buffer / IOSurface，恰好这就是要观察的。
    @MainActor
    static func runCaptureProfile(services: Services, scenario: String) {
        eval(MLXArray(0))
        let state = ExitState()

        let db: PortraitDB = services.db
        let embedder = services.embedder
        let worker = services.embeddingWorker
        let settings = services.settings

        // 打开对应开关
        switch scenario {
        case "B":
            settings.screenCaptureEnabled = true
        case "C":
            settings.audioCaptureEnabled = true
        case "D":
            settings.screenCaptureEnabled = true
            settings.audioCaptureEnabled = true
        default:
            break // A
        }

        print("=== capture-profile scenario=\(scenario) ===")
        print("RSS (Services started, before toggles settle): \(rssMB()) MB")
        fflush(stdout)

        Task.detached {
            defer { state.done = true }
            await worker.stop()

            // 让 capture 子系统初始化完成（Combine sink → start coordinator → SCStream）
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            print("RSS (after 5s settle): \(rssMB()) MB")
            fflush(stdout)

            let model = embedder.modelIdentifier
            let ids: [Int64]
            do {
                ids = try await db.framesNeedingEmbedding(model: model, limit: 32 * 50)
            } catch {
                FileHandle.standardError.write("framesNeedingEmbedding failed: \(error)\n".data(using: .utf8)!)
                state.code = 1
                return
            }
            let metas = (try? await db.framesByIds(ids)) ?? []
            let work: [String] = metas.compactMap {
                guard let t = $0.fullText, !t.isEmpty else { return nil }
                return t
            }
            print("usable frames: \(work.count)")

            // 跑 50 batch
            for b in 0..<50 {
                var chunk: [String] = []
                for j in 0..<32 {
                    chunk.append(work[(b * 32 + j) % max(work.count, 1)])
                }
                _ = try? await embedder.embedBatch(chunk)
                if (b + 1) % 10 == 0 {
                    let rss = rssMB()
                    let act = Int(Double(MLX.GPU.activeMemory) / 1024 / 1024)
                    let cac = Int(Double(MLX.GPU.cacheMemory) / 1024 / 1024)
                    print(String(format: "batch %3d  RSS=%d MB  mlx.active=%d MB  mlx.cache=%d MB", b + 1, rss, act, cac))
                    fflush(stdout)
                }
            }
            print("final RSS: \(rssMB()) MB")
        }

        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
        exit(state.code)
    }

    /// 一次性恢复 `frames_fts` 虚拟表（如果某次 migration / import 把它丢了）。
    /// 重建后跑 FTS5 builtin 'rebuild' 命令，从 frames.content 重新索引所有行。
    @MainActor
    static func runRebuildFramesFts(services: Services) {
        eval(MLXArray(0))
        let state = ExitState()
        guard let impl = services.db as? PortraitDBImpl else {
            print("ERROR: db is not PortraitDBImpl")
            exit(1)
        }
        Task.detached {
            defer { state.done = true }
            do {
                try await impl.dbPool.write { db in
                    // 检查存在
                    let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='frames_fts'") ?? 0
                    if exists > 0 {
                        print("frames_fts already exists; running rebuild only")
                        try db.execute(sql: "INSERT INTO frames_fts(frames_fts) VALUES('rebuild')")
                        print("rebuild done")
                        return
                    }
                    print("frames_fts missing; recreating + reindexing…")
                    // 跟 Schema.swift v1 migration 完全一致（tokenize='foundation_icu'）
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE frames_fts USING fts5(
                            app_name, window_name, browser_url, full_text,
                            tokenize='''foundation_icu''',
                            content='frames', content_rowid='id'
                        )
                        """)
                    // GRDB synchronize(withTable:) 走的是 INSERT/UPDATE/DELETE 触发器。
                    // 这里手工补齐（跟 GRDB 自动生成的等价）：
                    try db.execute(sql: """
                        CREATE TRIGGER __frames_fts_ai AFTER INSERT ON frames BEGIN
                            INSERT INTO frames_fts(rowid, app_name, window_name, browser_url, full_text)
                            VALUES (new.id, new.app_name, new.window_name, new.browser_url, new.full_text);
                        END
                        """)
                    try db.execute(sql: """
                        CREATE TRIGGER __frames_fts_ad AFTER DELETE ON frames BEGIN
                            INSERT INTO frames_fts(frames_fts, rowid, app_name, window_name, browser_url, full_text)
                            VALUES('delete', old.id, old.app_name, old.window_name, old.browser_url, old.full_text);
                        END
                        """)
                    try db.execute(sql: """
                        CREATE TRIGGER __frames_fts_au AFTER UPDATE ON frames BEGIN
                            INSERT INTO frames_fts(frames_fts, rowid, app_name, window_name, browser_url, full_text)
                            VALUES('delete', old.id, old.app_name, old.window_name, old.browser_url, old.full_text);
                            INSERT INTO frames_fts(rowid, app_name, window_name, browser_url, full_text)
                            VALUES (new.id, new.app_name, new.window_name, new.browser_url, new.full_text);
                        END
                        """)
                    // 用 content table 重建索引
                    try db.execute(sql: "INSERT INTO frames_fts(frames_fts) VALUES('rebuild')")
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames_fts") ?? -1
                    print("frames_fts created + rebuilt (\(count) docs)")
                }
            } catch {
                FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
                state.code = 1
            }
        }
        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
        exit(state.code)
    }

    /// E2E search test：跑几条 cross-lingual query 看 HybridSearchEngine 召回。
    /// 不做硬 assert（query 召回质量天然主观），打 top-5 给人看。
    @MainActor
    static func runSearchTest(services: Services) {
        eval(MLXArray(0))
        let state = ExitState()

        let engine = services.searchEngine
        let queries: [(String, String)] = [
            // (label, query)
            ("EN→ZH", "music player"),               // 应当召回 Spotify / 网易云
            ("ZH→EN", "聊天"),                       // 应当召回 Discord / 微信
            ("EN→EN", "code review"),                // 应当召回 Claude / Terminal
            ("ZH→ZH", "代码"),                       // 应当召回 Claude / Terminal
            ("EN→ZH", "browser"),                    // 应当召回 Safari / Chrome
            ("ZH→EN", "笔记"),                       // 应当召回 Goodnotes / Obsidian
        ]

        Task.detached {
            defer { state.done = true }
            for (label, q) in queries {
                print("")
                print("=== \(label): \"\(q)\" ===")
                fflush(stdout)
                do {
                    let results = try await engine.searchFrames(query: q, limit: 5)
                    if results.isEmpty {
                        print("  (no results)")
                    } else {
                        for (i, r) in results.enumerated() {
                            let snippet = r.snippet.prefix(80).replacingOccurrences(of: "\n", with: " ")
                            print(String(format: "  %d. [%@ | %.3f] %@", i + 1, r.appName, r.score, snippet))
                        }
                    }
                } catch {
                    print("  ERROR: \(error)")
                }
                fflush(stdout)
            }
        }

        while !state.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
        exit(state.code)
    }

    /// 当前进程 resident memory，单位 MB。
    private static func rssMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size) / 1024 / 1024
    }

    private static func dumpCase(label: String, text: String, embedder: BGEM3VectorEmbedder) async throws {
        print("=== \(label) ===")
        print("text: \(text)")
        fflush(stdout)

        let ids = try await embedder.debugTokenize(text)
        print("token_ids: \(ids.map(String.init).joined(separator: " "))")
        fflush(stdout)

        let v = try await embedder.embed(text)
        let norm = (v.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        print("dim: \(v.count)")
        print(String(format: "norm: %.4f", norm))
        print("vector: " + v.map { String(format: "%.6f", $0) }.joined(separator: ","))
        print("")
        fflush(stdout)
    }
}
