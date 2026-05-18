import CoreGraphics
import Foundation

/// 帧去重。比较当前帧 vs 上一保留帧，决定是否值得 OCR 入库。
///
/// 算法（抄 My-Orphies frame_comparison.rs）：
///   1. 下采样到 1/4 分辨率，转灰度
///   2. 算 pixel hash —— 与上次一致直接 false（早退，省 30-50% CPU）
///   3. Hellinger 直方图距离 —— < skipThreshold 视为相同
///   4. 强制保留：距上次保留超过 maxSkipDurationMs 也返回 true
///
/// 不是 actor —— 调用方 (CaptureCoordinator) 串行调用。
///
/// 性能注意：
///   - 用 Accelerate vDSP 算直方图，不要 Swift 原生遍历
///   - 下采样用 vImage（CoreGraphics 也行，但 vImage 更快）
final class FrameComparer {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter

    /// 上次保留帧的下采样灰度数据 + hash + 时间戳。
    private var lastKept: KeptFrame?

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 判断这一帧是否值得保留。`true` 时内部会更新 lastKept。
    func shouldKeep(_ image: CGImage, now: Date = Date()) -> Bool {
        // P0：所有帧都"保留"，调用方仍会 throw 上层 stub —— 这里不能 throw，签名是 Bool。
        // 注意：调用方走 stub 后这个值用不上。P1 起填真实算法。
        return true
    }

    /// 屏幕解锁 / 睡眠唤醒后调，清空 lastKept 强制下一帧保留。
    func reset() {
        lastKept = nil
    }

    private struct KeptFrame {
        let downscaledLuma: Data
        let hash: UInt64
        let at: Date
    }
}
