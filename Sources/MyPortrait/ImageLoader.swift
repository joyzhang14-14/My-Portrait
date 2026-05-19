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
        return c
    }()

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func store(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// Background-loaded thumbnail view. Drop-in for `Image(...)` — gives a placeholder while
/// loading, swaps to the actual downsampled image when ready.
struct AsyncDiskThumbnail: View {
    let path: String
    let targetPixelSize: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.2))
                    )
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        let key = "\(path)|\(Int(targetPixelSize))"
        if let cached = ImageThumbnailCache.shared.cached(key) {
            self.image = cached
            return
        }
        // Race-defensive: the file may have existed when the TimelineFrame
        // was built but been deleted since (e.g. CompactionWorker embeds
        // it into an MP4 chunk and rm's the JPG). Skip silently to avoid
        // ImageIO logging "*** ERROR: can't open" to stderr.
        guard FileManager.default.fileExists(atPath: path) else { return }
        let pixelSize = targetPixelSize * (NSScreen.main?.backingScaleFactor ?? 2.0)
        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            Self.downsample(path: path, maxPixel: pixelSize)
        }.value
        if let loaded {
            ImageThumbnailCache.shared.store(loaded, for: key)
            self.image = loaded
        }
    }

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

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        Image(systemName: "film")
                            .foregroundStyle(.white.opacity(0.2))
                    )
            }
        }
        .task(id: "\(videoPath)#\(offsetMs)") { await load() }
    }

    private func load() async {
        let key = "mp4:\(videoPath)#\(offsetMs)|\(Int(targetPixelSize))"
        if let cached = ImageThumbnailCache.shared.cached(key) {
            self.image = cached
            return
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
            self.image = loaded
        }
    }

    nonisolated static func extract(videoPath: String, offsetMs: Int, fps: Double, maxPixel: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: videoPath) else { return nil }
        let url = URL(fileURLWithPath: videoPath)

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        // offset_ms is the position into the MP4. If the migration didn't
        // record one (offsetMs == 0 for legacy chunks before timestamp_ms
        // alignment), fall back to fps-based reasoning so the first frame
        // still renders.
        let seconds: Double
        if offsetMs > 0 {
            seconds = Double(offsetMs) / 1000.0
        } else {
            // No offset recorded — assume frame 0. Used by legacy MP4 chunks
            // where each chunk corresponds to one frame.
            let effectiveFps = fps > 0 ? fps : 0.5
            seconds = max(0.0 / effectiveFps, 0)
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
}
