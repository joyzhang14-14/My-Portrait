import AppKit
import Foundation
import GRDB
import os.log

/// 剪贴板换内容 → input.sqlite 的 `clipboard_log` 一行。
///
/// 由 `PasteboardMonitor` 在 changeCount 变化时调用(它本来就只在那时读内容),
/// 所以跟着 Typing Capture 开关走。只记摘要,不存原件:
/// - 文本超过 30 字截前 30 字加 `...`
/// - 文件 `[file: a.pdf, b.png]`(整体同样按 30 字截)
/// - 图片 `[image]`,剪贴板被清空 `[empty]`,其它类型 `[other]`
/// - 密码管理器打了 ConcealedType 标记的、或在 Typing 黑名单 app 里复制的 → `[concealed]`
///
/// `ts_ms` = UTC epoch 毫秒,跟 keystroke_log / mouse_log 同口径;`bundle_id` 是
/// 复制那一刻的前台 app。
@MainActor
final class ClipboardLogger {

    nonisolated static let maxChars = 30
    private nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let dbPool: DatabasePool
    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "typing.clipboard")

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// 剪贴板刚换过内容时在主线程调,记下时刻和前台 app;读内容取摘要和写库
    /// 都在 `queue` 上做(读内容可能要等复制方 app 交数据)。
    func record(on queue: DispatchQueue) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let hidden = !bundleId.isEmpty && TypingPrivacyFilter.isBlacklisted(bundleId: bundleId)
        let db = dbPool
        queue.async { [log] in
            let content = ClipboardLogger.summary(.general, concealed: hidden)
            do {
                try db.write {
                    try $0.execute(
                        sql: "INSERT INTO clipboard_log (ts_ms, bundle_id, content) VALUES (:ts, :bid, :content)",
                        arguments: ["ts": ts, "bid": bundleId, "content": content])
                }
            } catch {
                log.warning("clipboard_log insert failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated static func summary(_ pb: NSPasteboard, concealed: Bool) -> String {
        let types = pb.types ?? []
        if concealed || types.contains(concealedType) { return "[concealed]" }
        if types.isEmpty { return "[empty]" }
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return truncate("[file: " + urls.map(\.lastPathComponent).joined(separator: ", ") + "]")
        }
        if let s = pb.string(forType: .string) { return truncate(s) }
        if NSImage.canInit(with: pb) { return "[image]" }
        return "[other]"
    }

    nonisolated static func truncate(_ s: String) -> String {
        s.count > maxChars ? String(s.prefix(maxChars)) + "..." : s
    }
}
