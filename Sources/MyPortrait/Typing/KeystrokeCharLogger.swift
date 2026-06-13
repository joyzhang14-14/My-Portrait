import Foundation
import AppKit
import CoreGraphics
import Carbon            // TISCopyCurrentKeyboardInputSource(输入源/输入法)
import GRDB
import os.log

/// L3 keystroke 字符 logger —— 跟 `KeystrokeLedger` 平行,挂同一条 CGEventTap callback。
///
/// 职责拆分:
/// - `KeystrokeLedger`:时间戳 ring buffer,给 `hasKeystroke` 用(v14 typing observer)
/// - `KeystrokeCharLogger`(本类):抓 Unicode 字符 + bundle_id 写 `keystroke_log` DB,
///    给 LLM Pass 2 当 L3 输入用
///
/// 中文 IME 的限制实测确认过(见 `current-arch-and-blockers.md` Q-A):
/// `CGEventKeyboardGetUnicodeString` 拿到的是**拼音字母 + 选词数字键**,
/// **拿不到合成的汉字**。所以这里存的中文 char 永远是 latin 字母,真中文得靠
/// `typing_events`(普通 app)或 OCR(canvas)。
///
/// 线程模型:
/// - `ingest(event:isBackspace:)` 在 CGEventTap callback 线程被同步调用
///   (要在那里同步提取 unicode —— `CGEvent` 是 C 结构,不能跨线程持有)
/// - DB 写派到 `writeQueue` 后台串行队列,**callback 不阻塞**
///
/// 见 `canvas-editor-capture-design-final.md` §3.2, §9.1。
final class KeystrokeCharLogger {

    private let store: KeystrokeStore
    private let writeQueue = DispatchQueue(label: "com.myportrait.keystroke-char.write")
    private let log = Logger(
        subsystem: "com.joyzhang.myportrait", category: "typing.keystroke-char")

    /// 黑名单(同 typing 设置页),命中不录。
    /// hardcode 默认值 + 用户配置的 union。`TypingObserver` 在 start() 时
    /// snapshot 一份推过来。
    private var blacklist: Set<String> = []
    private let blacklistLock = NSLock()

    /// 输入源缓存(锁保护的 Sendable 小类)。TIS API 只能主线程调,缓存对象在主线程
    /// 初始化 + 监听切换刷新,callback 线程只读 `.current`。
    private let inputSourceCache = InputSourceCache()

    init(store: KeystrokeStore) {
        self.store = store
    }

    /// `TypingObserver` 在 start() 时调用,推一份黑名单 snapshot。
    /// 后续 ConfigStore 变化也可以重新推。
    func updateBlacklist(_ ids: Set<String>) {
        blacklistLock.lock(); defer { blacklistLock.unlock() }
        blacklist = ids
    }

