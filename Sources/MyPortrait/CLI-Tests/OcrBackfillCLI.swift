import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Vision

/// 存量帧 OCR 补跑(2026-08-04,用户裁定"不信 AX、不硬编码 app 名单,一起走 OCR")。
///
/// 2026-08-04 之前 `OCRService.recognize` 有 AX 快路:非终端非浏览器 app 只要 AX 文本
/// ≥20 字就直接当 `full_text`,跳过 Vision。实测该假设在多数 app 上不成立 —— 同 app
/// 下 AX 长度 ÷ OCR 长度:Obsidian 0.06x / 微信 0.06x / Spotify 0.04x / Xcode 0.10x /
/// Preview 0.20x,AX 只给控件名(navigator/debug bar),正文一个字读不到。
/// 快路已移除;本 CLI 补存量的 **54,899 个 ax 帧 + 25,086 个无文字帧**。
///
/// ⚠️ **只写 `ocr_backfill_text` / `ocr_backfill_words`(Schema v43),不碰
/// `full_text`/`text_source`/`ocr_words_json`** —— WritingCaptureStore 依赖
/// `text_source=='ax'` 的语义(ChromeFilter 只对 ocr 帧过滤、统计 ax 帧数),覆盖会
/// 改变写作采集行为。读侧 `TimelineDB.ocrText()` 已改 COALESCE 优先补跑列。
///
/// 走 GRDB DatabasePool 并注册 FoundationTokenizer:UPDATE frames 会触发 frames_fts
/// 同步触发器,裸 sqlite3 写会因分词器缺失报错回滚(与 ReOcrCLI 同一坑)。
///
/// 用法:`swift run MyPortrait --ocr-backfill [--limit N] [--day YYYY-MM-DD]`
enum OcrBackfillCLI {

