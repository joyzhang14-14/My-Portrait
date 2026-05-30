import Foundation
import os.log

private let cliImportLog = Logger(subsystem: "com.myportrait.memory", category: "cli-import")

/// 从 Claude Code / Codex CLI 的本地会话文件里导入**用户手打的 prompt**。
///
/// 这批数据是地面真值(用户精确打的字),不走 OCR / keystroke 补全管线 ——
/// 纯结构化解析就能把"哪些行是用户输入"摘出来:排除 tool_result、系统注入、
/// slash 命令、subagent。摘出来后内容原样入库,不做内容审查。
///
/// 两个源:
///   - Claude Code:`~/.claude/projects/<encoded-cwd>/<session>.jsonl`,逐行
///     JSON;真实输入 = `type==user` 且 `message.content` 是字符串。
///   - Codex CLI:`~/.codex/history.jsonl`,逐行 `{session_id, ts, text}`,
///     纯手打历史(类似 shell history),零注入噪音。
enum CLIInputImporter {

    /// 解析出的一条用户输入。
    struct Imported: Sendable {
        let text: String
        let app: String        // "claude-code" | "codex-cli"
        let url: String?       // cli_import 一律 nil —— 避免前端按目录炸窗
        let tsMs: Int64
        let session: String?   // sessionId(CC) / session_id(Codex),用于数 session
        let location: String?  // 会话/项目目录(cwd),只作元数据,不参与分组
    }

    /// 扫盘结果 —— 各源的 session 数 + prompt 数(未去重前)。
    struct ScanResult: Sendable {
        let claudeCode: Int          // prompt 数
        let codex: Int
        let claudeCodeSessions: Int  // 涉及的 session 数
        let codexSessions: Int
        var total: Int { claudeCode + codex }
    }

    // MARK: - 路径

