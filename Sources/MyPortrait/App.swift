import SwiftUI
import AppKit
import GRDB
import MLX
import os.log

@main
struct MyPortraitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // CLI 模式：`--embed-dump <text>` 跑 bge-m3 推理 → stdout 拷向量 → exit。
        // 用于跟 Python FlagEmbedding 数值对齐（要求 cosine ≥ 0.999）。
        // 必须在任何 SwiftUI / AppDelegate 设置之前拦截，否则会被窗口初始化拖慢。
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--embed-dump") {
            let userText: String? = (idx + 1 < args.count) ? args[idx + 1] : nil
            EmbedDumpCLI.run(userText: userText)
            // EmbedDumpCLI.run 内部 exit(0/1)，不会返回。
        }
        if args.contains("--embed-batch-test") {
            EmbedDumpCLI.runBatchTest()
        }
        if args.contains("--embed-profile") {
            EmbedDumpCLI.runProfile()
        }
        // 真实路径 profile：跟正常 app 一样起 Services（DB + capture / compaction /
        // transcribe / retention 都空载跑着），但不显示窗口。
        if args.contains("--embed-profile-from-db") {
            print("=== bootstrap baseline ===")
            print("RSS before Services init: \(rssEarlyMB()) MB")
            fflush(stdout)
            let services = Services()
            print("RSS after Services init: \(rssEarlyMB()) MB")
            fflush(stdout)
            services.startManagedLifecycle()
            print("RSS after startManagedLifecycle: \(rssEarlyMB()) MB")
            fflush(stdout)
            EmbedDumpCLI.runProfileFromDB(services: services)
            // exit inside
        }
        if let idx = args.firstIndex(of: "--capture-profile"), idx + 1 < args.count {
            let scenario = args[idx + 1]
            print("=== capture profile scenario \(scenario) ===")
            fflush(stdout)
            let services = Services()
            services.startManagedLifecycle()
            EmbedDumpCLI.runCaptureProfile(services: services, scenario: scenario)
        }
        if args.contains("--rebuild-frames-fts") {
            print("=== rebuild-frames-fts ===")
            fflush(stdout)
            let services = Services()
            services.startManagedLifecycle()
            EmbedDumpCLI.runRebuildFramesFts(services: services)
        }
        if args.contains("--embed-search-test") {
            print("=== embed-search-test ===")
            fflush(stdout)
            let services = Services()
            services.startManagedLifecycle()
            EmbedDumpCLI.runSearchTest(services: services)
        }
        if args.contains("--embed-backfill") {
            print("=== backfill mode ===")
            print("RSS: \(rssEarlyMB()) MB")
            fflush(stdout)
            let services = Services()
            services.startManagedLifecycle()
            EmbedDumpCLI.runBackfill(services: services)
            // exit inside
        }
        // DEV-ONLY: `--event-prompt-test <yyyy-MM-dd>` validates the proposed
        // per-event clustering prompt against one day's data. stdout only,
        // writes nothing. Disposable — remove with EventPromptTest.swift.
        if let idx = args.firstIndex(of: "--event-prompt-test"), idx + 1 < args.count {
            EventPromptTestCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--backfill-day <yyyy-MM-dd>` runs the real Backfill for a
        // single day. Disposable — remove with EventPromptTest.swift.
        if let idx = args.firstIndex(of: "--backfill-day"), idx + 1 < args.count {
            BackfillDayCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--backfill-days <N>` runs the real Backfill over the
        // last N days in one process.
        if let idx = args.firstIndex(of: "--backfill-days"), idx + 1 < args.count,
           let n = Int(args[idx + 1]) {
            BackfillDaysCLI.run(daysBack: n)
            // run() exits the process internally.
        }
        // DEV-ONLY: `--dump-day <yyyy-MM-dd>` exports one day's sessions as JSON.
        if let idx = args.firstIndex(of: "--dump-day"), idx + 1 < args.count {
            DumpDayCLI.run(day: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--materialize-day <yyyy-MM-dd> <clustering.json>` writes
        // events from a subagent-produced clustering JSON.
        if let idx = args.firstIndex(of: "--materialize-day"), idx + 2 < args.count {
            MaterializeDayCLI.run(day: args[idx + 1], clusteringPath: args[idx + 2])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--dump-events-by-category` exports distill input buckets.
        if args.contains("--dump-events-by-category") {
            DumpEventsByCategoryCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--materialize-portrait <category> <decisions.json>`.
        if let idx = args.firstIndex(of: "--materialize-portrait"), idx + 2 < args.count {
            MaterializePortraitCLI.run(category: args[idx + 1], decisionsPath: args[idx + 2])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--dump-events-for-scoring` exports baseline-impact events.
        if args.contains("--dump-events-for-scoring") {
            DumpEventsForScoringCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--apply-scores <scores.json>` writes subagent scores back.
        if let idx = args.firstIndex(of: "--apply-scores"), idx + 1 < args.count {
            ApplyScoresCLI.run(scoresPath: args[idx + 1])
            // run() exits the process internally.
        }
        // DEV-ONLY: `--rescore` runs ImpactScorer over every event file.
        if args.contains("--rescore") {
            RescoreCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--distill` runs the full PortraitDistiller pass.
        if args.contains("--distill") {
            DistillCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--repair-portrait` re-reads + re-writes every portrait /
        // event .md to fix stale on-disk frontmatter formatting.
        if args.contains("--repair-portrait") {
            RepairPortraitCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: `--migrate-portrait-ema` one-time Phase 3 migration —
        // backup + reset every portrait file to the EMA clean baseline.
        if args.contains("--migrate-portrait-ema") {
            MigratePortraitEMACLI.run()
            // run() exits the process internally.
        }
        // `--import-default-pipes` seeds the two built-in pipes into
        // PipeStore. Idempotent (matches by name). Exits when done.
        if args.contains("--import-default-pipes") {
            DefaultPipesImportCLI.run()
            // run() exits the process internally.
        }
        // DEV-ONLY: MemoryScheduler 崩溃恢复 / retry / dead_letter 测试入口。
        // 见 SchedulerTestCLI.swift。各子命令内部 exit；--sched-lock 永久挂起。
        if args.contains("--sched-dump") {
            SchedulerTestCLI.dump()
        }
        if let idx = args.firstIndex(of: "--sched-lock"), idx + 2 < args.count {
            SchedulerTestCLI.lock(date: args[idx + 1], stageStr: args[idx + 2])
        }
        if args.contains("--sched-recover") {
            SchedulerTestCLI.recover()
        }
        if let idx = args.firstIndex(of: "--sched-reset"), idx + 1 < args.count {
            SchedulerTestCLI.reset(date: args[idx + 1])
        }
        if let idx = args.firstIndex(of: "--sched-inject"), idx + 3 < args.count {
            SchedulerTestCLI.inject(date: args[idx + 1], stageStr: args[idx + 2], kindStr: args[idx + 3])
        }
        if args.contains("--sched-budget-strings") {
            SchedulerTestCLI.budgetStrings()
        }
        if args.contains("--sched-trigger-test") {
            SchedulerTestCLI.triggerTest()
        }
        if let idx = args.firstIndex(of: "--sched-would-process"), idx + 1 < args.count {
            SchedulerTestCLI.wouldProcess(date: args[idx + 1])
        }
        // `--typing-observe` 只跑 TypingObserver（AX 订阅 + print 日志），
        // 不启动 capture / Memory pipeline / 不开窗口。AX 回调靠主 run loop，
        // 所以这里**不 exit()**：只置一个标志，AppDelegate 据此跳过
        // Services / 窗口创建，让 NSApplication run loop 继续活着。
        if args.contains("--typing-observe") {
            AppDelegate.typingObserveOnly = true
        }
        AppKeyboard.install()
    }

    var body: some Scene {
        // No WindowGroup — the AppDelegate creates the main window via
        // AppKit so SwiftUI doesn't insert any toolbar chrome of its own.
        // The `Settings` scene gives us the standard ⌘, → Settings flow
        // via the App menu without polluting the main sidebar.
        Settings {
            SettingsScene()
                .preferredColorScheme(.dark)
                .frame(minWidth: 880, minHeight: 580)
        }
    }
}

// MARK: - NSWindow subclass that refuses to ever have an NSToolbar

/// SwiftUI's NavigationSplitView keeps trying to install a sidebar-toggle
/// toolbar item, which forces an NSToolbar layer on the window. Overriding
/// the `toolbar` setter to no-op makes the window flat-out reject any
/// attempt to attach one. Combined with `.fullSizeContentView` + transparent
/// title bar, this leaves a single chrome layer: the title bar with the
/// traffic-light buttons floating over the content.
final class ChromelessWindow: NSWindow {
    // **`nonisolated` 是关键**：NSWindow.toolbar 在 SDK 里是 @MainActor 隔离的，
    // Swift 6 会在 override 的 getter 里插 `_checkExpectedExecutor`。但 macOS
    // 的 Accessibility 子系统（NSAccessibilityGetObjectForAttributeUsingLegacyAPI）
    // 会从**后台线程**调 `accessibilityChildrenAttribute` → 间接调这个 getter →
    // executor 检查发现不在 main → `dispatch_assert_queue_fail` 整进程崩。
    // getter 只返回常量 nil、setter 空体，不碰任何 actor 状态，标 nonisolated
    // 完全安全，且能让任意线程调用它而不触发 executor 断言。
    nonisolated override var toolbar: NSToolbar? {
        get { nil }
        set { /* refuse — keep nil forever */ }
    }
}

// MARK: - AppDelegate — owns the single app window

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: ChromelessWindow!
    var services: Services!
    var statusBarMenu: StatusBarMenu!

    /// `--typing-observe` CLI 模式标志。init() 里置位，launching 时分支。
    /// 仅在 App init（启动早期，单线程）写一次，之后只读 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) static var typingObserveOnly = false

    /// `--typing-observe` 模式下持有的 observer（持有它以保证存活 + 退出时 stop）。
    private var typingObserver: TypingObserver?

    /// SIGINT dispatch source —— 静态引用顶住生命周期，否则会被立即释放。
    /// 仅在 launching（MainActor）写一次 —— nonisolated(unsafe) 安全。
    nonisolated(unsafe) private static var sigintSource: DispatchSourceSignal?

    private let lifecycleLog = Logger(subsystem: "com.myportrait", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CLI 模式：只跑 TypingObserver，跳过 Services / 窗口创建。
        // 主 run loop 仍需活着（AX 回调靠它），所以不开窗口但不退出。
        if Self.typingObserveOnly {
            NSApp.setActivationPolicy(.accessory)
            // 开 ~/.portrait/portrait.sqlite 的 DatabasePool，让 observer 真正写库。
            // prepareDatabase 必须注册 FoundationTokenizer，否则 frames_fts
            // migration 会因 "no such tokenizer" 失败（同 PortraitDBImpl.init）。
            let store: TypingEventStore?
            do {
                let path = Storage.portraitDBPath
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                var config = Configuration()
                config.prepareDatabase { db in
                    db.add(tokenizer: FoundationTokenizer.self)
                }
                let pool = try DatabasePool(path: path, configuration: config)
                try DBSchema.migrator().migrate(pool)
                store = TypingEventStore(dbPool: pool)
                print("[TypingObserver] DB opened: \(path)")
            } catch {
                print("[TypingObserver] DB open failed: \(error) — print-only mode")
                store = nil
            }
            let observer = TypingObserver(store: store)
            observer.start()
            typingObserver = observer
            // Ctrl+C → 走 stop() 清理路径再退出。SIGINT 在 main queue 上回调。
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            src.setEventHandler { [weak self] in
                self?.typingObserver?.stop()
                exit(0)
            }
            src.resume()
            signal(SIGINT, SIG_IGN)  // 默认 handler 终止进程，先忽略让 dispatch source 接管
            // 防 src 被释放：用 associated 静态引用顶住其生命周期。
            Self.sigintSource = src
            print("[TypingObserver] --typing-observe mode — press Ctrl+C to stop")
            return
        }

        // 1. 服务层先起（无 UI 依赖，可在权限请求前 init）
        services = Services()
        statusBarMenu = StatusBarMenu(settings: services.settings, permissions: services.permissions)

        // 确保磁盘目录结构存在
        do {
            try Storage.ensureExists()
        } catch {
            lifecycleLog.error("Storage.ensureExists failed: \(error.localizedDescription, privacy: .public)")
        }

        NSApp.setActivationPolicy(.regular)

        window = ChromelessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 835),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 500)
        window.backgroundColor = .black
        // Explicit unhide — some macOS 26 chrome configurations hide these
        // by default when the title bar is transparent.
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false

        // Host the SwiftUI ContentView inside the AppKit window.
        // Inject the Services container + captureSettings into the environment
        // so any descendant view can read \.services (db / coordinator / reporter)
        // or \.captureSettings (toggle bindings for the Settings UI).
        let hosting = NSHostingView(
            rootView: ContentView()
                .environment(\.services, services)
                .environment(\.captureSettings, services.settings)
                .environmentObject(services.settings)
                .preferredColorScheme(.dark)
        )
        hosting.autoresizingMask = [.width, .height]
        // Default sizingOptions let SwiftUI's intrinsic size feed back into the
        // window — when frames reload on a date switch the intrinsic size
        // transiently changes and the visible content "shrinks" vertically.
        // Empty options keeps the window size fixed regardless of content.
        hosting.sizingOptions = []
        window.contentView = hosting

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wire config → window/app chrome. Theme / always-on-top / app name
        // / Dock icon / launch-at-login all flow through this once ConfigStore
        // changes (vim edits or in-app toggles both fire the trampoline).
        ConfigApplier.shared.install(window: window, statusBar: statusBarMenu)
        // 弹一次系统通知权限请求。用户拒绝后 ConfigStore 里的 toggle 仍可切，
        // 但 NotificationCenterService.post 会因 authorized=false 静默放弃。
        NotificationCenterService.shared.requestAuthorizationOnce()

        // 3. 启动 services 生命周期管理。
        //    - compactor / transcriber 立即开始（空转零成本）
        //    - coordinator / audio **由 settings 驱动**：默认开关都 OFF →
        //      首启不弹屏幕录制 / 麦克风权限。用户在 Settings 面板打开后才启。
        services.startManagedLifecycle()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // --typing-observe 模式：只需停 observer（走三步清理路径）。
        if Self.typingObserveOnly {
            typingObserver?.stop()
            return
        }
        // 进程退出前尽量优雅停止所有子系统（刷盘、关 SCStream、停 compaction、停录音）。
        // 同步等最多 ~1s，超时由系统 ~5s 后强制 kill 兜底。
        let sem = DispatchSemaphore(value: 0)
        let services = self.services
        Task.detached(priority: .userInitiated) {
            await services?.stopManagedLifecycle()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.0)
    }
}

// MARK: - App-level keyboard monitor — broadcasts arrow keys via NotificationCenter

enum AppKeyboard {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            print("[Keyboard] keyDown keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "")")
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            let isAlt = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 123:    // LeftArrow
                NotificationCenter.default.post(name: .leftArrowPressed, object: isAlt)
                return nil
            case 124:    // RightArrow
                NotificationCenter.default.post(name: .rightArrowPressed, object: isAlt)
                return nil
            default:
                return event
            }
        }
    }
}

extension Notification.Name {
    static let leftArrowPressed = Notification.Name("MyPortrait.LeftArrow")
    static let rightArrowPressed = Notification.Name("MyPortrait.RightArrow")
}

/// 启动期快速读 RSS（不依赖 EmbedDumpCLI，免循环依赖）。
private func rssEarlyMB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Int(info.resident_size) / 1024 / 1024
}
