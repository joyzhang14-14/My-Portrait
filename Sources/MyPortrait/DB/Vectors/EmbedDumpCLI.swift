import Foundation
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
