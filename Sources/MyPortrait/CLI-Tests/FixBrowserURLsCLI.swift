import Foundation
import GRDB

/// 维护 CLI:`--fix-browser-urls [--apply | --rollback]`
///
/// **用 OCR 到的地址栏修正浏览器帧的 URL / 标题。** 焦点缓存原先只在切 app 时刷新,
/// 同一个浏览器里换标签页,整段帧记的都是上一页的标题和 URL(09-08 已修采集侧,
/// 这里洗存量)。
///
/// 逐帧判定,确定性:
///   1. 在 OCR 词里只看地址栏那条水平带(Safari top 0.045–0.065,Chrome 0.08–0.11)
///      找符合 URL/域名正则的词。地址栏水平位置内(Safari 居中 / Chrome 靠左)优先,
///      带内但位置偏的要置信度 ≥ 0.5。
///   2. OCR 域名 vs 记录域名:相等 / 子串(被浮窗遮住会截断)/ 编辑距离相似度 ≥ 0.7
///      (`200m.us`≈`zoom.us`)都算一致,不动。`file://` 单独比。
///   3. 记录为空 → 填 OCR URL(标题空的一并填域名);域名不一致 → URL 换成 OCR,
///      标题换成域名(旧标题肯定也是旧页的)。
///   4. 地址栏候选域名在下方自动补全下拉里重复出现 → 地址栏还在打字,页面没跳,跳过
///      (只对 Safari 生效)。
///   5. 「正在播放」浮窗盖住地址栏中段,OCR 只读到候选的前半截(候选右侧紧挨着
///      非 URL 的词,或候选以 `/c` 截断)→ 只写域名,不写截断的路径。`file://` 不适用。
///
/// 默认 **dry-run**:打印统计 + 样例,完整清单写到
/// `~/.portrait/logs/fix-browser-urls-dryrun.tsv`。`--apply` 前把受影响行的旧值存进
/// `frames_url_fix_backup`,`--rollback` 从那张表整体还原。frames 有 FTS 触发器
/// (foundation_icu 分词器),必须经 PortraitDBImpl 的 pool 写。
enum FixBrowserURLsCLI {

    private final class ExitState: @unchecked Sendable { var code: Int32 = 0; var done = false }

