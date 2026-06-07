/// TypingObserver —— Typing Observer v2 顶层 orchestrator（v14 splice 模型）。
///
/// 通过 Accessibility (AX) API 订阅 frontmost app 的 focused text element，
/// 每次 `kAXValueChangedNotification` 把当前 AX value 交给
/// `TypingRecordWriter` —— 后者经 350ms debounce 收敛后用
/// `TextDiff.sandwich` 出 delta、就地 splice 进该 (app, element) session。
///
/// **AX 调用不在主线程跑**：`AXUIElementCopyAttributeValue` /
/// `AXObserverAddNotification` 等是同步跨进程调用，目标 app 卡住时会死锁。
/// 这里把每个 AX C 调用经 `axCall` 挪到后台串行队列 `AXSerialQueue`，MainActor
/// 用 `await` 等它 —— 调用真卡死也只卡住 AXSerialQueue，主线程照常跑 run loop、
/// app 不冻。所有 AX 操作再经 `enqueueAXOp` 串成一条链，保证顺序 +
/// `attachment` 不被并发改。
///
/// 生命周期：挂到 frontmost app，监听 NSWorkspace app 切换，切换时 flush
/// 旧 app 的 records、detach 旧 AXObserver、attach 新 app。

import AppKit
import ApplicationServices
import Foundation
import os.log
import QuartzCore

/// AX C 类型（AXUIElement / AXObserver）不是 Sendable，但跨线程传引用、
/// 跨线程调 AX C API 是安全的。装箱过 Swift 6 的 Sendable 检查。
private struct SendableBox<T>: @unchecked Sendable { let v: T }

@MainActor
final class TypingObserver {

    // MARK: - AX 订阅状态

    private struct Attachment {
        let pid: pid_t
        let bundleId: String
        let appName: String?
        let observer: AXObserver
        let appElement: AXUIElement
        var focusedElement: AXUIElement?
    }

    private var attachment: Attachment?
    private typealias ElementKey = TypingRecordWriter.ElementKey

    // MARK: - 依赖

    private let ledger = KeystrokeLedger()
    private let writer: TypingRecordWriter
    private let pasteboardMonitor = PasteboardMonitor()
    /// L3 字符 logger —— 挂在 KeystrokeLedger 同条 CGEventTap callback。
    /// 生产模式注入(写 keystroke_log),dev/observe 模式 nil。
    private let keystrokeCharLogger: KeystrokeCharLogger?

    /// 旧 `--typing-observe-m3` dev flag 的消费口（v14 已不喂 L2，仅编译兼容）。
    var onFoldEvent: (([IMEFoldEvent]) -> Void)?

    var onDevLog: ((String) -> Void)? {
        didSet { writer.onDevLog = onDevLog }
    }

    private let modeLabel: String

    // MARK: - AX 后台队列 / 串行 op 链

    /// AX 操作串行链 —— 每个 op 等上一个完成，保证顺序、`attachment` 不并发改。
    private var axOpChain: Task<Void, Never>?

    // MARK: - 其它状态

    private var workspaceObserverToken: NSObjectProtocol?
    private var blacklistCleanupTimer: Timer?
    private var running = false

    private static let messagingTimeout: Float = 1.5
    private static let blacklistCleanupSec: TimeInterval = 300

    private let pipelineLog = Logger(subsystem: "com.joyzhang.myportrait",
                                     category: "typing.pipeline")

    // MARK: - 生命周期

    init(
        store: TypingEventStore? = nil,
        keystrokeStore: KeystrokeStore? = nil,
        modeLabel: String = "production"
    ) {
        self.modeLabel = modeLabel
        self.writer = TypingRecordWriter(store: store, ledger: ledger, pasteboard: pasteboardMonitor)
        self.keystrokeCharLogger = keystrokeStore.map { KeystrokeCharLogger(store: $0) }
    }

