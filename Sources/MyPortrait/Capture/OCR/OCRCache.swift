import Foundation

/// `(app::title, imageHash)` → OCRResult 缓存。
///
/// 双重淘汰：TTL（默认 5 分钟）+ LRU（默认 100 条）。
///
/// 设计：`final class @unchecked Sendable + NSLock`。
/// 性能优先决定：不用 actor —— 跨 actor 边界比 NSLock 重得多，LRU 查询 O(1)
/// 本身就极便宜，关键是别让锁等待蔓延到调用方的 actor。
///
/// 用法（线程安全）：
/// ```swift
/// if let cached = cache.get(key: k) { return cached }
/// let result = try await ocr.recognize(image: img, focus: f)
/// cache.put(key: k, value: result)
/// ```
final class OCRCache: @unchecked Sendable {

    private let lock = NSLock()
    private let config: CaptureConfig
    private var entries: [OCRCacheKey: CacheEntry] = [:]
    private var lruOrder: [OCRCacheKey] = []

    init(config: CaptureConfig) {
        self.config = config
    }

    /// 查缓存。命中时刷新 LRU 顺序。
    /// P0：永远返回 nil（无缓存）。
    func get(key: OCRCacheKey, now: Date = Date()) -> OCRResult? {
        nil
    }

    /// 写入缓存。超出 LRU 容量时淘汰最久未访问。
    /// P0：noop。
    func put(key: OCRCacheKey, value: OCRResult, now: Date = Date()) {
        // noop
    }

    /// 清空所有条目。屏幕解锁 / app 切换批量发生时调。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        lruOrder.removeAll()
    }

    private struct CacheEntry {
        let value: OCRResult
        var lastAccess: Date
    }
}

/// 缓存 key。
/// - `appTitle`: 形如 "Safari::GitHub - PR #123"
/// - `imageHash`: 帧下采样 1/6 后的 pixel hash
public struct OCRCacheKey: Hashable, Sendable {
    public let appTitle: String
    public let imageHash: UInt64

    public init(appTitle: String, imageHash: UInt64) {
        self.appTitle = appTitle
        self.imageHash = imageHash
    }
}
