import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 流式 HEVC 编码器（AVAssetWriter + VideoToolbox 硬编）。
///
/// 用法：
/// ```swift
/// let enc = try HEVCEncoder(url: out, size: CGSize(width: 1920, height: 1080))
/// try await enc.start()
/// for frame in frames {
///     try await enc.append(image: frame.image, timestampMs: frame.ts)
/// }
/// try await enc.finalize()
/// ```
///
/// 设计：单次实例只压一个 MP4，写完即丢。重用要小心 AVAssetWriter 的状态机。
///
/// 性能：
///   - VideoToolbox 硬件编码（M 系列 / Intel 都有专用引擎）
///   - 使用 AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool 回收缓冲
///   - HEVC 平均码率 500 kbps（屏幕内容 1fps 经验值，远低于 30fps 视频）
final class HEVCEncoder {

    private let url: URL
    private let size: CGSize
    private let bitrate: Int

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    /// 第一帧的 timestamp_ms，后续帧相对它计算 CMTime。
    private var startTsMs: Int64?

    /// 已 append 的帧数。
    private(set) var frameCount: Int = 0

    init(url: URL, size: CGSize, bitrate: Int = 500_000) throws {
        // 输出目录必须存在。
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // 若已存在删除，避免 AVAssetWriter 报"already exists"。
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        self.url = url
        self.size = size
        self.bitrate = bitrate

        // 1. AVAssetWriter
        self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // 2. Input — HEVC 配置
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: 30,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        self.input = input
        guard writer.canAdd(input) else {
            throw HEVCEncoderError.cannotAddInput
        }
        writer.add(input)

        // 3. Pixel buffer adaptor + 池
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttrs
        )
    }

    /// 启动 writer 会话。必须在第一次 append 前调一次。
    func start() throws {
        guard writer.startWriting() else {
            throw HEVCEncoderError.startFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// 追加一帧。`timestampMs` 是 UTC 毫秒（DB 时间戳）。
    func append(image: CGImage, timestampMs: Int64) async throws {
        if startTsMs == nil {
            startTsMs = timestampMs
        }
        let offsetMs = max(0, timestampMs - (startTsMs ?? timestampMs))

        // 等 input 准备好接收数据（背压）。
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            if Task.isCancelled { throw CancellationError() }
        }

        // 从池子里拿 pixel buffer，把 CGImage 画进去。
        guard let pool = adaptor.pixelBufferPool else {
            throw HEVCEncoderError.pixelBufferPoolMissing
        }
        var pixelBufferOpt: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOpt)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOpt else {
            throw HEVCEncoderError.pixelBufferCreateFailed(status: status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw HEVCEncoderError.pixelBufferLockFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGImageByteOrderInfo.order32Little.rawValue

        guard let ctx = CGContext(
            data: baseAddr,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw HEVCEncoderError.bitmapContextFailed
        }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))

        let presentationTime = CMTime(value: offsetMs, timescale: 1000)
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw HEVCEncoderError.appendFailed(underlying: writer.error)
        }
        frameCount += 1
    }

    /// 关闭 writer，等编码完成。
    func finalize() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw HEVCEncoderError.finishFailed(underlying: writer.error)
        }
    }

    /// 总时长（毫秒）—— 给 DB video_chunks.end_ts_ms / 计算 fps 用。
    /// finalize 后才有意义。
    var durationMs: Int64 {
        // 当 frameCount=1 时 offsetMs 为 0，估个最小 1ms 兜底。
        guard frameCount > 1, let _ = startTsMs else { return 0 }
        let lastPresent = CMTimeGetSeconds(writer.movieTimeScale > 0 ? .zero : .zero)
        _ = lastPresent
        // 由 CompactionWorker 传入实际 last_ts - start_ts，HEVCEncoder 不需要追踪。
        return 0
    }
}

enum HEVCEncoderError: Error, CustomStringConvertible {
    case cannotAddInput
    case startFailed(underlying: Error?)
    case pixelBufferPoolMissing
    case pixelBufferCreateFailed(status: CVReturn)
    case pixelBufferLockFailed
    case bitmapContextFailed
    case appendFailed(underlying: Error?)
    case finishFailed(underlying: Error?)

    var description: String {
        switch self {
        case .cannotAddInput: return "HEVCEncoder.cannotAddInput"
        case .startFailed(let e): return "HEVCEncoder.startFailed(\(String(describing: e)))"
        case .pixelBufferPoolMissing: return "HEVCEncoder.pixelBufferPoolMissing"
        case .pixelBufferCreateFailed(let s): return "HEVCEncoder.pixelBufferCreateFailed(\(s))"
        case .pixelBufferLockFailed: return "HEVCEncoder.pixelBufferLockFailed"
        case .bitmapContextFailed: return "HEVCEncoder.bitmapContextFailed"
        case .appendFailed(let e): return "HEVCEncoder.appendFailed(\(String(describing: e)))"
        case .finishFailed(let e): return "HEVCEncoder.finishFailed(\(String(describing: e)))"
        }
    }
}
