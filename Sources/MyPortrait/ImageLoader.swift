import SwiftUI
import AppKit
import ImageIO
import AVFoundation
import CoreMedia

/// Loads JPEG/PNG thumbnails from disk, downsampling to a target pixel size to keep
/// memory and scroll FPS bounded. Backed by a single shared NSCache, off-main-thread.
@MainActor
final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        // 字节上限。⚠️ 这个数直接决定 app 的常驻内存水位:NSCache 不随切页
        // 释放、也等不到后台进程的系统内存压力,充到上限就一直攥着(实测
        // 512MB 上限时全 app 持续 500-700MB,heap 里 31 块 ~11.5MB 解码位图)。
        // 128MB ≈ 十来张主图或几百张条带缩略图,翻 Timeline 的体感够用;
        // 超出的只是重新从磁盘解码,换来常驻水位低 ~380MB。
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// 拨帧预览:长边 480px 的小图,单独一个 NSCache(16:10 一张约 0.6MB,
    /// 48MB ≈ 80 张),Timeline 页面消失时整个清掉。
    nonisolated static let previewPixel: CGFloat = 480
    private let previews: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()
    /// 正在解预览的 key(JPG 帧 / MP4 整个 chunk),防同一份活重复排队。
    private var warming = Set<String>()

    static func previewKey(_ frame: TimelineFrame) -> String? {
        guard frame.hasViewableMedia else { return nil }
        if let p = frame.snapshotPath { return "pv:\(p)" }
        if let v = frame.videoPath { return "pv:mp4:\(v)#\(frame.videoOffsetMs)" }
        return nil
    }
    func preview(_ key: String) -> NSImage? { previews.object(forKey: key as NSString) }
    func removePreviews() { previews.removeAllObjects() }
    private func storePreview(_ image: NSImage, for key: String) {
        let rep = image.representations.first
        previews.setObject(image, forKey: key as NSString,
                           cost: (rep?.pixelsWide ?? 0) * (rep?.pixelsHigh ?? 0) * 4)
    }

    /// 给这些帧解预览(已有的跳过)。JPG 一帧一个 ImageIO 缩略图;MP4 同一个
    /// chunk 的帧按时间顺序交给一个复用的生成器顺序解,比逐帧 seek 便宜得多。
    func warmPreviews(_ frames: [TimelineFrame]) {
        var chunks: [String: [(key: String, seconds: Double)]] = [:]
        for f in frames {
            guard let key = Self.previewKey(f), previews.object(forKey: key as NSString) == nil else { continue }
            if let path = f.snapshotPath {
                guard warming.insert(key).inserted else { continue }
                Task.detached(priority: .utility) {
                    let img = AsyncDiskThumbnail.downsample(path: path, maxPixel: Self.previewPixel)
                    await MainActor.run {
                        if let img { ImageThumbnailCache.shared.storePreview(img, for: key) }
                        ImageThumbnailCache.shared.warming.remove(key)
                    }
                }
            } else if let v = f.videoPath {
                chunks[v, default: []].append((key, AsyncMP4FrameThumbnail.seconds(f.videoOffsetMs)))
            }
        }
        for (path, items) in chunks {
            let tag = "chunk:\(path)"
            guard warming.insert(tag).inserted else { continue }
            Task.detached(priority: .utility) {
                await MP4Generators.shared.images(path: path, items: items, maxPixel: Self.previewPixel) { key, img in
                    await MainActor.run { ImageThumbnailCache.shared.storePreview(img, for: key) }
                }
                await MainActor.run { _ = ImageThumbnailCache.shared.warming.remove(tag) }
            }
        }
    }

    /// 全清。窗口关闭 / app 隐藏时调 —— NSCache 只在系统内存压力下才自动
    /// 回收,后台常驻进程等不到那一天,不主动清就一直占着(实测可达数百 MB)。
    /// 代价只是重开窗口后缩略图从磁盘重新解码。
    func removeAll() { cache.removeAllObjects(); previews.removeAllObjects() }
    func store(_ image: NSImage, for key: String) {
        // cost = 解码后近似字节数(像素宽×高×4),让 totalCostLimit 生效
        let rep = image.representations.first
        let cost = (rep?.pixelsWide ?? Int(image.size.width)) * (rep?.pixelsHigh ?? Int(image.size.height)) * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 预解码一帧进缓存(若还没缓存)。给 timeline 按方向键时提前解码前后
    /// 几帧用 —— 快速划过时图片已就绪,不用现等 MP4 抽帧/JPG downsample。
    /// cache key / pixelSize 跟 AsyncDiskThumbnail / AsyncMP4FrameThumbnail
    /// **完全一致**,这样预取的结果它们的 .task 直接命中。
    /// 默认优先级 .utility(低于当前帧的 .userInitiated),不抢当前帧的解码;
    /// Timeline 播放时预解前方几帧传 .userInitiated。在解的 key 不重复排队。
    func prefetch(_ frame: TimelineFrame, targetPixelSize: CGFloat,
                  priority: TaskPriority = .utility) {
        guard frame.hasViewableMedia else { return }
        let pixelSize = targetPixelSize * (NSScreen.main?.backingScaleFactor ?? 2.0)
        if let path = frame.snapshotPath {
            let key = "\(path)|\(Int(targetPixelSize))"
            guard cache.object(forKey: key as NSString) == nil, fetching.insert(key).inserted else { return }
            Task.detached(priority: priority) {
                let img = FileManager.default.fileExists(atPath: path)
                    ? AsyncDiskThumbnail.downsample(path: path, maxPixel: pixelSize) : nil
                await MainActor.run {
                    if let img { ImageThumbnailCache.shared.store(img, for: key) }
                    ImageThumbnailCache.shared.fetching.remove(key)
                }
            }
        } else if let vpath = frame.videoPath {
            let key = "mp4:\(vpath)#\(frame.videoOffsetMs)|\(Int(targetPixelSize))"
            guard cache.object(forKey: key as NSString) == nil, fetching.insert(key).inserted else { return }
            let ms = frame.videoOffsetMs
            let f = frame.videoFps
            Task.detached(priority: priority) {
                let img = await AsyncMP4FrameThumbnail.extract(
                    videoPath: vpath, offsetMs: ms, fps: f, maxPixel: pixelSize)
                await MainActor.run {
                    if let img { ImageThumbnailCache.shared.store(img, for: key) }
                    ImageThumbnailCache.shared.fetching.remove(key)
                }
            }
        }
    }
    private var fetching = Set<String>()
}

