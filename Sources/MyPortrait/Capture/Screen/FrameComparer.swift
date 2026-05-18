import CoreGraphics
import Foundation

/// 帧去重。比较当前帧 vs 上一保留帧，决定是否值得 OCR 入库。
///
/// 算法（抄 My-Orphies frame_comparison.rs）：
///   1. 下采样到 1/4 分辨率 + 灰度
///   2. 算 pixel hash (FNV-1a)：与上次一致直接 false（早退，省 30-50% CPU）
///   3. 算 256-bin Hellinger 直方图距离：< skipThreshold 视为相同
///   4. 强制保留：距上次保留超过 maxSkipDurationMs → 仍然返回 true
///
/// 不是 actor —— 调用方 (CaptureCoordinator) 串行调用。
///
/// 性能注意：
///   - 下采样用 CGContext + low quality（< 1ms for 1920→480）
///   - hash 用原生 FNV-1a 不分配
///   - 直方图 256 桶遍历单次
final class FrameComparer {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter
    private var lastKept: KeptFrame?

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 判断是否保留这一帧。`true` 时内部更新 lastKept。
    func shouldKeep(_ image: CGImage, now: Date = Date()) -> Bool {
        guard let downscaled = downscaleToGray(
            image, factor: max(1, config.frameDownscaleFactor)
        ) else {
            // 下采样失败 → 保守保留
            return true
        }

        let hash = fnv1aHash(downscaled.bytes)

        // 首帧 —— 必保留。
        guard let last = lastKept else {
            lastKept = KeptFrame(
                bytes: downscaled.bytes,
                hash: hash,
                histogram: histogram256(downscaled.bytes),
                at: now
            )
            return true
        }

        let maxSkipS = Double(config.maxSkipDurationMs) / 1000.0
        let elapsedS = now.timeIntervalSince(last.at)
        let mustForceKeep = elapsedS >= maxSkipS

        // 早退：hash 一致即视为同帧。
        if hash == last.hash {
            if mustForceKeep {
                lastKept = KeptFrame(
                    bytes: downscaled.bytes, hash: hash,
                    histogram: last.histogram,   // 直接复用，省一次直方图
                    at: now
                )
                return true
            }
            return false
        }

        // 直方图距离。
        let currHist = histogram256(downscaled.bytes)
        let dist = hellingerDistance(last.histogram, currHist)

        if dist < config.skipThreshold {
            if mustForceKeep {
                lastKept = KeptFrame(
                    bytes: downscaled.bytes, hash: hash,
                    histogram: currHist,
                    at: now
                )
                return true
            }
            return false
        }

        // 视觉差足够大 —— 保留并更新。
        lastKept = KeptFrame(
            bytes: downscaled.bytes, hash: hash,
            histogram: currHist,
            at: now
        )
        return true
    }

    /// 屏幕解锁 / 睡眠唤醒后调，清空 lastKept 强制下一帧保留。
    func reset() {
        lastKept = nil
    }

    // MARK: - 私有

    private struct KeptFrame {
        let bytes: [UInt8]
        let hash: UInt64
        let histogram: [UInt32]
        let at: Date
    }

    /// 下采样到 1/factor 分辨率 + 单通道灰度。
    /// 返回 raw bytes + 尺寸；失败返回 nil。
    private func downscaleToGray(_ image: CGImage, factor: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        let dstW = image.width / factor
        let dstH = image.height / factor
        guard dstW > 0, dstH > 0 else { return nil }

        let bytesCount = dstW * dstH
        var bytes = [UInt8](repeating: 0, count: bytesCount)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let ok = bytes.withUnsafeMutableBufferPointer { ptr -> Bool in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: dstW,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            return true
        }

        return ok ? (bytes, dstW, dstH) : nil
    }

    /// FNV-1a 64-bit hash。
    private func fnv1aHash(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return h
    }

    /// 256-bin 灰度直方图。
    private func histogram256(_ bytes: [UInt8]) -> [UInt32] {
        var hist = [UInt32](repeating: 0, count: 256)
        for b in bytes {
            hist[Int(b)] &+= 1
        }
        return hist
    }

    /// Hellinger 距离 ∈ [0, 1]。0 = identical，1 = totally different.
    /// 用 Bhattacharyya 系数变形：H = sqrt(1 - BC), BC = Σ sqrt(p_i q_i)
    private func hellingerDistance(_ a: [UInt32], _ b: [UInt32]) -> Double {
        var sumA: UInt64 = 0
        var sumB: UInt64 = 0
        for i in 0..<256 {
            sumA &+= UInt64(a[i])
            sumB &+= UInt64(b[i])
        }
        guard sumA > 0, sumB > 0 else { return 1.0 }

        let na = Double(sumA)
        let nb = Double(sumB)
        var bc = 0.0
        for i in 0..<256 {
            let pa = Double(a[i]) / na
            let pb = Double(b[i]) / nb
            bc += (pa * pb).squareRoot()
        }
        return max(0.0, 1.0 - bc).squareRoot()
    }
}
