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

    /// 生产模式注入:每次换内容记一行 clipboard_log。dev 模式 nil。
    var logger: ClipboardLogger?

    private var lastChangeCount: Int
    private var timer: Timer?

    /// `changeCount` 轮询间隔。只是整数比较，可以勤快点 —— 内容读取仍只在
    /// 计数器变化时发生。
    private static let pollIntervalSec: TimeInterval = 0.25

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
    /// 太短的剪贴板内容不参与（见 `typing_paste_min_chars`）。
    func looksLikePaste(_ segment: String) -> Bool {
        let minLen = ConfigStore.shared.capture.typingPasteMinChars
        guard let clip = currentText, clip.count >= minLen else { return false }
        return segment == clip || segment.contains(clip)
    }

    // MARK: - 私有

    /// 读内容走这条串行队列:复制方 app 只登记了类型、等有人读才交数据时,
    /// 读取要等它响应,它忙就能卡几秒,不能放在主线程。
    private let readQueue = DispatchQueue(label: "com.myportrait.pasteboard.read")

    private func poll() {
        let cc = NSPasteboard.general.changeCount
        guard cc != lastChangeCount else { return }   // 没复制过，不读内容
        lastChangeCount = cc
        logger?.record(on: readQueue)
        readQueue.async { [weak self] in
            let text = NSPasteboard.general.string(forType: .string)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.currentText = text }
            }
        }
    }
}
