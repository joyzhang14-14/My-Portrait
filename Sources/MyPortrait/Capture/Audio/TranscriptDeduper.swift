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
    /// 包含匹配要求的最短归一化长度(防 "en" 之类误命中)。
    static let minContainmentLength = 4
    /// 任一侧说话人为 nil 时,归一化文本必须达到这个长度才允许判重。
    /// 挡掉「嗯」("ng")「好的」("haode")「对对对」("duiduidui")这类
    /// 双方都常说的短应答 —— 它们恰好也是从不进声纹的 <2s 短段。
    static let minNormLenWhenSpeakerUncertain = 10
    /// mic 行参与「整行丢弃/删除」的时长上限(ms)。超过的多半是 diarize
    /// 退化产出的整 chunk 大段(回录 + 我自己的话混在一行),整行删会
    /// 连带丢我自己的话;只有 mic ⊂ loopback(无独有内容)豁免。
    static let maxKillableMs: Int64 = 15_000

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

    /// mic 段是否判定为 loopback 段的回录。**方向有意义**:被丢/被删的永远
    /// 是 mic 侧,所以所有"防误杀"门槛都围绕 mic 侧收紧。
    ///
    /// 防误杀的三层保护(对抗审查后收紧):
    ///   - 说话人:都识别出来且不同 → 不是回录。任一侧 **nil**(<2s 短段从
    ///     不进声纹、声纹关闭、ambiguous)→ 归一化文本必须 ≥ 10 字符才允许
    ///     判重 —— 否则戴耳机(物理上无回录)时我和对方 5s 内都说「嗯」
    ///     「好的」会被误删。
    ///   - 时长上限:mic 行超过 maxKillableMs(典型 = diarize 退化时整个
    ///     60s chunk 一条记录,回录和我自己的话混在一行)不许整行干掉 ——
    ///     唯一例外是 mic 文本**完整包含于** loopback(mic 行没有独有内容,
    ///     删了不丢任何东西)。
    ///   - 包含比例:loopback ⊂ mic 方向(mic 比 loopback 长)要求 loopback
    ///     至少占 mic 的 60% —— 防止「好的」("haode")作为子串命中长文本就
    ///     把整行带走(去声调拼音串无词边界,子串碰撞率高)。
    static func isDuplicate(mic: Segment, loopback: Segment) -> Bool {
        // 说话人都识别出来且不同 → 不是回录。
        if let sm = mic.speakerId, let sl = loopback.speakerId, sm != sl { return false }
        // 时间窗:±slack 内有重叠(先比时间,最便宜,挡掉绝大多数配对)。
        guard mic.absStartMs - slackMs <= loopback.absEndMs,
              loopback.absStartMs - slackMs <= mic.absEndMs else {
            return false
        }
        let nm = mic.norm, nl = loopback.norm
        guard !nm.isEmpty, !nl.isEmpty else { return false }

        // 说话人不确定(任一侧 nil)→ 短文本一律不判重(见上)。
        let speakerUncertain = mic.speakerId == nil || loopback.speakerId == nil
        if speakerUncertain, min(nm.count, nl.count) < minNormLenWhenSpeakerUncertain {
            return false
        }

        // 全等 / mic ⊂ loopback:mic 行没有独有内容,删了不丢东西 —— 不受
        // 时长上限约束。
        if nm == nl { return true }
        if nm.count >= minContainmentLength, nl.contains(nm) { return true }

        // 以下分支 mic 行可能含独有内容(回录 + 我自己的话混录),只允许
        // 短行参与整行判重,限制最坏情况的损失。
        guard mic.absEndMs - mic.absStartMs <= maxKillableMs else { return false }

        // loopback ⊂ mic:mic 多出来的部分通常是隔空拾取的垃圾音节
        //(「迪安福是嗎他這個是」⊃「是吗他这个是」),但要求比例 ≥ 60%,
        // 多出来的不能太多。
        if nl.count >= minContainmentLength,
           nl.count * 10 >= nm.count * 6,
           nm.contains(nl) {
            return true
        }

        // 编辑距离(Levenshtein)。超长串不截断比较(截断后按前缀算相似度
        // 会把 400 字符之后的独有内容连带删掉)—— 直接判不重复。
        let ca = Array(nm.unicodeScalars)
        let cb = Array(nl.unicodeScalars)
        guard max(ca.count, cb.count) <= 400 else { return false }
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
                if isDuplicate(mic: m, loopback: loopSorted[j]) {
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
