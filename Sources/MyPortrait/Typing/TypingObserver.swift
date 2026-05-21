/// TypingObserver —— Typing Observer v2 顶层 orchestrator（v14 splice 模型）。
///
/// 通过 Accessibility (AX) API 订阅 frontmost app 的 focused text element，
/// 每次 `kAXValueChangedNotification` 把当前 AX value 交给
/// `TypingRecordWriter` —— 后者经 350ms debounce 收敛后用
/// `TextDiff.sandwich` 出 delta、就地 splice 进该 (app, element) session 的
/// `text`，session flush 时 INSERT 一条新 record。
///
/// v14 砍掉了 marked-range composition 检测 与 Layer 2（IMEStateMachine）——
/// splice 的 `replaceSubrange` 天然就地纠正 IME 候选；debounce 收敛拼音中间态。
/// IMEStateMachine* 文件暂留（future commit 删）。
///
/// 并发模型：
///   AXObserver 的 C 回调（@convention(c)）契约上跑在主线程 —— 它的
///   run-loop source 被加到 CFRunLoopGetMain()。回调里用
///   `MainActor.assumeIsolated { }` 同步进入 MainActor，不用 `Task {}`
///   （会异步推迟、导致回调间乱序）。
///
/// 生命周期：挂到 frontmost app，监听 NSWorkspace app 切换通知，切换时
/// flush 旧 app 的 records、detach 旧 AXObserver、attach 新 app。

import AppKit
import ApplicationServices
import Foundation
import os.log
import QuartzCore

@MainActor
final class TypingObserver {

    // MARK: - AX 订阅状态

    /// 当前挂着的一组 AX 资源。app 切换时整体替换。
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

    /// Layer 1 —— CGEventTap 记录物理按键 / ⌘V / 回车。writer 据此判定
    /// 键盘活动关联、粘贴、发送。
    private let ledger = KeystrokeLedger()

    /// Layer 4 —— 写入层（per-element session / splice / flush / 黑名单）。
    private let writer: TypingRecordWriter

    /// 剪贴板镜像 —— 判定插入文本是不是粘贴来的。
    private let pasteboardMonitor = PasteboardMonitor()

    /// 旧 `--typing-observe-m3` dev flag 的消费口。v14 已不喂 Layer 2，
    /// 此属性保留仅为 m3 flag 编译兼容，实际不再被调用。
    var onFoldEvent: (([IMEFoldEvent]) -> Void)?

    /// dev flag 日志出口。设置时同步给 writer。
    var onDevLog: ((String) -> Void)? {
        didSet { writer.onDevLog = onDevLog }
    }

    /// 启动 banner 的运行模式标签。
    private let modeLabel: String

    // MARK: - 其它状态

    private var workspaceObserverToken: NSObjectProtocol?
    private var blacklistCleanupTimer: Timer?
    private var running = false

    private static let messagingTimeout: Float = 1.5
    private static let blacklistCleanupSec: TimeInterval = 300

    private let pipelineLog = Logger(subsystem: "com.joyzhang.myportrait",
                                     category: "typing.pipeline")

    // MARK: - 生命周期

    /// - Parameters:
    ///   - store: typing_events DAO。`nil`（dev 模式无 DB）时只在内存里跑、不落库。
    ///   - modeLabel: 启动 banner 的模式标签。
    init(store: TypingEventStore? = nil, modeLabel: String = "production") {
        self.modeLabel = modeLabel
        self.writer = TypingRecordWriter(store: store, ledger: ledger)
    }

    func start() {
        guard !running else { return }

        // Layer 1 起 CGEventTap。失败不崩，KeystrokeLedger 自身 log warning。
        do {
            try ledger.start()
        } catch {
            pipelineLog.warning("KeystrokeLedger.start failed: \(String(describing: error), privacy: .public)")
        }
        pasteboardMonitor.start()

        // 启动 banner —— 第一时间 print config / gate 状态，修补 silent failure。
        logStartupBanner()

        guard AXIsProcessTrusted() else {
            print("[TypingObserver] AX not granted — idle")
            return
        }
        running = true

        // 黑名单 TTL 清理：每 5min 扫一遍。
        blacklistCleanupTimer = Timer.scheduledTimer(
            withTimeInterval: Self.blacklistCleanupSec, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writer.cleanupBlacklist(now: CACurrentMediaTime())
            }
        }

