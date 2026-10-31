import Darwin
import Foundation
import GRDB
import MLX

/// 调试 CLI 工具（两个通用命令）：
///   - `--rebuild-frames-fts`：恢复 / 重建 `frames_fts` 虚拟表（migration / import
///     把它丢了时用）。
///   - `--embed-search-test`：跑几条 cross-lingual query 看搜索召回，人工 eyeball。
///
/// 历史上这里还有一批 bge-m3 embedding 基准 / backfill / profile 命令，
/// 随语义搜索子系统一起移除（保留这两个不依赖 embedder 的通用工具）。
enum EmbedDumpCLI {

    private final class ExitState: @unchecked Sendable {
        var code: Int32 = 0
        var done: Bool = false
    }

    /// 一次性恢复 `frames_fts` 虚拟表（如果某次 migration / import 把它丢了）。
    /// 重建后跑 FTS5 builtin 'rebuild' 命令，从 frames.content 重新索引所有行。
    @MainActor
    static func runRebuildFramesFts(db impl: PortraitDBImpl) {
        eval(MLXArray(0))
        let state = ExitState()
        Task.detached {
            defer { state.done = true }
            do {
                try await impl.screenPool.write { db in
                    // 检查存在
                    let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='frames_fts'") ?? 0
                    if exists > 0 {
                        print("frames_fts already exists; running rebuild only")
                        try db.execute(sql: "INSERT INTO frames_fts(frames_fts) VALUES('rebuild')")
                        print("rebuild done")
                        return
                    }
                    print("frames_fts missing; recreating + reindexing…")
                    // 建表和三个同步触发器用 screen 基线同一份文本(更新触发器带列限定,
                    // 媒体列的 UPDATE 不触发重分词)。
                    try db.execute(sql: DBSchema.framesFTS)
                    for sql in DBSchema.framesFTSTriggers { try db.execute(sql: sql) }
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

    /// E2E search test：跑几条 cross-lingual query 看搜索召回。
    /// 不做硬 assert（query 召回质量天然主观），打 top-5 给人看。
    @MainActor
    static func runSearchTest(db: PortraitDBImpl) {
        eval(MLXArray(0))
        let state = ExitState()

        // 直接用 DB pool 构造 FTS 引擎 —— 不需要完整 Services(避免与 GUI 双跑)。
        let engine = FTSSearchEngine(screenPool: db.screenPool, audioPool: db.audioPool)
        let frameQueries: [(String, String)] = [
            ("EN→ZH", "music player"),
            ("ZH→EN", "聊天"),
            ("EN→EN", "code review"),
            ("ZH→ZH", "代码"),
            ("EN→ZH", "browser"),
            ("ZH→EN", "笔记"),
        ]
        let transcriptionQueries: [(String, String)] = [
            ("ZH", "学习"),
            ("EN", "music"),
            ("ZH", "约会"),
            ("EN", "movie"),
        ]

        Task.detached {
            defer { state.done = true }
            print("\n>>> FRAMES <<<")
            for (label, q) in frameQueries {
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

            print("\n>>> TRANSCRIPTIONS <<<")
            for (label, q) in transcriptionQueries {
                print("")
                print("=== \(label): \"\(q)\" ===")
                fflush(stdout)
                do {
                    let results = try await engine.searchTranscriptions(query: q, limit: 5)
                    if results.isEmpty {
                        print("  (no results)")
                    } else {
                        for (i, r) in results.enumerated() {
                            let snippet = r.snippet.prefix(100).replacingOccurrences(of: "\n", with: " ")
                            print(String(format: "  %d. [%.3f] %@", i + 1, r.score, snippet))
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
}
