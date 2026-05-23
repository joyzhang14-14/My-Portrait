import Foundation

/// 写作采集 Step 0 —— 算法预压缩(非 LLM)。
///
/// 输入:一个 UTC 日期的 raw(typing_events + keystroke_log + frames)
/// 输出:`WritingCaptureStep0Output`(raw_sessions + throwaway + merge_candidates)
///
/// 算法:
/// 1. 切 session(idle > 5min / app 切 / url 切)
/// 2. 每 session 内 OCR Jaccard dedupe(> 95% 相似度合并)
/// 3. throwaway 短内容过滤(总字数 < 20 丢)
/// 4. Pass 2 合并候选集(同 app + url + 间隔 < 30min 一组)
///
/// 纯函数 + 静态方法,便于单测。
///
/// 详见 `canvas-editor-capture-design-final.md` §3.3 Step 0。
struct WritingCaptureStep0 {

    // MARK: - 参数

    /// 键盘 idle 超过这个时长就切 session
    static let idleThresholdMs: Int64 = 5 * 60 * 1000
    /// Pass 2 合并候选:同 app + url + 间隔小于这个的相邻 session 算一组
    static let mergeWindowMs: Int64 = 30 * 60 * 1000
    /// throwaway 最小字数
    static let throwawayMinChars = 20
    /// OCR Jaccard 相似度阈值
    static let ocrJaccardThreshold = 0.95
    /// throwaway preview 截断长度
    static let throwawayPreviewLen = 80

    // MARK: - 主入口

    /// 跑一遍。输入按 ts 升序。输出 sessions 也按 ts 升序。
    static func preprocess(
        typingEvents: [TypingEvent],
        keystrokes: [KeystrokeEntry],
        rawOcrFrames: [WritingCaptureRawOcr]
    ) -> WritingCaptureStep0Output {

        // 1. 切 session —— 用统一 activity timeline
        let allSessions = segmentSessions(
            typingEvents: typingEvents,
            keystrokes: keystrokes,
            ocrFrames: rawOcrFrames
        )

        // 2. throwaway 过滤
        var kept: [WritingCaptureRawSession] = []
        var thrown: [WritingCaptureThrowaway] = []
        for s in allSessions {
            if s.maxContentChars < throwawayMinChars {
                thrown.append(WritingCaptureThrowaway(
                    id: s.id,
                    app: s.app,
                    url: s.url,
                    startTs: s.startTs,
                    endTs: s.endTs,
                    chars: s.maxContentChars,
                    preview: previewText(from: s)
                ))
            } else {
                kept.append(s)
            }
        }

        // 3. Pass 2 合并候选集
        let candidates = computeMergeCandidates(kept)

        return WritingCaptureStep0Output(
            rawSessions: kept,
            throwawaySessions: thrown,
            mergeCandidates: candidates
        )
    }

    // MARK: - Session 切分