    /// 从 CGEventTap callback 同步调用 —— 内部异步写 DB,**不阻塞 callback**。
    /// `event` 必须是 `.keyDown` 事件;`isBackspace` 由调用方根据 keyCode 判好。
    func ingest(event: CGEvent, isBackspace: Bool) {
        // 同步在 callback 线程提取 —— `CGEvent` 是 C 结构,不能跨线程持有。
        var length = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
        let chars = length > 0
            ? String(utf16CodeUnits: buf, count: length)
            : ""
        // 提取修饰键(packed bit 字段,见 keystroke_log v24 migration)
        let flags = event.flags
        var modifiers = 0
        if flags.contains(.maskCommand)   { modifiers |= 0x01 }
        if flags.contains(.maskAlternate) { modifiers |= 0x02 }   // Option / Alt
        if flags.contains(.maskControl)   { modifiers |= 0x04 }
        if flags.contains(.maskShift)     { modifiers |= 0x08 }
        // `frontmostApplication` 实测在后台线程读 cached 值稳定(KeystrokeProbe 已验证)。
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 击键当时所用的输入源(如 keylayout.US=英文键盘 / inputmethod.Squirrel=拼音)。
        // 读主线程维护的缓存(TIS 不能在 callback 线程调,会崩);切换通知保证缓存跟手。
        // 只记这一个原始信号,判别"拉丁是英文字面还是拼音"的逻辑全在实验线,不进 Swift。
        let inputSource = inputSourceCache.current

        // 黑名单短路 —— 命中就不进队列了
        blacklistLock.lock()
        let drop = blacklist.contains(app)
        blacklistLock.unlock()
        if drop { return }

        // 派到后台写 DB —— callback 立刻返回
        let store = self.store
        let logger = self.log
        writeQueue.async {
            do {
                var entry = KeystrokeEntry(
                    id: nil,
                    tsMs: nowMs,
                    bundleId: app,
                    char: chars.isEmpty ? nil : chars,
                    isBackspace: isBackspace ? 1 : 0,
                    modifiers: modifiers,
                    inputSource: inputSource
                )
                try store.insert(&entry)
            } catch {
                logger.warning("insert failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

}

// MARK: - InputSourceCache

/// 输入源缓存。TIS/TSM API 内部 `dispatch_assert_queue(main)` —— **只能在主线程调**
/// (callback/tap 线程同步调会崩,实测 EXC_BREAKPOINT in TSMGetInputSourceProperty)。
/// 本对象在主线程初始化 + 监听输入法切换通知刷新缓存,callback 线程只读 `.current`。
/// 锁保护 → `@unchecked Sendable`,可安全跨线程持有。
final class InputSourceCache: @unchecked Sendable {
    private var cached: String?
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init() {
        DispatchQueue.main.async { [self] in
            refresh()
            observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil, queue: .main
            ) { [self] _ in refresh() }
        }
    }

    deinit {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
    }

    /// callback 线程读:击键当时的输入源 ID(切换通知保证缓存跟手)。
    var current: String? {
        lock.lock(); defer { lock.unlock() }; return cached
    }

    /// 主线程刷新缓存(TIS 要求主线程)。
    private func refresh() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        else { lock.lock(); cached = nil; lock.unlock(); return }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        lock.lock(); cached = id; lock.unlock()
    }
}

// MARK: - KeystrokeEntry + Store

/// 一条 `keystroke_log` 记录(v19 schema + v24 加 modifiers)。
struct KeystrokeEntry: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var tsMs: Int64
    var bundleId: String
    var char: String?              // nullable:纯退格 / 修饰键时为 nil
    var isBackspace: Int           // 0 / 1
    /// Packed bit 字段:0x01=cmd, 0x02=opt, 0x04=ctrl, 0x08=shift。无修饰=0。
    var modifiers: Int = 0
    /// 击键时所用的输入源 ID(如 `com.apple.keylayout.US`=英文键盘 /
    /// `im.rime.inputmethod.Squirrel`=拼音)。用于实验线判别"拉丁是英文字面还是拼音";
    /// 判别逻辑全在实验线,采集层只记这一个原始信号。旧行 / 拿不到时 nil。
    var inputSource: String? = nil

    static let databaseTableName = "keystroke_log"
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// 修饰键 packed Int → 人类可读字符串(给 LLM payload 用)。
    /// 例:0x01 → "cmd";0x09 → "cmd+shift";0 → nil。
    static func modifiersString(_ packed: Int) -> String? {
        var parts: [String] = []
        if packed & 0x01 != 0 { parts.append("cmd") }
        if packed & 0x02 != 0 { parts.append("opt") }
        if packed & 0x04 != 0 { parts.append("ctrl") }
        if packed & 0x08 != 0 { parts.append("shift") }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }
}

/// `keystroke_log` 的 DAO,跟 `TypingEventStore` 同一个 dbPool。
struct KeystrokeStore: Sendable {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// INSERT 一条击键。`KeystrokeCharLogger` 的 writeQueue 同步调用。
    func insert(_ entry: inout KeystrokeEntry) throws {
        try dbPool.write { db in
            try entry.insert(db)
        }
    }
}