/// Background-loaded thumbnail view. Drop-in for `Image(...)` — gives a placeholder while
/// loading, swaps to the actual downsampled image when ready.
struct AsyncDiskThumbnail: View {
    let path: String
    let targetPixelSize: CGFloat
    /// .fill = 填满槽位、溢出裁切(HomeView 方形附件缩略图要的);
    /// .fit = 完整适配不裁像素(Timeline 主画面要的,07-21 update)。
    var contentMode: ContentMode = .fill
    /// 没命中缓存时先等这么久再解码;期间换了帧(.task 被取消)就不解码。
    /// Timeline 快速拨帧时用它跳过一闪而过的帧。
    var decodeDelay: Duration = .zero
    /// ImageThumbnailCache.previewKey:有就在清晰图解出来前先显示那张小预览。
    var previewKey: String? = nil
    /// 先上了预览时清晰图至少等多久再解;Timeline 播放中传 .zero(每帧都解清晰图)。
    var previewDelay: Duration = AsyncDiskThumbnail.previewSettle

    @State private var image: NSImage?
    /// 当前 image 属于哪一帧(预览或清晰图)。
    @State private var shownID: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(Theme.textPrimary.opacity(0.2))
                    )
            }
        }
        .task(id: "\(path)|\(Int(targetPixelSize))") { await load() }
    }

    private func load() async {
        let key = "\(path)|\(Int(targetPixelSize))"
        if let cached = ImageThumbnailCache.shared.cached(key) {
            self.image = cached
            shownID = path
            return
        }
        let delay = showPreview(id: path) ? max(decodeDelay, previewDelay) : decodeDelay
        // Race-defensive: the file may have existed when the TimelineFrame
        // was built but been deleted since (e.g. CompactionWorker embeds
        // it into an MP4 chunk and rm's the JPG). Skip silently to avoid
        // ImageIO logging "*** ERROR: can't open" to stderr.
        guard FileManager.default.fileExists(atPath: path) else { return }
        if delay > .zero {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
        }
        let pixelSize = targetPixelSize * (NSScreen.main?.backingScaleFactor ?? 2.0)
        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            Self.downsample(path: path, maxPixel: pixelSize)
        }.value
        if let loaded {
            ImageThumbnailCache.shared.store(loaded, for: key)
            // .task(id:) 切帧时已 cancel 本 task,但 detached 解码不传播取消;
            // await 回来若已取消说明 path 已换 —— 只进缓存不回写,防慢的旧帧
            // 结果覆盖已显示的新帧。
            if !Task.isCancelled { self.image = loaded; shownID = path }
        }
    }

    /// 有预览就先上预览;同一帧已经显示着(只是换了尺寸档)就不退回预览。
    private func showPreview(id: String) -> Bool {
        guard shownID != id, let pk = previewKey, let pv = ImageThumbnailCache.shared.preview(pk) else { return false }
        image = pv
        shownID = id
        return true
    }

    /// 先上了预览时,清晰图至少等 50ms 再解:比拨帧最小间隔 40ms 长,连拨
    /// 过程中不解清晰图,停下就解。
    static let previewSettle: Duration = .milliseconds(50)

    nonisolated static func downsample(path: String, maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Extracts a single frame from an MP4 video chunk using AVAssetImageGenerator.
/// Cached the same way as JPG thumbnails. Used because the daemon that produced this DB stores most
/// frames packed inside compact_*.mp4 instead of writing per-frame JPGs.
struct AsyncMP4FrameThumbnail: View {
    let videoPath: String
    let offsetMs: Int             // offset into the MP4, in milliseconds
    let fps: Double               // chunk fps (used as fallback only)
    let targetPixelSize: CGFloat
    /// 同 AsyncDiskThumbnail.contentMode。
    var contentMode: ContentMode = .fill
    /// 没命中缓存时先等这么久再解码;期间换了帧(.task 被取消)就不解码。
    /// Timeline 快速拨帧时用它跳过一闪而过的帧。
    var decodeDelay: Duration = .zero
    /// ImageThumbnailCache.previewKey:有就在清晰图解出来前先显示那张小预览。
    var previewKey: String? = nil
    /// 先上了预览时清晰图至少等多久再解;Timeline 播放中传 .zero(每帧都解清晰图)。
    var previewDelay: Duration = AsyncDiskThumbnail.previewSettle

    @State private var image: NSImage?
    /// 当前 image 属于哪一帧(预览或清晰图)。
    @State private var shownID: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        Image(systemName: "film")
                            .foregroundStyle(Theme.textPrimary.opacity(0.2))
                    )
            }
        }
        .task(id: "\(videoPath)#\(offsetMs)|\(Int(targetPixelSize))") { await load() }
    }

    private func load() async {
        let key = "mp4:\(videoPath)#\(offsetMs)|\(Int(targetPixelSize))"
        let id = "\(videoPath)#\(offsetMs)"
        if let cached = ImageThumbnailCache.shared.cached(key) {
            self.image = cached
            shownID = id
            return
        }
        var delay = decodeDelay
        if shownID != id, let pk = previewKey, let pv = ImageThumbnailCache.shared.preview(pk) {
            image = pv
            shownID = id
            delay = max(delay, previewDelay)
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
        }
        let pixelSize = targetPixelSize * (NSScreen.main?.backingScaleFactor ?? 2.0)
        let path = videoPath
        let ms = offsetMs
        let f = fps
        let loaded = await Task.detached(priority: .userInitiated) {
            await Self.extract(videoPath: path, offsetMs: ms, fps: f, maxPixel: pixelSize)
        }.value
        if let loaded {
            ImageThumbnailCache.shared.store(loaded, for: key)
            // 同 AsyncDiskThumbnail:MP4 抽帧慢,切帧后迟到的旧结果只进缓存,
            // 不回写 image,防错帧画面一直挂着。
            if !Task.isCancelled { self.image = loaded; shownID = id }
        }
    }

    /// offset_ms 是在 MP4 里的位置;没记(老 chunk 一帧一个文件)就取第 0 帧。
    nonisolated static func seconds(_ offsetMs: Int) -> Double {
        offsetMs > 0 ? Double(offsetMs) / 1000.0 : 0
    }

    nonisolated static func extract(videoPath: String, offsetMs: Int, fps: Double, maxPixel: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: videoPath) else { return nil }
        return await MP4Generators.shared.image(path: videoPath, seconds: seconds(offsetMs), maxPixel: maxPixel)
    }
}

