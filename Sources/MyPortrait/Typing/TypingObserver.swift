/// TypingObserver —— 通过 Accessibility (AX) API 订阅 frontmost app 的
/// focused text element，把文本变化 diff 成打字事件。
///
/// **本版（Step 4）只 print 日志**：不写 DB、不接 TypingEventStore。
/// observer 接入正常 app 启动是 Step 7 的事；本版只能由 CLI flag
/// `--typing-observe` 拉起。
///
/// 并发模型：
///   AXObserver 的 C 回调（@convention(c)）契约上跑在主线程 ——
///   它的 run-loop source 被加到 CFRunLoopGetMain()。所以回调里用
///   `MainActor.assumeIsolated { }` 同步进入 MainActor 跑逻辑，
///   不用 `Task {}` / `DispatchQueue.main.async`（那会异步推迟、
///   导致回调间乱序）。
///
/// 生命周期：挂到 frontmost app，监听 NSWorkspace 的 app 切换通知，
/// 切换时 detach 旧 AXObserver、attach 新 app。

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TypingObserver {

    // MARK: - AX 订阅状态

    /// 当前挂着的一组 AX 资源。app 切换时整体替换。
    private struct Attachment {
        let pid: pid_t
        let bundleId: String
        let appName: String?
        /// AXObserverCreate 出来的 observer。CFType，需手动 CFRetain/CFRelease。
        let observer: AXObserver
        /// 被订阅的 app 元素。
        let appElement: AXUIElement
        /// 当前被订阅 kAXValueChangedNotification 的 focused 元素（可空）。
        var focusedElement: AXUIElement?
    }

    private var attachment: Attachment?

    /// 当前 focused 元素上一次的快照，用于 diff。
    /// Step 5 backlog: 升级为 [AXUIElement: AXSnapshot] dict，每 element 独立维护快照，避免切回旧窗口时整段被当 insert。
    private var lastSnapshot: AXSnapshot?

    /// kAXValueChangedNotification 的 ~200ms debounce task，新事件取消旧 task。
    private var debounceTask: Task<Void, Never>?

    /// NSWorkspace app 切换通知的 observer token。
    private var workspaceObserverToken: NSObjectProtocol?

    /// 是否已 start（用于 stop 幂等）。
    private var running = false

    /// 每个 AX 元素的跨进程消息超时（秒）。
    private static let messagingTimeout: Float = 1.5

    /// IME composition 标记属性名。SDK 没导出 `kAXMarkedTextRangeAttribute`
    /// 常量，但属性本身存在 —— 用字符串字面量直访。
    private static let markedTextRangeAttribute = "AXMarkedTextRange"

    /// value change 后等待的 debounce 间隔。
    private static let debounceMs: UInt64 = 200

    // MARK: - 生命周期

    func start() {
        guard !running else { return }

        // 静默检查 AX 权限 —— 不带 prompt（弹窗引导是后面的 UI 件）。
        guard AXIsProcessTrusted() else {
            print("[TypingObserver] AX not granted — idle")
            return
        }

        running = true

        // 监听 app 切换：切换时 detach 旧 observer、attach 新 app。
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserverToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // 先把要用的标量（pid，Sendable）取出来，不把非 Sendable 的
            // Notification / NSRunningApplication 带进 assumeIsolated。
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid: pid_t = app?.processIdentifier ?? -1
            // queue: .main 保证此 closure 在主线程；assumeIsolated 安全进入 MainActor。
            MainActor.assumeIsolated {
                self?.handleAppActivated(pid: pid)
            }
        }

        // 挂到当前 frontmost app。
        attachToFrontmostApp()
        print("[TypingObserver] started")
    }

    /// 停止并清理（幂等）。走与 deinit 相同的三步清理路径。
    func stop() {
        guard running else { return }
        running = false

        debounceTask?.cancel()
        debounceTask = nil

        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserverToken = nil
        }

        detach()
        lastSnapshot = nil
        print("[TypingObserver] stopped")
    }

    /// `isolated deinit` —— 在 MainActor 上跑（SE-0371），才能安全读
    /// 非 Sendable 的隔离字段（attachment / workspaceObserverToken）。
    isolated deinit {
        debounceTask?.cancel()
        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        // detach 要求的三步清理（remove source → remove notifications →
        // CFRelease observer），见 Self.teardown。
        if let att = attachment {
            Self.teardown(att)
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
        // 先 detach 旧的，再 attach 新的。
        detach()
        lastSnapshot = nil
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        attach(to: app)
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName

        // 1. 创建 AXObserver。
        var observerRef: AXObserver?
        let createErr = AXObserverCreate(pid, Self.axCallback, &observerRef)
        guard createErr == .success, let observer = observerRef else {
            print("[TypingObserver] AXObserverCreate failed (\(createErr.rawValue)) for \(bundleId)")
            return
        }
        // observer 是 CFType：CFRetain 持有它，deinit/detach 时 CFRelease 平衡。
        // （AXObserverCreate 返回的对象，存进我们的结构体后要保证存活期。）
        _ = Unmanaged.passRetained(observer)

        // 2. app 元素。
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // 3. app 元素订阅 focus 变化通知。
        let focusErr = AXObserverAddNotification(
            observer, appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon
        )
        if focusErr != .success {
            print("[TypingObserver] add focus-changed notification failed (\(focusErr.rawValue)) for \(bundleId)")
        }

        // 4. run-loop source 加到 main loop —— 这正是回调跑在主线程的依据。
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        attachment = Attachment(
            pid: pid,
            bundleId: bundleId,
            appName: appName,
            observer: observer,
            appElement: appElement,
            focusedElement: nil
        )

        // 5. 订阅当前 focused text 元素的 value 变化。
        subscribeFocusedElement()
    }

    /// detach —— stop / app 切换共用的清理。清掉 attachment 字段后调 teardown。
    private func detach() {
        guard let att = attachment else { return }
        attachment = nil
        Self.teardown(att)
    }

    /// 三步 AX 清理，deinit 与 detach 共用。`nonisolated` 以便 nonisolated
    /// deinit 也能调。只碰 CF / AX C-API，不碰 actor 状态。
    /// 严格三步顺序：a 移 source → b 撤所有 notification → c CFRelease observer。
    /// （passUnretained 不 retain self，漏一步 → 回调在 self 释放后被调 → 崩。）
    nonisolated private static func teardown(_ att: Attachment) {
        // a. 从 main run loop 移除 source。先断回调投递通道。
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(att.observer),
            .commonModes
        )

        // b. 撤掉所有已加的订阅。
        if let focused = att.focusedElement {
            AXObserverRemoveNotification(
                att.observer, focused,
                kAXValueChangedNotification as CFString
            )
        }
        AXObserverRemoveNotification(
            att.observer, att.appElement,
            kAXFocusedUIElementChangedNotification as CFString
        )

        // c. 释放 attach 时 CFRetain 的那次持有，平衡 create 时的 passRetained。
        Unmanaged.passUnretained(att.observer).release()
    }

    // MARK: - focused 元素订阅

    /// 读 app 当前 focused 元素，订阅它的 kAXValueChangedNotification。
    /// 焦点换元素时也走这条路（先 unsubscribe 旧的）。
    private func subscribeFocusedElement() {
        guard var att = attachment else { return }

        // 先撤掉旧 focused 元素的订阅。
        if let old = att.focusedElement {
            AXObserverRemoveNotification(
                att.observer, old,
                kAXValueChangedNotification as CFString
            )
            att.focusedElement = nil
        }

        // 读当前 focused 元素。
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            att.appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let focusedRef else {
            // 没有 focused 元素（如切到 Finder 桌面）—— 静默，不订阅。
            attachment = att
            lastSnapshot = nil
            return
        }
        // CFTypeRef → AXUIElement。AXUIElement 是 CFType，强转安全。
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(
            att.observer, focused,
            kAXValueChangedNotification as CFString,
            refcon
        )
        if addErr != .success {
            print("[TypingObserver] add value-changed notification failed (\(addErr.rawValue)) bundle=\(att.bundleId)")
            attachment = att
            return
        }

        att.focusedElement = focused
        attachment = att
        // 焦点换到新元素 —— 清旧快照，下次 value change 从空 diff。
        lastSnapshot = nil
    }

    // MARK: - 通知处理

    /// AXObserver 的 C 回调。run-loop source 在 main loop，故此函数跑在主线程。
    /// 用 assumeIsolated 同步进入 MainActor —— 不用 Task{}，避免异步推迟乱序。
    private static let axCallback: AXObserverCallback = {
        _ /* observer */, _ /* element */, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<TypingObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        // source 加在 main loop，此回调契约上在主线程，assumeIsolated 安全。
        MainActor.assumeIsolated {
            observer.handleNotification(name)
        }
    }

    private func handleNotification(_ name: String) {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            // 焦点换元素 —— 重订 value-changed 到新 focused 元素、清旧快照。
            subscribeFocusedElement()

        case kAXValueChangedNotification:
            // ~200ms debounce：取消上一个未触发的 task，排新的。
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceMs * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.processValueChange()
            }

        default:
            break
        }
    }

    // MARK: - 值变化 → 快照 → diff → print

    private func processValueChange() {
        guard let att = attachment, let focused = att.focusedElement else { return }

        // IME 过滤：marked text range 非空 = 正在 composition（未上屏拼写），
        // 跳过；等 commit 后那次 value change 再处理。
        if hasMarkedText(focused) {
            return
        }

        // 读 role —— 用于判断是否文本元素 + 写进快照。
        let role = copyStringAttr(focused, kAXRoleAttribute)

        // 读全文。
        var valueRef: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        )
        guard valueErr == .success else {
            // 拿不到 value —— 带具体原因 log。
            let reason: String
            switch valueErr {
            case .noValue, .attributeUnsupported:
                reason = "no-value"
            case .cannotComplete:
                reason = "ax-timeout"
            case .invalidUIElement:
                reason = "element-gone"
            default:
                reason = "ax-error-\(valueErr.rawValue)"
            }
            print("[TypingObserver] unsupported element role=\(role ?? "?") bundle=\(att.bundleId) reason=\(reason)")
            return
        }
        guard let value = valueRef as? String else {
            // value 存在但不是字符串 —— 不是文本元素。
            print("[TypingObserver] unsupported element role=\(role ?? "?") bundle=\(att.bundleId) reason=non-text-value")
            return
        }

        // 读选区（可空，失败不致命）。
        let selection = copySelectionRange(focused)

        let snapshot = AXSnapshot(
            value: value,
            selection: selection,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            role: role,
            bundleId: att.bundleId,
            appName: att.appName,
            elementHint: nil
        )

        defer { lastSnapshot = snapshot }

        // 首次快照无 old，不 diff。
        guard let old = lastSnapshot else { return }

        if let change = TextDiff.diff(from: old.value, to: snapshot.value) {
            let roleStr = role ?? "?"
            print("[TypingObserver] \(change.kind) \"\(change.text)\" (\(change.languageHint)) — \(att.bundleId) / \(roleStr)")
        }
    }

    // MARK: - AX 读取小工具

    /// marked text range 是否存在且非空（IME composition 中）。
    private func hasMarkedText(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, Self.markedTextRangeAttribute as CFString, &ref
        )
        // 属性不支持 / 无值 → 视为没有 marked text。
        guard err == .success, let ref else { return false }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return false }
        let axValue = ref as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return false }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return false }
        return range.length > 0
    }

    /// 读字符串属性，失败返回 nil。
    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    /// 读 kAXSelectedTextRangeAttribute → Range<Int>，失败返回 nil。
    private func copySelectionRange(_ element: AXUIElement) -> Range<Int>? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &ref
        )
        guard err == .success, let ref else { return nil }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        guard range.location >= 0, range.length >= 0 else { return nil }
        return range.location ..< (range.location + range.length)
    }
}
