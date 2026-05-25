import Foundation

/// 写作采集 worker 的 LLM prompt 模板(英文,跟 MemoryPrompts 风格一致)。
/// 运行时数据由各 agent 的 `buildPrompt` 拼接。
///
/// 完整设计见 `canvas-editor-capture-design-final.md` §8。
enum WritingCapturePrompts {

    // MARK: - Pass 1 —— Context Timeline 提取(整天 1 次,OCR-only)

    static let pass1ContextTimeline = #"""
    You analyze a day's worth of OCR data and produce a TIMELINE of what the user was DOING throughout the day.

    INPUT (all timestamps in unix ms, sorted ascending)
    - ocr_frames: list of OCR text frames per time range, with focused app/URL metadata.
      Pre-processed: adjacent frames with >50% Jaccard similarity have been deduped,
      anchored to ±10s of a typing/keystroke event. Format:
      [{frame_id, start_ts, end_ts, app, url, text}, ...]
    - typing_summary: every typing_event in the window (no text content shown).
      Format: [{ts, app, url, chars}, ...]
      Tells you which time slices the user was ACTUALLY typing (AX confirmed
      content went into an input field) vs which slices they were just looking
      at content.
    - keystroke_activity: raw key presses aggregated per (1-minute bucket, app).
      Format: [{ts_minute, app, count}, ...]
      Tells you the physical typing rhythm even when AX missed it (canvas
      editors, etc). High count = user actively typing; zero count = passive
      reading / browsing.

    CROSS-SIGNAL READING (critical for accurate intent_type)
    - OCR alone is misleading: "Slack with English text" on screen could be
      the user reading messages OR replying. typing_summary + keystroke_activity
      disambiguates.
    - High keystroke + low/no typing_summary in canvas-like app
      (Google Docs, Notion, Obsidian web) → user IS writing (canvas_fusion).
    - Zero keystroke + zero typing_summary + OCR text changing → user is
      reading / scrolling, intent = "reading".
    - Zero keystroke + stable OCR → idle, skip the segment.
    - Many short chat-style typing_summary entries → "chat".
    - Long typing_summary in editor app → "writing".

    TASK

    Walk through the frames in temporal order and identify CONTEXT SEGMENTS where the user
    was doing a coherent activity. Each segment should be:
    - Continuous in time
    - Same general INTENT (writing / searching / reading / chatting / running commands)
    - Same app or URL, OR clearly connected (e.g., research session jumping between apps)

