import AppKit
import Foundation
import QuartzCore

/// 轻量剪贴板监视器 —— 维护一份当前剪贴板纯文本的内存镜像，供 TypingObserver
/// 判定「某段插入文本是不是粘贴来的」。
///
/// 用剪贴板管理器（Maccy / Paste 等）的标准模式：轮询 `NSPasteboard.changeCount`
/// （白菜价的整数比较），**只在计数器变化（= 发生过复制）时才读一次内容**。
/// 不是每次访问剪贴板，不扰民。
///
/// 跟 ⌘V 时间关联判据互补：⌘V 抓 ⌘V 粘贴（含被 app 转格式、镜像匹配不上的）；
/// 剪贴板镜像抓所有粘贴方式（⌘V / 菜单 Paste / 右键 Paste）且知道确切内容。
@MainActor
final class PasteboardMonitor {

    /// 当前剪贴板纯文本镜像。nil = 剪贴板非文本 / 空。
    private(set) var currentText: String?

    private var lastChangeCount: Int
    private var timer: Timer?

    /// `changeCount` 轮询间隔。只是整数比较，可以勤快点 —— 内容读取仍只在
    /// 计数器变化时发生。
    private static let pollIntervalSec: TimeInterval = 0.25

    /// 剪贴板内容短于此长度不参与粘贴匹配 —— 避免「打的字恰好等于剪贴板」
    /// 那种巧合误判（如剪贴板是 "ok"、用户也打了 "ok"）。
    private static let minMatchLen = 6

    init() {
        let pb = NSPasteboard.general
        lastChangeCount = pb.changeCount
        currentText = pb.string(forType: .string)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSec,
                                     repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// `segment` 是否就是 / 包含当前剪贴板内容 —— 命中即判定为粘贴。
    /// 太短的剪贴板内容不参与（见 `minMatchLen`）。
    func looksLikePaste(_ segment: String) -> Bool {
        guard let clip = currentText, clip.count >= Self.minMatchLen else { return false }
        return segment == clip || segment.contains(clip)
    }

    // MARK: - 私有

    private func poll() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }   // 没复制过，不读内容
        lastChangeCount = cc
        currentText = pb.string(forType: .string)
    }
}