    func start() {
        guard !running else { return }

        // L3 字符 logger 必须在 ledger.start() 之前挂上 —— start() 后 tap
        // 立刻活,callback 已经会读 ledger.charLogger。
        if let charLogger = keystrokeCharLogger {
            // 同步 typing 黑名单 snapshot 给 keystroke_log 写入路径。
            // 只塞 app 级 entries(urlPrefix 空):keystroke_log 行级没有 URL
            // 信息,只能按 bundle_id 屏蔽。URL 级屏蔽走 TypingRecordWriter
            // 那条路。
            let entries = ConfigStore.shared.privacy.typingBlacklistEntries
            let appLevel = entries.compactMap { $0.urlPrefix.isEmpty ? $0.bundleId : nil }
            let hardcoded = TypingPrivacyFilter.defaultBlacklist
            let union = Set(hardcoded).union(appLevel)
            charLogger.updateBlacklist(union)
            ledger.charLogger = charLogger
        }

        // 回车摇读:回车一按,延迟几 ms 抢读焦点字段现值喂回 writer —— 救 IME 末尾
        // 落字被「发送清空/跳页」抢在采集前(聊天 app 字段发送前会短暂显示落定值,
        // 可能救回;搜索跳页字段没显示过落定值,通常仍救不了)。实验性,延迟需真机调。
        ledger.onSubmitKey = { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                await self.submitRaceBurst()
            }
        }

        do {
            try ledger.start()
        } catch {
            pipelineLog.warning("KeystrokeLedger.start failed: \(String(describing: error), privacy: .public)")
        }
        pasteboardMonitor.start()
        logStartupBanner()

        guard AXIsProcessTrusted() else {
            print("[TypingObserver] AX not granted — idle")
            return
        }
        running = true

