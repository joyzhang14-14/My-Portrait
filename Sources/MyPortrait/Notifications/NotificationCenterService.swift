import Foundation
import AppKit
import Observation
import os.log

/// 自建造鱼通知中心(替代 UNUserNotificationCenter)。
///
/// 为什么自建:macOS 原生通知 body 最多 3 行截断、不渲染 markdown、不能放链接,
/// 跟 screenpipe 那套自渲染浮窗体验差太远。这里走纯 Swift/AppKit/SwiftUI:
/// 一个 NSPanel 浮在屏幕右上,SwiftUI 卡片渲染 markdown,点击触发回调。
///
/// API(`post(Kind)`)保持跟旧 UN 版本兼容,callers 不用改。
@MainActor
@Observable
final class NotificationCenterService {
    static let shared = NotificationCenterService()

    enum Kind: Sendable {
        case cronJobRun(jobName: String, body: String, convId: UUID)
        case appUpdate(version: String)
        case captureStall(reason: String)
    }

    /// 当前可见的通知列表(最旧在前,最新在后)。Overlay view observe 这个。
    private(set) var active: [InAppNotification] = []

    /// 点击 cron job 通知时的回调。app 启动时由 ContentView 接进来:
    /// 通常是 "切到 .home + chat.switchTo(convId) + 主窗口拉到前台"。
    var onCronJobTap: (UUID) -> Void = { _ in }

    private let log = Logger(subsystem: "com.myportrait", category: "notifications")
    private let defaultTimeout: TimeInterval = 20

    private init() {}

    func post(_ kind: Kind) {
        let n = ConfigStore.shared.notifications
        let title: String
        let body: String
        var onTap: (() -> Void)?

        switch kind {
        case let .cronJobRun(jobName, body_, convId):
            guard n.cronJobAlerts else {
                log.notice("post skipped: cronJobAlerts is OFF"); return
            }
            guard !n.mutedCronJobs.contains(jobName) else {
                log.notice("post skipped: '\(jobName, privacy: .public)' is muted"); return
            }
            title = "🛰️ \(jobName)"
            body = body_
            onTap = { [weak self] in self?.onCronJobTap(convId) }

        case let .appUpdate(version):
            guard n.appUpdates else { return }
            title = "My Portrait \(version) available"
            body = "Open the app to install."

        case let .captureStall(reason):
            guard n.captureStalls else { return }
            title = "Capture stalled"
            body = reason
        }

        let notif = InAppNotification(
            id: UUID(),
            title: title,
            body: body,
            createdAt: Date(),
            timeout: defaultTimeout,
            onTap: onTap
        )
        active.append(notif)
        log.notice("posted: \(title, privacy: .public)")

        // 有通知 → 浮窗 show(lazy install + orderFront)。
        NotificationOverlay.shared.show()

        scheduleDismiss(notif.id, after: defaultTimeout)
    }

    func dismiss(_ id: UUID) {
        active.removeAll { $0.id == id }
        // 没通知了 → 浮窗 hide(orderOut),释放屏幕空间 + hit-test 让位。
        if active.isEmpty {
            NotificationOverlay.shared.hide()
        }
    }

    private func scheduleDismiss(_ id: UUID, after: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            self?.dismiss(id)
        }
    }
}

/// 一条活动中的通知。`onTap` 是闭包(非 Codable),所以不持久化 —— app 重启
/// 后丢失所有未读通知,跟原生通知中心的"已读历史"语义不同。够用。
struct InAppNotification: Identifiable {
    let id: UUID
    let title: String
    let body: String
    let createdAt: Date
    let timeout: TimeInterval
    let onTap: (() -> Void)?
}
