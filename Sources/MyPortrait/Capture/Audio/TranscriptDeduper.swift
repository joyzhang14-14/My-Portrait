import Foundation

/// 跨通道转录去重 —— 解决「外放通话」场景的双份转录。
///
/// 不戴耳机外放时,对方的声音从扬声器出来:系统音频(system_loopback)
/// 数字直录一份,同时被麦克风(default_microphone)隔空拾取再录一份 ——
/// 同一句话在 audio_transcriptions 出现两行(声纹还都识别为同一人)。
///
/// 判定规则(三道门,全过才算重复):
///   1. 跨通道:只比较 mic 段 vs loopback 段(同通道内不去重,调用方保证)。
///   2. 时间窗:两段绝对时间区间 ±slackMs 内有重叠(声学路径几乎零延迟,
///      但两路 VAD 独立分段,边界可差几秒)。
///   3. 文本近似:拼音归一化后「包含」或编辑距离相似。两路 Whisper 输出
///      常繁简不一致(「現在」vs「现在」码点全不同),用 Foundation 自带的
///      Han→Latin 变换统一成拼音再比 —— 繁简同音自动归一,不引入转换表。
///
/// 额外保护:两段说话人都识别出来且**不同** → 直接判不重复(我和对方在
/// 几秒内说了同样的短语时,跨通道 + 同文本 + 不同人不是回录)。
///
/// 重复时**保留 loopback 份、丢 mic 份**:loopback 是数字信号直录;mic 那份
/// 经过扬声器失真 + 房间混响,误识明显更多(实测同句 mic 份质量更差)。
enum TranscriptDeduper {

    /// 时间窗余量(ms)。两路 VAD 边界差实测 1-2s,留 5s。
    static let slackMs: Int64 = 5_000
    /// VADRecorder 段长上限(maxSegmentSeconds = 60)对应的 ms。对侧 chunk
    /// 最多比本段早开始 60s 仍含重叠段。
    static let maxSegmentMs: Int64 = 60_000
    /// 查对侧候选时按 chunk recorded_at_ms 往前多看的范围。
    static let lookbackMs: Int64 = maxSegmentMs + slackMs
    /// 编辑距离相似度阈值(1 - 距离/较长串长度)。
    static let similarityThreshold: Double = 0.75
    /// 归一化后短于此长度的文本只接受完全相等(防 "en" 之类误命中包含)。
    static let minContainmentLength = 4

    /// 一段转录的去重视图(绝对时间,ms)。`norm` 在构造时算一次,
    /// 避免批量配对时反复跑拼音变换。
    struct Segment: Sendable {
        let id: Int64?          // DB 行 id(已落库的候选有;新段为 nil)
        let absStartMs: Int64
        let absEndMs: Int64
        let speakerId: Int?
        let norm: String        // normalize(text) 产物

        init(id: Int64?, absStartMs: Int64, absEndMs: Int64, speakerId: Int?, text: String) {
            self.id = id
            self.absStartMs = absStartMs
            self.absEndMs = absEndMs
            self.speakerId = speakerId
            self.norm = TranscriptDeduper.normalize(text)
        }
    }

    /// 拼音归一化:汉字→拼音(繁简同音归一)→去声调→小写→只留字母数字。
    static func normalize(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(String.UnicodeScalarView(
            plain.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    /// 两段是否判定为同一句话(调用方保证两段来自不同通道)。
    static func isDuplicate(_ a: Segment, _ b: Segment) -> Bool {
        // 说话人都识别出来且不同 → 不是回录。
        if let sa = a.speakerId, let sb = b.speakerId, sa != sb { return false }
        // 时间窗:±slack 内有重叠(先比时间,最便宜,挡掉绝大多数配对)。
        guard a.absStartMs - slackMs <= b.absEndMs, b.absStartMs - slackMs <= a.absEndMs else {
            return false
        }
        return textsSimilar(a.norm, b.norm)
    }

    /// 归一化文本近似:全等、包含(有长度门槛)或编辑距离相似度 ≥ 阈值。
    static func textsSimilar(_ na: String, _ nb: String) -> Bool {
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let (short, long) = na.count <= nb.count ? (na, nb) : (nb, na)
        // 太短的文本(「嗯」→ "n")只认上面的全等,包含/编辑距离都易误命中。
        guard short.count >= minContainmentLength else { return false }
        // 包含:两路 VAD 分段边界不同,一侧常是另一侧的子句
        //(mic「迪安福是嗎他這個是」⊇ loopback「是吗他这个是」)。
        if long.contains(short) { return true }
        // 编辑距离(Levenshtein):截 400 字符防极端长段 O(n²) 失控。
        let ca = Array(na.unicodeScalars.prefix(400))
        let cb = Array(nb.unicodeScalars.prefix(400))
        let dist = levenshtein(ca, cb)
        let sim = 1.0 - Double(dist) / Double(max(ca.count, cb.count))
        return sim >= similarityThreshold
    }

    /// 批量版(历史清理用):返回 mic 段里与任一 loopback 段重复的行 id。
    /// 内部按 absStartMs 排序 + 滑动下界,避免全配对 O(n·m)。
    static func duplicateMicIds(mic: [Segment], loopback: [Segment]) -> [Int64] {
        guard !mic.isEmpty, !loopback.isEmpty else { return [] }
        let micSorted = mic.sorted { $0.absStartMs < $1.absStartMs }
        let loopSorted = loopback.sorted { $0.absStartMs < $1.absStartMs }
        var ids: [Int64] = []
        var lo = 0
        for m in micSorted {
            // loopback 段长 ≤ maxSegmentMs:开始时间早于这个下界的不可能再重叠。
            while lo < loopSorted.count,
                  loopSorted[lo].absStartMs < m.absStartMs - slackMs - maxSegmentMs {
                lo += 1
            }
            var j = lo
            while j < loopSorted.count, loopSorted[j].absStartMs <= m.absEndMs + slackMs {
                if isDuplicate(m, loopSorted[j]) {
                    if let id = m.id { ids.append(id) }
                    break
                }
                j += 1
            }
        }
        return ids
    }

    /// 经典两行 DP。
    private static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
