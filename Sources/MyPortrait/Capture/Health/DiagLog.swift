import Foundation
import os.log

/// 结构化诊断日志 —— 长期保留版,补 unified-log 的两个洞:
///   1. macOS unified log 在磁盘紧张时几小时就被回收
///   2. 现有 os.log 调用大多是字符串拼接,grep 起来不结构化
///
/// 写到 `~/.portrait/logs/diagnostic.log`,JSONL 格式(一行一个 obj):
///   {"ts":"2026-05-31T...","level":"error","name":"transcribe.timeout",
///    "ctx":{"chunkId":1234,"path":".../a.wav","durationS":28.5}}
///
/// **rotating**:文件 > 5MB → rename 成 `.1`,`.1` 已存在则继续 `.2`…保留 5 代。
/// 总占地上限 ~25MB。
///
/// API 故意简单:`DiagLog.event("foo.bar", ctx: [...])` 或
/// `DiagLog.error("foo.bar", ctx: [...])`。**不替代 os.log** —— 同时也 mirror
/// 到 os.log(同 subsystem com.myportrait.diag),开发期看着方便。
///
/// 调用方应该:
///   - 在 catch 块里调 `.error("subsystem.op.failed", ctx: [关键 id, ...])`
///   - 在关键流水线 boundary 调 `.event("scheduler.tick.start", ctx: [...])`
enum DiagLog {

    /// 最大单文件大小,触发 rotation。
    private static let maxBytes: Int = 5 * 1024 * 1024
    /// 保留多少代历史(.1 ... .keep)。
    private static let keep: Int = 5

    private static let queue = DispatchQueue(label: "com.myportrait.diaglog")
    private static let osLogger = Logger(subsystem: "com.myportrait.diag", category: "event")
    nonisolated(unsafe) private static var didEnsureDir = false

    static var logFileURL: URL {
        Storage.dailyLogsDir.appendingPathComponent("diagnostic.log")
    }

    /// 普通事件 —— 流水线 checkpoint / 状态变化 / 关键决策。
    static func event(_ name: String, ctx: [String: Any] = [:]) {
        write(level: "info", name: name, ctx: ctx)
        osLogger.info("\(name, privacy: .public) \(jsonString(ctx), privacy: .public)")
    }

    /// 警告事件 —— 不一定 fatal,但值得留底。
    static func warn(_ name: String, ctx: [String: Any] = [:]) {
        write(level: "warn", name: name, ctx: ctx)
        osLogger.warning("\(name, privacy: .public) \(jsonString(ctx), privacy: .public)")
    }

    /// 错误事件 —— catch 块里调,把 input / id 等关键 context 塞进 ctx。
    /// 用法:
    ///   } catch {
    ///       DiagLog.error("transcribe.failed", ctx: [
    ///         "chunkId": chunk.id ?? 0,
    ///         "path": chunk.filePath,
    ///         "err": String(describing: error)
    ///       ])
    ///   }
    static func error(_ name: String, ctx: [String: Any] = [:]) {
        write(level: "error", name: name, ctx: ctx)
        osLogger.error("\(name, privacy: .public) \(jsonString(ctx), privacy: .public)")
    }

    // MARK: - 内部

    private static func write(level: String, name: String, ctx: [String: Any]) {
        let line: [String: Any] = [
            "ts":    Self.isoFmt.string(from: Date()),
            "level": level,
            "name":  name,
            "ctx":   sanitize(ctx),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: []),
              let s = String(data: data, encoding: .utf8) else { return }
        let payload = Data((s + "\n").utf8)
        queue.async {
            ensureDir()
            rotateIfNeeded()
            appendData(payload)
        }
    }

    /// JSONSerialization 不接受 nil/NaN/特殊类型;给 ctx 做一遍清洗,
    /// 任何 unsupported 一律 String(describing:) 兜底。
    private static func sanitize(_ ctx: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in ctx {
            if JSONSerialization.isValidJSONObject([v]) {
                out[k] = v
            } else if let v = v as? CustomStringConvertible {
                out[k] = String(describing: v)
            } else {
                out[k] = "<unrepresentable>"
            }
        }
        return out
    }

    private static func jsonString(_ ctx: [String: Any]) -> String {
        let s = sanitize(ctx)
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: []),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private static func ensureDir() {
        guard !didEnsureDir else { return }
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        didEnsureDir = true
    }

    /// 当前文件 ≥ maxBytes → 移成 `.1`,原 `.1` → `.2`,以此类推。
    /// 超过 `keep` 的丢弃。
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let url = logFileURL
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }

        // 删除最老的(`.keep`),依次往后 rename。
        let oldest = url.appendingPathExtension("\(keep)")
        try? fm.removeItem(at: oldest)
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let from = url.appendingPathExtension("\(i)")
            let to   = url.appendingPathExtension("\(i + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        // 当前 → .1
        if fm.fileExists(atPath: url.path) {
            try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
    }

    /// append 一段 bytes 到文件末尾。文件不存在则创建。
    private static func appendData(_ data: Data) {
        let url = logFileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    nonisolated(unsafe) private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
