/// TypingObserver —— Typing Observer v2 的 L1+L2+L3+L4 顶层 orchestrator（M4）。
///
/// 通过 Accessibility (AX) API 订阅 frontmost app 的 focused text element。
/// 每次 `kAXValueChangedNotification`：
///   0. IME composition 检测 —— marked-text-range 非空 = 拼音 preedit 未上屏，
///      整段跳过；不暴露该属性的 app 走 350ms debounce 兜底
///   1. `TextDiff.sandwich` diff 出 delta（segment = 新打的字 / deletion = 删的字）
///   2. 速度阈值 burst 检测 —— 大段且极快 = 鼠标点击触发的 AX 全文吸附，
///      进黑名单、不入库
///   2.5 L1 键盘活动关联闸门 —— correlation 窗口内无物理按键 = 非用户打字，丢弃
///   3. segment 喂 Layer 2（IME 折叠）；deletion 交 `TypingRecordWriter`
///   4. Layer 2 折出的 commit 累加进该 app 的 master record
///   5/7. 5s debounce flush，写库前减黑名单
///
/// **M4 的关键修正**：步骤 1 拿到的是 prev→new 的 delta，不是整段 newValue。
/// 旧实现把整段 newValue 当新 commit append，导致 edit_log 全是版本快照。
///
/// 并发模型：
///   AXObserver 的 C 回调（@convention(c)）契约上跑在主线程 ——
///   它的 run-loop source 被加到 CFRunLoopGetMain()。所以回调里用
///   `MainActor.assumeIsolated { }` 同步进入 MainActor 跑逻辑，
///   不用 `Task {}` / `DispatchQueue.main.async`（那会异步推迟、
///   导致回调间乱序）。
///
/// 生命周期：挂到 frontmost app，监听 NSWorkspace 的 app 切换通知，
/// 切换时 flush 旧 app 的 record、detach 旧 AXObserver、attach 新 app。

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
        /// AXObserverCreate 出来的 observer。CFType，需手动 CFRetain/CFRelease。
        let observer: AXObserver
        /// 被订阅的 app 元素。
        let appElement: AXUIElement
        /// 当前被订阅 kAXValueChangedNotification 的 focused 元素（可空）。
        var focusedElement: AXUIElement?
    }

    private var attachment: Attachment?

    // MARK: - 各 element 的 diff 快照

    /// 一个 AX element 的 diff 状态。
    private struct ElementState {
        /// 用于 prev→new diff 的上次快照。IME composition 期间**保持不变**。
        var lastValueSnapshot: String
        /// 用于 burst 速度阈值的上次 value-change 时刻（CACurrentMediaTime）。
        var lastValueChangeTs: TimeInterval
        /// 上次是否处于 IME composition —— 用于检测进入/退出 composition 的过渡。
        var wasComposing: Bool = false
        /// debounce 兜底路径的待 diff 计时器（不暴露 marked-range 的 app 用）。
        var debounceTimer: Timer?
        /// debounce 窗口内最近一次见到的完整值。
        var pendingValue: String?
    }

    private typealias ElementKey = TypingRecordWriter.ElementKey

    /// per (app, element) 的 diff 快照。首次见到某 element 只存 baseline 不 diff
    /// （否则整段被当 insert）。element 失焦 / app 切走时清对应条目。
    private var elementState: [ElementKey: ElementState] = [:]

    /// IME composition 检测的三态。
    private enum CompositionState { case composing, idle, unknown }

    // MARK: - Layer 1 / Layer 2 / Layer 4

    /// Layer 1 —— 人类心跳层。CGEventTap 记录物理按键；步骤 2.5 的键盘活动
    /// 关联闸门靠 `hasKeystroke(within:)` 判定 value 变化是不是用户打的。
    private let ledger = KeystrokeLedger()

    /// Layer 2 —— 多 element IME 折叠层。
    private let registry = IMEStateMachineRegistry()

    /// Layer 4 —— 写入层（in-progress record / 跨记录 delete / flush / 黑名单）。
    private let writer: TypingRecordWriter

    /// 剪贴板镜像 —— 判定插入文本是不是粘贴来的（与 ⌘V 判据互补）。
    private let pasteboardMonitor = PasteboardMonitor()

    /// L2 折叠出的 IMEFoldEvent 的额外消费口（`--typing-observe-m3` dev flag 注入）。
    var onFoldEvent: (([IMEFoldEvent]) -> Void)?

    /// dev flag 日志出口（burst / 跨记录 delete / flush 关键事件 + 启动 banner）。
    /// 设置时同步给 writer。
    var onDevLog: ((String) -> Void)? {
        didSet { writer.onDevLog = onDevLog }
    }

    /// 启动 banner 里显示的运行模式标签（production / m4-dev / ...）。
    private let modeLabel: String

    // MARK: - 其它状态

    /// NSWorkspace app 切换通知的 observer token。
    private var workspaceObserverToken: NSObjectProtocol?

    /// 规则 9 的 compose-timeout tick 定时器（100ms 间隔，main thread）。
    private var tickTimer: Timer?

    /// 黑名单 TTL 清理定时器（5min 间隔）。
    private var blacklistCleanupTimer: Timer?

    /// 是否已 start（用于 stop 幂等）。
    private var running = false

    /// 每个 AX 元素的跨进程消息超时（秒）。
    private static let messagingTimeout: Float = 1.5

    /// compose-timeout tick 间隔。
    private static let tickIntervalSec: TimeInterval = 0.100

    /// 黑名单 TTL 清理间隔。
    private static let blacklistCleanupSec: TimeInterval = 300

    /// IME marked-text-range 的 AX 属性名。app 不暴露 → 走 debounce 兜底。
    private static let markedTextRangeAttribute = "AXMarkedTextRange"

    /// 不暴露 marked-range 的 app 的 debounce 兜底窗口。与 L2 规则 9 的
    /// compose-timeout（350ms）一致 —— 静默这么久即认定 composition 结束。
    private static let compositionDebounceSec: TimeInterval = 0.350

    /// value 变化与 ⌘V 的关联窗口 —— 这么短内发生过 ⌘V，即判定本次变化是粘贴。
    private static let pasteAssocSec: TimeInterval = 0.3

    private let pipelineLog = Logger(subsystem: "com.joyzhang.myportrait",
                                     category: "typing.pipeline")

    // MARK: - 生命周期

    /// - Parameters:
    ///   - store: typing_events DAO。`nil` 时（`--typing-observe` /
    ///     `--typing-observe-m3` dev 模式）L4 只在内存里累加、不落库。
    ///   - modeLabel: 启动 banner 的模式标签。
    init(store: TypingEventStore? = nil,
         modeLabel: String = "production") {
        self.writer = TypingRecordWriter(store: store)
        self.modeLabel = modeLabel
    }

    func start() {
        guard !running else { return }

        // Layer 1 起 CGEventTap。失败不崩，KeystrokeLedger 自身会 log warning。
        // 先起 ledger —— 这样启动 banner 能如实报告它的状态。
        do {
            try ledger.start()
        } catch {
            pipelineLog.warning("KeystrokeLedger.start failed: \(String(describing: error), privacy: .public)")
        }

        // 剪贴板监视器 —— 轮询 changeCount 维护内存镜像。
        pasteboardMonitor.start()

        // 启动 banner —— 第一时间 print 全部关键 config + gate 状态。修补
        // 「某个 gate 静默把 observer 搞哑」的 silent failure（paused / ledger
        // down / AX denied 都会让采集无声失效）。
        logStartupBanner()

        // 静默检查 AX 权限 —— 不带 prompt（弹窗引导是 UI 件）。
        guard AXIsProcessTrusted() else {
            print("[TypingObserver] AX not granted — idle")
            return
        }

        running = true

        // compose-timeout tick：每 100ms 驱动一次 registry.tick。
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.tickIntervalSec,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTick()
            }
        }

        // 黑名单 TTL 清理：每 5min 扫一遍，减掉 1h 前的条目。
        blacklistCleanupTimer = Timer.scheduledTimer(
            withTimeInterval: Self.blacklistCleanupSec, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writer.cleanupBlacklist(now: CACurrentMediaTime())
            }
        }

        // 监听 app 切换：切换时 flush + detach 旧 observer、attach 新 app。
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

    /// 停止并清理（幂等）。flush 所有 in-progress record 到 DB。
    func stop() {
        guard running else { return }
        running = false

        tickTimer?.invalidate()
        tickTimer = nil
        blacklistCleanupTimer?.invalidate()
        blacklistCleanupTimer = nil

        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserverToken = nil
        }

        // observer 整体停：flush L2 buffer → 累加 → flush 所有 record 落库。
        let flushed = registry.flushAll()
        if let bundleId = attachment?.bundleId {
            handleFoldEvents(flushed, bundleId: bundleId, nowMs: TypingRecordWriter.nowMs())
        }
        writer.flushAll(nowMs: TypingRecordWriter.nowMs())

        pasteboardMonitor.stop()
        ledger.stop()

        detach()
        // 收回所有 element 的 debounce 计时器。
        for st in elementState.values { st.debounceTimer?.invalidate() }
        elementState.removeAll()
        print("[TypingObserver] stopped")
    }

    /// `isolated deinit` —— 在 MainActor 上跑（SE-0371），才能安全读
    /// 非 Sendable 的隔离字段（attachment / workspaceObserverToken）。
    isolated deinit {
        tickTimer?.invalidate()
        blacklistCleanupTimer?.invalidate()
        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        // detach 要求的三步清理（remove source → remove notifications →
        // CFRelease observer），见 Self.teardown。
        if let att = attachment {
            Self.teardown(att)
        }
    }

    // MARK: - 启动 banner

    /// 第一时间 print 关键 config + gate 状态。任何 gate 处在「会哑」状态
    /// 加 `⚠️` 显眼标记 —— 修补 silent failure。
    private func logStartupBanner() {
        let cfg = ConfigStore.shared.recording
        let enabled = cfg.typingCaptureEnabled
        let corrMs = cfg.typingKeyCorrelationWindowMs
        let axOK = AXIsProcessTrusted()
        let ledgerOK = ledger.isRunning

        print("[TypingObserver] starting (mode=\(modeLabel))")
        print("[TypingObserver] config:")

        // 总开关：dev flag 绕过 Services，故此字段对 dev 模式无效。
        if modeLabel == "production" {
            print("  typing_capture_enabled    = \(enabled)")
        } else {
            print("  typing_capture_enabled    = \(enabled)   (ignored — dev flag bypasses Services)")
        }

        print("  keyboard_correlation_ms   = \(corrMs)")
        print("  ime_composition_detection = enabled  (marked-range or 350ms debounce)")

        // L1 闸门依赖 KeystrokeLedger；它没起来 → hasKeystroke 永远 false
        // → 步骤 2.5 把所有输入丢光。
        if ledgerOK {
            print("  keystroke_ledger          = running")
        } else {
            print("  keystroke_ledger          = down   ⚠️  WILL DROP ALL INPUT (L1 gate)")
        }

        print("  terminal_blocklist        = \(TypingPrivacyFilter.terminalBlocklistCount) apps")

        if axOK {
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
        // app 切走：flush 旧 app 的 L2 buffer → 累加 → 立即把它的 record 落库。
        if let oldBundle = attachment?.bundleId {
            handleFoldEvents(registry.flushAll(), bundleId: oldBundle,
                             nowMs: TypingRecordWriter.nowMs())
            writer.flush(bundleId: oldBundle, nowMs: TypingRecordWriter.nowMs())
            let msg = "app-switch flush bundle=\(oldBundle)"
            pipelineLog.info("\(msg, privacy: .public)")
            onDevLog?(msg)
            // 清掉旧 app 的 element 快照（元素已无效，留着字典无限涨）。
            // 先收回它们的 debounce 计时器 —— composition 中途切 app 即丢弃。
            for (k, st) in elementState where k.bundleId == oldBundle {
                st.debounceTimer?.invalidate()
            }
            elementState = elementState.filter { $0.key.bundleId != oldBundle }
        } else {
            _ = registry.flushAll()
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

        // 终端黑名单（算法限制）：终端输入/输出共享同一 AX 元素，stdout 会被
        // 误判为用户输入 —— 终端整段不订阅。
        if TypingPrivacyFilter.isTerminalApp(bundleId: bundleId) {
            print("[TypingObserver] terminal app, observer idle bundle=\(bundleId)")
            return
        }

        // 1. 创建 AXObserver。
        var observerRef: AXObserver?
        let createErr = AXObserverCreate(pid, Self.axCallback, &observerRef)
        guard createErr == .success, let observer = observerRef else {
            print("[TypingObserver] AXObserverCreate failed (\(createErr.rawValue)) for \(bundleId)")
            return
        }
        // observer 是 CFType：CFRetain 持有它，deinit/detach 时 CFRelease 平衡。
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

        // 立刻读一次 baseline 值写进 elementState —— 否则该 element 的第一次
        // value 变化会撞上"首次见到只存值不 diff"，把第一个字符吞掉。
        // 读失败（如某些不可读元素）→ 退化为空串 baseline。
        let key = ElementKey(bundleId: att.bundleId, elementHash: Int(CFHash(focused)))
        var baselineRef: CFTypeRef?
        let baselineErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &baselineRef
        )
        let baseline = (baselineErr == .success ? (baselineRef as? String) : nil) ?? ""
        elementState[key] = ElementState(lastValueSnapshot: baseline,
                                         lastValueChangeTs: CACurrentMediaTime())
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
            // 焦点换元素：对旧 focused 元素 flush L2 buffer + 清快照，再重订。
            if let att = attachment, let old = att.focusedElement {
                let oldHash = Int(CFHash(old))
                handleFoldEvents(registry.handleFocusChange(elementHash: oldHash),
                                 bundleId: att.bundleId,
                                 nowMs: TypingRecordWriter.nowMs())
                // composition 中途切焦点 → 丢弃该 element 状态（含 debounce 计时器）。
                clearElementState(ElementKey(bundleId: att.bundleId, elementHash: oldHash))
            }
            subscribeFocusedElement()

        case kAXValueChangedNotification:
            // v2 逐条同步处理，不 debounce —— 状态机本来就是为逐条事件设计的。
            processValueChange()

        default:
            break
        }
    }

    // MARK: - tick

    /// compose-timeout tick：100ms 一次，驱动 registry 对所有 element 跑规则 9。
    /// registry 里的状态机只属于当前 attach 的 app（切 app 时已 flushAll 清空）。
    private func handleTick() {
        let events = registry.tick(now: CACurrentMediaTime())
        guard !events.isEmpty, let bundleId = attachment?.bundleId else { return }
        handleFoldEvents(events, bundleId: bundleId, nowMs: TypingRecordWriter.nowMs())
    }

    // MARK: - 值变化 → composition 检测 → diff → burst → L1 → L2/delete → L4

    private func processValueChange() {
        guard let att = attachment, let focused = att.focusedElement else { return }

        // 隐私闸门：secure field（密码输入框）不读值、不 diff。
        let role = copyStringAttr(focused, kAXRoleAttribute)
        if TypingPrivacyFilter.isSecureRole(role) { return }

        let elementHash = Int(CFHash(focused))
        let key = ElementKey(bundleId: att.bundleId, elementHash: elementHash)

        // ── 步骤 0：IME composition 检测 ────────────────────────────
        // 拼音 preedit 期间（marked range 非空）整段跳过：不 diff、不更新
        // snapshot、不喂 L2。snapshot 保持 pre-composition；等上屏（marked
        // range 清空）再一次性 diff 出干净的汉字。
        let markedState = markedTextState(of: focused)
        if markedState == .composing {
            cancelDebounce(key)
            noteComposing(key: key, composing: true, bundleId: att.bundleId)
            return
        }

        // 读 focused 元素当前完整文本值。
        var valueRef: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        )
        guard valueErr == .success else {
            // 元素已消失 —— 清掉它的快照条目（含计时器）。其它读失败静默忽略。
            if valueErr == .invalidUIElement { clearElementState(key) }
            return
        }
        guard let newValue = valueRef as? String else {
            // value 存在但不是字符串 —— 不是文本元素。
            return
        }

        // 首次见到该 element（baseline 未预存成功）→ 只存快照不 diff。
        guard elementState[key] != nil else {
            elementState[key] = ElementState(lastValueSnapshot: newValue,
                                             lastValueChangeTs: CACurrentMediaTime())
            return
        }

        // composition 刚结束的过渡（composing→idle/unknown）。
        noteComposing(key: key, composing: false, bundleId: att.bundleId)

        if markedState == .unknown {
            // 该 app 不暴露 marked-range → 350ms debounce 兜底：静默这么久
            // 才认定 composition 结束、做一次同步快照 diff。
            // 粘贴判据：⌘V 时间关联，或本次插入 delta 命中剪贴板镜像。
            let prevSeen = elementState[key]?.pendingValue
                ?? elementState[key]?.lastValueSnapshot ?? ""
            let delta = TextDiff.sandwich(prev: prevSeen, new: newValue).newMid
            if ledger.hasPaste(within: Self.pasteAssocSec)
                || pasteboardMonitor.looksLikePaste(delta) {
                handlePasteValueChange(key: key, newValue: newValue)
            } else {
                scheduleDebounce(key: key, newValue: newValue)
            }
        } else {
            // markedState == .idle：app 暴露 marked-range 且当前非 composition
            // → 立即 diff。
            cancelDebounce(key)
            performDiff(newValue: newValue, key: key, pid: att.pid)
        }
    }

    // MARK: - IME composition 检测

    /// 读 focused 元素的 marked-text-range（IME preedit 区间）。
    /// - `.composing`: marked range 非空 → 拼音正在 composition、未上屏。
    /// - `.idle`:      属性可读但 range 空 → 非 composition。
    /// - `.unknown`:   app 不暴露此属性 → 调用方走 debounce 兜底。
    private func markedTextState(of element: AXUIElement) -> CompositionState {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, Self.markedTextRangeAttribute as CFString, &ref
        )
        guard err == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else {
            return .unknown
        }
        let axValue = ref as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return .unknown }
        return range.length > 0 ? .composing : .idle
    }

    /// 跟踪 composition 进入/退出，仅在状态翻转时发一条 dev log（不逐键 print）。
    private func noteComposing(key: ElementKey, composing: Bool, bundleId: String) {
        guard var st = elementState[key], st.wasComposing != composing else { return }
        st.wasComposing = composing
        elementState[key] = st
        onDevLog?(composing
                  ? "composition started bundle=\(bundleId)"
                  : "composition committed bundle=\(bundleId)")
    }

    // MARK: - debounce 兜底（不暴露 marked-range 的 app）

    /// 取消某 element 的 debounce 计时器。
    private func cancelDebounce(_ key: ElementKey) {
        guard var st = elementState[key], st.debounceTimer != nil else { return }
        st.debounceTimer?.invalidate()
        st.debounceTimer = nil
        st.pendingValue = nil
        elementState[key] = st
    }

    /// (重新) 安排一次 debounce 后的同步快照 diff。窗口内有新变化 → 重置计时。
    ///
    /// L1 键盘活动关联闸门在**这里**判（value-change 时刻）—— debounce 触发
    /// 时刻离按键已超过 correlation 窗口，那时再查 hasKeystroke 必然失败。
    /// 无按键 = 程序输出 / 鼠标点击 AX 全文吸附 → 不更新 pendingValue、不重排
    /// 计时器（pendingValue 保持 stale → 后续 fire 的 diff 不含这次噪声）。
    private func scheduleDebounce(key: ElementKey, newValue: String) {
        let corrWindowSec =
            Double(ConfigStore.shared.recording.typingKeyCorrelationWindowMs) / 1000.0
        guard ledger.hasKeystroke(within: corrWindowSec) else {
            pipelineLog.debug("L1:drop:no-keystroke(debounce) bundle=\(key.bundleId, privacy: .public)")
            return
        }
        guard var st = elementState[key] else { return }
        st.debounceTimer?.invalidate()
        st.pendingValue = newValue
        st.debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.compositionDebounceSec, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDebounce(key: key) }
        }
        elementState[key] = st
    }

    /// debounce 计时器触发：拿窗口内最后的完整值做一次**同步**快照 diff，
    /// 直接 accumulate / handleDelete，**不经 Layer 2** —— 避免 L2 异步 tick
    /// flush 与同步 handleDelete 抢跑导致漏删 / 错删。
    ///
    /// self-heal：某次快照不巧抓到半截拼音（如 "nih"），下一次快照 diff 出
    /// prevMid="nih" / newMid="你好"。先删后插、全同步，两种残留都能纠正：
    ///   - "nih" 还在 in-progress record → handleDelete 同 record .backwards 减掉
    ///   - "nih" 已被 5s flush 进 DB → handleDelete 跨 record 在末尾 2000 字符减掉
    private func fireDebounce(key: ElementKey) {
        guard var st = elementState[key], let pending = st.pendingValue else { return }
        let prevValue = st.lastValueSnapshot
        st.debounceTimer = nil
        st.pendingValue = nil
        st.lastValueSnapshot = pending
        elementState[key] = st

        let (_, prevMid, newMid, _) = TextDiff.sandwich(prev: prevValue, new: pending)
        if prevMid.isEmpty, newMid.isEmpty { return }
        onDevLog?("debounce diff bundle=\(key.bundleId) "
                  + "del=\"\(prevMid.prefix(16))\" seg=\"\(newMid.prefix(16))\"")
        let nowMs = TypingRecordWriter.nowMs()
        // 先删后插 —— self-heal 的关键：prevMid 含上次快照的半截拼音残留。
        if !prevMid.isEmpty {
            writer.handleDelete(deletedText: prevMid, bundleId: key.bundleId, nowMs: nowMs)
        }
        if !newMid.isEmpty {
            writer.accumulate(commitTexts: [newMid], bundleId: key.bundleId, nowMs: nowMs)
        }
    }

    /// debounce 路径上、由 ⌘V 触发的 value 变化 —— 粘贴不是打字：
    ///   1. 先把窗口内「粘贴之前的真实打字」flush 掉（别跟粘贴一起丢）
    ///   2. 粘贴 delta 进黑名单（flush 时 stripBlacklist 减掉，belt-and-suspenders）
    ///   3. snapshot 跳过粘贴段 —— 后续打字从粘贴后干净 diff
    private func handlePasteValueChange(key: ElementKey, newValue: String) {
        guard var st = elementState[key] else { return }
        st.debounceTimer?.invalidate()
        st.debounceTimer = nil
        let prevSnap = st.lastValueSnapshot
        let beforePaste = st.pendingValue ?? prevSnap   // 粘贴前的值

        // 1. 粘贴之前、窗口里尚未 flush 的真实打字。
        if beforePaste != prevSnap {
            let (_, tDel, tIns, _) = TextDiff.sandwich(prev: prevSnap, new: beforePaste)
            let nowMs = TypingRecordWriter.nowMs()
            if !tDel.isEmpty {
                writer.handleDelete(deletedText: tDel, bundleId: key.bundleId, nowMs: nowMs)
            }
            if !tIns.isEmpty {
                writer.accumulate(commitTexts: [tIns], bundleId: key.bundleId, nowMs: nowMs)
            }
        }

        // 2. 粘贴 delta 入黑名单。
        let (_, _, pasteIns, _) = TextDiff.sandwich(prev: beforePaste, new: newValue)
        if !pasteIns.isEmpty {
            writer.recordBurst(key: key, segment: pasteIns, now: CACurrentMediaTime())
            let msg = "paste blacklisted bundle=\(key.bundleId) \(pasteIns.count) chars"
            pipelineLog.info("\(msg, privacy: .public)")
            onDevLog?(msg)
        }

        // 3. snapshot 吸收粘贴段。
        st.lastValueSnapshot = newValue
        st.pendingValue = nil
        elementState[key] = st
    }

    /// 清掉某 element 的全部状态（含 debounce 计时器）。
    private func clearElementState(_ key: ElementKey) {
        elementState[key]?.debounceTimer?.invalidate()
        elementState[key] = nil
    }

    // MARK: - diff → burst → L1 闸门 → L2 / handleDelete → L4

    /// 对一个 element 做 prev→new diff，跑完 burst / L1 / L2 / handleDelete。
    /// prev 取 `elementState[key].lastValueSnapshot`。
    private func performDiff(newValue: String, key: ElementKey, pid: pid_t) {
        guard var state = elementState[key] else { return }
        let prevValue = state.lastValueSnapshot

        // ── 步骤 1：sandwich diff 出 delta ──────────────────────────
        let (prefix, prevMid, newMid, _) = TextDiff.sandwich(prev: prevValue, new: newValue)
        let segment = newMid       // 用户这次新打的字符
        let deletion = prevMid     // 用户这次删的字符
        state.lastValueSnapshot = newValue
        if segment.isEmpty, deletion.isEmpty {
            elementState[key] = state
            return
        }

        // ── 粘贴检测：⌘V 时间关联，或 segment 命中剪贴板镜像 ──────
        // 粘贴 delta 进黑名单（flush 时 stripBlacklist 减掉），不入 edit_log。
        if ledger.hasPaste(within: Self.pasteAssocSec)
            || pasteboardMonitor.looksLikePaste(segment) {
            elementState[key] = state  // snapshot 已推进，吸收粘贴段
            if !segment.isEmpty {
                writer.recordBurst(key: key, segment: segment, now: CACurrentMediaTime())
            }
            let msg = "paste blacklisted bundle=\(key.bundleId) \(segment.count) chars"
            pipelineLog.info("\(msg, privacy: .public)")
            onDevLog?(msg)
            return
        }

        // ── 步骤 2：速度阈值 burst 检测 ─────────────────────────────
        let now = CACurrentMediaTime()
        let intervalMs = (now - state.lastValueChangeTs) * 1000.0
        if TypingRecordWriter.isBurst(segmentCharCount: segment.count,
                                      intervalMs: intervalMs) {
            writer.recordBurst(key: key, segment: segment, now: now)
            state.lastValueChangeTs = now
            elementState[key] = state
            let msg = "burst bundle=\(key.bundleId) size=\(segment.count) "
                + "interval=\(Int(intervalMs))ms"
            pipelineLog.info("\(msg, privacy: .public)")
            onDevLog?(msg)
            return  // 不进 edit_log、不喂 Layer 2
        }
        state.lastValueChangeTs = now
        elementState[key] = state

        // ── 步骤 2.5：L1 键盘活动关联闸门 ──────────────────────────
        // value 变化前 correlation 窗口内若无物理按键 → 判定非用户打字
        // （程序输出 / 收到的消息 / AX 自动吸附），整段丢弃。窗口由
        // typing_key_correlation_window_ms 配置（UI 可调，50–500ms）。
        let corrWindowSec =
            Double(ConfigStore.shared.recording.typingKeyCorrelationWindowMs) / 1000.0
        guard ledger.hasKeystroke(within: corrWindowSec) else {
            pipelineLog.debug("L1:drop:no-keystroke bundle=\(key.bundleId, privacy: .public)")
            return
        }

        // ── 步骤 3：喂 Layer 2 + handleDelete ──────────────────────
        let nowMs = TypingRecordWriter.nowMs()
        if !segment.isEmpty {
            // segment 一律作 .insert 喂 L2；range.location 指向插入点
            // （= 公共前缀的 UTF-16 长度），L2 规则 3 靠它判连续输入。
            let raw = RawEdit(
                kind: .insert,
                text: segment,
                script: Script.classify(segment),
                range: NSRange(location: prefix.utf16.count, length: 0),
                ts: now,
                pid: pid,
                elementHash: key.elementHash,
                traceTag: nil
            )
            handleFoldEvents(registry.feed(raw), bundleId: key.bundleId, nowMs: nowMs)
        }
        if !deletion.isEmpty {
            writer.handleDelete(deletedText: deletion, bundleId: key.bundleId, nowMs: nowMs)
        }
    }

    // MARK: - IMEFoldEvent handler

    /// L2 折出的事件：log 一行 + 转交 onFoldEvent（dev flag）+ commit 累加进
    /// Layer 4 的 master record。
    private func handleFoldEvents(_ events: [IMEFoldEvent],
                                  bundleId: String, nowMs: Int64) {
        guard !events.isEmpty else { return }
        for event in events {
            pipelineLog.debug(
                "[L2] \(String(describing: event.kind), privacy: .public) \"\(event.text, privacy: .public)\" trace=\(event.traceTag?.description ?? "-", privacy: .public)")
        }
        onFoldEvent?(events)
        // M4 只把 .insert 喂给 L2，故 L2 只会折出 .commit。防御性 filter。
        let commitTexts = events.filter { $0.kind == .commit }.map(\.text)
        writer.accumulate(commitTexts: commitTexts, bundleId: bundleId, nowMs: nowMs)
    }

    // MARK: - AX 读取小工具

    /// 读字符串属性，失败返回 nil。
    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }
}
