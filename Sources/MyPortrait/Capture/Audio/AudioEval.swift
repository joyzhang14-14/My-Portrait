import Foundation

/// 转录 / 说话人分离的离线评估指标。复刻 screenpipe-audio-eval。
///
///   - WER / CER：基于 Levenshtein 编辑距离的词 / 字符错误率。
///   - DER：说话人分离错误率 = (误检 + 漏检 + 说话人错配) / 总语音时长，
///     时间轴离散成 10ms 帧（pyannote / dscore 的惯例）。
///
/// 纯函数，无副作用 —— 给回归测试当基准（见 AudioEvalTests）。
enum AudioEval {

    // MARK: - WER / CER

    /// 词错误率 = 词级编辑距离 / 参考词数。
    static func wer(reference: String, hypothesis: String) -> Float {
        let r = normalize(reference).split(separator: " ").map(String.init)
        let h = normalize(hypothesis).split(separator: " ").map(String.init)
        if r.isEmpty { return h.isEmpty ? 0 : 1 }
        return Float(levenshtein(r, h)) / Float(r.count)
    }

    /// 字符错误率 = 字符级编辑距离 / 参考字符数。
    static func cer(reference: String, hypothesis: String) -> Float {
        let r = Array(normalize(reference))
        let h = Array(normalize(hypothesis))
        if r.isEmpty { return h.isEmpty ? 0 : 1 }
        return Float(levenshtein(r, h)) / Float(r.count)
    }

    /// 归一化：小写、去掉除 ASCII 撇号外的非字母数字字符、折叠空白。
    static func normalize(_ s: String) -> String {
        var buf = ""
        var lastSpace = true
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "'" {
                buf.append(ch)
                lastSpace = false
            } else if ch.isWhitespace, !lastSpace {
                buf.append(" ")
                lastSpace = true
            }
        }
        return buf.trimmingCharacters(in: .whitespaces)
    }

    /// Levenshtein 编辑距离（双行 DP，O(min) 内存）。
    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let (x, y) = a.count < b.count ? (b, a) : (a, b)
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    // MARK: - DER

    /// 一段带说话人标签的语音区间（秒）。
    struct EvalSegment: Sendable {
        let start: Double
        let duration: Double
        let speaker: String
        var end: Double { start + duration }
    }

    struct DERScore: Sendable, Equatable {
        let der: Double
        let falseAlarmRate: Double
        let missedDetectionRate: Double
        let speakerErrorRate: Double
        let totalSpeechSeconds: Double
    }

    private static let frameSecs = 0.01
    /// 写进「无说话人」帧的哨兵标签（不会和真实说话人名冲突）。
    private static let silence = "\u{0}<silence>"

    /// 说话人分离错误率。`reference` / `hypothesis` 是带标签的语音区间列表。
    static func der(reference: [EvalSegment], hypothesis: [EvalSegment]) -> DERScore {
        let totalEnd = (reference + hypothesis).map(\.end).max() ?? 0
        guard totalEnd > 0 else {
            return DERScore(der: 0, falseAlarmRate: 0, missedDetectionRate: 0,
                            speakerErrorRate: 0, totalSpeechSeconds: 0)
        }
        let nFrames = Int((totalEnd / frameSecs).rounded(.up)) + 1
        let refFrames = renderFrames(reference, nFrames)
        let hypRaw = renderFrames(hypothesis, nFrames)
        // 把 hypothesis 的标签贪心映射到 reference 的标签（避开匈牙利算法）。
        let mapping = greedyMapping(refFrames, hypRaw)
        let hypFrames = hypRaw.map { mapping[$0] ?? $0 }

        var totalSpeech = 0, falseAlarm = 0, missed = 0, speakerError = 0
        for i in 0..<nFrames {
            let r = refFrames[i], h = hypFrames[i]
            let rSpeech = r != silence, hSpeech = h != silence
            if rSpeech { totalSpeech += 1 }
            switch (rSpeech, hSpeech) {
            case (false, true): falseAlarm += 1
            case (true, false): missed += 1
            case (true, true) where r != h: speakerError += 1
            default: break
            }
        }
        guard totalSpeech > 0 else {
            return DERScore(der: 0, falseAlarmRate: 0, missedDetectionRate: 0,
                            speakerErrorRate: 0, totalSpeechSeconds: 0)
        }
        let denom = Double(totalSpeech)
        return DERScore(
            der: Double(falseAlarm + missed + speakerError) / denom,
            falseAlarmRate: Double(falseAlarm) / denom,
            missedDetectionRate: Double(missed) / denom,
            speakerErrorRate: Double(speakerError) / denom,
            totalSpeechSeconds: denom * frameSecs
        )
    }

    private static func renderFrames(_ segs: [EvalSegment], _ n: Int) -> [String] {
        var frames = [String](repeating: silence, count: n)
        for seg in segs {
            let s = max(0, Int((seg.start / frameSecs).rounded(.down)))
            let e = min(n, Int((seg.end / frameSecs).rounded(.up)))
            if s < e { for i in s..<e { frames[i] = seg.speaker } }
        }
        return frames
    }

    /// 贪心 1-对-1：按重叠帧数降序，把每个 hyp 标签分配给重叠最多且未被占的 ref 标签。
    private static func greedyMapping(_ reference: [String], _ hypothesis: [String]) -> [String: String] {
        var overlap: [String: [String: Int]] = [:]    // h -> r -> 帧数
        for i in 0..<min(reference.count, hypothesis.count) {
            let r = reference[i], h = hypothesis[i]
            if r == silence || h == silence { continue }
            overlap[h, default: [:]][r, default: 0] += 1
        }
        var pairs: [(h: String, r: String, count: Int)] = []
        for (h, rs) in overlap { for (r, c) in rs { pairs.append((h, r, c)) } }
        pairs.sort { $0.count > $1.count }

        var hypToRef: [String: String] = [:]
        var claimed = Set<String>()
        for p in pairs where hypToRef[p.h] == nil && !claimed.contains(p.r) {
            hypToRef[p.h] = p.r
            claimed.insert(p.r)
        }
        return hypToRef
    }
}
