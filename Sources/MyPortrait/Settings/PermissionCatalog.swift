import SwiftUI

/// 一项系统权限的状态。TCC 是三态;非 TCC 的后台 helper 只有开/关,映到
/// granted / denied。
enum PermissionState {
    case granted, denied, unknown

    var isGranted: Bool { self == .granted }
}

/// App 用到的一项系统权限。
struct PermissionItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// 给用户看的"要它来干嘛"。
    let why: String
    let state: PermissionState
    /// nil = 系统没提供请求 API(Full Disk Access 就是),只能跳系统设置手动加。
    let request: (() -> Void)?
    let openSettings: () -> Void
}

/// App 要用到的**全部**系统权限,一处定义。
///
/// Onboarding 的 Permissions 步和设置页 General ▸ Permissions 共用这份清单。
/// 两边各写一份必然走偏 —— 以后加一项权限只改了 onboarding,设置页那张
/// "你给了哪些权限"的表就少一条,而那张表的全部意义就是让用户**看全**。
@MainActor
enum PermissionCatalog {

    /// `helperApproved`:合盖 helper 是 SMAppService 后台项,**不是 TCC**,
    /// PermissionMonitor 的轮询管不到,由调用方自己查了传进来。
    static func items(monitor: PermissionMonitor, helperApproved: Bool) -> [PermissionItem] {
        [
            PermissionItem(
                id: "screen",
                icon: "rectangle.inset.filled.on.rectangle",
                title: "Screen Recording",
                why: "Required to capture what's on your screen for OCR and context.",
                state: state(monitor.screenRecording),
                request: { monitor.requestScreenRecording() },
                openSettings: { monitor.openSettings(for: .screen) }
            ),
            PermissionItem(
                id: "accessibility",
                icon: "accessibility",
                title: "Accessibility",
                why: "Required to read window titles, focus state, and global keyboard events.",
                state: state(monitor.accessibility),
                request: { monitor.requestAccessibility() },
                openSettings: { monitor.openSettings(for: .accessibility) }
            ),
            PermissionItem(
                id: "microphone",
                icon: "mic",
                title: "Microphone",
                why: "Required if you want voice transcription as part of memory.",
                state: state(monitor.microphone),
                request: { monitor.requestMicrophone() },
                openSettings: { monitor.openSettings(for: .microphone) }
            ),
            PermissionItem(
                id: "full-disk",
                icon: "externaldrive",
                title: "Full Disk Access",
                why: "Import data from Claude Code CLI, Codex CLI and Screenpipe.",
                state: state(monitor.fullDiskAccess),
                request: nil,
                openSettings: { monitor.openSettings(for: .fullDisk) }
            ),
            // 合盖时保持运行 —— 特权 root daemon,靠 pmset disablesleep 挡
            // clamshell 睡眠。Allow → register() 并跳系统设置让用户批准一次。
            PermissionItem(
                id: "sleep-helper",
                icon: "bolt.fill",
                title: "Background activity helper",
                why: "Lets pipelines keep running while your Mac sits idle or the lid is shut. Register once in System Settings ▸ Login Items & Extensions.",
                state: helperApproved ? .granted : .denied,
                request: { SleepHelperClient.shared.enable() },
                openSettings: { SleepHelperClient.shared.openSystemSettings() }
            ),
        ]
    }

    static func state(_ s: PermissionMonitor.Status) -> PermissionState {
        switch s {
        case .granted:       return .granted
        case .denied:        return .denied
        case .notDetermined: return .unknown
        }
    }
}

/// Granted / Not granted 小药丸。Onboarding 和设置页共用一个,免得两边
/// 同一件事写出两种词、两种颜色。
struct PermissionStatusPill: View {
    let state: PermissionState

    var body: some View {
        let (label, color): (String, Color) = {
            switch state {
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
}