    /// 用所有 raw 事件(typing_events / keystrokes / ocr 帧)构造统一 activity
    /// 时间轴,切成 sessions。session 边界:
    ///   - idle gap > 5 min
    ///   - app 切
    ///   - url 切
    static func segmentSessions(
        typingEvents: [TypingEvent],
        keystrokes: [KeystrokeEntry],
        ocrFrames: [WritingCaptureRawOcr]
    ) -> [WritingCaptureRawSession] {

        // 构造活动点(ts, app, url)的统一时间轴。typing_events 用 startedAt,
        // OCR 帧用 tsMs,keystroke 用 tsMs。每个事件标注其 app/url。
        struct ActivityPoint {
            let ts: Int64
            let app: String
            let url: String?
        }

        var points: [ActivityPoint] = []
        for e in typingEvents {
            points.append(ActivityPoint(
                ts: e.startedAt, app: e.bundleId,
                url: e.url.isEmpty ? nil : e.url))
        }
        for k in keystrokes {
            // keystroke 不带 url,先存 nil,匹配 session 时跟 typing/OCR 的 url 对齐
            points.append(ActivityPoint(ts: k.tsMs, app: k.bundleId, url: nil))
        }
        for f in ocrFrames {
            points.append(ActivityPoint(ts: f.tsMs, app: f.app, url: f.url))
        }
        points.sort { $0.ts < $1.ts }
        guard !points.isEmpty else { return [] }

        // 走一遍切 session。
        // 注意:keystroke 没 url,会跟当前 session(若 app 一致)合并 —— 不另开新
        // session。判 url-change 时,空 url 不算"换 url",维持当前。
        struct SessionAcc {
            var app: String
            var url: String?
            var start: Int64
            var lastTs: Int64
        }

        var rawBoundaries: [SessionAcc] = []
        var cur = SessionAcc(
            app: points[0].app, url: points[0].url,
            start: points[0].ts, lastTs: points[0].ts
        )
        for p in points.dropFirst() {
            let gap = p.ts - cur.lastTs
            let appChanged = p.app != cur.app
            // url 切:p 有非空 url 且 != 当前 session 的 url
            // (p.url == nil 时不算切,因为是 keystroke 没带 url)
            let urlChanged: Bool = {
                guard let pu = p.url, !pu.isEmpty else { return false }
                return pu != (cur.url ?? "")
            }()

            if gap > idleThresholdMs || appChanged || urlChanged {
                rawBoundaries.append(cur)
                cur = SessionAcc(
                    app: p.app, url: p.url,
                    start: p.ts, lastTs: p.ts
                )
            } else {
                cur.lastTs = p.ts
                // 如果当前 session url 是 nil(从 keystroke 起头)但 p 带了 url
                // → 把 url 填上(这种情况是 typing observer 还没起来,先抓到键)
                if cur.url == nil, let pu = p.url, !pu.isEmpty {
                    cur.url = pu
                }
            }
        }
        rawBoundaries.append(cur)

        // 把每个 SessionAcc 包成完整 WritingCaptureRawSession ——
        // 按时间窗 + (app, url) 把 raw 数据归到这条 session。
        var result: [WritingCaptureRawSession] = []
        for acc in rawBoundaries {
            let id = makeSessionId(startTs: acc.start, app: acc.app)
            let sessionTyping = typingEvents.filter {
                $0.bundleId == acc.app
                    && $0.startedAt >= acc.start && $0.startedAt <= acc.lastTs
                    && urlMatch(($0.url.isEmpty ? nil : $0.url), acc.url)
            }
            let sessionKeys = keystrokes.filter {
                $0.bundleId == acc.app
                    && $0.tsMs >= acc.start && $0.tsMs <= acc.lastTs
            }
            let sessionFrames = ocrFrames.filter {
                $0.app == acc.app
                    && $0.tsMs >= acc.start && $0.tsMs <= acc.lastTs
                    && urlMatch($0.url, acc.url)
            }
            let dedupedFrames = jaccardDedupe(sessionFrames)
            let maxChars = computeMaxContentChars(
                typingEvents: sessionTyping,
                ocrFrames: dedupedFrames
            )
            result.append(WritingCaptureRawSession(
                id: id,
                app: acc.app,
                url: acc.url,
                startTs: acc.start,
                endTs: acc.lastTs,
                typingEvents: sessionTyping,
                keystrokes: sessionKeys,
                ocrFrames: dedupedFrames,
                maxContentChars: maxChars
            ))
        }
        return result
    }

    /// 一个 url 是否匹配一个 session 的 url。session url == nil 时,任意 url
    /// 都算匹配(包括 nil);session url 非空时,严格相等(或 raw 是 nil)。
    /// 用于 raw 数据归属到 session 时容错。
    private static func urlMatch(_ raw: String?, _ session: String?) -> Bool {
        guard let s = session, !s.isEmpty else { return true }
        guard let r = raw, !r.isEmpty else { return true }
        return r == s
    }

    // MARK: - OCR Jaccard dedupe(per session)

    /// 相邻两帧 Jaccard 相似度 > 95% → 合并(保留第一帧的 frameId/startTs,
    /// 把 endTs 延到后续帧)。单遍贪心。
    static func jaccardDedupe(
        _ frames: [WritingCaptureRawOcr]
    ) -> [WritingCaptureOcrFrame] {
        guard !frames.isEmpty else { return [] }
        var out: [WritingCaptureOcrFrame] = []
        var cur = WritingCaptureOcrFrame(
            frameId: frames[0].id,
            startTs: frames[0].tsMs,
            endTs: frames[0].tsMs,
            app: frames[0].app,
            url: frames[0].url,
            text: frames[0].text
        )
        var curTokens = tokenize(frames[0].text)
        for f in frames.dropFirst() {
            let fTokens = tokenize(f.text)
            let sim = jaccard(curTokens, fTokens)
            if sim > ocrJaccardThreshold {
                // 合并:延长 endTs,文本以更长的为准(canvas 滚动时新帧可能多内容)
                cur = WritingCaptureOcrFrame(
                    frameId: cur.frameId,
                    startTs: cur.startTs,
                    endTs: f.tsMs,
                    app: cur.app,
                    url: cur.url,
                    text: f.text.count > cur.text.count ? f.text : cur.text
                )
                if f.text.count > curTokens.count { curTokens = fTokens }
            } else {
                out.append(cur)
                cur = WritingCaptureOcrFrame(
                    frameId: f.id, startTs: f.tsMs, endTs: f.tsMs,
                    app: f.app, url: f.url, text: f.text
                )
                curTokens = fTokens
            }
        }
        out.append(cur)
        return out
    }

