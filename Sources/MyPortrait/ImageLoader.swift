import SwiftUI
import AppKit
import ImageIO

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
