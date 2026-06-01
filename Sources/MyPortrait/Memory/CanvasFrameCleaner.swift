import Foundation

/// canvas(AX 稀疏)session 的 OCR 帧预处理 —— 自适应,无几何/无 per-app 配置。
///
/// 两件事:
///   1. chromeTokens:跨帧频率法识别 UI chrome 词(tab 名/菜单/"正在保存"等)。
///      出现在 > 85% 帧里的 token 判为 chrome。纯频率驱动,任何分辨率/窗口/
///      浏览器/语言自适应。**只当提示给 LLM**,不剥原文(避免误删正文常用词)。
///   2. coarseSnapshots:按时间桶(默认 90s)取每桶最长一帧,塌缩 OCR 抖动 +
///      降帧数。时间分桶是自适应的,不是写死坐标。
enum CanvasFrameCleaner {

    /// chrome 判定:token 出现帧占比 > 此值。
    static let chromeFrequencyThreshold = 0.85
    /// 少于这么多帧不做频率分析(样本太少不可靠)。
    static let minFramesForFrequency = 4
    /// 快照时间桶大小。每桶取最长一帧滤掉 OCR 微抖动,90s 保留细颗粒的编辑
    /// 时间分辨率(版本级以下)。
    static let snapshotBucketMs: Int64 = 90 * 1000
    /// 快照上限。窗口 fanout 把帧数摊给并发 subagent,不为单 agent 上下文降;
    /// 但每帧都是一串 subagent token,20 在"版本级颗粒度"和 token 成本间平衡。
    static let maxSnapshots = 20

    /// 跨帧频率识别 chrome token。frames 太少返回空集。
    static func chromeTokens(_ frames: [WritingCaptureRawOcr]) -> [String] {
        guard frames.count >= minFramesForFrequency else { return [] }
        var freq: [String: Int] = [:]
        for f in frames {
            for t in WritingCaptureStep0.tokenize(f.text) {
                freq[t, default: 0] += 1
            }
        }
        let n = Double(frames.count)
        return freq.compactMap { (tok, cnt) in
            Double(cnt) / n > chromeFrequencyThreshold ? tok : nil
        }.sorted()
    }

    /// 时间桶粗快照:每 `snapshotBucketMs` 一桶,取桶内最长文本那帧。
    /// 输出按 ts 升序。超 `maxSnapshots` 均匀采样。
    static func coarseSnapshots(_ frames: [WritingCaptureRawOcr]) -> [WritingCaptureOcrFrame] {
        guard !frames.isEmpty else { return [] }
        let sorted = frames.sorted { $0.tsMs < $1.tsMs }
        let start = sorted[0].tsMs
        var byBucket: [Int64: WritingCaptureRawOcr] = [:]
        for f in sorted {
            let bucket = (f.tsMs - start) / snapshotBucketMs
            if let cur = byBucket[bucket] {
                if f.text.count > cur.text.count { byBucket[bucket] = f }
            } else {
                byBucket[bucket] = f
            }
        }
        var snaps = byBucket.keys.sorted().map { byBucket[$0]! }
        if snaps.count > maxSnapshots {
            let total = snaps.count
            var sampled = (0..<maxSnapshots).map { snaps[($0 * total) / maxSnapshots] }
            // 均匀采样可能恰好漏掉**内容最完整的那一帧**(用户滚动 review 整篇文档
            // 的快照)—— canvas 的标题/结尾常只在这种帧里。保证 session 窗内最长帧
            // 一定入选(最长 OCR 帧 ≈ 文档最完整状态;chrome 由 LLM 逐帧剥离)。
            if let longest = snaps.max(by: { $0.text.count < $1.text.count }),
               !sampled.contains(where: { $0.id == longest.id }) {
                sampled[sampled.count - 1] = longest
            }
            snaps = sampled.sorted { $0.tsMs < $1.tsMs }
        }
        return snaps.map {
            WritingCaptureOcrFrame(
                frameId: $0.id, startTs: $0.tsMs, endTs: $0.tsMs,
                app: $0.app, url: $0.url, windowTitle: $0.windowTitle,
                text: $0.text
            )
        }
    }
}