    /// 把文本切成 token set,用作 Jaccard 输入。
    /// 切分:空格 + 标点。中文按字符切(每个汉字一个 token)。
    static func tokenize(_ s: String) -> Set<String> {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 用 Unicode 字符分类拆分 —— 字母数字组连续算一个 token,中文每字一个。
        var tokens = Set<String>()
        var current = ""
        for c in trimmed {
            if c.isLetter || c.isNumber {
                if isCJK(c) {
                    if !current.isEmpty { tokens.insert(current); current = "" }
                    tokens.insert(String(c))
                } else {
                    current.append(c)
                }
            } else {
                if !current.isEmpty { tokens.insert(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.insert(current) }
        return tokens
    }

    /// 是否中日韩统一表意 + 扩展 A/B/C 等常见区段。够覆盖中文/日文汉字/韩文谚文也按
    /// 字符切——足够 dedupe 用,不追求严格分词。
    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            let v = s.value
            // 简体/繁体常见 + 韩文谚文音节 + 日文 hiragana/katakana
            return (0x3040...0x30FF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
                || (0x20000...0x2A6DF).contains(v)
        }
    }

    /// `|A ∩ B| / |A ∪ B|`。两个都空算 1.0(完全相同),一边空算 0.0。
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return Double(inter) / Double(union)
    }

    // MARK: - throwaway 字数

    /// session 总字数 = max(typing_events.text 总长, max OCR 帧 text 长)。
    /// throwaway 判定阈值。
    static func computeMaxContentChars(
        typingEvents: [TypingEvent],
        ocrFrames: [WritingCaptureOcrFrame]
    ) -> Int {
        let typingTotal = typingEvents.map { $0.text.count }.reduce(0, +)
        let ocrMax = ocrFrames.map { $0.text.count }.max() ?? 0
        return max(typingTotal, ocrMax)
    }

    /// 给 throwaway 列表的 preview。截 typing_events.text 第一段 或 第一帧 OCR
    /// 的前 80 字符。
    static func previewText(from session: WritingCaptureRawSession) -> String {
        let typingText = session.typingEvents.first?.text ?? ""
        let ocrText = session.ocrFrames.first?.text ?? ""
        let src = !typingText.isEmpty ? typingText : ocrText
        return String(src.prefix(throwawayPreviewLen))
    }

    // MARK: - Pass 2 合并候选集

    /// 同 app + 同 url + 间隔 < 30min 的相邻 session 算一组。
    /// 输入 sessions 已按 startTs 升序。
    static func computeMergeCandidates(
        _ sessions: [WritingCaptureRawSession]
    ) -> [[String]] {
        guard !sessions.isEmpty else { return [] }
        var groups: [[String]] = []
        var cur: [String] = [sessions[0].id]
        var prev = sessions[0]
        for s in sessions.dropFirst() {
            let gap = s.startTs - prev.endTs
            let sameApp = s.app == prev.app
            let sameUrl = (s.url ?? "") == (prev.url ?? "")
            if sameApp && sameUrl && gap < mergeWindowMs {
                cur.append(s.id)
            } else {
                groups.append(cur)
                cur = [s.id]
            }
            prev = s
        }
        groups.append(cur)
        return groups
    }

    // MARK: - session id

    /// 生成稳定的 session id。`sess_<6 字 hex>`,基于 (startTs, app) hash。
    private static func makeSessionId(startTs: Int64, app: String) -> String {
        var hasher = Hasher()
        hasher.combine(startTs)
        hasher.combine(app)
        let h = hasher.finalize() & 0xFFFFFF
        return String(format: "sess_%06x", h)
    }
}
