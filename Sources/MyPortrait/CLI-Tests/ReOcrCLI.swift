import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Vision

/// 一次性 CLI:对 frames 表里 snapshot_path 还在的 Safari Google Doc 帧
/// 重跑 Vision OCR,覆盖 full_text + ocr_words_json + text_source。
///
/// 用途:OCRService.recognize 之前的 AX 快路把 Safari 帧的 full_text 写成了
/// tab bar chrome 文本(Google Doc canvas AX 拿不到),要把这些覆盖成 Vision
/// 跑出来的真正页面内容。
///
/// 用法:`swift run MyPortrait --reocr-google-docs-today`
enum ReOcrCLI {

    static func runGoogleDocsToday() {
        Task {
            do {
                let count = try await reocrToday()
                print("[re-ocr] done. updated \(count) frame(s)")
                exit(0)
            } catch {
                fputs("[re-ocr] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// MP4 版:对今日 Google Doc 已压进 MP4 的帧(snapshot_path NULL,
    /// video_chunk_id 非空)按 offset_ms 从视频抽帧 → Vision OCR → 覆盖。
    static func runGoogleDocsTodayMP4() {
        Task {
            do {
                let count = try await reocrTodayMP4()
                print("[re-ocr-mp4] done. updated \(count) frame(s)")
                exit(0)
            } catch {
                fputs("[re-ocr-mp4] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    private static func reocrToday() async throws -> Int {
        // 1. 打开 DB
        let dbPath = NSString(string: "~/.portrait/portrait.sqlite").expandingTildeInPath
        // 注册 foundation_icu 分词器 —— UPDATE frames 触发的 frames_fts 同步触发器
        // 就能正常分词,不必再 drop/recreate 触发器(那会留下索引过时 + 中断时触发器
        // 永久消失、连累主 app 搜索的坑)。
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let dbPool = try DatabasePool(path: dbPath, configuration: config)

        // 2. 查 jpg-alive 的今日 Google Doc Safari 帧
        struct FrameTodo: Sendable {
            let id: Int64
            let path: String
        }
        let todos: [FrameTodo] = try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, snapshot_path FROM frames
                WHERE app_name = 'Safari'
                  AND browser_url LIKE '%docs.google%'
                  AND date(timestamp_ms / 1000, 'unixepoch', 'localtime') = date('now', 'localtime')
                  AND snapshot_path IS NOT NULL
                ORDER BY timestamp_ms
                """).compactMap { row in
                guard let id = row["id"] as Int64?,
                      let path = row["snapshot_path"] as String? else { return nil }
                return FrameTodo(id: id, path: path)
            }
        }
        print("[re-ocr] \(todos.count) frame(s) to re-OCR")

        let langs = ["zh-Hans", "zh-Hant", "en-US"]

        var updated = 0
        for (idx, todo) in todos.enumerated() {
            guard let image = loadCGImage(at: todo.path) else {
                fputs("[re-ocr] frame \(todo.id): cannot load \(todo.path)\n", stderr)
                continue
            }
            do {
                let (fullText, wordsJson) = try await ocr(image: image, languages: langs)
                try await dbPool.write { db in
                    try db.execute(
                        sql: """
                            UPDATE frames
                            SET full_text = :t, ocr_words_json = :w, text_source = 'ocr'
                            WHERE id = :id
                            """,
                        arguments: ["t": fullText, "w": wordsJson, "id": todo.id]
                    )
                }
                updated += 1
                if (idx + 1) % 20 == 0 || idx == todos.count - 1 {
                    print("[re-ocr] \(idx + 1)/\(todos.count) done")
                }
            } catch {
                fputs("[re-ocr] frame \(todo.id): \(error.localizedDescription)\n", stderr)
            }
        }

        return updated
    }

    private struct MP4Todo: Sendable {
        let id: Int64
        let videoPath: String
        let offsetMs: Int64
    }

    private static func reocrTodayMP4() async throws -> Int {
        let dbPath = NSString(string: "~/.portrait/portrait.sqlite").expandingTildeInPath
        // 注册 foundation_icu 分词器(同 reocrToday),frames_fts 同步触发器照常分词,
        // 无需 drop/recreate 触发器。
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let dbPool = try DatabasePool(path: dbPath, configuration: config)

        // 今日 Google Doc 的 MP4 帧 + 视频路径 + offset,按视频文件分组
        let todos: [MP4Todo] = try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id AS id, v.file_path AS path, f.offset_ms AS off
                FROM frames f JOIN video_chunks v ON v.id = f.video_chunk_id
                WHERE f.app_name = 'Safari'
                  AND f.browser_url LIKE '%docs.google%'
                  AND date(f.timestamp_ms / 1000, 'unixepoch', 'localtime') = date('now', 'localtime')
                  AND f.video_chunk_id IS NOT NULL
                  AND f.offset_ms IS NOT NULL
                ORDER BY v.file_path, f.offset_ms
                """).compactMap { row in
                guard let id = row["id"] as Int64?,
                      let path = row["path"] as String?,
                      let off = row["off"] as Int64? else { return nil }
                return MP4Todo(id: id, videoPath: path, offsetMs: off)
            }
        }
        print("[re-ocr-mp4] \(todos.count) MP4 frame(s) to re-OCR")

        let langs = ["zh-Hans", "zh-Hant", "en-US"]
        let root = NSString(string: "~/.portrait").expandingTildeInPath

        // 按视频文件分组,一个 asset 抽多帧(省去反复开文件)
        let byVideo = Dictionary(grouping: todos) { $0.videoPath }
        var updated = 0
        var done = 0
        for (relPath, group) in byVideo {
            let abs = (relPath as NSString).isAbsolutePath
                ? relPath : (root as NSString).appendingPathComponent(relPath)
            let asset = AVURLAsset(url: URL(fileURLWithPath: abs))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(value: 500, timescale: 1000)
            gen.requestedTimeToleranceAfter = CMTime(value: 500, timescale: 1000)
            for todo in group {
                done += 1
                let time = CMTime(value: todo.offsetMs, timescale: 1000)
                guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else {
                    fputs("[re-ocr-mp4] frame \(todo.id): extract failed @\(todo.offsetMs)ms\n", stderr)
                    continue
                }
                do {
                    let (fullText, wordsJson) = try await ocr(image: cg, languages: langs)
                    try await dbPool.write { db in
                        try db.execute(sql: """
                            UPDATE frames SET full_text = :t, ocr_words_json = :w, text_source = 'ocr'
                            WHERE id = :id
                            """, arguments: ["t": fullText, "w": wordsJson, "id": todo.id])
                    }
                    updated += 1
                } catch {
                    fputs("[re-ocr-mp4] frame \(todo.id): ocr failed: \(error.localizedDescription)\n", stderr)
                }
                if done % 25 == 0 || done == todos.count {
                    print("[re-ocr-mp4] \(done)/\(todos.count) done")
                }
            }
        }
        return updated
    }

    /// snapshot_path 在 DB 里以 ~/.portrait/ 为根的相对路径存。
    private static func loadCGImage(at path: String) -> CGImage? {
        let root = NSString(string: "~/.portrait").expandingTildeInPath
        let abs = (path as NSString).isAbsolutePath
            ? path
            : (root as NSString).appendingPathComponent(path)
        let url = URL(fileURLWithPath: abs)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func ocr(image: CGImage, languages: [String]) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        let req = VNRecognizeTextRequest()
                        req.recognitionLanguages = languages
                        req.usesLanguageCorrection = false
                        req.recognitionLevel = .accurate
                        let handler = VNImageRequestHandler(cgImage: image, options: [:])
                        try handler.perform([req])
                        let observations = req.results ?? []
                        var parts: [String] = []
                        var words: [[String: Any]] = []
                        for obs in observations {
                            guard let cand = obs.topCandidates(1).first else { continue }
                            let t = cand.string
                            if t.isEmpty { continue }
                            parts.append(t)
                            // 词级 bbox:按空白拆,逐词查 boundingBox
                            var idx = t.startIndex
                            while idx < t.endIndex {
                                while idx < t.endIndex, t[idx].isWhitespace { idx = t.index(after: idx) }
                                guard idx < t.endIndex else { break }
                                let start = idx
                                while idx < t.endIndex, !t[idx].isWhitespace { idx = t.index(after: idx) }
                                let range = start..<idx
                                guard let rect = try? cand.boundingBox(for: range)?.boundingBox else { continue }
                                let top = 1.0 - Double(rect.origin.y) - Double(rect.size.height)
                                words.append([
                                    "text": String(t[range]),
                                    "left": Double(rect.origin.x),
                                    "top": top,
                                    "width": Double(rect.size.width),
                                    "height": Double(rect.size.height),
                                    "confidence": Double(cand.confidence)
                                ])
                            }
                        }
                        let merged = parts.joined(separator: " ")
                        let cleaned = merged.replacingOccurrences(
                            of: "[0-9]{30,}", with: " ", options: .regularExpression
                        )
                        let wordsJson: String = {
                            guard let data = try? JSONSerialization.data(withJSONObject: words),
                                  let s = String(data: data, encoding: .utf8) else { return "[]" }
                            return s
                        }()
                        cont.resume(returning: (cleaned, wordsJson))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}
