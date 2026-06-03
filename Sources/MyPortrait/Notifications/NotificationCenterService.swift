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
        case cronJobRun(jobId: UUID, jobName: String, body: String, convId: UUID)
        case appUpdate(version: String)
        case captureStall(reason: String)
        /// scheduler 自动跑完一条 memory pipeline(event / portrait /
        /// personality / writing / speech)时发。`success=false` 走失败样式。
        /// `summary` 一行人话:"processed 3 days" / "12 records"。
        case schedulerRun(pipeline: String, success: Bool, summary: String)
        /// pipeline 失败但**需要用户介入**(quota exhausted / auth revoked /
        /// model deprecated / DB corrupt / agent spawn failed)。红色 banner +
        /// 自动跳转 Settings → Scheduler。`kindLabel` 是 LLMFailureKind.shortLabel。
        case pipelineNeedsFix(pipeline: String, kindLabel: String, userMessage: String)
        /// pipeline 失败但 scheduler 会**自动重试**(transient network / rate
        /// limit / truncated / DB busy / schema)。灰色,告知"retrying in Xh"。
        case pipelineAutoRecovering(pipeline: String, kindLabel: String, nextRetryLabel: String)
        /// 自动更新倒计时 banner —— 用户开了 autoDownloadUpdates,Sparkle
        /// 已经后台下完新版,banner 倒数 \`seconds\` 秒后调 onTimeout
        /// (触发 install + relaunch);用户在期间点 banner 调 onPostpone
        /// (取消这次,让 Sparkle 下次检查重试)。
        case updateCountdown(
            version: String,
            seconds: TimeInterval,
            onPostpone: @MainActor () -> Void,
            onTimeout: @MainActor () -> Void
        )
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
        var onTimeout: (() -> Void)? = nil
        var timeout = defaultTimeout
        var cronJobId: UUID? = nil

        switch kind {
        case let .cronJobRun(jobId, jobName, body_, convId):
            guard n.cronJobAlerts else {
                log.notice("post skipped: cronJobAlerts is OFF"); return
            }
            // Mute 拦截:按 cron job id 查 CronJobStore.cronJobs.muted。
            // 改名不丢状态,跟旧 byName 名单完全脱钩。
            let muted = CronJobStore.shared.cronJobs.first { $0.id == jobId }?.muted ?? false
            guard !muted else {
                log.notice("post skipped: '\(jobName, privacy: .public)' muted by user"); return
            }
            title = "🛰️ \(jobName)"
            body = body_
            cronJobId = jobId
            onTap = { [weak self] in self?.onCronJobTap(convId) }

        case let .appUpdate(version):
            guard n.appUpdates else { return }
            title = "My Portrait \(version) available"
            body = "Open the app to install."

        case let .captureStall(reason):
            guard n.captureStalls else { return }
            title = "Capture stalled"
            body = reason

        case let .updateCountdown(version, seconds, onPostpone, onTimeoutCb):
            title = "Updating to \(version)"
            body = "App will restart automatically. Click to postpone."
            timeout = seconds
            onTap = { onPostpone() }
            onTimeout = { onTimeoutCb() }

        case let .schedulerRun(pipeline, success, summary):
            guard n.schedulerAlerts else {
                log.notice("post skipped: schedulerAlerts is OFF"); return
            }
            // ⚙️ 跑完 / ⚠️ 失败 —— 跟 cron job 的 🛰️ 区分,一眼看出是 scheduler。
            title = success ? "⚙️ \(pipeline)" : "⚠️ \(pipeline) failed"
            body = summary

        case let .pipelineNeedsFix(pipeline, kindLabel, userMessage):
            guard n.schedulerAlerts else {
                log.notice("post skipped: schedulerAlerts is OFF"); return
            }
            // 🛑 = action required from user;桶 B。
            title = "🛑 \(pipeline) needs attention"
            body = "\(userMessage) [\(kindLabel)]"

        case let .pipelineAutoRecovering(pipeline, kindLabel, nextRetryLabel):
            guard n.schedulerAlerts else {
                log.notice("post skipped: schedulerAlerts is OFF"); return
            }
            // 🔁 = auto-recovering;桶 A。低优先,信息性。
            title = "🔁 \(pipeline) retrying \(nextRetryLabel)"
            body = "Auto-recovering from \(kindLabel) — no action needed."
        }

        let notif = InAppNotification(
            id: UUID(),
            title: title,
            body: body,
            createdAt: Date(),
            timeout: timeout,
            cronJobId: cronJobId,
            onTap: onTap,
            onTimeout: onTimeout
        )
        active.append(notif)
        log.notice("posted: \(title, privacy: .public)")

        // 有通知 → 浮窗 show(lazy install + orderFront)。
        NotificationOverlay.shared.show()

        // 不再用独立计时器自动消失 —— 改由 NotificationCardView 的(可暂停)
        // 进度条 tick 驱动:倒计时跑满时卡片回调 timeoutReached(id)。这样
        // hover 暂停进度条时,自动消失也跟着暂停(单一时钟,两个计时器不会打架)。
    }

    func dismiss(_ id: UUID) {
        active.removeAll { $0.id == id }
        // 没通知了 → 浮窗 hide(orderOut),释放屏幕空间 + hit-test 让位。
        if active.isEmpty {
            NotificationOverlay.shared.hide()
        }
    }

    /// 卡片的(可暂停)进度条倒计时跑满时调 —— 由 NotificationCardView 驱动。
    /// hover 暂停 tick 时不会触发,所以暂停期间通知不会消失。
    /// 还在 active 里 = 用户没点掉 → 触发 onTimeout(updateCountdown 倒计时到点要
    /// install)。先 fire 再 dismiss,因为 onTimeout 可能调 NSApp.terminate,
    /// Sparkle 会接管,dismiss 那行不一定跑到。
    func timeoutReached(_ id: UUID) {
        if let notif = active.first(where: { $0.id == id }) {
            notif.onTimeout?()
        }
        dismiss(id)
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
    /// 非 nil = 这条通知是 cron job 跑出来的,jobId 是源任务 id。
    /// NotificationCardView 用它决定是否在 banner 上画 "Mute" 按钮。
    let cronJobId: UUID?
    let onTap: (() -> Void)?
    /// 倒计时跑完(用户没 dismiss 也没 tap)时调。给 updateCountdown 用 ——
    /// 触发 NSApp.terminate → Sparkle install-on-quit 链路。
    let onTimeout: (() -> Void)?
}