    private static var claudeProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }
    private static var codexHistoryFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/history.jsonl", isDirectory: false)
    }

    // MARK: - 对外:收集全部

    /// 单独解析 Claude Code 的用户输入。`since`:增量游标(ms),只取发送时刻
    /// 晚于它的;nil → 全量。去重在 store 落库时还会再兜一道。
    static func collectClaudeCode(since: Int64? = nil) -> [Imported] {
        filterSince(parseClaudeCode(), since)
    }

    /// 单独解析 Codex 的用户输入。`since` 同上。
    static func collectCodex(since: Int64? = nil) -> [Imported] {
        filterSince(parseCodex(), since)
    }

    private static func filterSince(_ rows: [Imported], _ since: Int64?) -> [Imported] {
        guard let since else { return rows }
        return rows.filter { $0.tsMs > since }
    }

    /// 只数数 —— 给 UI scan 用,只计 `since` 之后的增量(prompt 数 + session 数)。
    static func scan(sinceClaudeCode: Int64?, sinceCodex: Int64?) -> ScanResult {
        let cc = filterSince(parseClaudeCode(), sinceClaudeCode)
        let codex = filterSince(parseCodex(), sinceCodex)
        return ScanResult(
            claudeCode: cc.count,
            codex: codex.count,
            claudeCodeSessions: Set(cc.compactMap { $0.session }).count,
            codexSessions: Set(codex.compactMap { $0.session }).count
        )
    }

    // MARK: - kind 分类(纯长度,无 LLM)

    /// 长文 / 短句 —— writing_records.kind 取值跟 OCR 管线一致。
    static func classifyKind(_ text: String) -> String {
        text.count >= 140 ? "long_form" : "short_form"
    }

    // MARK: - Claude Code 解析

    private struct CCLine: Decodable {
        let type: String?
        let isMeta: Bool?
        let isSidechain: Bool?
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let message: CCMessage?
    }
    private struct CCMessage: Decodable {
        let role: String?
        let content: CCContent?
    }
    /// `content` 可能是字符串(用户输入)或数组(tool_result)。
    /// 只在字符串时取出文本;数组 / 对象 → nil,自然排除。
    private struct CCContent: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            text = (try? c.decode(String.self))
        }
    }

    /// 以这些标记开头的 content 是系统注入 / slash 命令 / bash `!` 输出 /
    /// `/compact` 后自动注入的 AI 会话摘要 —— 都不是用户手打,排除。
    private static let ccNoisePrefixes = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-caveat>", "<local-command-stdout>",
        "<system-reminder>",
        "This session is being continued from a previous conversation that ran out of context",
    ]

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func parseClaudeCode() -> [Imported] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: nil)
        else { return [] }

        let iso = makeISOFormatter()
        var out: [Imported] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let content = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let row = decodeCC(String(line), iso: iso) else { continue }
                    out.append(row)
                }
            }
        }
        cliImportLog.info("Claude Code: parsed \(out.count) user messages")
        return out
    }

    private static func decodeCC(_ line: String, iso: ISO8601DateFormatter) -> Imported? {
        guard let data = line.data(using: .utf8),
              let l = try? JSONDecoder().decode(CCLine.self, from: data)
        else { return nil }
        guard l.type == "user",
              l.message?.role == "user",
              l.isMeta != true,
              l.isSidechain != true,
              let text = l.message?.content?.text
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if ccNoisePrefixes.contains(where: { trimmed.hasPrefix($0) }) { return nil }
        let tsMs = l.timestamp.flatMap { iso.date(from: $0) }
            .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        guard tsMs > 0 else { return nil }
        // url 留 nil(不炸窗),cwd 进 location。
        return Imported(text: trimmed, app: "claude-code", url: nil, tsMs: tsMs,
                        session: l.sessionId, location: l.cwd)
    }

    // MARK: - Codex 解析

    private struct CodexHistLine: Decodable {
        let ts: Int64?
        let text: String?
        let session_id: String?
    }

    /// rollout 文件首行 session_meta —— 取 session_id → cwd。
    private struct CodexRolloutMeta: Decodable {
        struct Payload: Decodable { let id: String?; let cwd: String? }
        let payload: Payload?
    }

    /// 扫 ~/.codex/sessions 与 archived_sessions 下所有 rollout-*.jsonl,
    /// 读首行 session_meta,建 session_id → cwd 映射(history.jsonl 没存 cwd)。
    private static func codexSessionCwd() -> [String: String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent(".codex/sessions", isDirectory: true),
                     home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)]
        var map: [String: String] = [:]
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en
            where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let first = firstLine(of: url),
                      let data = first.data(using: .utf8),
                      let meta = try? JSONDecoder().decode(CodexRolloutMeta.self, from: data),
                      let id = meta.payload?.id, let cwd = meta.payload?.cwd
                else { continue }
                map[id] = cwd
            }
        }
        return map
    }

    /// 只读文件首行(rollout session_meta 很小),避免整文件载入。
    private static func firstLine(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < 65536 {
            guard let chunk = try? h.read(upToCount: 4096), !chunk.isEmpty else { break }
            buf.append(chunk)
            if let nl = buf.firstIndex(of: 0x0A) {
                return String(data: buf[..<nl], encoding: .utf8)
            }
        }
        return String(data: buf, encoding: .utf8)
    }

    private static func parseCodex() -> [Imported] {
        guard let content = try? String(contentsOf: codexHistoryFile, encoding: .utf8)
        else { return [] }
        let cwdMap = codexSessionCwd()
        var out: [Imported] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let l = try? JSONDecoder().decode(CodexHistLine.self, from: data),
                  let secs = l.ts, secs > 0,
                  let text = l.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            let loc = l.session_id.flatMap { cwdMap[$0] }
            out.append(Imported(text: text, app: "codex-cli", url: nil, tsMs: secs * 1000,
                                session: l.session_id, location: loc))
        }
        cliImportLog.info("Codex: parsed \(out.count) user messages")
        return out
    }
}