    For each segment, output:
    - start_ts / end_ts: time range
    - app / url: dominant app + URL (the one used most in this segment; if mixed take majority)
    - intent_type: ONE of:
        "writing"  — composing original content (article / email / message / notes / code)
        "search"   — searching for info (queries, browsing results)
        "reading"  — reading content (docs / articles / chats they did NOT write)
        "command"  — running commands (terminal / shell)
        "chat"     — short conversational responses
        "other"    — anything else
    - summary: ≤ 100 chars, what they were doing. Be specific:
        GOOD: "Drafting thesis chapter 3 in Obsidian about ML fairness"
        BAD:  "Using Obsidian"

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "timeline": [
        {
          "start_ts": 1716393600000,
          "end_ts":   1716393900000,
          "app":      "md.obsidian",
          "url":      null,
          "intent_type": "writing",
          "summary":  "Drafting design doc for canvas editor capture"
        }
      ]
    }

    HARD RULES (a violation makes the output invalid)
    - **JSON string escaping**: ANY `"` (English double quote) inside a string value MUST
      be escaped as `\"`. Same for `\` (→ `\\`) and newlines (→ `\n`). Forgetting to escape
      user text breaks the parser. Always escape.
    - timeline is sorted by start_ts ascending and segments DO NOT overlap
    - segments may skip empty stretches (no requirement to cover the full day)
    - "intent_type" is EXACTLY one of: "writing" | "search" | "reading" | "command" | "chat" | "other"
    - "summary" ≤ 100 chars
    - Respond with ONLY the JSON object, no markdown / prose / code fences

    EDGE CASES
    - Mixed activity stretch → prefer breaking into multiple segments (over-segment is fine, under-segment is not)
    - Idle / no meaningful OCR content stretch → skip, no segment needed
    - Single-frame stretch with clear intent → still emit a segment
    """#

    // MARK: - Pass 2 —— per-(app, URL) group 多源融合 → writing_records

    static let pass2Fusion = #"""
    You consolidate one user's activity within ONE (app, url) group on a single UTC day
    into final writing_records. You judge what's a complete record on your own — no
    hard rule about length, "short response", or "throwaway".

    The user wants to PRESERVE almost every piece of MEANINGFUL input they produced —
    short chat replies, quick social-media posts, terse commit messages, ⌘+Enter-sent
    messages — these all matter as behavior / speech-style signal. Only drop input that
    has NO meaningful content (e.g. an accidental keystroke that produced "a", a single
    space, repeated test gibberish like "aaaa").

    INPUT
    - context_timeline: Pass 1's whole-day timeline (segments describing what user did
      per time range). Use this to understand the SURROUNDING context of this group.
      Format: [{start_ts, end_ts, app, url, intent_type, summary}, ...]
    - group_meta: the (app, url) this group covers + total session count
    - raw_sessions: every session inside this group, each with multi-source data:
      [{session_id, start_ts, end_ts, keystroke_text, keystroke_count,
        typing_events, keystroke_log, ocr_frames}, ...]

      **THREE-SOURCE CROSS-VALIDATION — read carefully:**

      Two sources are GROUND TRUTH (cannot lie about what the user typed):
        - keystroke_text: STRING of every char the user physically pressed
          (sorted, modifier-key-only and shortcut presses excluded, backspace
          shown as "<BS>"). For Chinese IME this is the LATIN PINYIN the user
          typed, NOT the composed characters.
        - keystroke_count: total raw key presses (debug aid)

      Two sources are FALLIBLE and must be cross-checked against the ground truth:
        - typing_events[*]: AX-path data. `text` is what the input field
          contained per AX. **AX can lie** —— it captures paste/load/program-write
          /sync/iCloud-merge content as if the user typed it. Verify against
          `keystroke_text` before trusting.
        - ocr_frames[*]: screen OCR (already Jaccard-deduped and anchor-filtered
          to ±10s of a typing/keystroke). **OCR can mislead** —— it shows whatever
          is on screen including content the user is just reading.

      keystroke_log[*] is the raw stream backing keystroke_text:
        [{ts, char, bs, mods, shortcut}]. Use it to spot timing patterns / shortcuts.
        - `mods` = "cmd" / "cmd+shift" / etc.; nil = no modifier.
        - `shortcut` is pre-derived from (char, mods):
          "paste" = ⌘V       "cut"  = ⌘X
          "copy"  = ⌘C       "undo" = ⌘Z       "redo" = ⌘⇧Z
        - Use `shortcut` directly for self-paste vs external-paste judgement
          per §3a; don't re-derive from char+mods.
        - Shortcut presses are NOT user "typing" the literal letter.

    TASK

    Look at this entire (app, url) group on this day, then produce writing_records.

    1. SEGMENT THE GROUP INTO RECORDS
       Decide where one "thing the user wrote" ends and the next one begins. You may:
       - Treat each typing_events row as its own record (if the user sent multiple
         short messages in a chat)
       - Combine adjacent typing_events into one bigger record (if they're parts of
         a single document or message that was edited multiple times)
       - Pull content from ocr_frames when typing_events is empty (canvas editors)
       - Use keystroke_log timing/clusters to spot delete-bursts, paste events,
         shortcut-triggered actions
       - Split a single typing_events row into multiple records if the user clearly
         switched topics or sent multiple messages within it
       Aim for records that correspond to ONE thing the user did intentionally.

    2. CLASSIFY EACH RECORD'S `kind`
       - "long_form"  — substantive writing: article, essay, code, document, long
                        email, multi-paragraph note. Usually ≥ 100 chars with
                        structure.
       - "short_form" — short discrete output: chat reply, social media post, commit
                        message, IM, brief comment. Length varies — could be 3 chars
                        ("好的") or 80 chars ("我也觉得这部电影后半段太拖了").
                        The SIGNAL is "user produced a discrete piece of communication
                        with intent".
       - "other"       — meaningful input that's neither (e.g. search-style typing
                        the user wants to remember, a single creative word/phrase).

    3. DROP ONLY GENUINE NOISE INTO `discarded`
       Drop only if there's NO meaningful intent:
       - Accidental key (single char with no follow-up, no commit)
       - Repeated gibberish: "aaaaa", "test test test"
       - Pure shortcut keystrokes with no resulting content (Cmd+Tab spam, etc.)
       - Empty session (typing=0, OCR=0)
       - **External paste with no user editing** (see §3a — large paste of AI reply,
         web copy, etc. with no surrounding cut/typing pattern indicating it's the user's)
       - **Pinyin / keystroke residue not composed into a real language** (see §3b)
       Use free-text reason describing why.
       DO NOT drop just because content is short — short messages are SIGNAL.
       DO NOT drop just because keystroke is missing — Chinese IME shows pinyin only,
         and OCR / typing_events.text are still valid sources when keystroke is sparse.

    3b. LANGUAGE-COHERENCE FILTER (when `user_languages` is provided in group_meta)

       `group_meta.user_languages` lists languages the user actually speaks/writes
       (e.g. "Chinese, English"). Any candidate record's final `text` MUST be
       readable in at least one of these languages — i.e. it should look like
       words / phrases / sentences a literate speaker of that language would
       recognize.

       **Drop** as gibberish/residue when:
       - text consists of obvious pinyin tokens that never composed into Chinese
         (e.g. "ox1prompt1moban1diyici1ch v11 flash" — pinyin syllables with
         IME selection digits "1", no actual Chinese characters)
       - text is a sequence of single Latin letters / random chars with no
         word-level structure (e.g. "Promoxm", "pro 2-tage1")
       - text mixes language fragments incoherently AND keystroke_text shows it
         was abandoned pinyin input (lots of <BS>, no Chinese commit)

       **Keep** even if rough when:
       - text is short but a real word in user's language ("Pro", "json", "OK")
       - text is a deliberate code/identifier ("PipelineA-v2", "useState")
       - text is in user's language with typos / informal style (real users typo)
       - text mixes user's languages naturally ("用 ffmpeg 提取关键帧")

       If `user_languages` is empty/missing, fall back to: accept anything that
       looks like coherent text in any major language.

    3c. USER REJECTION PATTERNS (when `user_rejected_examples` is provided)

       `user_rejected_examples` is the user's recent manual rejections. Each item
       has {text, app, kind, reason_category, reason_text}.

       reason_category values:
       - "gibberish"     → pinyin residue / random chars / OCR garbage
       - "private"       → user considers content too personal to keep
       - "irrelevant"    → not meaningful writing in this context
       - "typo_residue"  → mid-edit state, not a finished thought
       - "other"         → see reason_text

       For each new candidate record, check if it's structurally / semantically
       similar to ANY past rejection (same gibberish shape, same private topic,
       same fragment pattern, same app+content combo). If yes:
       → Put in `discarded` with reason "matches user rejection pattern: <ref>"
       → Where <ref> = a short phrase identifying the matched rejection.

       Be conservative: only drop on clear similarity. When in doubt, keep —
       the user can reject again, and that's faster than missing real content.

    3a. KEYSTROKE-EVENT TIMELINE (self-paste vs external paste)

       edit_log entries carry kinds that map to keyboard events. Use them to judge
       whether pasted content is the user's own or external:

       - kind="commit"  → user typed (or short paste ≤100 chars, treated as user input)
       - kind="delete"  → user deleted via backspace
       - kind="paste"   → ⌘V with text > 100 chars (potentially external)
       - kind="cut"     → ⌘X — user cut their own selection (with text = what was cut)
       - kind="undo"    → ⌘Z (no text payload)
       - kind="redo"    → ⌘⇧Z
       - kind="submit"  → Return key, message sent

       Rules:
       (a) kind="paste" preceded by kind="cut" within the same session
           (or recent prior session in same group): user is REORGANIZING their own
           content — KEEP as user-original. Same applies if a prior session in the
           group contains the cut/copied text.
       (b) kind="paste" with no preceding cut/copy in the group, AND keystroke_text
           shows no IME backing for the pasted content: likely EXTERNAL paste
           (AI reply, web copy, doc snippet). EITHER:
              - Drop the session if the whole session is just this paste, OR
              - Keep the record but exclude the pasted block from `text` (treat
                like an inline quote — user's surrounding edits stay).
       (c) Many small kind="commit" (≤100 chars each) interleaved → normal typing
           with occasional snippet moves. KEEP everything.
       (d) Pure kind="undo"/"redo"/"cut" with no surviving authored text → user
           was reshaping; if the resulting AX/OCR text is non-trivial AND matches
           text that appeared in prior session edit_logs, KEEP it (user moved
           their writing). Otherwise drop.

       For Chinese IME: keystroke_text is pinyin, text is composed Chinese.
       Phonetic match (e.g. text "你好" ↔ keystroke_text containing "nihao") confirms
       user wrote it. If keystroke_text is empty BUT typing_events.text or OCR
       shows Chinese, that's still acceptable — the user's writing is real, just
       captured via AX/OCR instead.

       DO NOT drop because intent_type from Pass 1 was "search" or "chat" — the user
       wants to keep short chats.

    4. CONTENT RECONSTRUCTION
       For AX path (typing_events.text non-empty):
       - text = typing_events.text (DO NOT modify — v14 splice already cleaned it)
       - edit_log = filter typing_events.edit_log:
         * DROP ASCII-letter commits immediately followed by Chinese commit (IME middle)
         * KEEP final commits
         * COALESCE continuous backspace runs into one "delete" entry
       For canvas path (typing_events empty or much shorter than OCR):
       - text = reconstructed from OCR + keystroke timing
       - Strip IME residue (trailing ASCII matching recent pinyin keystrokes without
         subsequent Chinese commit)
       - edit_log = synthesized from OCR diff + keystroke backspace clusters

    5. FIELDS per record
       - text, edit_log, kind, source as above
       - source: "ax_cleaned" | "canvas_fusion" | "merged"
           Use "ax_cleaned" when typing_events is the main content source.
           Use "canvas_fusion" when OCR + keystrokes drove the reconstruction.
           Use "merged" when this record combines multiple sessions of different sources.
       - confidence ∈ [0, 1]: how sure you are about the reconstruction
       - context_summary ≤ 100 chars: distill what the user did, from context_timeline + content
       - app, url: from group_meta
       - start_ts: earliest session.start_ts that contributed
       - end_ts: latest session.end_ts that contributed
       - reference_typing_event_ids: typing_events ids that contributed (JSON array)
       - reference_frame_ids: frame_ids that contributed (JSON array)
       - reference_keystroke_range: {start, end} ms range of keystrokes that contributed

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "records": [
        {
          "text": "...",
          "edit_log": [
            {"kind": "commit", "text": "今天天气真好", "ts": 1716393600000}
          ],
          "kind": "long_form",
          "source": "ax_cleaned",
          "confidence": 0.85,
          "context_summary": "Personal journal entry about weather",
          "app": "md.obsidian",
          "url": null,
          "start_ts": 1716393600000,
          "end_ts":   1716393700000,
          "reference_typing_event_ids": [123, 124],
          "reference_frame_ids":        [],
          "reference_keystroke_range":  {"start": 1716393600000, "end": 1716393700000}
        },
        {
          "text": "好的!",
          "edit_log": [{"kind": "commit", "text": "好的!", "ts": 1716393800000}],
          "kind": "short_form",
          "source": "ax_cleaned",
          "confidence": 0.9,
          "context_summary": "Brief acknowledgment in Discord chat",
          "app": "com.hnc.Discord",
          "url": null,
          "start_ts": 1716393800000,
          "end_ts": 1716393801000,
          "reference_typing_event_ids": [125],
          "reference_frame_ids": [],
          "reference_keystroke_range": {"start": 1716393800000, "end": 1716393801000}
        }
      ],
      "discarded": [
        {
          "reason": "accidental keystroke producing single char 'a' with no follow-up",
          "session_ids": ["sess_abc"],
          "preview": "a"
        }
      ]
    }

    HARD RULES (a violation makes the output invalid)
    - **JSON string escaping**: ANY `"` (English double quote) that appears INSIDE a JSON
      string value MUST be escaped as `\"`. Same for `\` (escape as `\\`) and newlines
      (escape as `\n`). Most common failure: user content like 我说："我是男生" gets
      emitted without escapes, breaks the parser. Always escape.
    - Every input session_id from raw_sessions appears EXACTLY ONCE — either inside some
      record's `reference_*_ids` (its originating session) or in `discarded.session_ids`
    - A session_id NEVER appears in both records and discarded
    - "kind" is EXACTLY one of: "long_form" | "short_form" | "other"
    - "source" is EXACTLY one of: "ax_cleaned" | "canvas_fusion" | "merged"
    - "discarded.reason" is free-text describing why (no enum prefix required)
    - "context_summary" ≤ 100 chars per record
    - "kind" in edit_log entries is EXACTLY "commit" or "delete"
    - edit_log is sorted by ts ascending
    - AX path output: text MUST EQUAL typing_events.text (do NOT modify content)
    - Respond with ONLY the JSON object, no markdown / prose / code fences

    EDGE CASES
    - Whole group is genuine noise → all sessions in `discarded`, records=[]
    - Group has only OCR (no typing/keystroke) → still try to reconstruct from OCR if
      it represents user-typed content; if it's just app chrome / web content the user
      was reading → discarded
    - One session has clearly multiple distinct sent messages → split into multiple records
    """#
}
