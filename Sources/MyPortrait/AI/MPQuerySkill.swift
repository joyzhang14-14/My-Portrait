import Foundation

/// SKILL.md 风格说明 —— 端口自 screenpipe 的同款做法。第一条用户消息前
/// 注入一次,告诉 AI 它有一个本地数据查询 CLI 可调。Pi 把 PATH 里
/// `mp-query` 视为普通可执行,通过 bash tool 调用拿 JSON 数据。
enum MPQuerySkill {

    /// 第 2 轮起每轮补发的一句话提醒。完整 `preamble` 只第 1 轮发,但 Pi/Claude
    /// session 跨轮持续后,模型对早期那条 user-message 指令的注意力会衰减,且第 2
    /// 轮起根本不再注入 —— 于是它"忘了"自己能查数据,张口就"不知道"。每轮补这
    /// 一句让它始终记得 mp-query 在手 + 默认查 today。
    static let reminder = """
        [Reminder] You have `mp-query` on PATH (call it via your bash tool) to read \
        the user's OWN captured data — meeting/audio transcripts, screen OCR, app \
        activity. For ANY question about what the user did, saw, heard, discussed, or \
        worked on, run mp-query BEFORE answering — never say you don't know without \
        checking. Start with `mp-query activity-summary --start today` (widen if \
        needed: `1h ago` / `2d ago` / `7d ago`), then `mp-query audio` for transcripts \
        or `mp-query search --content ocr` for on-screen text.
        """

