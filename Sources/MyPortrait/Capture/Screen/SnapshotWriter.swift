import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os.log

/// JPG 异步落盘。
///
/// 路径：`~/.portrait/raw_data/frames/YYYY-MM-DD/{ts_ms}_m{monitor}.jpg`
///
/// 设计：actor 自然序列化 `write` 调用 —— 同一时刻只有一个 ImageIO 编码。
/// 调用方流程：
///   1. `predictURL(timestamp:)` 同步拿到 URL，立即可入库
///   2. `Task.detached { try await writer.write(image:to:) }` 启异步 IO
///   3. IO 失败只 log，DB 那行的 snapshot_path 会指向不存在的文件
///      由 P3 compaction worker 顺手清理（找不到就把 frame 标 invalid）
///
/// 性能：
///   - ImageIO 直接编码，零 NSImage / NSBitmapImageRep 中转
///   - 缩放用 CGContext + medium quality（视觉素材，质量比速度优先）
actor SnapshotWriter {

    private let config: CaptureConfig
    private let reporter: UnimplementedReporter
    private let logger = Logger(subsystem: "com.myportrait.capture", category: "snapshot")

    /// 已确认存在的日期目录（一天一条）。免重复调 `createDirectory`。
    private var ensuredDayDirs: Set<String> = []

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(config: CaptureConfig, reporter: UnimplementedReporter) {
        self.config = config
        self.reporter = reporter
    }

    /// 同步计算文件路径。不创建任何目录、不做 IO。
    /// `actor` 之外可直接调（计算纯函数 + 静态 formatter，线程安全）。
    nonisolated func predictURL(timestamp: Date) -> URL {
        let day = Self.dayFormatter.string(from: timestamp)
        let tsMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        return config.framesDir
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(tsMs)_m\(config.monitorId).jpg")
    }

    /// 编码 JPG 并写入指定 URL。actor 序列化保证同一时刻仅一个编码任务。
    /// 失败抛错（调用方一般 catch + log，不影响主流程）。
    func write(image: CGImage, to url: URL) async throws {
        // 1. 父目录就绪（按天缓存，免重复 syscall）。
        let parent = url.deletingLastPathComponent()
        if !ensuredDayDirs.contains(parent.path) {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )
            ensuredDayDirs.insert(parent.path)
        }

        // 2. 必要时缩放。
        let toEncode = resizeIfNeeded(image, maxWidth: config.jpegMaxWidth)

        // 3. ImageIO 编码。
        let utType = UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utType, 1, nil
        ) else {
            throw SnapshotError.destinationCreateFailed(url: url)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: config.jpegQuality
        ]
        CGImageDestinationAddImage(dest, toEncode, options as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw SnapshotError.encodeFailed(url: url)
        }
    }

    /// 缓存重置（屏幕解锁等场景调）。
    func reset() {
        ensuredDayDirs.removeAll()
    }

    // MARK: - 私有

    private func resizeIfNeeded(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard maxWidth > 0, image.width > maxWidth else { return image }

        let scale = Double(maxWidth) / Double(image.width)
        let dstW = maxWidth
        let dstH = Int((Double(image.height) * scale).rounded())

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGImageByteOrderInfo.order32Little.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return ctx.makeImage() ?? image
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case destinationCreateFailed(url: URL)
    case encodeFailed(url: URL)

    var description: String {
        switch self {
        case .destinationCreateFailed(let url):
            return "SnapshotError.destinationCreateFailed(\(url.path))"
        case .encodeFailed(let url):
            return "SnapshotError.encodeFailed(\(url.path))"
        }
    }
}