/// 按 chunk 复用 AVURLAsset + AVAssetImageGenerator(LRU,≈4 个 chunk × 清晰 / 预览
/// 两档尺寸 = 8 个),不再每抽一帧就新建一套、重新解析 MP4 头。生成器只在这个
/// actor 里用。
actor MP4Generators {
    static let shared = MP4Generators()
    private var lru: [(key: String, gen: AVAssetImageGenerator)] = []

    private func generator(_ path: String, _ maxPixel: CGFloat) -> AVAssetImageGenerator {
        let key = "\(path)|\(Int(maxPixel))"
        if let i = lru.firstIndex(where: { $0.key == key }) {
            let e = lru.remove(at: i)
            lru.append(e)
            return e.gen
        }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        g.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        lru.append((key, g))
        if lru.count > 8 { lru.removeFirst() }
        return g
    }

    func image(path: String, seconds: Double, maxPixel: CGFloat) async -> NSImage? {
        let g = generator(path, maxPixel)
        let (stream, cont) = AsyncStream.makeStream(of: NSImage?.self)
        g.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { cg, _, _ in
            cont.yield(cg.map { NSImage(cgImage: $0, size: .zero) })
            cont.finish()
        }
        for await img in stream { return img }
        return nil
    }

    /// 同一个 chunk 的多帧按时间顺序一次性交给生成器,解出一张回调一张。
    func images(path: String, items: [(key: String, seconds: Double)], maxPixel: CGFloat,
                each: @Sendable (String, NSImage) async -> Void) async {
        guard FileManager.default.fileExists(atPath: path), !items.isEmpty else { return }
        let g = generator(path, maxPixel)
        let times = items.map { CMTime(seconds: $0.seconds, preferredTimescale: 600) }.sorted { $0 < $1 }
        var keys: [Int64: String] = [:]
        for it in items { keys[CMTime(seconds: it.seconds, preferredTimescale: 600).value] = it.key }
        let byTime = keys, last = times[times.count - 1]
        let (stream, cont) = AsyncStream.makeStream(of: (String, NSImage).self)
        g.generateCGImagesAsynchronously(forTimes: times.map { NSValue(time: $0) }) { req, cg, _, _, _ in
            if let cg, let key = byTime[req.convertScale(600, method: .roundHalfAwayFromZero).value] {
                cont.yield((key, NSImage(cgImage: cg, size: .zero)))
            }
            if CMTimeCompare(req, last) == 0 { cont.finish() }
        }
        for await (key, img) in stream { await each(key, img) }
    }
}

