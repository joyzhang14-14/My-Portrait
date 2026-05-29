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

    private static func reocrToday() async throws -> Int {
        // 1. 打开 DB
        let dbPath = NSString(string: "~/.portrait/portrait.sqlite").expandingTildeInPath
        let dbPool = try DatabasePool(path: dbPath)

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

        // 3. 临时 DROP FTS update trigger(避免 foundation_icu tokenizer 在
        //    sqlite3 CLI 上下文里找不到 —— 这里用 GRDB 直连也一样需要)。
        //    SwiftPM 这边没注册 FoundationTokenizer。
        try await dbPool.write { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS __frames_fts_au")
        }

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

        // 4. 重建 FTS update trigger(跟 schema 一致)
        try await dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER __frames_fts_au AFTER UPDATE ON "frames" BEGIN
                  INSERT INTO "frames_fts"("frames_fts", "rowid", "app_name", "window_name", "browser_url", "full_text") VALUES('delete', OLD."rowid", OLD."app_name", OLD."window_name", OLD."browser_url", OLD."full_text");
                  INSERT INTO "frames_fts"("rowid", "app_name", "window_name", "browser_url", "full_text") VALUES (NEW."rowid", NEW."app_name", NEW."window_name", NEW."browser_url", NEW."full_text");
                END
                """)
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