        blacklistCleanupTimer = Timer.scheduledTimer(
            withTimeInterval: Self.blacklistCleanupSec, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.writer.cleanupBlacklist(now: CACurrentMediaTime()) }
        }

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserverToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid: pid_t = app?.processIdentifier ?? -1
            MainActor.assumeIsolated {
                self?.enqueueAXOp { await self?.handleAppActivated(pid: pid) }
            }
        }

        enqueueAXOp { [weak self] in await self?.attachToFrontmostApp() }
        print("[TypingObserver] started")
    }

    func stop() {
        guard running else { return }
        running = false

        blacklistCleanupTimer?.invalidate()
        blacklistCleanupTimer = nil
        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserverToken = nil
        }

        writer.flushAll()
        pasteboardMonitor.stop()
        // 先 ledger.stop()(关 tap 并 wait 到 tap 线程 RunLoop 退出),再清
        // charLogger。否则 charLogger=nil 跟仍在跑的 tap 线程读 charLogger
        // (KeystrokeLedger:441)对同一指针并发 retain/release → 数据竞争。
        ledger.stop()
        ledger.charLogger = nil
        // detach 串进 op 链 —— 等在飞的 AX op 跑完再清，避免 CFRelease 撞用。
        enqueueAXOp { [weak self] in self?.detach() }
        print("[TypingObserver] stopped")
    }

    /// `isolated deinit` —— MainActor 上跑（SE-0371）。
    isolated deinit {
        blacklistCleanupTimer?.invalidate()
        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let att = attachment {
            Self.teardown(att)
        }
    }

    // MARK: - AX 后台调用 / op 链

    /// 把一个 AX C 调用挪到后台串行队列跑，MainActor `await` 它。
    /// 调用卡死也只卡 AXSerialQueue，主线程照常跑 run loop。
    private func axCall<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            AXSerialQueue.shared.async { cont.resume(returning: work()) }
        }
    }

    /// 把一个 AX 操作串进链尾 —— 等上一个 op 完成再跑，保证顺序。
    private func enqueueAXOp(_ op: @escaping @MainActor () async -> Void) {
        let prev = axOpChain
        axOpChain = Task { @MainActor in
            await prev?.value
            await op()
        }
    }

    // MARK: - 启动 banner

    private func logStartupBanner() {
        let cfg = ConfigStore.shared.capture
        print("[TypingObserver] starting (mode=\(modeLabel))")
        print("[TypingObserver] config:")
        print("  typing_capture_enabled    = \(cfg.typingCaptureEnabled)")
        print("  keyboard_correlation_ms   = \(cfg.typingKeyCorrelationWindowMs)")
        if ledger.isRunning {
            print("  keystroke_ledger          = running")
        } else {
            print("  keystroke_ledger          = down   ⚠️  WILL DROP ALL INPUT")
        }
        print("  terminal_blocklist        = \(TypingPrivacyFilter.terminalBlocklistCount) apps")
        if AXIsProcessTrusted() {
            print("  ax_permission             = granted")
        } else {
            print("  ax_permission             = DENIED   ⚠️  OBSERVER WILL NOT START")
        }
    }

    // MARK: - attach / detach

    private func attachToFrontmostApp() async {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("[TypingObserver] no frontmost app")
            return
        }
        await attach(to: app)
    }

    private func handleAppActivated(pid: pid_t) async {
        if let oldBundle = attachment?.bundleId {
            writer.flushApp(bundleId: oldBundle)
            let msg = "app-switch flush bundle=\(oldBundle)"
            pipelineLog.info("\(msg, privacy: .public)")
            onDevLog?(msg)
        }
        detach()
        guard running, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        await attach(to: app)
    }

    private func attach(to app: NSRunningApplication) async {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName

        if TypingPrivacyFilter.isBlacklisted(bundleId: bundleId) {
            print("[TypingObserver] skipped — blacklisted app bundle=\(bundleId)")
            return
        }
        if TypingPrivacyFilter.isTerminalApp(bundleId: bundleId) {
            print("[TypingObserver] terminal app, observer idle bundle=\(bundleId)")
            return
        }

        // AXObserverCreate 在 AXSerialQueue 上跑（不卡主线程）。
        let cb = Self.axCallback
        let created: SendableBox<AXObserver?> = await axCall {
            var ref: AXObserver?
            return SendableBox(v: AXObserverCreate(pid, cb, &ref) == .success ? ref : nil)
        }
        guard running, let observer = created.v else {
            print("[TypingObserver] AXObserverCreate failed for \(bundleId)")
            return
        }
        // observer 是 CFType：CFRetain 持有，detach/deinit 时 CFRelease 平衡。
        _ = Unmanaged.passRetained(observer)

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let obsBox = SendableBox(v: observer)
        let appBox = SendableBox(v: appElement)
        let refconBox = SendableBox(v: refcon)
        _ = await axCall {
            AXObserverAddNotification(
                obsBox.v, appBox.v,
                kAXFocusedUIElementChangedNotification as CFString, refconBox.v)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer), .commonModes
        )

        // 在 await 期间可能已被 stop()/再次 app-switch 改写 —— 重核。
        guard running, attachment == nil else {
            Self.teardown(Attachment(pid: pid, bundleId: bundleId, appName: appName,
                                     observer: observer, appElement: appElement,
                                     focusedElement: nil))
            return
        }
        attachment = Attachment(
            pid: pid, bundleId: bundleId, appName: appName,
            observer: observer, appElement: appElement, focusedElement: nil
        )
        await subscribeFocusedElement()
    }

    private func detach() {
        guard let att = attachment else { return }
        attachment = nil
        Self.teardown(att)
    }

    /// AX 清理。**不调 `AXObserverRemoveNotification`**（同步跨进程，会卡死）——
    /// observer 紧接着 CFRelease，注册的 notification 随它一起销毁。
    /// `CFRunLoopRemoveSource` + `CFRelease` 都是本地操作，不阻塞。
    nonisolated private static func teardown(_ att: Attachment) {
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(att.observer), .commonModes
        )
        Unmanaged.passUnretained(att.observer).release()
    }

    // MARK: - focused 元素订阅

    private func subscribeFocusedElement() async {
        guard let att0 = attachment else { return }
        let observer = att0.observer
        let appElement = att0.appElement

        // 撤旧 focused 元素订阅（v14 仍保留这一处 remove —— observer 活着）。
        if let old = att0.focusedElement {
            let obsBox = SendableBox(v: observer)
            let oldBox = SendableBox(v: old)
            _ = await axCall {
                AXObserverRemoveNotification(
                    obsBox.v, oldBox.v, kAXValueChangedNotification as CFString)
            }
            guard running, attachment != nil else { return }
            attachment?.focusedElement = nil
        }

        // 读 focused 元素。
        let appBox = SendableBox(v: appElement)
        let focusedResult: SendableBox<AXUIElement?> = await axCall {
            var ref: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(
                appBox.v, kAXFocusedUIElementAttribute as CFString, &ref)
            return SendableBox(v: (e == .success ? (ref.map { $0 as! AXUIElement }) : nil))
        }
        guard running, attachment != nil, let focused = focusedResult.v else { return }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let obsBox = SendableBox(v: observer)
        let focBox = SendableBox(v: focused)
        let refconBox = SendableBox(v: refcon)
        let addErr: Int32 = await axCall {
            AXObserverAddNotification(
                obsBox.v, focBox.v, kAXValueChangedNotification as CFString,
                refconBox.v).rawValue
        }
        guard running, attachment != nil else { return }
        if addErr != AXError.success.rawValue {
            print("[TypingObserver] add value-changed notification failed (\(addErr))")
            return
        }
        attachment?.focusedElement = focused

        // 读 baseline。
        let baseline: String = await axCall {
            var ref: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(
                focBox.v, kAXValueAttribute as CFString, &ref)
            return (e == .success ? (ref as? String) : nil) ?? ""
        }
        guard running, let attB = attachment else { return }

        // 浏览器 app → 读焦点窗口 AXDocument 拿当前页面 URL（同 FocusProbe）。
        // 浏览器 app → 从焦点元素往上爬，找 AXWebArea 的 AXURL（值是 CFURL）。
        // 多个 AXWebArea（iframe 嵌套）时外层覆盖内层 → 留最外层 = 顶层页面。
        var url = ""
        if Self.browserBundleIds.contains(attB.bundleId) {
            url = await axCall {
                func parent(_ el: AXUIElement) -> AXUIElement? {
                    var p: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(
                            el, kAXParentAttribute as CFString, &p) == .success,
                          let p, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
                    return (p as! AXUIElement)
                }
                var result = ""
                var cur: AXUIElement? = focBox.v
                for _ in 0..<12 {
                    guard let c = cur else { break }
                    var ref: CFTypeRef?
                    if AXUIElementCopyAttributeValue(c, "AXURL" as CFString, &ref) == .success,
                       let nsurl = ref as? NSURL, let s = nsurl.absoluteString,
                       s.hasPrefix("http") {
                        result = s
                    }
                    cur = parent(c)
                }
                return result
            }
            guard running, attachment != nil else { return }
        }

        guard let att = attachment else { return }
        let key = ElementKey(pid: att.pid, elementHash: Int(bitPattern: CFHash(focused)))
        writer.beginSession(key: key, bundleId: att.bundleId, baseline: baseline, url: url)
    }

    /// 9 个浏览器 bundle id —— 跟 FocusProbe.browserBundleIds 平行（各自维护）。
    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "org.chromium.Chromium",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox",
    ]

    // MARK: - 通知处理

    /// AXObserver 的 C 回调。run-loop source 在 main loop → 此函数跑在主线程，
    /// 但只做「串一个 op 进链」这件轻活，不碰 AX C API、不阻塞。
    private static let axCallback: AXObserverCallback = {
        _, _, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<TypingObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        MainActor.assumeIsolated {
            observer.enqueueAXOp { [weak observer] in
                await observer?.handleNotification(name)
            }
        }
    }

    private func handleNotification(_ name: String) async {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            if let att = attachment, let old = att.focusedElement {
                let oldKey = ElementKey(pid: att.pid, elementHash: Int(bitPattern: CFHash(old)))
                writer.flushElement(oldKey)
            }
            await subscribeFocusedElement()
        case kAXValueChangedNotification:
            await processValueChange()
        default:
            break
        }
    }

    // MARK: - 值变化 → writer

    private func processValueChange() async {
        guard let att = attachment, let focused = att.focusedElement else { return }
        let focBox = SendableBox(v: focused)

        // secure field（密码框）不读值。
        let role: String? = await axCall {
            var ref: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(
                focBox.v, kAXRoleAttribute as CFString, &ref)
            return (e == .success ? (ref as? String) : nil)
        }
        if TypingPrivacyFilter.isSecureRole(role) { return }

        let newValue: String? = await axCall {
            var ref: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(
                focBox.v, kAXValueAttribute as CFString, &ref)
            return (e == .success ? (ref as? String) : nil)
        }
        // await 期间 focus / app 可能已变 —— 重核仍是同一 element。
        guard running, let att2 = attachment, let focused2 = att2.focusedElement,
              CFHash(focused2) == CFHash(focused), let newValue else { return }
        let key = ElementKey(pid: att2.pid, elementHash: Int(bitPattern: CFHash(focused2)))
        writer.noteValueChange(key: key, newValue: newValue)
    }

    // MARK: - 回车摇读(IME 末尾落字救援,实验性)

    /// 摇读的多档延迟(从回车起算的**累计 ms**):**每 5ms 一读、一直读到 200ms**。
    /// Electron app(claudefordesktop)的 AX 在 IME 落字时传播很慢(实测落字后 500ms
    /// AX 还停在拼音),短延迟根本抢不到落定的汉字 —— 所以密集扫到 200ms,赌这窗口里
    /// AX 总会冒出落定值。读到空(字段清空)立即停;同值不重复喂、但继续读(落定值一
    /// 出现就喂,占位符只喂一次触发发送,不 spam)。研究参照:macism 称 CJK race 完全
    /// 稳定要 ~150ms。
    private static let submitRaceDelaysMs: [UInt64] = Array(stride(from: 5, through: 200, by: 5))

    /// 回车一按,按上面多档延迟连读焦点字段现值喂回 writer —— 趁「发送清空/跳页」前
    /// 把 IME 末尾落定的字截下来。复用 processValueChange 同款安全读(secure 跳过、
    /// 每读重核仍是同一 element)。读到空 → 停(已清空,别喂占位符)。
    @MainActor
    private func submitRaceBurst() async {
        guard running, let att = attachment, let focused = att.focusedElement else { return }
        let focBox = SendableBox(v: focused)
        let role: String? = await axCall {
            var ref: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(focBox.v, kAXRoleAttribute as CFString, &ref)
            return (e == .success ? (ref as? String) : nil)
        }
        if TypingPrivacyFilter.isSecureRole(role) { return }
        var slept: UInt64 = 0
        var lastFed: String? = nil
        for target in Self.submitRaceDelaysMs {
            try? await Task.sleep(nanoseconds: (target - slept) * 1_000_000)
            slept = target
            guard running, let att2 = attachment, let focused2 = att2.focusedElement,
                  CFHash(focused2) == CFHash(focused) else { return }
            let value: String? = await axCall {
                var ref: CFTypeRef?
                let e = AXUIElementCopyAttributeValue(focBox.v, kAXValueAttribute as CFString, &ref)
                return (e == .success ? (ref as? String) : nil)
            }
            guard let value else { return }
            if value.isEmpty { return }       // 字段已清空 → 停
            if value == lastFed { continue }  // 同值不重复喂,但继续读(等落定值/清空冒出来)
            let key = ElementKey(pid: att2.pid, elementHash: Int(bitPattern: CFHash(focused2)))
            writer.noteValueChange(key: key, newValue: value)
            lastFed = value
        }
    }
}
