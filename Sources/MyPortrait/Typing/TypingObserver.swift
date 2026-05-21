/// TypingObserver —— Typing Observer v2 的 Layer 1~3 orchestrator（M4）。
///
/// 通过 Accessibility (AX) API 订阅 frontmost app 的 focused text element，
/// 把每次 `kAXValueChangedNotification` 折成一段 `RawEdit`，经
///   Layer 1（KeystrokeLedger 心跳过滤）→ Layer 2（IMEStateMachineRegistry 折叠）
///   → Layer 3（TypingSessionAggregator 会话聚合）
/// 聚合成「一次输入会话」并写进 `typing_events` 表。
///
/// **M4 到 DB 写入为止**：Layer 3 把同一 (pid, element) 上的多条
/// `IMEFoldEvent` 攒成一条 `TypingEvent`，会话关闭时（submit / idle /
/// focus_change / app_change / max_chars 五个触发器）落库。
/// 不做 Layer 4（metadata enrichment / URL 黑名单）、不做健康检查。
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

    // MARK: - Layer 1 / Layer 2 / Layer 3

    /// Layer 1 —— 人类心跳层。observer 持有一个实例，start/stop 同步起停。
    private let ledger = KeystrokeLedger()

    /// Layer 2 —— 多 element IME 折叠层。
    private let registry = IMEStateMachineRegistry()

    /// Layer 3 —— 会话聚合层。把 IMEFoldEvent 攒成输入会话。
    private let aggregator = TypingSessionAggregator()

    /// `typing_events` 表 DAO —— 会话关闭时写库。
    private let store: TypingEventStore

    /// 每个 element 上次缓存的完整文本值。key = elementHash = CFHash(focused)。
    /// 首次见到某 element 只存值不 diff（否则整段被当 insert）。
    /// element 失焦 / app 切走时清对应条目，避免字典无限涨。
    private var lastValues: [Int: String] = [:]

    /// 当前上下文的 thread id —— attach / 焦点切换时算一次缓存，建
    /// SessionContext 时复用。同一窗口 1 小时内的会话串成一个 thread。
    private var currentThreadId: String = UUID().uuidString

    /// L2 折叠出的 IMEFoldEvent 的额外消费口。dev flag 注入。
    var onFoldEvent: (([IMEFoldEvent]) -> Void)?

    /// 会话关闭并产出 TypingEvent 时的额外消费口。dev flag（--typing-observe-m4）注入。
    var onTypingEvent: ((TypingEvent) -> Void)?

    // MARK: - 其它状态

    /// NSWorkspace app 切换通知的 observer token。
    private var workspaceObserverToken: NSObjectProtocol?

    /// 规则 9 的 compose-timeout tick 定时器（100ms 间隔，main thread）。
    private var tickTimer: Timer?

    /// 是否已 start（用于 stop 幂等）。
    private var running = false

    /// 每个 AX 元素的跨进程消息超时（秒）。
    private static let messagingTimeout: Float = 1.5

    /// L1 心跳关联窗口（秒）。insert/replace 与 delete 各一档，硬编码（M5 才挪进 ConfigStore）。
    private static let keystrokeWindowEditSec: TimeInterval = 0.120
    private static let keystrokeWindowDeleteSec: TimeInterval = 0.200

    /// compose-timeout tick 间隔。
    private static let tickIntervalSec: TimeInterval = 0.100

    /// Layer 3 会话 idle 超时（秒）。无新 event 超过此时长 → idle 关闭。
    private static let sessionIdleSec: TimeInterval = 4.0

    /// submit_close 的提交键关联窗口（秒）。
    private static let submitWindowSec: TimeInterval = 0.300

    /// thread 复用窗口（毫秒）—— 同窗口 1 小时内的会话串成一个 thread。
    private static let threadReuseWindowMs: Int64 = 3_600_000

    private let pipelineLog = Logger(subsystem: "com.joyzhang.myportrait",
                                     category: "typing.pipeline")

    // MARK: - 生命周期

    init(store: TypingEventStore) {
        self.store = store
    }

    func start() {
        guard !running else { return }

        // 静默检查 AX 权限 —— 不带 prompt（弹窗引导是 UI 件）。
        guard AXIsProcessTrusted() else {
            print("[TypingObserver] AX not granted — idle")
            return
        }

        running = true

        // Layer 1 起 CGEventTap。失败不崩，KeystrokeLedger 自身会 log warning，
        // isRunning 保持 false，hasKeystroke 永远 false。
        do {
            try ledger.start()
        } catch {
            pipelineLog.warning("KeystrokeLedger.start failed: \(String(describing: error), privacy: .public)")
        }

        // compose-timeout tick：每 100ms 驱动一次 registry.tick。
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickIntervalSec,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTick()
            }
        }
        tickTimer = timer

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

        tickTimer?.invalidate()
        tickTimer = nil

        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserverToken = nil
        }

        // 整体停 —— 关闭所有未完成的 Layer 3 会话，落库未丢的内容。
        // 旧 app 元素多半已失效，finalText 用 lastValues 兜底（取不到 → ""）。
        for key in aggregator.allKeys() {
            let finalText = lastValues[key.elementHash] ?? ""
            closeSession(key: key, reason: "idle", finalText: finalText)
        }
        emit(registry.flushAll())

        ledger.stop()

        detach()
        lastValues.removeAll()
        print("[TypingObserver] stopped")
    }

    /// `isolated deinit` —— 在 MainActor 上跑（SE-0371），才能安全读
    /// 非 Sendable 的隔离字段（attachment / workspaceObserverToken）。
    isolated deinit {
        tickTimer?.invalidate()
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
        // app 切走（app_change 关闭触发器）：旧 app 的元素多半已失效，
        // 对每个在册 Layer 3 会话用 lastValues 兜底作 finalText 关闭并落库，
        // 再 flush L2、清值缓存，detach 旧的 attach 新的。
        for key in aggregator.allKeys() {
            let finalText = lastValues[key.elementHash] ?? ""
            closeSession(key: key, reason: "app_change", finalText: finalText)
        }
        emit(registry.flushAll())
        lastValues.removeAll()
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
        // Layer 1 心跳误判为用户输入 —— 终端整段不订阅。
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

        // 立刻读一次 baseline 值写进 lastValues —— 否则该 element 的第一次
        // value 变化会撞上 processValueChange 的"首次见到只存值不 diff"，
        // 把第一个字符吞掉。读失败（如某些不可读元素）→ 退化为空串 baseline。
        // 元素正处于 IME composition 时也照读 raw value，后续 Layer 2 状态机
        // 会折叠 composition。
        let elementHash = Int(CFHash(focused))
        var baselineRef: CFTypeRef?
        let baselineErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &baselineRef
        )
        if baselineErr == .success, let baseline = baselineRef as? String {
            lastValues[elementHash] = baseline
        } else {
            lastValues[elementHash] = ""
        }

        // 重算缓存 thread id —— 同 (bundle, window) 1 小时内的会话串成一个 thread。
        recomputeThreadId(bundleId: att.bundleId)
    }

    /// 重算并缓存 `currentThreadId`：查最近 1 小时内同 (bundle, window) 的
    /// 最后一条 typing_events，命中 → 复用其 thread id，否则新建 UUID。
    /// 查询失败（DB 错误）静默退化为新 UUID。
    private func recomputeThreadId(bundleId: String) {
        let windowTitle = currentWindowTitle()
        if let last = try? store.lastEvent(bundleId: bundleId,
                                           windowTitle: windowTitle,
                                           withinMs: Self.threadReuseWindowMs) {
            currentThreadId = last.threadId
        } else {
            currentThreadId = UUID().uuidString
        }
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
            // 焦点换元素（focus_change 关闭触发器）：对旧 focused 元素 ——
            // ① 读它当前 AX value 作 finalText（读失败用 lastValues 兜底）
            // ② closeSession 关闭其 Layer 3 会话并落库
            // ③ 清值缓存，再重订到新元素 + 重算 thread id。
            if let att = attachment, let old = att.focusedElement {
                let oldHash = Int(CFHash(old))
                let oldKey = SessionKey(pid: att.pid, elementHash: oldHash)
                let finalText = copyStringAttr(old, kAXValueAttribute)
                    ?? lastValues[oldHash] ?? ""
                closeSession(key: oldKey, reason: "focus_change", finalText: finalText)
                lastValues[oldHash] = nil
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

    /// compose-timeout tick：100ms 一次。
    /// ① 驱动 registry 对所有 element 跑规则 9（compose timeout flush）。
    /// ② idle_close 关闭触发器：关掉所有 4s 内无新 event 的 Layer 3 会话。
    private func handleTick() {
        let now = CACurrentMediaTime()
        // compose-timeout flush 出的 commit 属于当前 focused 元素 —— 喂进它的会话。
        let tickEvents = registry.tick(now: now)
        emit(tickEvents)
        if !tickEvents.isEmpty,
           let att = attachment, let focused = att.focusedElement {
            let key = SessionKey(pid: att.pid, elementHash: Int(CFHash(focused)))
            feedAggregator(tickEvents, key: key, focused: focused)
        }

        for key in aggregator.idleKeys(now: now, idleSeconds: Self.sessionIdleSec) {
            // 若该 key 正是当前 focused 元素 → 读其 AX value 作 finalText，
            // 否则用 lastValues 兜底（取不到 → ""）。
            let finalText: String
            if let focused = attachment?.focusedElement,
               Int(CFHash(focused)) == key.elementHash {
                finalText = copyStringAttr(focused, kAXValueAttribute)
                    ?? lastValues[key.elementHash] ?? ""
            } else {
                finalText = lastValues[key.elementHash] ?? ""
            }
            closeSession(key: key, reason: "idle", finalText: finalText)
        }
    }

    // MARK: - 值变化 → RawEdit → L1 → L2 → handler

    private func processValueChange() {
        guard let att = attachment, let focused = att.focusedElement else { return }

        // 暂停闸门：菜单栏暂停开关打开时，整体丢弃 value 变化。
        // AX 订阅保持不动，恢复后下一次 value 变化立即生效。
        if ConfigStore.shared.recording.typingCapturePaused { return }

        // 隐私闸门：secure field（密码输入框）不读值、不 diff。
        let role = copyStringAttr(focused, kAXRoleAttribute)
        if TypingPrivacyFilter.isSecureRole(role) {
            return
        }

        let elementHash = Int(CFHash(focused))

        // 读 focused 元素当前完整文本值。
        var valueRef: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        )
        guard valueErr == .success else {
            // 元素已消失 —— 清掉它的值缓存条目。其它读失败静默忽略。
            if valueErr == .invalidUIElement {
                lastValues[elementHash] = nil
            }
            return
        }
        guard let newValue = valueRef as? String else {
            // value 存在但不是字符串 —— 不是文本元素。
            return
        }

        // 取该 element 上次缓存的值。首次见到 → 只存值不 diff。
        guard let oldValue = lastValues[elementHash] else {
            lastValues[elementHash] = newValue
            return
        }

        // submit_close 关闭触发器：输入框从「有内容」骤然清空（提交后框被清）
        // 且最近 300ms 内按过提交键 → 判定为「提交」，用提交前的内容 oldValue
        // 作 finalText 关闭会话落库，清空那次变化不喂 L2/L3。
        let key = SessionKey(pid: att.pid, elementHash: elementHash)
        if oldValue.count >= 3 && newValue.count < 3
            && ledger.hasSubmitKey(within: Self.submitWindowSec) {
            lastValues[elementHash] = newValue
            closeSession(key: key, reason: "submit", finalText: oldValue)
            return
        }

        lastValues[elementHash] = newValue

        // 求单段连续编辑。无变化 → nil → return。
        guard let raw = RawEdit.from(oldValue: oldValue, newValue: newValue,
                                     pid: att.pid, elementHash: elementHash,
                                     ts: CACurrentMediaTime()) else {
            return
        }

        // Layer 1：心跳过滤。insert/replace 看 120ms 窗口，delete 看 200ms。
        let window: TimeInterval = (raw.kind == .delete)
            ? Self.keystrokeWindowDeleteSec
            : Self.keystrokeWindowEditSec
        guard ledger.hasKeystroke(within: window) else {
            pipelineLog.debug("L1:drop:no-keystroke kind=\(String(describing: raw.kind), privacy: .public)")
            return
        }

        // Layer 2：折叠。Layer 3：把折出的 event 喂进会话聚合器。
        let events = registry.feed(raw)
        emit(events)
        let overMax = feedAggregator(events, key: key, focused: focused)
        // max_chars 关闭触发器：累计 commit 字符数超 10000 → 读当前 focused
        // 元素 AX value 作 finalText 关闭会话落库。之后用户继续打字自然开新 session。
        if overMax {
            let finalText = copyStringAttr(focused, kAXValueAttribute)
                ?? lastValues[elementHash] ?? ""
            closeSession(key: key, reason: "max_chars", finalText: finalText)
        }
    }

    // MARK: - IMEFoldEvent handler

    /// 每条 IMEFoldEvent log 一行 + 转交 onFoldEvent 闭包。
    /// （Layer 3 的 aggregator.feed 由 `feedAggregator` 单独做 —— 它需要明确的
    ///  SessionKey / SessionContext，emit 处于多个调用点拿不到统一的 key。）
    private func emit(_ events: [IMEFoldEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            pipelineLog.debug(
                "[L2] \(String(describing: event.kind), privacy: .public) \"\(event.text, privacy: .public)\" script=\(String(describing: event.script), privacy: .public) trace=\(event.traceTag?.description ?? "-", privacy: .public)")
        }
        onFoldEvent?(events)
    }

    // MARK: - Layer 3 会话聚合

    /// 把一组 IMEFoldEvent 喂进 Layer 3 会话聚合器。
    /// - Returns: 该 session 累计 commit 字符数是否已超 max_chars。
    @discardableResult
    private func feedAggregator(_ events: [IMEFoldEvent],
                                key: SessionKey,
                                focused: AXUIElement) -> Bool {
        guard !events.isEmpty else { return false }
        let ctx = makeSessionContext(focused: focused)
        var overMax = false
        for event in events {
            if aggregator.feed(event, key: key, ctx: ctx) { overMax = true }
        }
        return overMax
    }

    /// 关闭统一子流程（五个关闭触发器共用）。
    /// ① `registry.handleFocusChange` flush L2 的 Composing buffer，
    ///    把 flush 出的 event 先喂进 aggregator（保证 editLog 完整）。
    /// ② `aggregator.close` 产出 `TypingEvent?`。
    /// ③ 非 nil → 写库 + 转交 onTypingEvent。
    private func closeSession(key: SessionKey, reason: String, finalText: String) {
        // ① flush L2 残余 buffer，喂进 aggregator —— 用被关闭的 key，不依赖
        //    「当前 focused」（focus_change 时焦点已换走）。
        let flushed = registry.handleFocusChange(elementHash: key.elementHash)
        if !flushed.isEmpty {
            emit(flushed)
            // 仅当会话仍在册时才喂（flush 的 event 不该为已不存在的会话凭空建一个）。
            if aggregator.hasSession(key) {
                let ctx = currentSessionContextForClose()
                for event in flushed {
                    _ = aggregator.feed(event, key: key, ctx: ctx)
                }
            }
        }

        // ② 产出 TypingEvent（finalText < 3 → nil 丢弃）。无论产出与否都移除 key。
        guard let event = aggregator.close(key: key, finalText: finalText,
                                           reason: reason) else {
            return
        }

        // ③ 写库 + dev flag 消费口。
        do {
            try store.insert(event)
        } catch {
            pipelineLog.warning("typing_events insert failed: \(String(describing: error), privacy: .public)")
        }
        onTypingEvent?(event)
    }

    /// 给当前 focused 元素构造 SessionContext。
    private func makeSessionContext(focused: AXUIElement) -> SessionContext {
        let role = copyStringAttr(focused, kAXRoleAttribute)
        return SessionContext(
            bundleId: attachment?.bundleId ?? "unknown",
            appName: attachment?.appName,
            windowTitle: currentWindowTitle(),
            elementRole: role,
            threadId: currentThreadId
        )
    }

    /// closeSession 步骤① flush 出 event 但会话恰好是新建的兜底场景用。
    /// 正常情况下会话早已存在、ctx 已固定，这里只是 `aggregator.feed` 的形参要求。
    private func currentSessionContextForClose() -> SessionContext {
        if let focused = attachment?.focusedElement {
            return makeSessionContext(focused: focused)
        }
        return SessionContext(
            bundleId: attachment?.bundleId ?? "unknown",
            appName: attachment?.appName,
            windowTitle: currentWindowTitle(),
            elementRole: nil,
            threadId: currentThreadId
        )
    }

    // MARK: - AX 读取小工具

    /// 读字符串属性，失败返回 nil。
    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    /// 读当前 app 的 focused 窗口标题，失败返回 nil。
    private func currentWindowTitle() -> String? {
        guard let att = attachment else { return nil }
        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            att.appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard err == .success, let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        return copyStringAttr(window, kAXTitleAttribute)
    }
}