    static func run(limit: Int?, day: String?) {
        Task {
            do {
                let n = try await backfill(limit: limit, day: day)
                print("[ocr-backfill] done. updated \(n) frame(s)")
                exit(0)
            } catch {
                fputs("[ocr-backfill] ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    private struct Todo: Sendable {
        let id: Int64
        let snapshotPath: String?
        let videoPath: String?
        let offsetMs: Int64
    }

    private static func backfill(limit: Int?, day: String?) async throws -> Int {
        let dbPath = NSString(string: "~/.portrait/portrait.sqlite").expandingTildeInPath
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
        let dbPool = try DatabasePool(path: dbPath, configuration: config)
        // CLI 不经过 PortraitDBImpl.init,schema 可能还停在旧版本(v43 的补跑列
        // 是本次新增)。migrator 幂等,已迁移过就是空操作。
        try DBSchema.migrator().migrate(dbPool)
        let root = NSString(string: "~/.portrait").expandingTildeInPath

        let range = day.flatMap(utcDayRange)
        let dayClause = range == nil ? "" : "AND f.timestamp_ms >= :s AND f.timestamp_ms < :e"
        let sqlArgs: StatementArguments = range.map {
            ["s": $0.0, "e": $0.1]           // dict 形式(CLAUDE.md 铁律,数组字面量会偶发死锁)
        } ?? StatementArguments()
        let limitClause = limit.map { "LIMIT \($0)" } ?? ""

        let todos: [Todo] = try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.snapshot_path, vc.file_path AS vpath,
                       COALESCE(f.offset_ms, 0) AS off
                FROM frames f
                LEFT JOIN video_chunks vc ON f.video_chunk_id = vc.id
                WHERE f.ocr_backfill_text IS NULL
                  AND (f.text_source IS NULL OR f.text_source <> 'ocr')
                  AND (f.snapshot_path IS NOT NULL OR vc.file_path IS NOT NULL)
                  \(dayClause)
                ORDER BY f.id
                \(limitClause)
                """, arguments: sqlArgs)
                .map { Todo(id: $0["id"], snapshotPath: $0["snapshot_path"],
                            videoPath: $0["vpath"], offsetMs: $0["off"]) }
        }
        print("[ocr-backfill] todo \(todos.count) frame(s)")

        var done = 0
        for (i, t) in todos.enumerated() {
            guard let image = try? await loadImage(t, root: root) else { continue }
            guard let (text, words) = try? await ocr(image: image) else { continue }
            try await dbPool.write { db in
                try db.execute(sql: """
                    UPDATE frames
                       SET ocr_backfill_text = :t, ocr_backfill_words = :w
                     WHERE id = :id
                    """, arguments: ["t": text, "w": words, "id": t.id])
            }
            done += 1
            if (i + 1) % 200 == 0 {
                print("[ocr-backfill] \(i + 1)/\(todos.count) updated=\(done)")
            }
        }
        return done
    }

    private static func utcDayRange(_ day: String) -> (Int64, Int64)? {
        let fm = DateFormatter()
        fm.dateFormat = "yyyy-MM-dd"
        fm.timeZone = TimeZone(identifier: "UTC")
        guard let d = fm.date(from: day) else { return nil }
        let s = Int64(d.timeIntervalSince1970 * 1000)
        return (s, s + 86_400_000)
    }

    private static func loadImage(_ t: Todo, root: String) async throws -> CGImage? {
        if let p = t.snapshotPath {
            let abs = (p as NSString).isAbsolutePath
                ? p : (root as NSString).appendingPathComponent(p)
            if FileManager.default.fileExists(atPath: abs),
               let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: abs) as CFURL, nil) {
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
        }
        guard let v = t.videoPath else { return nil }
        let abs = (v as NSString).isAbsolutePath
            ? v : (root as NSString).appendingPathComponent(v)
        guard FileManager.default.fileExists(atPath: abs) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: abs))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(value: CMTimeValue(max(0, t.offsetMs)), timescale: 1000)
        return try? await gen.image(at: time).image
    }

    /// Vision OCR。参数与 `OCRService.performOCR` 逐字一致(accurate / 无语言校正 /
    /// zh-Hans+zh-Hant+en-US),words_json 结构一致(左上原点、词级 bbox)。
    private static func ocr(image: CGImage) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String), Error>) in
            DispatchQueue.global(qos: .utility).async {
                autoreleasepool {
                    do {
                        let req = VNRecognizeTextRequest()
                        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                        req.usesLanguageCorrection = false
                        req.recognitionLevel = .accurate
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
                        var parts: [String] = []
                        var words: [[String: Any]] = []
                        for obs in req.results ?? [] {
                            guard let cand = obs.topCandidates(1).first else { continue }
                            let t = cand.string
                            if t.isEmpty { continue }
                            parts.append(t)
                            var idx = t.startIndex
                            while idx < t.endIndex {
                                while idx < t.endIndex, t[idx].isWhitespace { idx = t.index(after: idx) }
                                guard idx < t.endIndex else { break }
                                let start = idx
                                while idx < t.endIndex, !t[idx].isWhitespace { idx = t.index(after: idx) }
                                let range = start..<idx
                                guard let rect = try? cand.boundingBox(for: range)?.boundingBox else { continue }
                                words.append([
                                    "text": String(t[range]),
                                    "left": Double(rect.origin.x),
                                    "top": 1.0 - Double(rect.origin.y) - Double(rect.size.height),
                                    "width": Double(rect.size.width),
                                    "height": Double(rect.size.height),
                                    "confidence": Double(cand.confidence),
                                ])
                            }
                        }
                        let merged = parts.joined(separator: " ")
                            .replacingOccurrences(of: "[0-9]{30,}", with: " ",
                                                  options: .regularExpression)
                        let wj = String(data: try JSONSerialization.data(withJSONObject: words),
                                        encoding: .utf8) ?? "[]"
                        cont.resume(returning: (merged, wj))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}
