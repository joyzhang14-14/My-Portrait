import CoreGraphics
import Foundation

/// JPG 异步落盘。
///
/// 路径：`~/.portrait/raw_data/frames/YYYY-MM-DD/{ts_ms}_m{monitor}.jpg`
///
/// 设计要点：
///   - `enqueue` 同步返回预定路径，立即可入库（不等磁盘）
///   - 内部串行化 ImageIO 编码（避免多个并发编码撞 CPU）
///   - 失败 → 静默 log，DB 那行的 snapshot_path 会指向不存在的文件
///     由 P3 compaction worker 顺手清理（找不到就把 frame 标 invalid）
///
/// 性能注意：
///   - 用 ImageIO 直接调 (`CGImageDestination`)，不走 NSImage / NSBitmapImageRep 中转
///   - 缩放用 vImage，不要 NSImage `.resize`
actor SnapshotWriter {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 提交一帧写盘。立即返回预计 URL（不等 IO）。
    ///
    /// P1 实现：
    ///   1. 计算 URL（含日期子目录、时间戳文件名）
    ///   2. 创建父目录（缓存"今天已建过"省 syscall）
    ///   3. Task 内异步：缩放 → ImageIO 编码 → 写盘
    ///   4. 失败 → log
    ///
    /// P0：throw notImplemented（actor func 不返回 URL 也行，让 caller 走 stub 流）。
    func enqueue(image: CGImage, timestamp: Date) async throws -> URL {
        throw reporter.notImplemented("SnapshotWriter.enqueue")
    }
}
