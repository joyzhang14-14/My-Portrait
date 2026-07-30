import Foundation
import AppKit
import CoreGraphics
import GRDB
import os.log

/// 鼠标按下/松开 logger —— 跟 `KeystrokeCharLogger` 平行,挂**同一条** CGEventTap
/// callback(`KeystrokeLedger` 那条)。
///
/// 为什么挂那条 tap,而不是 `InputWatcher`:
/// `InputWatcher` 用 `NSEvent.addGlobalMonitorForEvents`,需要 **Input Monitoring**
/// 权限,而该权限已从 onboarding 移除(击键采集的 listenOnly tap 只要 Accessibility)。
/// 挂 InputWatcher 会在大多数机器上静默地一条都记不到。挂现成的 tap 则:同一权限、
/// 同一线程模型、时间戳与击键天然对齐(下游要把点击插进击键序列里排序)。
///
/// 为什么要采集鼠标:canvas 路靠回放击键流重建正文,而鼠标点击此前**零采集** ——
/// 用户点一下把光标挪到句子中间再打字,重建器只能按打字先后顺序拼在尾巴上。
/// 方向键只是「光标动了」的可见冰山(实验线实测 3 条全部错序,1 条还跨 session
/// 删掉了别的记录打的字),鼠标点击是水下那部分。
///
/// 线程模型(与 `KeystrokeCharLogger` 一致):
/// - `ingest(event:type:)` 在 CGEventTap callback 线程被**同步**调用
///   (`CGEvent` 是 C 结构,不能跨线程持有,坐标必须当场取出)
/// - DB 写派到 `writeQueue` 后台串行队列,**callback 不阻塞**
///
/// 采集层只记原始信号:不判「这一下点在哪个词上」、不判「插入点是否移动」。
/// 坐标→词的映射(要用 `frames.ocr_words_json` 的词级 bbox)以及要不要因此拒绝
/// 重建,全在实验线。
final class MouseClickLogger {

    private let store: MouseEventStore
    private let writeQueue = DispatchQueue(label: "com.myportrait.mouse-click.write")
    private let log = Logger(
        subsystem: "com.joyzhang.myportrait", category: "typing.mouse-click")

    /// 黑名单(同 typing 设置页),命中只清坐标、仍写行。
    /// `TypingObserver` 在 start() 时 snapshot 一份推过来。
    private var blacklist: Set<String> = []
    private let blacklistLock = NSLock()

    init(store: MouseEventStore) {
        self.store = store
    }

    /// `TypingObserver` 在 start() 时调用,推一份黑名单 snapshot。
    func updateBlacklist(_ ids: Set<String>) {
        blacklistLock.lock(); defer { blacklistLock.unlock() }
        blacklist = ids
    }

