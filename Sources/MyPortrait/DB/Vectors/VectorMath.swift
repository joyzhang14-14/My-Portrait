import Accelerate
import Foundation

/// 向量计算工具。用 Accelerate（vDSP）让大批量 cosine 走 SIMD。
enum VectorMath {

    /// L2 归一化（in-place）。bge-m3 输出后应该已经归一化，但这里保险一下。
    static func l2Normalize(_ v: inout [Float]) {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))   // sum of squares
        let n = norm.squareRoot()
        guard n > 1e-10 else { return }
        var inv = 1 / n
        vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
    }

    /// 余弦相似度（假设双方已 L2 归一化）= 点积。
    /// vDSP_dotpr 走 SIMD，~1024 维 < 1µs。
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vector dim mismatch")
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// 批量 cosine：query vs 多个 candidate（已归一化）。
    /// 返回每个 candidate 的相似度。SIMD + 单次 alloc。
    static func cosineSimilarities(query: [Float], candidates: [[Float]]) -> [Float] {
        candidates.map { cosineSimilarity(query, $0) }
    }
}

// MARK: - BLOB 编解码

extension Data {
    /// `[Float]` → little-endian BLOB（4 bytes/元素）。
    /// 直接 memcpy，~1µs。
    init(floats: [Float]) {
        self = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// BLOB → `[Float]`。如果字节数不是 4 的倍数返回 nil。
    var asFloats: [Float]? {
        guard count % MemoryLayout<Float>.size == 0 else { return nil }
        let n = count / MemoryLayout<Float>.size
        return withUnsafeBytes { rawBuf -> [Float] in
            let typed = rawBuf.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: typed.baseAddress, count: n))
        }
    }
}
