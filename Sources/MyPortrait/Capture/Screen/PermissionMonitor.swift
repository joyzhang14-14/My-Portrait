import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os.log

/// 系统级权限实时监控。仿 `My-Orphies/crates/screenpipe-core/src/permissions.rs`
/// 的设计 —— 把"权限状态"做成可订阅的 4-state 值（NotNeeded / NotDetermined /
/// Granted / Denied），后端 Services 订阅它就能在 **用户在 System Settings 里授权
/// 之后自动恢复**，不需要手动 toggle 一次。
///
/// **检测方式**（全部本地，不走 XPC）：
///   - Screen recording: `CGPreflightScreenCaptureAccess()` —— 直接查 TCC
///   - Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)`
///   - Accessibility: `AXIsProcessTrusted()`
///
/// **轮询策略**：每 3 秒查一次。CGPreflight* / AXIsProcessTrusted 都是纯本地
/// dispatch_assert-free 调用，开销可忽略；3 秒延迟用户感知不到。
///
/// **持久化**：权限本身由 macOS TCC 持久化（一次授权后跨重启都记着）。我们
/// 这里 *不存* 任何状态 —— 重启 app 直接查 TCC 拿到当前 ground truth。
@MainActor
final class PermissionMonitor: ObservableObject {

    enum Status: Sendable, Equatable {
        case notDetermined
        case granted
        case denied
        var isGranted: Bool { self == .granted }
    }

    @Published private(set) var screenRecording: Status = .notDetermined
    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var accessibility: Status = .notDetermined
    /// Full Disk Access。**没有 request API** —— 只能让用户去 System Settings
    /// 手动加。检测靠 probe 读 TCC 数据库本身(macOS 每台必有,只在 FDA 授权
    /// 后才可读)。3 秒轮询会自动捕获用户授权后的状态翻转。
    @Published private(set) var fullDiskAccess: Status = .notDetermined

    private let logger = Logger(subsystem: "com.myportrait.capture", category: "permissions")
    private let pollInterval: TimeInterval = 3.0
    private var pollTask: Task<Void, Never>?

    init() {
        // 立即同步刷一次，避免 UI 启动时短暂闪 .notDetermined
        refresh()
    }

