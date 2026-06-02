import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// 首次启动引导。**当前未自动接入** —— 在 Settings → General → Maintenance
/// 有个 "Preview onboarding" 按钮可以手动唤起。等流程跑顺再切到首启自动弹。
///
/// 8 步:
///   1. Welcome
///   2. Permissions(5 项)
///   3. Personal info(全选填)
///   4. Connect an AI(可跳过)
///   5. Memory provider
///   6. Scheduler
///   7. Speaker training
///   8. Done
///
/// 所有步都允许 Skip;最后一步 Finish **永远可点**(用户连不连都能过)。
struct OnboardingView: View {

    /// 关闭回调 —— 由调用方决定怎么 dismiss(.sheet binding 或 window close)。
    var onFinish: () -> Void

    @State private var step: Int = 0
    private let totalSteps = 8

    /// Onboarding 期间 NSWindow 缩到的尺寸(比主 app 的 1200x835 小一截,
    /// 视觉上一看就知道是"setup wizard"而不是主 app)。
    private static let onboardingSize = NSSize(width: 720, height: 560)
    /// 主 app 的窗口尺寸(跟 App.swift 里 ChromelessWindow 初始一致),Finish
    /// 后恢复。
    private static let mainAppSize = NSSize(width: 1200, height: 835)

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(SidebarBackdrop().ignoresSafeArea())
        .onAppear { resizeWindow(to: Self.onboardingSize, animate: false) }
        // **不能再靠 .onDisappear 还原窗口尺寸** —— ContentView 用
        // Group + if/else 切到 mainContent 时,SwiftUI 把 OnboardingView 从
        // view tree 摘掉的时机不固定;onDisappear 可能在 mainContent 已经
        // 按"老 onboarding size 720x560"布局之后才烧起来,等用户点 sidebar
        // 重新触发 layout 才纠正回去(用户复现的"app 缩小,点 timeline 才恢
        // 复"就是这个)。改成在 Finish 按钮回调里**先**还原窗口尺寸,**再**
        // 调 onFinish() 翻 flag,顺序明确。
    }

    /// Finish 按钮的最终步:先 **同步、无动画** 把窗口 resize 回主 app
    /// 尺寸,等一个 runloop tick 让 NSHostingView / SwiftUI 完成对新尺寸的
    /// layout 传播,再翻 onboardingCompleted flag 切到 mainContent。
    ///
    /// 之前的版本用了 `animate: true` 做 setFrame —— animate 会让 NSWindow
    /// 在 runloop 里调度一个动画,过程中 contentView 的 frame 不会立刻
    /// 是目标尺寸。等 onFinish() 翻 flag,SwiftUI 立刻重算 mainContent,
    /// 这时拿到的 hosting view 尺寸还在动画的起点附近(老 720x560),
    /// mainContent 第一帧就按那个尺寸 layout → 用户看到的"缩水主 UI"。
    /// 动画跑完 hosting frame 才到 1200x835,但 SwiftUI 已经按小尺寸算完
    /// 不会自动重排。点 sidebar 强制刷新 layout 才纠正过来。
    ///
    /// 修法:animate:false 让 setContentSize 同步走完;再用
    /// DispatchQueue.main.async 把 flag 翻动推到下个 runloop tick,
    /// 保证 NSHostingView 已经 layout 完才让 SwiftUI 见到新 onboardingCompleted。
    private func finish() {
        resizeWindow(to: Self.mainAppSize, animate: false)
        DispatchQueue.main.async {
            onFinish()
        }
    }

    /// 拿到 app 主 NSWindow + 改 content size + 居中。ContentView 的 Group
    /// 切换 view 不会重建 NSWindow(同一个 NSApplicationDelegate.window),所以
    /// 这里 resize 是直接对那个 window 操作。
    ///
    /// 主 window 标志:有 .titled style + .resizable。NSPanel 浮层(NotificationOverlay
    /// 等)styleMask 通常不含 .titled,过滤掉。
    private func resizeWindow(to size: NSSize, animate: Bool) {
        let mainWindow = NSApp.windows.first { w in
            w.styleMask.contains(.titled) && w.styleMask.contains(.resizable)
        }
        guard let window = mainWindow else {
            print("[Onboarding] resizeWindow: no main window found (windows=\(NSApp.windows.count))")
            return
        }
        // setContentSize 处理「内容尺寸」(去掉 titlebar 后),最干净;不需要
        // 自己 contentRect 转换。但 setContentSize 默认从左下扩展 → 显式重新
        // 居中:用旧 frame center 算新 frame origin。
        let oldFrame = window.frame
        let oldCenter = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
        window.setContentSize(size)
        // setContentSize 之后 frame.size 变了,但 origin 还没动 —— 显式居中。
        let newFrame = window.frame
        let newOrigin = NSPoint(x: oldCenter.x - newFrame.width / 2,
                                y: oldCenter.y - newFrame.height / 2)
        window.setFrame(NSRect(origin: newOrigin, size: newFrame.size),
                        display: true, animate: animate)
        print("[Onboarding] resized \(oldFrame.size) → \(size)")
    }

    // MARK: - Header / progress

    private var progressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.white.opacity(0.10))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Step switch

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: PermissionsStep()
        case 2: PersonalInfoStep()
        case 3: ConnectAIStep()
        case 4: MemoryProviderStep()
        case 5: SchedulerStep()
        case 6: SpeakerTrainingStep()
        default: FinishStep()
        }
    }

    // MARK: - Footer (Back / Skip / Next / Finish)

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Spacer(minLength: 0)
            if step > 0 && step < totalSteps - 1 {
                Button("Skip") { advance() }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
            }
            Button(step == totalSteps - 1 ? "Finish" : "Next") {
                if step == totalSteps - 1 { finish() }
                else { advance() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.20))
    }

    private func advance() {
        guard step < totalSteps - 1 else { return }
        withAnimation(.easeInOut(duration: 0.18)) { step += 1 }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to My Portrait")
                .font(.system(size: 32, weight: .semibold))
            Text("A private, on-device AI memory system. It quietly captures what you do, then turns it into a long-term portrait that any chat model you connect can reference. Everything stays on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Captures screen + keyboard + audio with your permission")
                bullet("Builds a portrait you can read, edit, or delete at any time")
                bullet("Brings your own AI — ChatGPT, Claude, Gemini, DeepSeek, Ollama")
            }
            .padding(.top, 8)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 40)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green.opacity(0.75))
                .padding(.top, 2)
            Text(s).font(.system(size: 13))
        }
    }
}

