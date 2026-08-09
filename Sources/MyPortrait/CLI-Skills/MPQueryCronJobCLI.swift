import Foundation

/// `mp-query cronjob ...` 子命令 —— 端口自 screenpipe 的 `pipe install/list/uninstall`。
///
/// AI agent 在 chat 里跟用户聊定 name + schedule + prompt 后,通过 bash 跑
/// `mp-query cronjob add ...` 直接落盘 `~/.portrait/cron_jobs/<slug>/cron_job.md`
/// (复用 `CronJobFile.renderMarkdown` 保证格式不会写错),并 post Darwin
/// notification `com.myportrait.cronjobs.reload` 通知主 app 重读 store。
///
/// 为什么走 CLI 而不让 AI 直接 Write 文件:
/// 1. frontmatter 格式不会错(slug/id/字段拼写全在 Swift 这边)
/// 2. 触发 reload 信号,无需重启 app 就能看到新 cron job
/// 3. preamble 不用塞精确 frontmatter 模板,AI 只需记一条命令
enum MPQueryCronJobCLI {

    /// Darwin 通知名 —— CronJobStore 在 init 时 observe 这个。
    static let reloadNotification = "com.myportrait.cronjobs.reload"

    static func run(args: [String]) -> Never {
        guard let sub = args.first else {
            printUsage()
            exit(2)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "add":    runAdd(args: rest)
        case "list":   runList(args: rest)
        case "remove", "rm", "uninstall": runRemove(args: rest)
        case "help", "--help", "-h":
            printUsage(); exit(0)
        default:
            errJSON("unknown cronjob subcommand: \(sub). try `mp-query cronjob help`.")
        }
    }

    // MARK: - add

    private static func runAdd(args: [String]) -> Never {
        let opts = parseOpts(args)
        guard let name = opts["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            errJSON("--name is required (e.g. --name \"Obsidian Updater\")")
        }
        guard let scheduleStr = opts["schedule"]?.trimmingCharacters(in: .whitespaces), !scheduleStr.isEmpty else {
            errJSON("--schedule is required (e.g. --schedule \"every 60m\" / \"daily at 9\" / \"weekly 2 at 9\")")
        }
        let windowStr = opts["window"] ?? "none"

        // prompt 来源:--prompt 内联 / --prompt-file 文件 / stdin。
        // AI 写多行 prompt 时 stdin / prompt-file 更安全,不用 escape 引号。
        let prompt: String
        if let inline = opts["prompt"] {
            prompt = inline
        } else if let path = opts["prompt-file"] {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                errJSON("could not read --prompt-file: \(path)")
            }
            prompt = s
        } else {
            // stdin 读到 EOF。AI 用 `echo "..." | mp-query cronjob add ...` 模式时走这条。
            let data = FileHandle.standardInput.readDataToEndOfFile()
            prompt = String(data: data, encoding: .utf8) ?? ""
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errJSON("prompt is empty. pass --prompt \"...\" / --prompt-file <path> / pipe via stdin")
        }

        // schedule / window 复用 CronJobFile 的解码器,语法跟主 app 完全一致。
        let schedule = CronJobFile.decodeCadence(scheduleStr)
        if case .never = schedule, scheduleStr.lowercased() != "never" {
            errJSON("could not parse --schedule \"\(scheduleStr)\". valid forms: never | every 60m | daily at 21 | weekly 2 at 9")
        }
        let window = CronJobFile.decodeWindow(windowStr)
        if case .none = window, windowStr.lowercased() != "none" {
            errJSON("could not parse --window \"\(windowStr)\". valid forms: none | last 30m | last 2h | today")
        }