    /// 从 CGEventTap callback 同步调用 —— 内部异步写 DB,**不阻塞 callback**。
    /// `type` 必须是 `.leftMouseDown` / `.leftMouseUp` / `.rightMouseDown`。
    func ingest(event: CGEvent, type: CGEventType) {
        guard let kind = Self.kind(for: type) else { return }

        // 同步在 callback 线程取出 —— CGEvent 不能跨线程持有。
        let location = event.location
        // 双击/三击:双击后打字是**替换那个词**,三击是替换整行,语义与单击移动
        // 光标完全不同。系统把连击折叠成同一个 down 事件的 clickState。
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let flags = event.flags
        var modifiers = 0
        if flags.contains(.maskCommand)   { modifiers |= 0x01 }
        if flags.contains(.maskAlternate) { modifiers |= 0x02 }
        if flags.contains(.maskControl)   { modifiers |= 0x04 }
        if flags.contains(.maskShift)     { modifiers |= 0x08 }   // shift+click = 扩展选区
        let modifierBits = modifiers

        // 主显示器像素尺寸:OCR 的 bbox 是归一化 0..1,没有它就没法把坐标对到词,
        // 而 frames 表不存画面尺寸、事后不可恢复。CoreGraphics 的 display 查询
        // 可跨线程调(不碰 AppKit —— NSScreen 在 tap 线程读是另一类崩溃源,
        // 同 InputSourceCache 注释里 TIS 那个坑)。
        // ⚠️多显示器下 location 是 union 空间坐标,主屏尺寸只够单屏场景归一化;
        // 真要支持多屏得记「包含该点的那块屏」的 bounds,留给需要时再说。
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let screenW = Int(bounds.width)
        let screenH = Int(bounds.height)

        // ⚠️**投递目标**:tap 挂在 .headInsertEventTap,拿到事件时点击**还没生效**,
        // 所以下面那个 frontmost 是点击**之前**的窗口 —— 而「点一下把别的窗口切到
        // 前面」恰恰是最需要认对的场景,只看 frontmost 必然标错。这个字段是窗口
        // 服务器算好的「会投给谁」,从事件里直接读的整数:零枚举、零分配、无 race、
        // 不要额外权限。两者不同 = 这一下点击切换了 app,本身就是有用信号。
        // (不用 CGWindowListCopyWindowInfo 找「点在哪个窗口里」:它要分配全屏窗口
        //  数组,而 CGEventTap 有超时、回调慢会被 macOS 停掉 —— 那正是 5/22-5/23
        //  keystroke_log 大段空洞的真因,见 keystrokeLedgerTapCallback 顶部注释。)
        let targetPidRaw = event.getIntegerValueField(.eventTargetUnixProcessID)
        let targetPid = targetPidRaw > 0 ? Int(targetPidRaw) : nil

        // `frontmostApplication` 实测在后台线程读 cached 值稳定(同 KeystrokeCharLogger)。
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let store = self.store
        let logger = self.log
        let snapshot = { () -> Set<String> in
            blacklistLock.lock(); defer { blacklistLock.unlock() }; return blacklist
        }()
        writeQueue.async {
            // pid → bundle 解析放在**后台队列**,不占 callback。NSRunningApplication
            // 文档标注线程安全;进程此刻必然还活着(它正要收这个事件)。
            let targetBundle = targetPid
                .flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
                .flatMap { $0.bundleIdentifier }
            // frontmost 与 target 任一命中黑名单就清坐标 —— 坐标泄露的是**接收方**
            // 屏幕上的位置,只看 frontmost 会漏。
            let redact = snapshot.contains(app)
                || (targetBundle.map { snapshot.contains($0) } ?? false)
            do {
                var entry = MouseEventEntry(
                    id: nil,
                    tsMs: nowMs,
                    bundleId: app,
                    kind: kind,
                    targetPid: targetPid,
                    targetBundleId: targetBundle,
                    x: redact ? nil : location.x,
                    y: redact ? nil : location.y,
                    screenW: screenW,
                    screenH: screenH,
                    clickCount: max(1, clickCount),
                    modifiers: modifierBits
                )
                try store.insert(&entry)
            } catch {
                logger.warning("insert failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 只认这三种 —— `dragged` 是高频事件,不记(按下/松开两行就能还原拖拽选区)。
    static func kind(for type: CGEventType) -> String? {
        switch type {
        case .leftMouseDown:  return "left_down"
        case .leftMouseUp:    return "left_up"
        case .rightMouseDown: return "right_down"
        default:              return nil
        }
    }
}

// MARK: - MouseEventEntry + Store

/// 一条 `mouse_log` 记录(v42 schema)。
struct MouseEventEntry: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var tsMs: Int64
    var bundleId: String
    /// `left_down` / `left_up` / `right_down`。
    var kind: String
    /// 事件投递目标进程(`CGEvent.eventTargetUnixProcessID`)。拿不到时 nil。
    /// ⚠️`bundleId` 是点击**之前**的 frontmost(tap 在 app 收到事件前就拿到了),
    /// 两者不同 = 这一下点击切换了 app。判「光标落在哪个 app」要看 target。
    var targetPid: Int?
    /// `targetPid` 解析出的 bundle id(后台队列解析,失败为 nil)。
    var targetBundleId: String?
    /// 全局显示坐标系原始像素(左上原点)。黑名单 app 为 nil。
    var x: Double?
    var y: Double?
    /// 当时主显示器像素尺寸,给下游把坐标归一化到 OCR bbox 的 0..1 用。
    var screenW: Int?
    var screenH: Int?
    /// 1=单击 2=双击(选词) 3=三击(选行)。
    var clickCount: Int = 1
    /// Packed bit,与 keystroke_log 同一套:0x01=cmd 0x02=opt 0x04=ctrl 0x08=shift。
    var modifiers: Int = 0

    static let databaseTableName = "mouse_log"
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `mouse_log` 的 DAO,跟 `KeystrokeStore` 同一个 dbPool。
struct MouseEventStore: Sendable {

    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// INSERT 一条鼠标事件。`MouseClickLogger` 的 writeQueue 同步调用。
    func insert(_ entry: inout MouseEventEntry) throws {
        try dbPool.write { db in
            try entry.insert(db)
        }
    }
}
