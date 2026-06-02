import Foundation

/// 一段连续语音 + 它的音色向量 + 局部说话人标签。port 自 screenpipe `SpeechSegment`。
struct SpeechSegment {
    var start: Double          // 秒
    var end: Double            // 秒
    var samples: [Float]
    var localSpeaker: Int      // EmbeddingManager 给的「本次 chunk 内」局部 id
    var embedding: [Float]     // 512 维，已 L2 归一化
}

/// 一次 diarize 调用内的临时说话人聚类（内存）。port 自 `embedding_manager.rs`。
///
/// 它给同一个 chunk 内的多个语音段打「局部」说话人标签（用于合并相邻同人段），
/// 这些局部 id 之后再由 OnnxSpeakerDiarizer 映射到 DB 的持久 speaker id。
final class EmbeddingManager {
    private var speakers: [Int: [Float]] = [:]
    private var nextId = 1
    private let maxSpeakers: Int

    init(maxSpeakers: Int = Int.max) { self.maxSpeakers = maxSpeakers }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// 找匹配的局部说话人；没有则新建；到上限则强制并到最近的。
    func searchSpeaker(embedding: [Float], threshold: Float) -> Int {
        var bestId: Int?
        var bestSim = threshold
        for (id, emb) in speakers {
            let sim = Self.cosine(embedding, emb)
            if sim > bestSim { bestId = id; bestSim = sim }
        }
        if let id = bestId { return id }
        if speakers.count < maxSpeakers {
            let id = nextId
            nextId += 1
            speakers[id] = embedding
            return id
        }
        // 到上限：并到最相似的现有说话人。
        if let closest = closestSpeaker(embedding) { return closest }
        let id = nextId
        nextId += 1
        speakers[id] = embedding
        return id
    }

    private func closestSpeaker(_ embedding: [Float]) -> Int? {
        var bestId: Int?
        var bestSim = -Float.greatestFiniteMagnitude
        for (id, emb) in speakers {
            let sim = Self.cosine(embedding, emb)
            if sim > bestSim { bestId = id; bestSim = sim }
        }
        return bestId
    }
}

/// 把一段音频切成多个说话人语音段。port 自 screenpipe `segment.rs`。
///
/// 算法：pyannote 分离模型逐 10s 窗口跑 → 每帧 argmax，类别 0 = 静音、其余 =
/// 有人说话。语音起止边界确定后，截出该段、用 CAM++ 抽向量、交给 EmbeddingManager
/// 打局部标签；相邻同标签段合并。
enum SpeakerSegmenter {

    /// frame_size：分离模型每个输出帧对应的样本数（screenpipe 实测值）。
    private static let frameSize = 270
    /// 输出第一帧对应的样本偏移（screenpipe 实测值）。
    private static let frameStart = 721
    /// 段内聚类的余弦阈值。
    private static let clusterThreshold: Float = 0.45
    /// 抽向量的最短样本数（< 此长度补齐）。
    private static let minSegmentSamples = 1600

    /// `samples`：16kHz mono。返回合并后的语音段（按时间序）。
    static func segments(
        samples: [Float],
        sampleRate: Int,
        segmentation: SpeakerSegmentationModel,
        embedding: SpeakerEmbeddingExtractor,
        manager: EmbeddingManager
    ) -> [SpeechSegment] {
        guard !samples.isEmpty else { return [] }
        let windowSize = sampleRate * 10

        // 补零到 windowSize 的整数倍。
        var padded = samples
        let rem = samples.count % windowSize
        if rem != 0 {
            padded.append(contentsOf: [Float](repeating: 0, count: windowSize - rem))
        }

        var offset = frameStart
        var startOffset = 0.0
        var isSpeeching = false
        var current: SpeechSegment?
        var result: [SpeechSegment] = []

        var pos = 0
        while pos < padded.count {
            let end = min(pos + windowSize, padded.count)
            let window = Array(padded[pos..<end])
            let frames = (try? segmentation.process(window: window)) ?? []

            for classes in frames {
                let speech = argmax(classes) != 0
                if speech {
                    if !isSpeeching {
                        startOffset = Double(offset)
                        isSpeeching = true
                    }
                } else if isSpeeching {
                    if let seg = makeSegment(
                        startOffset: startOffset, offset: offset, sampleRate: sampleRate,
                        samples: samples, padded: padded, embedding: embedding, manager: manager
                    ) {
                        // 相邻同说话人段合并。
                        if var prev = current {
                            if prev.localSpeaker == seg.localSpeaker {
                                // 合并段采用「贡献样本更多」那一段的声纹,跟合并后用
                                // max-samples 评判一致(原来只留第一段的,样本变长后
                                // enroll 长度护栏被架空)。比较要在 append 之前。
                                if seg.samples.count > prev.samples.count {
                                    prev.embedding = seg.embedding
                                }
                                prev.end = seg.end
                                prev.samples.append(contentsOf: seg.samples)
                                current = prev
                            } else {
                                result.append(prev)
                                current = seg
                            }
                        } else {
                            current = seg
                        }
                    }
                    isSpeeching = false
                }
                offset += frameSize
            }
            pos += windowSize
        }
        if let last = current { result.append(last) }
        return result
    }

    private static func argmax(_ v: [Float]) -> Int {
        guard !v.isEmpty else { return 0 }
        var bestIdx = 0
        var best = v[0]
        for i in 1..<v.count where v[i] > best { best = v[i]; bestIdx = i }
        return bestIdx
    }

    /// 截出 [startOffset, offset] 这段音频、抽向量、打局部标签。port create_speech_segment。
    private static func makeSegment(
        startOffset: Double, offset: Int, sampleRate: Int,
        samples: [Float], padded: [Float],
        embedding: SpeakerEmbeddingExtractor, manager: EmbeddingManager
    ) -> SpeechSegment? {
        let start = startOffset / Double(sampleRate)
        let end = Double(offset) / Double(sampleRate)

        let floorIdx = samples.count > minSegmentSamples ? samples.count - minSegmentSamples : 0
        let startIdx = Int(min(start * Double(sampleRate), Double(floorIdx)))
        var endIdx = Int(min(end * Double(sampleRate), Double(samples.count)))
        guard endIdx > startIdx else { return nil }

        let segmentSamples: [Float]
        if endIdx - startIdx < minSegmentSamples {
            let diff = minSegmentSamples - (endIdx - startIdx)
            if endIdx + diff <= padded.count {
                endIdx += diff
                segmentSamples = Array(padded[startIdx..<endIdx])
            } else if startIdx >= diff {
                segmentSamples = Array(padded[(startIdx - diff)..<endIdx])
            } else {
                var v = Array(padded[startIdx..<endIdx])
                v.append(contentsOf: [Float](repeating: 0, count: minSegmentSamples - v.count))
                segmentSamples = v
            }
        } else {
            segmentSamples = Array(padded[startIdx..<endIdx])
        }

        guard let emb = embedding.embed(segmentSamples) else { return nil }
        let speaker = manager.searchSpeaker(embedding: emb, threshold: clusterThreshold)
        return SpeechSegment(
            start: start, end: end, samples: segmentSamples,
            localSpeaker: speaker, embedding: emb
        )
    }
}
