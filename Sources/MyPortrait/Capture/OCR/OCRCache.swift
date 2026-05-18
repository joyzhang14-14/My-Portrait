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

    init(config: CaptureConfig) {
        self.config = config
    }

    /// 查缓存。命中时刷新 `lastAccess`。TTL 超期视为未命中并清掉条目。
    func get(key: OCRCacheKey, now: Date = Date()) -> OCRResult? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }

        if now.timeIntervalSince(entry.lastAccess) > config.ocrCacheTTLSeconds {
            entries[key] = nil
            return nil
        }

        // 命中：刷新 lastAccess（用作 LRU 排序）。
        var updated = entry
        updated.lastAccess = now
        entries[key] = updated
        return updated.value
    }

    /// 写入缓存。超出 LRU 容量时淘汰 `lastAccess` 最早的条目。
    ///
    /// 复杂度：写入 O(1)；超容淘汰 O(n)，但 n=100，且只在 miss + 满时发生。
    func put(key: OCRCacheKey, value: OCRResult, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        if entries[key] != nil {
            entries[key] = CacheEntry(value: value, lastAccess: now)
            return
        }

        entries[key] = CacheEntry(value: value, lastAccess: now)

        if entries.count > config.ocrCacheMaxEntries {
            // 找最早访问的条目踢掉。100 条规模 O(n) 也就 ~100ns。
            var oldestKey: OCRCacheKey?
            var oldestDate = Date.distantFuture
            for (k, e) in entries where e.lastAccess < oldestDate {
                oldestDate = e.lastAccess
                oldestKey = k
            }
            if let k = oldestKey {
                entries[k] = nil
            }
        }
    }

    /// 清空所有条目。屏幕解锁 / app 切换批量发生时调。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// 当前条目数（调试 / 测试用）。
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
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
