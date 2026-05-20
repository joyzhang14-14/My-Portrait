import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
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
    }

    // MARK: - 触发系统对话框

    /// 请求 screen recording 权限。如果当前 binary 不在 TCC，弹标准系统对话框；
    /// 如果是 Denied 状态（用户之前主动拒过），CGRequestScreenCaptureAccess()
    /// 不会再弹，只能跳到 System Settings。
    /// 调用后立刻 refresh 一次拿到最新状态（用户可能秒授权）。
    /// 返回 `CGRequestScreenCaptureAccess()` 的结果（true = 已授权）。
    ///
    /// **必须调它而不是只 openSettings**：首次调用会弹系统标准对话框 **并把
    /// app 注册进 TCC 的"屏幕录制"列表**。从没调过的话，app 可能根本不在那个
    /// 列表里 / 状态不对，用户在系统设置里怎么勾都没用。
    @discardableResult
    func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
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

    /// 直接跳到 System Settings 对应面板。用户拒过权限的话弹窗弹不了，靠这个。
    func openSettings(for perm: Kind) {
        let url: URL
        switch perm {
        case .screen:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .microphone:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
        NSWorkspace.shared.open(url)
    }

    enum Kind: Sendable {
        case screen, microphone, accessibility
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
}