    /// 拼到每个 conversation 第一条用户消息前。新 conv = 新 Pi 进程 = SKILL
    /// 必须重发一次让模型看到。
    static var preamble: String {
        """
        # Skill: my-portrait local data

        You are running inside My Portrait, a macOS app that captures the
        user's screen (OCR / app / window / browser URL) and audio
        (transcription via Whisper). All data is stored locally on this Mac.

        You have a CLI tool `mp-query` on PATH. Use it through your bash
        tool whenever the user asks about their own activity, screen
        history, conversations, meetings, work, or anything that requires
        looking at their captured data.

        ## Commands

        ```
        mp-query activity-summary --start "1h ago" [--end "now"]
          → top apps, top windows, frame counts, inferred mode (coding /
            browsing / meeting / writing / …). Best first call for broad
            "what was I doing?" questions.

        mp-query search --start "1h ago" [--end "now"] [--q "keyword"]
                        [--app "Chrome"] [--content all|ocr|audio]
                        [--limit 10]
          → matching screen frames + audio transcripts. Drop --q to get
            recent frames in the range; use --q for keyword filter.

        mp-query audio --start "1h ago" [--end "now"] [--limit 60]
          → audio transcriptions in a range (microphone + system audio).

        mp-query memories --q "keyword" [--scope portrait|events] [--limit 20]
          → search the user's curated knowledge base — TWO scopes by default:
            * `portrait/` — long-term distilled profile: who the user is,
              their personality concepts, persistent preferences, recurring
              themes ("curiosity", "writing style", "people"). This is the
              high-signal source for "what kind of person am I / what do I
              care about / what do you know about me" questions.
            * `events/<day>/*.md` — individual day-clustered events:
              one .md per discrete activity ("worked on auth flow",
              "talked to Sarah about housing"). The history-of-what-happened.
            Returns snippet (first 300 chars) per hit. Use `--scope portrait`
            or `--scope events` to limit. Combine with `mp-query read` for
            full text.

        mp-query read --path <rel>
          → read a single .md file's FULL CONTENT. `<rel>` is the relative
            path returned by `mp-query memories` (the `path` field),
            e.g. `portrait/personality/curiosity.md` or
            `events/2026-05-16/cluster-foo.md`. Use this after `memories`
            when you need the whole note, not just the 300-char snippet.
            Only files under `portrait/` and `events/` are readable.

        mp-query writing --start "30d ago" [--end "now"] [--q "..."]
                         [--app "..."] [--limit 10]
          → search what the user actually TYPED — LLM-distilled writing
            records (typing stream + AX full text + LLM cleanup). Way
            more reliable than OCR for "find what I wrote about X" —
            OCR only catches what's visible on screen at capture time
            (truncated, scrolled past, garbled). `writing` has the real
            cleaned text, app, URL, context summary. **Default to this
            first** when the user says "I wrote / I typed / find what I
            said about / my answer to / my notes on ...".

        mp-query cronjob add    --name "..." --schedule "..." [options]
        mp-query cronjob list
        mp-query cronjob remove <slug>
          → manage scheduled AI cron jobs (background tasks). See the
            "Creating cron jobs" section below for the full workflow.
        ```

        Time format: `30m ago` / `1h ago` / `2d ago` / `today` /
        `yesterday` / `now` / ISO 8601.

        Output is JSON to stdout. Error is JSON on stderr + non-zero exit.

        ## Workflow

        1. Read the user's question. If it's about their activity / day /
           apps / meetings / what they were doing — **start with
           `mp-query activity-summary --start "1h ago"`** (or wider range
           if the question implies longer, e.g. "today" → `--start today`).
        2. If the summary is enough → answer. If you need specifics
           (verbatim text, search a keyword), follow up with
           `mp-query search` or `mp-query audio`.
        3. Keep `--limit` low (10-20). Don't dump huge result sets into
           your context.
        4. Cite times naturally ("around 2:30 PM you were in Cursor…").
           Don't reproduce raw JSON to the user.

        If the question isn't about their captured data (e.g. they ask
        you to write code, explain something general), just answer
        normally — don't run mp-query for no reason.

        ## ⚠ Anti-patterns (don't do these)

        - **Don't introspect the `mp-query` binary** —
          no `strings`, `file`, `which`, `cat`, `head` on it; no reading
          the shell wrapper. It's a real CLI that talks to a local
          SQLite DB. If a call returns empty `data: []`, **that time
          range simply has no captured frames** (the app may have been
          off, or the user wasn't using the Mac). Don't treat empty
          results as "the tool is broken" — accept it and tell the user.
        - **One probe is enough.** If `activity-summary --start today`
          returns the right shape (apps + windows arrays), the CLI is
          fine. Don't run more diagnostic calls. Tool budget per turn
          should be ≤ 4 mp-query calls.
        - **Don't pipe `mp-query` output into other shell tools** like
          `strings`, `xxd`, `od` — output is already JSON. Use `jq` if
          you must filter.

        ## Creating cron jobs

        Cron jobs are background AI tasks that run on a schedule (e.g.
        "every hour summarize my Obsidian inbox" / "every day at 9 push
        my git changes"). Each run spawns a fresh agent conversation
        with the saved prompt and optional captured-data context window.

        When the user expresses an intent like "create a task that runs
        every X" / "make it remind me to Y every morning" / "set up a
        background job that Z" — use `mp-query cronjob add` to create it.

        Workflow:

        1. **Talk first**, then act. Confirm with the user (briefly,
           one or two lines) what you understood:
           - `name`: short title (e.g. "Obsidian Updater")
           - `schedule`: how often
           - `prompt`: what the job should do each run
           - `window`: how much recent screen / audio context to pass in
             (most jobs don't need any — default "none")
           - `connections`: which integrations to wire in (e.g. obsidian,
             gmail). Only if the prompt references them.
        2. Run `mp-query cronjob add`. **Always pass `--prompt-file`,
           not `--prompt`**, when the prompt is multi-line or contains
           quotes:
           ```bash
           cat > /tmp/cj.md <<'EOF'
           <multi-line prompt body here>
           EOF
           mp-query cronjob add \\
             --name "Obsidian Updater" \\
             --schedule "every 60m" \\
             --window "none" \\
             --connections obsidian \\
             --prompt-file /tmp/cj.md
           ```
        3. On success the CLI returns `{"ok": true, "slug": "...", ...}`
           and the new job appears immediately in the Cron Jobs page
           (no app restart needed). Tell the user it's created and where
           to find it.

        Schedule syntax (exactly these forms):
          - `never`
          - `every 60m`            (every N minutes)
          - `daily at 21`          (hour 0–23, local time)
          - `weekly 2 at 9`        (weekday 0=Sun…6=Sat, hour)

        Window syntax:
          - `none` | `last 30m` | `last 2h` | `today`

        Editing an existing job: there's no `edit` subcommand —
        `mp-query cronjob list`, find the slug, `mp-query cronjob remove
        <slug>`, then re-add with the new values.

        ## ⚠ Anti-patterns for cron jobs

        - **Don't write `cron_job.md` directly via your write tool**.
          The CLI keeps the frontmatter / slug / id consistent and
          signals the running app to reload. Bypassing it = the new job
          won't show up until the user restarts.
        - **Don't pick window > none unless the prompt actually needs
          recent activity**. Most jobs (git push, email digest,
          reminders) don't read screen data. Defaulting to "last 1h"
          wastes tokens.
        - **One job per request**. If the user describes two tasks,
          confirm and create them one at a time, not in a batch.

"""
    }
}