    /// 启动后台轮询。Services 在 startManagedLifecycle 里调一次。
    func start() {
        guard pollTask == nil else { return }
        let ns = UInt64(pollInterval * 1_000_000_000)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: ns)
            }
        }
        logger.info("PermissionMonitor started (poll=\(self.pollInterval)s)")

        // **不再启动即请求屏幕录制权限**。原本这里无条件 requestScreenRecording
        // 是想"让 app 出现在系统设置的屏幕录制列表里"。但 hardened runtime
        // 开了以后,Apple Development 证书 Debug 构建每次 rebuild cdhash 都变,
        // TCC 看每次启动都是"新 app",反复弹"录屏权限"对话框,体验极差。
        //
        // 现在的请求路径:
        //   1. Onboarding Permissions 步,用户主动点 Allow → requestScreenRecording
        //   2. ScreenCaptureService 实际起 capture 时,preflight 失败 → fallback
        //      request(用户已经手动开了 capture toggle,弹窗是预期的)
        // 后台 3s 轮询 refresh() 仍在,用户在 System Settings 授权后自动捕获。
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 强制立即查一次（toggle 触发时主动用）。
    func refresh() {
        let newScreen = Self.checkScreenRecording()
        if newScreen != screenRecording {
            logger.info("screen recording: \(String(describing: self.screenRecording), privacy: .public) → \(String(describing: newScreen), privacy: .public)")
            screenRecording = newScreen
        }
        let newMic = Self.checkMicrophone()
        if newMic != microphone {
            logger.info("microphone: \(String(describing: self.microphone), privacy: .public) → \(String(describing: newMic), privacy: .public)")
            microphone = newMic
        }
        let newAX = Self.checkAccessibility()
        if newAX != accessibility {
            logger.info("accessibility: \(String(describing: self.accessibility), privacy: .public) → \(String(describing: newAX), privacy: .public)")
            accessibility = newAX
        }
        let newFDA = Self.checkFullDiskAccess()
        if newFDA != fullDiskAccess {
            logger.info("full disk access: \(String(describing: self.fullDiskAccess), privacy: .public) → \(String(describing: newFDA), privacy: .public)")
            fullDiskAccess = newFDA
        }
    }

    // MARK: - 触发系统对话框

    /// 请求 screen recording 权限。如果当前 binary 不在 TCC，弹标准系统对话框；
    /// 如果是 Denied 状态（用户之前主动拒过），CGRequestScreenCaptureAccess()
    /// 触发屏幕录制权限请求。
    ///
    /// **关键**：`CGRequestScreenCaptureAccess()` 是 CGWindowList 时代的老 API，
    /// macOS 14+/26 上对 ScreenCaptureKit app 不一定弹窗也不一定注册。真正能
    /// 触发系统提示 + 把 app 加进"屏幕录制"列表的，是**实际发起一次
    /// `SCShareableContent` 查询**。所以这里两个都做：先调老 API（无害），
    /// 再真正 probe 一次 SCK —— 没权限会抛错（预期内），但这次调用本身已经
    /// 让 macOS 把 app 注册进 TCC + 弹出系统对话框。
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Task { @MainActor [weak self] in
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
            } catch {
                // 没权限 → 抛错，预期内。注册副作用已经发生。
                self?.logger.info("SCShareableContent probe threw (expected if not yet granted): \(String(describing: error), privacy: .public)")
            }
            self?.refresh()
        }
    }

    /// 请求 microphone。NotDetermined 状态会弹标准对话框；Denied 状态系统对话框
    /// 不弹，给 caller 一个 `false` 完事 —— 这时打开 Settings。
    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 请求 accessibility 权限。AXIsProcessTrustedWithOptions + prompt 选项
    /// 会弹系统标准对话框（如果还没拒绝过）。
    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue!] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// 直接跳到 System Settings 对应面板。用户拒过权限的话弹窗弹不了,靠这个。
    /// macOS 13+(Ventura,System Settings 重做)走新 URL scheme
    /// `com.apple.settings.PrivacySecurity.extension`;老系统兼容旧 scheme。
    /// 新 URL 在新系统打不开时退化到旧的(NSWorkspace.open 返回 false → 兜底)。
    func openSettings(for perm: Kind) {
        let anchor: String
        switch perm {
        case .screen:        anchor = "Privacy_ScreenCapture"
        case .microphone:    anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .fullDisk:      anchor = "Privacy_AllFiles"
        }
        let modernURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
        let legacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        if !NSWorkspace.shared.open(modernURL) {
            NSWorkspace.shared.open(legacyURL)
        }
    }

    enum Kind: Sendable {
        case screen, microphone, accessibility, fullDisk
    }

    // MARK: - 检测实现（macOS）

    private static func checkScreenRecording() -> Status {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private static func checkMicrophone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func checkAccessibility() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Full Disk Access 没有公开 API,只能 probe。**真去 open() 才能触发
    /// TCC 校验** —— `isReadableFile`/`access(R_OK)` 只查 Unix BSD 权限,
    /// TCC.db Unix 层就不世界可读,这条会假阴(每次启动误判 denied)。
    ///
    /// 用 open() + EACCES/EPERM 区分:
    ///   - 成功(fd >= 0)→ 有 FDA
    ///   - errno == EACCES(13)/EPERM(1)→ TCC 拒了 → 没 FDA
    ///   - errno == ENOENT(2)→ 文件不存在(理论上不会,TCC.db 每台 Mac 都有)
    ///     退化当 denied 处理,反正用户没法用功能
    private static func checkFullDiskAccess() -> Status {
        let path = NSString(string: "~/Library/Application Support/com.apple.TCC/TCC.db")
            .expandingTildeInPath
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        return .denied   // EACCES / EPERM / ENOENT 都按 denied 处理
    }
}