        let enabled = (opts["enabled"] ?? "true").lowercased() != "false"
        let muted = (opts["muted"] ?? "false").lowercased() == "true"
        let connections = (opts["connections"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Slug 唯一性:已存在就拒绝,逼 AI 改名或先 remove。不像 CronJobStore.save
        // 那样静默加 `-2` 后缀 —— CLI 场景必须 fail-fast 让 AI 看见冲突。
        let slug = CronJobFile.slug(name)
        let dir = Storage.cronJobsDir.appendingPathComponent(slug, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: Storage.cronJobsDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dir.path) {
            errJSON("cron job with slug \"\(slug)\" already exists at \(dir.path). pick a different --name or run `mp-query cronjob remove \(slug)` first.")
        }

        let job = CronJob(
            name: name, prompt: prompt, window: window,
            schedule: schedule, isEnabled: enabled,
            connections: connections, muted: muted
        )

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = CronJobFile.renderMarkdown(job)
        do {
            try md.write(to: dir.appendingPathComponent("cron_job.md"), atomically: true, encoding: .utf8)
        } catch {
            errJSON("could not write cron_job.md: \(error.localizedDescription)")
        }

        postReload()

        emitJSON([
            "ok": true,
            "slug": slug,
            "id": job.id.uuidString,
            "path": dir.appendingPathComponent("cron_job.md").path
        ])
    }

    // MARK: - list

    private static func runList(args: [String]) -> Never {
        _ = args
        let fm = FileManager.default
        let root = Storage.cronJobsDir
        let subdirs = (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var out: [[String: Any]] = []
        for sub in subdirs {
            let mdURL = sub.appendingPathComponent("cron_job.md")
            guard fm.fileExists(atPath: mdURL.path),
                  let text = try? String(contentsOf: mdURL, encoding: .utf8),
                  let job = CronJobFile.parseMarkdown(text, fallbackName: sub.lastPathComponent)
            else { continue }
            out.append([
                "slug": sub.lastPathComponent,
                "id": job.id.uuidString,
                "name": job.name,
                "enabled": job.isEnabled,
                "muted": job.muted,
                "schedule": CronJobFile.encode(job.schedule),
                "window": CronJobFile.encode(job.window),
                "connections": job.connections,
                "prompt": job.prompt
            ])
        }
        emitJSON(["data": out, "count": out.count])
    }

    // MARK: - remove

    private static func runRemove(args: [String]) -> Never {
        // 支持 `mp-query cronjob remove obsidian-updater`(位置参) 或
        // `--slug obsidian-updater` / `--name "Obsidian Updater"`。
        let opts = parseOpts(args)
        let positional = args.first(where: { !$0.hasPrefix("--") })
        let slug: String = {
            if let s = opts["slug"], !s.isEmpty { return s }
            if let n = opts["name"], !n.isEmpty { return CronJobFile.slug(n) }
            if let p = positional { return p }
            return ""
        }()
        guard !slug.isEmpty else {
            errJSON("specify which cron job to remove: positional slug, --slug, or --name")
        }

        let dir = Storage.cronJobsDir.appendingPathComponent(slug, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            errJSON("no cron job with slug \"\(slug)\". run `mp-query cronjob list` to see what's there.")
        }
        do {
            try fm.removeItem(at: dir)
        } catch {
            errJSON("could not remove \(dir.path): \(error.localizedDescription)")
        }
        postReload()
        emitJSON(["ok": true, "slug": slug])
    }

    // MARK: - reload signal

    /// Post 一条 Distributed Notification,主 app 在 CronJobStore 里 observe 这个,
    /// 收到 → `load()`。避免用户为了看新 cron job 还要重启 app。
    private static func postReload() {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(Notification.Name(reloadNotification),
                                    object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - helpers

    /// 跟 MPQueryCLI.parseOpts 同款 —— 支持 `--key val` 和 `--key=val`,
    /// 用 updateValue 避开 enum static func 下标赋值优化坑。
    private static func parseOpts(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let stripped = String(a.dropFirst(2))
            if let eq = stripped.firstIndex(of: "=") {
                let key = String(stripped[..<eq])
                let val = String(stripped[stripped.index(after: eq)...])
                out.updateValue(val, forKey: key)
                i += 1
                continue
            }
            if i + 1 < args.count {
                out.updateValue(args[i + 1], forKey: stripped)
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private static func emitJSON(_ obj: Any) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        exit(0)
    }

    private static func errJSON(_ msg: String) -> Never {
        let obj = ["error": msg]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }
        exit(1)
    }

    private static func printUsage() {
        let usage = """
        mp-query cronjob — manage scheduled AI cron jobs

        USAGE
          mp-query cronjob add    --name "..." --schedule "..." [options]
          mp-query cronjob list
          mp-query cronjob remove <slug>

        ADD OPTIONS
          --name "<title>"           required. user-facing name (becomes slug).
          --schedule "<spec>"        required. one of:
                                       never | every 60m | daily at 21 | weekly 2 at 9
          --window "<spec>"          context window. default "none". one of:
                                       none | last 30m | last 2h | today
          --prompt "<text>"          prompt body. inline. use --prompt-file for multi-line.
          --prompt-file <path>       read prompt body from file (utf-8).
                                       if neither --prompt nor --prompt-file, reads stdin.
          --connections a,b,c        integration ids (e.g. obsidian,gmail).
          --enabled true|false       default true.
          --muted true|false         default false. true = task runs but no banner.

        REMOVE
          mp-query cronjob remove <slug>          (positional)
          mp-query cronjob remove --slug <slug>
          mp-query cronjob remove --name "<title>" (slugifies automatically)

        EXAMPLES
          mp-query cronjob add --name "Obsidian Updater" \\
            --schedule "every 60m" --window "none" \\
            --connections obsidian \\
            --prompt-file /tmp/prompt.md

          mp-query cronjob list

          mp-query cronjob remove obsidian-updater
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}