        // 监听 app 切换。
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserverToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid: pid_t = app?.processIdentifier ?? -1
            MainActor.assumeIsolated { self?.handleAppActivated(pid: pid) }
        }

        attachToFrontmostApp()
        print("[TypingObserver] started")
    }

    /// 停止并清理（幂等）。flush 所有 in-progress session 落库。
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
        ledger.stop()
        detach()
        print("[TypingObserver] stopped")
    }

    /// `isolated deinit` —— MainActor 上跑（SE-0371），才能安全读隔离字段。
    isolated deinit {
        blacklistCleanupTimer?.invalidate()
        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let att = attachment {
            Self.teardown(att)
        }
    }

    // MARK: - 启动 banner

    private func logStartupBanner() {
        let cfg = ConfigStore.shared.recording
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

    private func attachToFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("[TypingObserver] no frontmost app")
            return
        }
        attach(to: app)
    }

    private func handleAppActivated(pid: pid_t) {
        // app 切走：flush 旧 app 的所有 in-progress session 落库。
        if let oldBundle = attachment?.bundleId {
            writer.flushApp(bundleId: oldBundle)
            let msg = "app-switch flush bundle=\(oldBundle)"
            pipelineLog.info("\(msg, privacy: .public)")
            onDevLog?(msg)
        }
        detach()
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        attach(to: app)
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName

        // 隐私闸门：密码管理器 / 机密类 app 整体不订阅 AX。
        if TypingPrivacyFilter.isBlacklisted(bundleId: bundleId) {
            print("[TypingObserver] skipped — blacklisted app bundle=\(bundleId)")
            return
        }
        // 终端黑名单（算法限制）：终端输入/输出共享同一 AX 元素。
        if TypingPrivacyFilter.isTerminalApp(bundleId: bundleId) {
            print("[TypingObserver] terminal app, observer idle bundle=\(bundleId)")
            return
        }

        var observerRef: AXObserver?
        let createErr = AXObserverCreate(pid, Self.axCallback, &observerRef)
        guard createErr == .success, let observer = observerRef else {
            print("[TypingObserver] AXObserverCreate failed (\(createErr.rawValue)) for \(bundleId)")
            return
        }
        // observer 是 CFType：CFRetain 持有，detach/deinit 时 CFRelease 平衡。
        _ = Unmanaged.passRetained(observer)

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let focusErr = AXObserverAddNotification(
            observer, appElement,
            kAXFocusedUIElementChangedNotification as CFString, refcon
        )
        if focusErr != .success {
            print("[TypingObserver] add focus-changed notification failed (\(focusErr.rawValue)) for \(bundleId)")
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        attachment = Attachment(
            pid: pid, bundleId: bundleId, appName: appName,
            observer: observer, appElement: appElement, focusedElement: nil
        )
        subscribeFocusedElement()
    }

    private func detach() {
        guard let att = attachment else { return }
        attachment = nil
        Self.teardown(att)
    }

    /// AX 清理，deinit 与 detach 共用。`nonisolated` 以便 nonisolated deinit 也能调。
    ///
    /// **不调 `AXObserverRemoveNotification`**：它是同步跨进程调用，切走 app
    /// 时目标 app 正忙 / 后台化会把主线程吊死在 `__ulock_wait`。observer
    /// 紧接着 `CFRelease`，注册的 notification 随 observer 一起销毁。
    nonisolated private static func teardown(_ att: Attachment) {
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(att.observer),
            .commonModes
        )
        Unmanaged.passUnretained(att.observer).release()
    }

    // MARK: - focused 元素订阅

    /// 读 app 当前 focused 元素，订阅它的 kAXValueChangedNotification，
    /// 并让 writer 为它开一段新 session（baseline = 此刻 AX value）。
    private func subscribeFocusedElement() {
        guard var att = attachment else { return }

        if let old = att.focusedElement {
            AXObserverRemoveNotification(
                att.observer, old, kAXValueChangedNotification as CFString
            )
            att.focusedElement = nil
        }

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            att.appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard err == .success, let focusedRef else {
            attachment = att   // 无 focused 元素（如桌面）—— 静默
            return
        }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(
            att.observer, focused, kAXValueChangedNotification as CFString, refcon
        )
        if addErr != .success {
            print("[TypingObserver] add value-changed notification failed (\(addErr.rawValue)) bundle=\(att.bundleId)")
            attachment = att
            return
        }
        att.focusedElement = focused
        attachment = att

        // 读 baseline（此刻 element 完整内容）→ writer 开新 session。
        var baselineRef: CFTypeRef?
        let baselineErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &baselineRef
        )
        let baseline = (baselineErr == .success ? (baselineRef as? String) : nil) ?? ""
        let key = ElementKey(pid: att.pid, elementHash: Int(CFHash(focused)))
        writer.beginSession(key: key, bundleId: att.bundleId, baseline: baseline)
    }

    // MARK: - 通知处理

    /// AXObserver 的 C 回调。run-loop source 在 main loop，故此函数跑在主线程。
    private static let axCallback: AXObserverCallback = {
        _, _, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<TypingObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        MainActor.assumeIsolated {
            observer.handleNotification(name)
        }
    }

    private func handleNotification(_ name: String) {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            // 焦点换元素：flush 旧 element 的 session，再订到新元素。
            if let att = attachment, let old = att.focusedElement {
                let oldKey = ElementKey(pid: att.pid, elementHash: Int(CFHash(old)))
                writer.flushElement(oldKey)
            }
            subscribeFocusedElement()

        case kAXValueChangedNotification:
            processValueChange()

        default:
            break
        }
    }

    // MARK: - 值变化 → writer

    private func processValueChange() {
        guard let att = attachment, let focused = att.focusedElement else { return }

        // 隐私闸门：secure field（密码输入框）不读值。
        let role = copyStringAttr(focused, kAXRoleAttribute)
        if TypingPrivacyFilter.isSecureRole(role) { return }

        var valueRef: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        )
        guard valueErr == .success, let newValue = valueRef as? String else { return }

        let key = ElementKey(pid: att.pid, elementHash: Int(CFHash(focused)))
        writer.noteValueChange(key: key, newValue: newValue)
    }

    // MARK: - AX 读取小工具

    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }
}