// MARK: - Step 2: Permissions

/// macOS TCC permissions onboarding 关心的 5 项。每项有:
///   - 状态(granted / denied / unknown)实时刷新
///   - 一键请求按钮(没 API 的就跳系统设置)
private struct PermissionsStep: View {
    @StateObject private var monitor = PermissionMonitor()
    @State private var inputMonitoring: PermStatus = .unknown
    /// UI 刷新 trigger —— Input Monitoring 不在 PermissionMonitor 里,用 timer 拉一次。
    @State private var pollTask: Task<Void, Never>? = nil

    enum PermStatus { case granted, denied, unknown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Grant permissions")
                    .font(.system(size: 24, weight: .semibold))
                Text("Each one unlocks a specific capture layer. Skip any you don't want — the rest of the app keeps working.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                permRow(
                    icon: "rectangle.inset.filled.on.rectangle",
                    title: "Screen Recording",
                    why: "Required to capture what's on your screen for OCR and context.",
                    status: mapAppKit(monitor.screenRecording),
                    action: { monitor.requestScreenRecording() },
                    openSettings: { monitor.openSettings(for: .screen) }
                )
                permRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    why: "Required to read window titles, focus state, and global keyboard events.",
                    status: mapAppKit(monitor.accessibility),
                    action: { monitor.requestAccessibility() },
                    openSettings: { monitor.openSettings(for: .accessibility) }
                )
                permRow(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    why: "Required for the keystroke ledger — Accessibility alone isn't enough for global CGEventTap on macOS.",
                    status: inputMonitoring,
                    action: { requestInputMonitoring() },
                    openSettings: { openInputMonitoringSettings() }
                )
                permRow(
                    icon: "mic",
                    title: "Microphone",
                    why: "Required if you want voice transcription as part of memory.",
                    status: mapAppKit(monitor.microphone),
                    action: { monitor.requestMicrophone() },
                    openSettings: { monitor.openSettings(for: .microphone) }
                )
                permRow(
                    icon: "externaldrive",
                    title: "Full Disk Access",
                    why: "Required so we can read your Screenpipe history (if you use it). macOS won't ever let an app auto-prompt for this — you'll have to add My Portrait in System Settings manually.",
                    status: mapAppKit(monitor.fullDiskAccess),
                    action: nil,
                    openSettings: { monitor.openSettings(for: .fullDisk) }
                )
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            monitor.start()
            refreshExtraPerms()
            startPoll()
        }
        .onDisappear {
            monitor.stop()
            pollTask?.cancel()
        }
    }

    // MARK: row

    @ViewBuilder
    private func permRow(
        icon: String,
        title: String,
        why: String,
        status: PermStatus,
        action: (() -> Void)?,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    statusPill(status)
                }
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if status != .granted, let action {
                    Button("Allow") { action() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func statusPill(_ s: PermStatus) -> some View {
        let (label, color): (String, Color) = {
            switch s {
            case .granted: return ("Granted", .green)
            case .denied:  return ("Not granted", .orange)
            case .unknown: return ("Unknown", .gray)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.20))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func mapAppKit(_ s: PermissionMonitor.Status) -> PermStatus {
        switch s {
        case .granted:      return .granted
        case .denied:       return .denied
        case .notDetermined: return .unknown
        }
    }

    // MARK: Input Monitoring & Notification — 不在 PermissionMonitor 里,自己查

    private func refreshExtraPerms() {
        inputMonitoring = checkInputMonitoring()
    }

    private func startPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                refreshExtraPerms()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func checkInputMonitoring(forceProbe: Bool = false) -> PermStatus {
        // **两层检查**:
        //   1. IOHIDCheckAccess —— 标准 API,但 hidd 后台 daemon 内存里有
        //      stale cache(tccutil reset 后 TCC db 清了 daemon 还说 granted),
        //      自己一个人不可信
        //   2. 真发个 null event + 自己装个 CGEventTap 看能不能收到 —— 这条
        //      绕过 daemon cache,直接 round-trip 验证 tap 能不能跑
        //
        // 两条都过才算 .granted。哪条不过 → 显示 .denied / .unknown 让用户
        // 重新走 Allow 流程。
        let api = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if api == kIOHIDAccessTypeDenied { return .denied }

        // 稳态短路:已确认 granted 后,3s 轮询信任 IOHIDCheckAccess==granted,不再每
        // 次重进 run loop 跑 tap probe(那会每 3s 卡 UI ~100ms)。首次(.unknown)仍跑
        // 一次 probe;tccutil reset 后 api 会翻 denied/notDeterm,自然重新探。
        if api == kIOHIDAccessTypeGranted && !forceProbe && inputMonitoring == .granted {
            return .granted
        }

        // probe 实际 tap 能不能 round-trip 收事件
        let tapWorks = probeInputMonitoringTap()
        if tapWorks { return .granted }

        // API 说 granted 但 tap 收不到事件 → daemon cache 撒谎,实际没权限
        return api == kIOHIDAccessTypeGranted ? .denied : .unknown
    }

    /// 装一个临时 CGEventTap,自己 post 一个 null event,看 callback 能不
    /// 能收到。能收到 → tap 真起来了,Input Monitoring 是 truly granted。
    /// 收不到 → 即使 IOHIDCheckAccess 说 granted,实际 tap 也跑不动。
    ///
    /// 同步实现:run loop spin 至多 100 ms 等 callback。结束清理 tap。
    private func probeInputMonitoringTap() -> Bool {
        // 用 heap 分配的 box 把"received"标志传进 C-style callback。
        // userInfo 直接传 &local 不行,callback 异步触发时 local 可能已出作用域。
        final class FlagBox { var received = false }
        let box = FlagBox()
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<FlagBox>.fromOpaque(boxPtr).release() }

        // 监听 null event(类型 0)—— 没人用,不污染别的 app
        let mask = CGEventMask(1 << CGEventType.null.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, info in
                if let info = info {
                    Unmanaged<FlagBox>.fromOpaque(info).takeUnretainedValue().received = true
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: boxPtr)
        else { return false }   // tap 创建直接失败 → 100% 没权限

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // post 一个 null event 给自己
        if let nullEvent = CGEvent(source: nil) {
            nullEvent.post(tap: .cgSessionEventTap)
        }

        // run loop spin 至多 100 ms 等 callback
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline && !box.received {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }

        // 清理
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        CFMachPortInvalidate(tap)

        return box.received
    }

    private func requestInputMonitoring() {
        // 1) 标准 API —— Apple-notarized 应用一般够,但自签 cert / 非
        //    notarize app `IOHIDRequestAccess` 经常**静默返回 false**,系统
        //    设置 → 隐私 → Input Monitoring 列表里**根本不出现 MyPortrait
        //    那条**,用户没东西可 toggle。
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        // 2) **真正能把 app 注册进系统列表的副作用**:尝试创建一个
        //    CGEventTap。macOS 不管 tap 实际有没有权限运行,只要进程"试图"
        //    创建过 tap,就会把它写进 Input Monitoring 列表。
        //    .listenOnly + 立刻 invalidate,纯触发副作用,不真起 tap。
        let mask: CGEventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil)
        if let tap = tap {
            // 拿到了说明已经有权限,直接 release 不留 tap
            CFMachPortInvalidate(tap)
        }
        // tap == nil 也无所谓 —— 创建尝试本身已经把 app 注册进系统列表了

        // 3) 直接跳到系统设置 Input Monitoring 面板,用户可以立刻看到
        //    "MyPortrait" 那一行并 toggle。
        openInputMonitoringSettings()

        refreshExtraPerms()
    }

    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Step 3: Personal info

/// 紧凑版的 Personal info 表单。完全 optional —— 跳过等于全空,LLM prompt 不
/// 加 about-user 段。
private struct PersonalInfoStep: View {
    @State private var config = ConfigStore.shared
    @State private var newLanguage: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tell me about you (optional)")
                    .font(.system(size: 24, weight: .semibold))
                Text("Filled fields are passed to the memory pipeline as extra context. Empty fields are skipped. You can edit any of this later in Memories → Personal Info.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                groupCard("Name") {
                    formRow("First name") {
                        textField(\.personalInfo.firstName, placeholder: "Given name")
                    }
                    formRow("Middle name") {
                        textField(\.personalInfo.middleName, placeholder: "Optional")
                    }
                    formRow("Last name") {
                        textField(\.personalInfo.lastName, placeholder: "Family name")
                    }
                    formRow("Also goes by") {
                        textField(\.personalInfo.alias, placeholder: "Nickname / English name")
                    }
                }

                groupCard("Identity") {
                    formRow("Pronouns") {
                        Picker("", selection: config.binding(\.personalInfo.gender)) {
                            ForEach(PersonalInfoGender.allCases, id: \.self) { g in
                                Text(g.displayName).tag(g)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    formRow("Nationality") {
                        textField(\.personalInfo.nationality, placeholder: "e.g. Chinese")
                    }
                    formRow("Ethnicity") {
                        textField(\.personalInfo.ethnicity, placeholder: "Optional")
                    }
                    formRow("Date of birth") {
                        textField(\.personalInfo.birthDate, placeholder: "YYYY-MM-DD")
                    }
                }

                groupCard("Languages") {
                    languagesEditor
                }

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: helpers

    @ViewBuilder
    private func groupCard<Content: View>(_ title: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.textPrimary.opacity(0.45))
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
    }

    @ViewBuilder
    private func formRow<Trailing: View>(_ label: String,
                                         @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer(minLength: 12)
            trailing()
        }
    }

    @ViewBuilder
    private func textField(_ kp: WritableKeyPath<MyPortraitConfig, String>,
                           placeholder: String) -> some View {
        TextField(placeholder, text: config.binding(kp))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
            .frame(width: 220)
    }

    @ViewBuilder
    private var languagesEditor: some View {
        let langs = config.current.personalInfo.languages
        VStack(alignment: .leading, spacing: 6) {
            if langs.isEmpty {
                Text("No languages added yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(langs.enumerated()), id: \.offset) { idx, lang in
                HStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.50))
                    Text(lang).font(.system(size: 12))
                    Spacer()
                    Button {
                        config.mutate { c in
                            guard idx < c.personalInfo.languages.count else { return }
                            c.personalInfo.languages.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("Add a language (e.g. English, 中文)", text: $newLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(addLanguage)
                Button("Add") { addLanguage() }
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addLanguage() {
        let v = newLanguage.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        config.mutate { c in
            if !c.personalInfo.languages.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                c.personalInfo.languages.append(v)
            }
        }
        newLanguage = ""
    }
}

// MARK: - Step 4: Connect AI

/// 列出 AI category 的 tile,点一个 → 展开 inline add 面板。我们不重写
/// connection 流程 —— 跑出 Settings → Connections 的同款 ConnectionsView,
/// 嵌进 onboarding 里走它自己的添加流程。
private struct ConnectAIStep: View {
    @Environment(AppState.self) private var appState

    /// 已连接的 AI integration 数。给底部那行小提示用。
    private var connectedCount: Int {
        IntegrationRegistry.all.filter {
            ($0.category == .ai || $0.category == .local) && appState.isConnected($0.id)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect an AI")
                    .font(.system(size: 24, weight: .semibold))
                Text("Pick a provider you already have access to. You'll bring your own credentials — My Portrait never resells AI usage. You can connect more later in Settings → Connections, and you can finish setup without connecting anything.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // 直接嵌入现有 ConnectionsView —— 用户点 tile → expand → add 流程
            // 跟 Settings 里完全一致,不重写。**限制只展示 AI/local 两类**,
            // 不出现 Notion/SMTP/Calendar 等。
            ConnectionsView(
                categoryFilter: [.ai, .local],
                showsHeader: false
            )
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Image(systemName: connectedCount > 0 ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(connectedCount > 0 ? .green : .secondary)
                Text(connectedCount > 0
                     ? "Connected \(connectedCount) provider\(connectedCount == 1 ? "" : "s") — you're good to go."
                     : "Nothing connected yet. You can skip this and connect later from Settings → Connections.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
        }
    }
}

// MARK: - Step 5: Memory AI provider

/// 选 memory pipeline 用哪个 provider + 主/轻两档 model。可选项跟 Settings →
/// Memory → Parameter 的 AI provider 段同源(只列已连接 + 未 disable 的)。
/// 全空时显示提示,可 Skip。
private struct MemoryProviderStep: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigStore.shared

    private var availableProviders: [Provider] {
        let aiCfg = config.current.aiModels
        return Provider.allCases.filter {
            appState.isConnected($0.integrationId)
            && !aiCfg.disabledProviderIds.contains($0.integrationId)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Memory AI model")
                    .font(.system(size: 24, weight: .semibold))
                Text("Which AI runs the memory pipeline — clustering raw activity into events, scoring importance, distilling your portrait, refreshing personality. Two model slots: a main model for heavy tasks, a lighter model for clustering / writing capture. You can change all of this later in Settings → Memory → Parameter.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                if availableProviders.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text("No connected AI provider yet. Go back to the previous step to connect one — or skip this and set it later in Settings → Memory → Parameter.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
                } else {
                    providerCard
                }

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var providerCard: some View {
        let providerId = config.current.memory.providerId
        let selectedProvider = Provider(rawValue: providerId) ?? availableProviders.first ?? .chatgpt
        let models = config.current.aiModels.visibleModels(
            forIntegrationId: selectedProvider.integrationId,
            available: selectedProvider.availableModels
        )

        VStack(alignment: .leading, spacing: 12) {
            row("Provider", desc: "Which AI service to use.") {
                Picker("", selection: config.binding(\.memory.providerId)) {
                    ForEach(availableProviders, id: \.rawValue) { p in
                        Text(Self.providerDisplayName(p)).tag(p.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Divider().overlay(Color.white.opacity(0.08))
            row("Main model", desc: "Heavy tasks: impact scoring, event clustering, portrait distillation.") {
                Picker("", selection: config.binding(\.memory.model)) {
                    ForEach(models, id: \.self) { m in Text(m).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Divider().overlay(Color.white.opacity(0.08))
            row("Light model", desc: "Lighter tasks: tag clustering, writing capture passes.") {
                Picker("", selection: config.binding(\.memory.modelLight)) {
                    ForEach(models, id: \.self) { m in Text(m).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func row<Trailing: View>(_ title: String,
                                     desc: String,
                                     @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    private static func providerDisplayName(_ p: Provider) -> String {
        switch p {
        case .chatgpt:     return "Codex (ChatGPT)"
        case .openaiBYOK:  return "OpenAI (API key)"
        case .anthropic:   return "Anthropic (API key)"
        case .ollama:      return "Ollama (local)"
        case .gemini:      return "Gemini (API key)"
        case .perplexity:  return "Perplexity (API key)"
        case .deepseek:    return "DeepSeek (API key)"
        case .claudeCode:  return "Claude Code CLI"
        }
    }
}

// MARK: - Step 6: Scheduler

/// 4 个自动调度器的频率配置(event / portrait / personality / writing capture)。
/// 每个只暴露 frequency 下拉 + 非 off 时的 timeOfDay TimePicker。weekly /
/// monthly 的 dayOfWeek / dayOfMonth 走默认值(周日 / 1 号),用户后续在
/// Settings 里调。
private struct SchedulerStep: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Automatic processing")
                    .font(.system(size: 24, weight: .semibold))
                Text("Each pipeline stage can run automatically on its own schedule, or stay manual-only. Times are local; weekly/monthly defaults to Sunday / the 1st (tune later in Settings → Memory → Scheduler).")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                schedulerCard(
                    title: "Event processing",
                    desc: "Clusters raw activity into events and scores their long-term importance.",
                    config: \.scheduler.event)
                schedulerCard(
                    title: "Portrait distillation",
                    desc: "Distills events into long-term portrait entries (one LLM call per category).",
                    config: \.scheduler.portrait)
                schedulerCard(
                    title: "Personality refresh",
                    desc: "Aggregates events + portraits + OCR into personality tags.",
                    config: \.scheduler.personality)
                schedulerCard(
                    title: "Writing capture",
                    desc: "Stages writing records from your typing for review. Approval is always manual.",
                    config: \.scheduler.writingCapture)
                schedulerCard(
                    title: "Speech style",
                    desc: "Distills how you talk and write (formality, language mix, recurring phrases) into the Speech Style portrait.",
                    config: \.scheduler.speechStyle)

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func schedulerCard(
        title: String,
        desc: String,
        config kp: WritableKeyPath<MyPortraitConfig, SchedulerConfig>
    ) -> some View {
        let freq = config.binding(kp.appending(path: \.frequency))
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Text("Frequency")
                    .font(.system(size: 12))
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: freq) {
                    Text("Off (manual only)").tag(SchedulerFrequency.off)
                    Text("Daily").tag(SchedulerFrequency.daily)
                    Text("Weekly").tag(SchedulerFrequency.weekly)
                    Text("Monthly").tag(SchedulerFrequency.monthly)
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer(minLength: 0)
            }

            if freq.wrappedValue != .off {
                HStack(spacing: 12) {
                    Text("Time")
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    timeOfDayPicker(binding: config.binding(kp.appending(path: \.timeOfDay)))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    /// "HH:mm" string ↔ DatePicker。同 SchedulerSettingsView 风格但更紧凑。
    @ViewBuilder
    private func timeOfDayPicker(binding: Binding<String>) -> some View {
        let date = Binding<Date>(
            get: {
                let parts = binding.wrappedValue.split(separator: ":")
                let h = Int(parts.first ?? "3") ?? 3
                let m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                var dc = DateComponents()
                dc.hour = h; dc.minute = m
                return Calendar.current.date(from: dc) ?? Date()
            },
            set: { newDate in
                let dc = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let h = dc.hour ?? 3, m = dc.minute ?? 0
                binding.wrappedValue = String(format: "%02d:%02d", h, m)
            }
        )
        DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
    }
}

// MARK: - Step 7: Speaker training

/// 直接复用 Settings → Speakers 里那张自洽的 VoiceTrainingCard —— 它已经
/// 自带:不依赖 audio toggle、临时强开 audio + speaker_id、训练完恢复、
/// mic 权限检查、30s 倒计时 sheet。Onboarding 只负责标题 / 描述这层 chrome。
private struct SpeakerTrainingStep: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Train your voice (optional)")
                    .font(.system(size: 24, weight: .semibold))
                Text("My Portrait separates speakers by voiceprint. Read a short passage now and future recordings can attribute lines to \"you\" instead of \"unknown cluster #3\". You can do this any time later from Settings → Speakers.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                VoiceTrainingCard(existingNames: [])

                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Step 8: Finish

private struct FinishStep: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 40)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.system(size: 32, weight: .semibold))
            Text("My Portrait is ready. It will start capturing in the background — open the chat anytime to talk to your portrait, or visit Settings → Memory to tune how it consolidates events.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                FinishHint(icon: "bubble.left.and.bubble.right", text: "Open the chat from the sidebar to ask anything.")
                FinishHint(icon: "person.text.rectangle", text: "Edit your portrait under Memories at any time.")
                FinishHint(icon: "lock.shield", text: "Everything you see can be deleted from Settings → Data & Privacy.")
            }
            .padding(.top, 8)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 40)
    }
}

private struct FinishHint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary.opacity(0.70))
                .frame(width: 18)
                .padding(.top, 1)
            Text(text).font(.system(size: 13))
        }
    }
}
