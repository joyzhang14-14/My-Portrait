import Foundation

/// SKILL.md 风格说明 —— 第一条用户消息前注入,告诉 AI 它有一个 `mp-folders`
/// CLI 可调来按用户对话需求整理 event folder。
///
/// 跟 MPQuerySkill 同模式 —— 各负责一域:mp-query 只读(数据查询),
/// mp-folders 读写(folder 元数据)。同一个 PiAgent 把两个 preamble 都拼到
/// 首条消息前。
enum FoldersSkill {

    static var preamble: String {
        """
        # Skill: my-portrait event folders

        Events captured by My Portrait can be grouped into **project-level
        folders** ("My Portrait", "Valis", "UCI Application", …). Folders are
        pure metadata at `~/.portrait/events/_folders/<slug>.json` — they
        index event relative paths, the event .md files themselves never
        move. One event lives in at most one folder; cross-cutting themes
        stay on event tags.

        You have a CLI tool `mp-folders` on PATH for this. Use it through
        your bash tool whenever the user asks you to **organize / group /
        sort / file / put / pull together / tidy up** their events into
        projects, or to **rename / delete / merge / split** existing folders.

        ## Commands

        ```
        mp-folders list                                       → all folders
        mp-folders show <slug>                                → folder + its events
        mp-folders search-events --q "..." [--tag ...] [--start ...] [--end ...]
                                 [--unclassified] [--limit 20]
                                                              → find candidate events
        mp-folders create --name "..." --description "..." [--events e1,e2,...]
        mp-folders add    --slug X --events e1,e2,...
        mp-folders remove --slug X --events e1,e2,...
        mp-folders rename --slug X [--name "..."] [--description "..."]
        mp-folders delete --slug X                            → folder removed, events un-classify
        ```

        Time format (`--start` / `--end`): `today` / `yesterday` /
        `Nd ago` / `yyyy-MM-dd`.
        Events arg: comma-separated relative paths under `events/`, e.g.
        `2026-05-16/cluster-foo.md,2026-05-17/cluster-bar.md`.

        Output is JSON to stdout. Errors are JSON `{"error": "..."}` on
        stderr + non-zero exit.

        ## Workflow

        1. **Always start with `mp-folders list`** to see what folders
           already exist — never create a duplicate of an existing project.
        2. To find events to organize, use `mp-folders search-events` with
           keywords / tags / a time window. Pass `--unclassified` to limit
           to events that aren't yet in any folder.
        3. **Confirm with the user** before mutating:
           - Show the candidate events + intended action
             ("I'll put these 7 events into a new folder 'Valis'")
           - One or two lines, then act on approval.
        4. Use `mp-folders create` / `add` / `remove` / `rename` / `delete`
           to apply. Each call commits atomically — no separate approve step.
        5. Tell the user what changed ("Created folder 'Valis' with 7 events;
           folder slug: valis").

        ## Anti-patterns (don't do these)

        - **Don't bulk-classify on your own** (e.g. scanning every event
          and inventing folders). Folders are project containers — the user
          decides what counts as a project. Always wait for their intent.
        - **Don't auto-pull tiny groups into folders**. If the user hasn't
          asked, leave them ungrouped.
        - **Don't edit `_folders/*.json` directly via your write tool**.
          Always go through `mp-folders` — it keeps slug rules, timestamps,
          and event path validation consistent.
        - **One operation per request**. If the user describes two distinct
          organizations, do them one at a time, confirm between each.
        - **Don't introspect the binary**. No `file`, `strings`, `which`
          on `mp-folders`. It's a real CLI — call it with subcommands.

"""
    }
}