    private struct Proposal {
        let id: Int64
        let app: String
        let oldTitle: String?
        let oldUrl: String?
        let newTitle: String?
        let newUrl: String
        let kind: String   // fill_empty / host_mismatch
    }

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"^(https?://)?([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?(/\S*)?$"#, options: [.caseInsensitive])
    private static let fileRegex = try! NSRegularExpression(pattern: #"^file:/"#, options: [.caseInsensitive])

    static func run(apply: Bool, rollback: Bool) {
        let state = ExitState()
        print("=== fix-browser-urls (\(rollback ? "ROLLBACK" : apply ? "APPLY" : "dry-run")) ===")
        fflush(stdout)

        let dbImpl: PortraitDBImpl
        do { dbImpl = try PortraitDBImpl() } catch { print("ERROR: open DB: \(error)"); exit(1) }
        let pool = dbImpl.dbPool

        Task.detached {
            defer { state.done = true }
            do {
                if rollback { try await doRollback(pool); return }
                let proposals = try await scan(pool)
                report(proposals)
                if apply { try await doApply(pool, proposals) }
            } catch {
                print("ERROR: \(error)"); state.code = 1
            }
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        exit(state.code)
    }

    // MARK: - 扫描

    private static func scan(_ pool: DatabasePool) async throws -> [Proposal] {
        let (proposals, stats, snapped): ([Proposal], [String: Int], Int) = try await pool.read { db in
            // 已知域名词表:所有非空 browser_url 归一化后出现 ≥3 次的域名,当作 OCR 吸附的参照。
            var knownHosts: [String: Int] = [:]
            let urlCursor = try String.fetchCursor(db, sql:
                "SELECT browser_url FROM frames WHERE browser_url IS NOT NULL AND browser_url != ''")
            while let u = try urlCursor.next() { knownHosts[host(u), default: 0] += 1 }
            knownHosts = knownHosts.filter { $0.value >= 3 }

            var proposals: [Proposal] = []
            var stats: [String: Int] = [:]
            var snapped = 0
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, app_name, window_name, browser_url,
                       COALESCE(ocr_words_json, ocr_backfill_words) AS words
                FROM frames WHERE app_name IN ('Safari', 'Google Chrome')
                """)
            while let r = try cursor.next() {
                let app: String = r["app_name"]
                let id: Int64 = r["id"]
                let title: String? = r["window_name"]
                let url: String? = r["browser_url"]
                guard let raw: String = r["words"], let words = parseWords(raw) else {
                    stats["\(app)|no_words", default: 0] += 1; continue
                }
                guard let candResult = addressCandidate(app: app, words: words) else {
                    stats["\(app)|no_candidate", default: 0] += 1; continue
                }
                var cand = normalizePunctuation(candResult.text)
                var oh = host(cand)
                if isTypingDropdown(app: app, words: words, host: oh) {
                    stats["\(app)|typing_skipped", default: 0] += 1; continue
                }
                let rh = url.flatMap(host)
                if let rh, sameHost(oh, rh) { stats["\(app)|same_host", default: 0] += 1; continue }
                let newUrl: String
                let joined = joinContinuation(app: app, words: words, cand: cand,
                                              candLeft: candResult.left, candWidth: candResult.width)
                if joined.appended > 0 { stats["\(app)|joined_continuation", default: 0] += 1 }
                cand = normalizePunctuation(joined.text)
                if oh != "file", joined.truncated {
                    stats["\(app)|overlay_truncated", default: 0] += 1
                    newUrl = "https://\(oh)/"
                } else {
                    if let snap = snapHost(oh, known: knownHosts) {
                        if let range = cand.range(of: oh, options: .caseInsensitive) {
                            cand.replaceSubrange(range, with: snap)
                        }
                        oh = snap
                        snapped += 1
                    }
                    newUrl = cand.lowercased().hasPrefix("http") || cand.lowercased().hasPrefix("file:")
                        ? cand : "https://" + cand
                }
                let kind = (url ?? "").isEmpty ? "fill_empty" : "host_mismatch"
                let newTitle: String? = kind == "host_mismatch" ? oh : ((title ?? "").isEmpty ? oh : title)
                stats["\(app)|\(kind)", default: 0] += 1
                proposals.append(Proposal(id: id, app: app, oldTitle: title, oldUrl: url,
                                          newTitle: newTitle, newUrl: newUrl, kind: kind))
            }
            return (proposals, stats, snapped)
        }
        print("\n结果                          帧数")
        for k in stats.keys.sorted() { print("\(pad(k, 30))\(stats[k]!)") }
        print("吸附了 \(snapped) 帧(OCR 域名读错,靠已知域名词表纠正)")
        return proposals
    }

    /// OCR 域名不在已知词表里时,找一个词表里的域名吸附过去:去点相等(如
    /// digitalfidelity.com≈digital.fidelity.com)或编辑距离 ≤2 且长度 ≥6(如 200m.us≈zoom.us)。
    /// 多候选取编辑距离最小,平手取出现次数最多。
    private static func snapHost(_ ocrHost: String, known: [String: Int]) -> String? {
        if known[ocrHost] != nil { return nil }
        let ocrStripped = ocrHost.replacingOccurrences(of: ".", with: "")
        var best: (host: String, dist: Int, count: Int)?
        for (kh, count) in known {
            let dotless = kh.replacingOccurrences(of: ".", with: "") == ocrStripped
            let dist = levenshtein(Array(ocrHost), Array(kh))
            guard dotless || (dist <= 2 && kh.count >= 6) else { continue }
            let d = dotless ? 0 : dist
            if best == nil || d < best!.dist || (d == best!.dist && count > best!.count) {
                best = (kh, d, count)
            }
        }
        return best?.host
    }

    /// OCR 词 JSON → (text, top, left, width, confidence)。backfill 的数字有时是字符串,一并吃。
    private static func parseWords(_ raw: String) -> [(text: String, top: Double, left: Double, width: Double, conf: Double)]? {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        return arr.compactMap { w in
            guard let t = w["text"] as? String, let top = num(w["top"]), let left = num(w["left"]) else { return nil }
            return (t, top, left, num(w["width"]) ?? 0, num(w["confidence"]) ?? 0)
        }
    }

    private static func addressBand(_ app: String) -> ClosedRange<Double> { app == "Safari" ? 0.045...0.065 : 0.08...0.11 }

    private static func addressCandidate(app: String, words: [(text: String, top: Double, left: Double, width: Double, conf: Double)]) -> (text: String, left: Double, width: Double)? {
        // 只看地址栏那一条水平带:Safari top≈0.053、Chrome ≈0.092。带外的
        // 菜单栏(0.011)、「正在播放」浮窗歌词(0.036)、标签栏(0.096)都会有像域名的词。
        let band = addressBand(app)
        let leftRange: ClosedRange<Double> = app == "Safari" ? 0.25...0.62 : 0.04...0.30
        var cands: [(inBox: Int, negConf: Double, top: Double, text: String, left: Double, width: Double)] = []
        for w in words where band.contains(w.top) {
            var t = w.text.trimmingCharacters(in: .whitespaces)
            while let last = t.last, ".,;:".contains(last) { t.removeLast() }
            guard matches(urlRegex, t) || matches(fileRegex, t) else { continue }
            cands.append((leftRange.contains(w.left) ? 0 : 1, -w.conf, w.top, t, w.left, w.width))
        }
        guard let best = cands.min(by: { ($0.inBox, $0.negConf, $0.top) < ($1.inBox, $1.negConf, $1.top) }) else { return nil }
        return best.inBox == 0 || best.negConf <= -0.5 ? (best.text, best.left, best.width) : nil
    }

    private static let urlCharsRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9\-._~:/?#@!$&'()*+,;=%|]+$"#)

    /// OCR 会把长 URL 切成两段(query 串、uuid),带空格的 file 路径也会在空格处切开。
    /// 候选右边紧挨着(间距 < 0.02)的词:只含 URL 字符 → 拼回去;file 路径 → 按空格拼
    /// (%20);是散文(空格 / 汉字,「正在播放」浮窗的歌词)→ 判定地址栏被遮挡,截断。
    private static func joinContinuation(app: String, words: [(text: String, top: Double, left: Double, width: Double, conf: Double)], cand: String, candLeft: Double, candWidth: Double) -> (text: String, appended: Int, truncated: Bool) {
        let band = addressBand(app)
        let isFile = cand.lowercased().hasPrefix("file:")
        var text = cand, right = candLeft + candWidth, appended = 0
        let sorted = words.filter { band.contains($0.top) && $0.left >= candLeft + candWidth - 0.005 }
            .sorted { $0.left < $1.left }
        for w in sorted {
            let gap = w.left - right
            if gap >= 0.02 { break }
            if gap < -0.005 { continue }
            let t = w.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if matches(urlCharsRegex, t) {
                text += t
            } else if isFile, !t.contains(" ") {
                text += "%20" + (t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? t)
            } else {
                return (text, appended, true)
            }
            appended += 1
            right = w.left + w.width
        }
        return (text, appended, false)
    }

    /// 地址栏候选域名在下方自动补全下拉里原样重复,说明地址栏还在打字、页面其实没跳
    /// (实测:候选 anthropic.com,下拉区同时有 "Start Page"——页面还停在起始页)。
    /// 只对 Safari 生效,Chrome 没找到同类证据。
    private static func isTypingDropdown(app: String, words: [(text: String, top: Double, left: Double, width: Double, conf: Double)], host oh: String) -> Bool {
        guard app == "Safari" else { return false }
        let band: ClosedRange<Double> = 0.065...0.11
        let leftRange: ClosedRange<Double> = 0.25...0.62
        for w in words where band.contains(w.top) && leftRange.contains(w.left) {
            var t = w.text.trimmingCharacters(in: .whitespaces).lowercased()
            while let last = t.last, ".,;:".contains(last) { t.removeLast() }
            if t == oh { return true }
        }
        return false
    }

    /// OCR 把 URL 里的 ASCII 标点认成全角(`？tab=rm`)、file:// 路径认出竖线
    /// (`file:/|/Users`),这里做确定性字符映射修正,不做别的猜测性改写。
    private static let fullwidthMap: [Character: Character] = [
        "？": "?", "＆": "&", "：": ":", "／": "/", "＝": "=", "＃": "#", "＋": "+"]
    private static func normalizePunctuation(_ s: String) -> String {
        var t = String(s.map { fullwidthMap[$0] ?? $0 })
        t = t.replacingOccurrences(of: "file:/|/", with: "file:///")
        while true {
            if t.hasSuffix("...") { t.removeLast(3) }
            else if let last = t.last, "|…".contains(last) { t.removeLast() }
            else { break }
        }
        return t
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 域名(去 www.);file:// 统一返回 "file"。
    private static func host(_ u: String) -> String {
        var s = u.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("file:") { return "file" }
        s = s.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        var h = s.split(whereSeparator: { "/?#:".contains($0) }).first.map(String.init)?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private static func sameHost(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a == "file" || b == "file" { return false }
        if a.contains(b) || b.contains(a) { return true }
        let d = levenshtein(Array(a), Array(b))
        return 1.0 - Double(d) / Double(max(a.count, b.count, 1)) >= 0.7
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - 报告 / 写库

    private static func report(_ proposals: [Proposal]) {
        print("\n拟改 \(proposals.count) 帧。样例(每类前 8 条):")
        for kind in ["host_mismatch", "fill_empty"] {
            for p in proposals.filter({ $0.kind == kind }).prefix(8) {
                print("  #\(p.id) \(p.app) \(kind)\n     \(p.oldUrl ?? "∅")  →  \(p.newUrl)\n     \(p.oldTitle ?? "∅")  →  \(p.newTitle ?? "∅")")
            }
        }
        let out = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portrait/logs/fix-browser-urls-dryrun.tsv")
        var tsv = "id\tapp\tkind\told_url\tnew_url\told_title\tnew_title\n"
        for p in proposals {
            tsv += [String(p.id), p.app, p.kind, p.oldUrl ?? "", p.newUrl, p.oldTitle ?? "", p.newTitle ?? ""]
                .map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") + "\n"
        }
        try? tsv.write(to: out, atomically: true, encoding: .utf8)
        print("\n完整清单:\(out.path)")
    }

    private static func doApply(_ pool: DatabasePool, _ proposals: [Proposal]) async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS frames_url_fix_backup (
                    frame_id INTEGER PRIMARY KEY, window_name TEXT, browser_url TEXT, fixed_at_ms INTEGER NOT NULL)
                """)
        }
        var done = 0
        for chunk in stride(from: 0, to: proposals.count, by: 500).map({ Array(proposals[$0..<min($0 + 500, proposals.count)]) }) {
            try await pool.write { db in
                for p in chunk {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO frames_url_fix_backup (frame_id, window_name, browser_url, fixed_at_ms)
                        VALUES (:id, :title, :url, :now)
                        """, arguments: ["id": p.id, "title": p.oldTitle, "url": p.oldUrl, "now": nowMs])
                    try db.execute(sql: "UPDATE frames SET browser_url = :url, window_name = :title WHERE id = :id",
                                   arguments: ["url": p.newUrl, "title": p.newTitle, "id": p.id])
                }
            }
            done += chunk.count
            print("  已改 \(done)/\(proposals.count)"); fflush(stdout)
        }
        print("完成。回滚:--fix-browser-urls --rollback")
    }

    private static func doRollback(_ pool: DatabasePool) async throws {
        let n = try await pool.write { db -> Int in
            let rows = try Row.fetchAll(db, sql: "SELECT frame_id, window_name, browser_url FROM frames_url_fix_backup")
            for r in rows {
                let id: Int64 = r["frame_id"]
                try db.execute(sql: "UPDATE frames SET browser_url = :url, window_name = :title WHERE id = :id",
                               arguments: ["url": r["browser_url"] as String?, "title": r["window_name"] as String?, "id": id])
            }
            try db.execute(sql: "DROP TABLE frames_url_fix_backup")
            return rows.count
        }
        print("已从备份还原 \(n) 帧,备份表已删。")
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
}
