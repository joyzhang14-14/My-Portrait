import Foundation
import GRDB
import os.log

/// `frames.ocr_words_json` / `ocr_backfill_words` 的小数只留 5 位(10-25 update)。
///
/// 词框坐标是 0–1 的比例,Vision 给的 Double 带 16–17 位小数,占了这两列大半体积。
/// 5 位 = 万分之 0.1 屏,3024 px 宽的屏上最大误差 0.02 px;实测(17 万词)只省到
/// 4 位也只多省 3 个百分点,而读词框的阈值(同行 0.008、锚点 0.02 分格)翻转多 3–10 倍。
///
/// - 新帧:`PortraitDBImpl.encodeOCRFields` 写库前过 `rounded(_:)`。
/// - 旧帧:`run(dbPool:)` 后台按 id 分批改写一遍,进度存 `ocr_words_slim_state`,
///   中途退出下次接着跑,跑完不再动。只改数字,字段名、字段类型(Screenpipe 导入那批
///   坐标是字符串 `"0.0537…"`,改完仍是字符串)和文字一律不变,下游 `json.loads` 照读。
///
/// ⚠️ 只改这两列,不碰 `full_text` —— frames_fts 的 AU 触发器只盯 app_name /
/// window_name / browser_url / full_text,这里的 UPDATE 不会触发重建索引。
/// 省下的页留在库文件里给新帧复用,文件本身要 VACUUM 才变小。
enum OCRWordsSlimmer {

    static let decimals = 5
    private static let scale = 1e5
    private static let batch = 200
    private static let log = Logger(subsystem: "com.myportrait.db", category: "ocr-words-slim")

    static func round(_ v: Double) -> Double { (v * scale).rounded() / scale }

    static func rounded(_ w: OCRWord) -> OCRWord {
        OCRWord(text: w.text, left: round(w.left), top: round(w.top), width: round(w.width),
                height: round(w.height), confidence: round(w.confidence))
    }

    /// 旧行改写。数字(含字符串形式的小数)截到 5 位;没有可截的或解析不了 → nil(原样留着)。
    static func slim(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        var changed = false
        let out = v.slimmed(&changed)
        guard changed, let enc = try? JSONEncoder().encode(out) else { return nil }
        return String(data: enc, encoding: .utf8)
    }

    /// 后台把旧帧改写一遍。幂等:进度表记着最后一个处理完的 id,跑完记 done。
    static func run(dbPool: DatabasePool) async {
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS ocr_words_slim_state (
                        id INTEGER PRIMARY KEY CHECK (id = 1), last_id INTEGER NOT NULL, done INTEGER NOT NULL)
                    """)
                try db.execute(sql: "INSERT OR IGNORE INTO ocr_words_slim_state (id, last_id, done) VALUES (1, 0, 0)")
            }
            guard let start = try await dbPool.read({ db in
                try Row.fetchOne(db, sql: "SELECT last_id, done FROM ocr_words_slim_state WHERE id = 1")
            }), (start["done"] as Int64) == 0 else { return }
            // 新代码写进来的帧已经是 5 位,只需改写到开跑时的最大 id。
            let end = try await dbPool.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM frames") ?? 0
            }
            var last: Int64 = start["last_id"]
            var rewritten = 0
            log.notice("start: frames \(last, privacy: .public)…\(end, privacy: .public)")
            while last < end, !Task.isCancelled {
                let from = last
                let rows: [(Int64, String?, String?)] = try await dbPool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT id, ocr_words_json, ocr_backfill_words FROM frames
                        WHERE id > :last AND id <= :end ORDER BY id LIMIT :n
                        """, arguments: ["last": from, "end": end, "n": Int64(batch)])
                        .map { ($0["id"], $0["ocr_words_json"], $0["ocr_backfill_words"]) }
                }
                guard let tail = rows.last?.0 else { last = end; break }
                let updates: [(Int64, String?, String?)] = rows.compactMap { id, words, backfill in
                    let w = words.flatMap(slim)
                    let b = backfill.flatMap(slim)
                    return (w == nil && b == nil) ? nil : (id, w, b)
                }
                try await dbPool.write { db in
                    for (id, w, b) in updates {
                        try db.execute(sql: """
                            UPDATE frames SET ocr_words_json = COALESCE(:w, ocr_words_json),
                                              ocr_backfill_words = COALESCE(:b, ocr_backfill_words)
                            WHERE id = :id
                            """, arguments: ["w": w, "b": b, "id": id])
                    }
                    try db.execute(sql: "UPDATE ocr_words_slim_state SET last_id = :id WHERE id = 1",
                                   arguments: ["id": tail])
                }
                rewritten += updates.count
                last = tail
                try await Task.sleep(nanoseconds: 50_000_000)   // 让开采集的写锁
            }
            if last >= end {
                try await dbPool.write { db in
                    try db.execute(sql: "UPDATE ocr_words_slim_state SET done = 1 WHERE id = 1")
                }
                log.notice("done: rewrote \(rewritten, privacy: .public) frames this run")
            }
        } catch {
            log.warning("stopped: \(String(describing: error), privacy: .public)")
        }
    }
}

/// 只为改写数字而解析的通用 JSON 值。Int 先于 Double 解,`1` 不会变成 `1.0`。
private enum JSONValue: Codable {
    case bool(Bool), int(Int64), double(Double), string(String), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// 数字截 5 位;对象里**坐标类字段**的字符串小数也截(Screenpipe 那批),词文本不动。
    func slimmed(_ changed: inout Bool) -> JSONValue {
        switch self {
        case .double(let v):
            let r = OCRWordsSlimmer.round(v)
            if r != v { changed = true }
            return .double(r)
        case .array(let a):
            return .array(a.map { $0.slimmed(&changed) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if case .string(let s) = v, Self.numericKeys.contains(k), s.contains("."), let d = Double(s) {
                    let r = String(OCRWordsSlimmer.round(d))
                    if r != s { changed = true }
                    out[k] = .string(r)
                } else {
                    out[k] = v.slimmed(&changed)
                }
            }
            return .object(out)
        default:
            return self
        }
    }

    private static let numericKeys: Set<String> = ["left", "top", "width", "height", "confidence", "conf"]
}
