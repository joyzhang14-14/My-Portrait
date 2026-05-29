import Foundation

/// 写作采集 worker 的 LLM prompt 模板(英文,跟 MemoryPrompts 风格一致)。
/// 运行时数据由各 agent 的 `buildPrompt` 拼接。
///
/// 完整设计见 `canvas-editor-capture-design-final.md` §8。
///
/// **prompt 风格**:主体只描述**抽象场景**,不出现具体 app 名 / 具体 user text。
/// 具体例子集中在文末 EXAMPLES 块。这样规则保持通用性,不会被某个 app 的特殊
/// 形态绑死。
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
    - OCR alone is misleading: text on screen could be content the user is
      reading OR content the user is composing. typing_summary + keystroke_activity
      disambiguates.
    - High keystroke + low/no typing_summary in a canvas-style editor (apps that
      don't expose input fields to AX) → user IS writing.
    - Zero keystroke + zero typing_summary + OCR text changing → user is reading
      / scrolling, intent = "reading".
    - Zero keystroke + stable OCR → idle, skip the segment.
    - Many short, separated typing_summary bursts → conversational chat.
    - Long sustained typing_summary in editor-style app → long-form writing.

    TASK

    Walk through the frames in temporal order and identify CONTEXT SEGMENTS where the user
    was doing a coherent activity. Each segment should be:
    - Continuous in time
    - Same general INTENT (writing / searching / reading / chatting / running commands)
    - Same app or URL, OR clearly connected (e.g., a research session jumping between apps)

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
    - summary: ≤ 100 chars. Describe the SCENE / SURFACE the user is on (what
        kind of interface they're looking at), NOT what their typed text is
        about.
        • Identify the surface from OCR VISUAL cues: chat UI (channel /
          message list, send button, reply thread), code editor (line numbers,
          syntax-colored tokens, tabs), document / notes (long prose with
          headings, no UI chrome), web article (article body + nav chrome),
          terminal (prompt + command output), search results (link list +
          snippets), email (inbox / thread), settings / preferences pane, etc.
        • If the app is a known platform, name it ("chatting on Discord",
          "drafting in Apple Notes", "browsing a GitHub repo page", "running
          shell commands in Terminal"). For unknown apps, describe the surface
          type ("conversational chat window", "long-form document editor",
          "code editor with multiple tabs").
        • DO NOT include the user's typed content, the conversation topic,
          or what their document is about.
          BAD: "Says it can store years of data" / "Discussing AI usage limits"
          GOOD: "Chatting on Discord with one peer"
          BAD: "Writing Python packaging notes"
          GOOD: "Drafting a long note in Apple Notes"

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "timeline": [
        { "start_ts": <ms>, "end_ts": <ms>, "app": "<bundle_id>", "url": <string|null>,
          "intent_type": "writing", "summary": "<≤100 chars>" }
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
    hard rule about length or "short response".

    The user wants to PRESERVE almost every piece of MEANINGFUL input they produced —
    brief replies, quick posts, terse commit-style messages, ⌘+Enter-sent fragments —
    these all matter as behavior / speech-style signal. Only drop input that has NO
    meaningful content (an accidental keystroke, a single space, repeated test gibberish).

    INPUT
    - context_timeline: Pass 1's whole-day timeline (segments describing what the user
      did per time range). Use this to understand the SURROUNDING context of this group.
      Format: [{start_ts, end_ts, app, url, intent_type, summary}, ...]
    - group_meta: the (app, url) this group covers + total session count +
      optional user_languages
    - raw_sessions: every session inside this group, each with multi-source data:
      [{session_id, start_ts, end_ts, keystroke_text, keystroke_count,
        typing_events, keystroke_log, ocr_frames, chrome_tokens}, ...]

      **MULTI-SOURCE CROSS-VALIDATION — read carefully:**

      Two sources are GROUND TRUTH for "what the user physically pressed":
        - keystroke_text: STRING of every char the user physically pressed (sorted;
          modifier-only and shortcut presses excluded; backspace shown as "<BS>").
          For IME-based languages (e.g. Chinese pinyin) this is the LATIN phonetic
          input the user typed, NOT the composed characters.
        - keystroke_count: total raw key presses (debug aid)

      Two sources are FALLIBLE and must be cross-checked:
        - typing_events[*]: AX-path data. `text` is what the input field contained
          per accessibility. **AX can lie** — it surfaces paste / file-load /
          program-write / sync-merge content the same way it surfaces typing.
          Verify against `keystroke_text` and the keyboard-event log.
        - ocr_frames[*]: screen OCR, already Jaccard-deduped and anchor-filtered
          to ±10s of a typing/keystroke event. **OCR can mislead** — it shows
          whatever is on screen including content the user is just reading.

      keystroke_log[*] is the raw stream backing keystroke_text:
        [{ts, char, bs, mods, shortcut}]. Use it to spot timing patterns / shortcuts.
        - `mods` = "cmd" / "cmd+shift" / etc.; nil = no modifier.
        - `shortcut` is pre-derived from (char, mods):
          "paste" = ⌘V       "cut"  = ⌘X
          "copy"  = ⌘C       "undo" = ⌘Z       "redo" = ⌘⇧Z
        - Use `shortcut` directly for self-paste vs external-paste judgement;
          don't re-derive from char+mods.
        - Shortcut presses are NOT user "typing" the literal letter.

    CANVAS EDIT-HISTORY RECONSTRUCTION (Google Docs / Figma / web editors, no AX)
      When typing_events is empty/sparse, reconstruct the edit_log YOURSELF by
      comparing the DOCUMENT BODY across consecutive ocr_frames over time:
        - ocr_frames here are COARSE time-bucketed snapshots (~one every few
          minutes, the cleanest frame per bucket) — a version-level timeline, not
          every keystroke. Aim for VERSION-LEVEL edits (a paragraph/sentence
          added or removed between snapshots), matching that granularity.
        - chrome_tokens is an ADAPTIVE list of UI words that appeared in almost
          every frame this session (tab names, menu/toolbar labels, "saving/saved",
          file name, URL fragments). These are app/browser chrome, NOT the user's
          writing. When comparing snapshots, IGNORE any change made of only
          chrome_tokens — it is UI churn, never a real edit.
        - A paragraph/sentence of real prose that APPEARS in a later snapshot and
          wasn't before → a "commit" edit. Use the new body text.
        - A paragraph/sentence present then GONE in a later snapshot, net reduction
          > ~15 chars of real prose → a "delete" edit. Record what was removed.
        - This is for revision habits: how much the user adds vs deletes, whether
          they revise heavily. The FINAL record text = the most complete / last
          body state across the snapshots (use the RAW frame text, not stripped).

      CRITICAL — DO NOT INVENT EDITS. Accuracy beats completeness here:
        - If you are NOT confident a change is a real body edit (could be OCR
          jitter, word-order scramble, scrolling, or chrome churn), DO NOT emit an
          edit for it. A missed edit is fine; a fabricated edit is NOT.
        - NEVER turn chrome text (anything in chrome_tokens: URLs, tab names,
          "saving", toolbar labels, app names) into an edit_log entry.
        - When unsure, emit a SHORTER edit_log with only the edits you are sure of,
          or an empty edit_log — never pad it with noise.

    INTERPRETIVE PRIORITY when sources disagree
    - If keystroke is present and consistent with typing_events.text (or its IME
      composition), trust typing_events.text.
    - If typing_events is absent or very sparse but the app is one where the user
      types into an input field (chat / messaging / canvas editor / scratchpad):
      lean on AX text when AX has content; lean on OCR when OCR has content;
      treat keystroke as supporting evidence, not a veto.
    - When all three disagree on the SAME stretch of content, prefer typing_events
      then OCR then keystroke — but always sanity-check against §3a and §3b.

    TASK

    Look at this entire (app, url) group on this day, then produce writing_records.

    1. SEGMENT THE GROUP INTO RECORDS
       Decide where one "thing the user wrote" ends and the next one begins. You may:
       - Treat each typing_events row as its own record (typical for chat-style apps
         where each Enter sends a separate message)
       - Combine adjacent typing_events into one bigger record (parts of a single
         document or message edited multiple times)
       - Pull content from ocr_frames when typing_events is empty (canvas-style apps
         that don't expose AX; or apps that swallow keystroke events)
       - Use keystroke_log timing/clusters to spot delete-bursts, paste events,
         shortcut-triggered actions
       - Split a single typing_events row into multiple records if the user clearly
         switched topics or sent multiple separate things within it
       Aim for records that correspond to ONE thing the user did intentionally.

    2. CLASSIFY EACH RECORD'S `kind`
       - "long_form"  — substantive writing: article, essay, code, document, long
                        email, multi-paragraph note. Usually ≥ 100 chars with
                        structure.
       - "short_form" — short discrete output: chat reply, social media post,
                        commit-style message, IM, brief comment. Length varies
                        widely. The SIGNAL is "user produced a discrete piece of
                        communication with intent".
       - "other"      — meaningful input that's neither (a remembered search query,
                        a single creative word/phrase the user typed deliberately).

    3. DO NOT DISCARD ANYTHING IN THIS PASS
       Translate every session you receive into a record. A separate Pass 3
       gate decides what to drop based on keystroke-support evidence. Your
       job here is purely transcription + segmentation + cleanup.
       - If a session looks like noise / external paste / keystroke residue,
         STILL emit a record for it. Pass 3 will drop it.
       - Do not include `discarded` in your output. Output `records` only.
       - Every input session_id must appear in at least one record's
         `reference_*_ids`.

    3a. KEYSTROKE-EVENT TIMELINE (self-paste vs external paste)

       edit_log entries (and the keystroke_log shortcut field) carry kinds that map
       to keyboard events. Use them to judge whether pasted content is the user's
       own or external:

       - kind="commit" → user typed (or short paste ≤100 chars, treated as user input)
       - kind="delete" → user deleted via backspace
       - kind="paste"  → ⌘V with text > 100 chars (potentially external)
       - kind="cut"    → ⌘X — user cut their own selection (text = what was cut)
       - kind="undo"   → ⌘Z (no text payload)
       - kind="redo"   → ⌘⇧Z
       - kind="submit" → Return key, message sent

       Rules:
       (a) kind="paste" preceded by kind="cut" within the same session (or in a
           recent prior session of the same group): user is REORGANIZING their own
           content — KEEP as user-original. Same if a prior session in the group
           contained the cut/copied text.
       (b) kind="paste" with no preceding cut/copy in the group, AND keystroke_text
           shows no IME backing for the pasted content: likely EXTERNAL paste.
           EITHER drop the session if the whole session is just this paste, OR
           keep the record but exclude the pasted block from `text` (treat like
           an inline quote — surrounding user edits stay).
       (c) Many small kind="commit" (≤100 chars each) interleaved → normal typing
           with occasional snippet moves. KEEP everything.
       (d) Pure kind="undo"/"redo"/"cut" with no surviving authored text → user
           was reshaping; if the resulting AX/OCR text is non-trivial AND matches
           text that appeared in prior session edit_logs, KEEP it (user moved
           their writing). Otherwise drop.

       For IME-based languages: keystroke_text is the phonetic input (e.g. pinyin),
       text is the composed character output. Phonetic correspondence between the
       two confirms the user wrote it. If keystroke_text is empty BUT
       typing_events.text or OCR shows composed content, that's still acceptable —
       the user's writing is real, just captured via AX/OCR.

       DO NOT drop because intent_type from Pass 1 was "search" or "chat" — short
       chats and queries are signal the user wants kept.

    3b. LANGUAGE-COHERENCE FILTER (when `user_languages` is provided)

       `group_meta.user_languages` lists languages the user actually speaks/writes.
       A candidate record's final `text` MUST be readable in at least one of these
       languages — looking like words / phrases / sentences a literate speaker
       would recognize.

       Drop as gibberish/residue when:
       - text is a sequence of phonetic tokens (IME pinyin syllables / selection
         digits) that never composed into the target language
       - text is single Latin letters / random chars with no word-level structure
       - text mixes language fragments incoherently AND keystroke_text shows it
         was abandoned IME input (many <BS>, no successful composition)

       Keep even if rough when:
       - text is short but a real word in user's language
       - text is a deliberate code identifier / version tag
       - text is in user's language with typos or informal style (real users typo)
       - text mixes user's languages naturally

       If `user_languages` is empty/missing, accept anything that looks like
       coherent text in any major language.

    3c. USER REJECTION PATTERNS (when `user_rejected_examples` is provided)

       `user_rejected_examples` is the user's recent manual rejections. Each item
       has {text, app, kind, reason_category, reason_text}.

       reason_category values: "gibberish" | "private" | "irrelevant" |
       "typo_residue" | "other".

       For each new candidate record, check if it's structurally / semantically
       similar to ANY past rejection (same gibberish shape, same private topic,
       same fragment pattern, same app+content combo). If yes:
       → Put in `discarded` with reason "matches user rejection pattern: <ref>"
       → Where <ref> = a short phrase identifying the matched rejection.

       Be conservative: only drop on clear similarity. When in doubt, keep —
       the user can reject again, and that's faster than missing real content.

    4. CONTENT RECONSTRUCTION
       For AX path (typing_events.text non-empty):
       - text = typing_events.text (DO NOT modify — already cleaned)
       - edit_log = filter typing_events.edit_log:
         * DROP ASCII-letter commits immediately followed by an IME composition
           commit (IME middle state)
         * KEEP final commits
         * COALESCE continuous backspace runs into one "delete" entry
       For canvas path (typing_events empty or much shorter than OCR):
       - text = reconstructed from OCR + keystroke timing
       - Strip IME residue (trailing phonetic tokens not followed by composition)
       - edit_log = synthesized from OCR diff + keystroke backspace clusters

    5. FIELDS per record
       - text, edit_log, kind, source as above
       - source: "ax_cleaned" | "canvas_fusion" | "merged"
           "ax_cleaned"    — typing_events is the main content source
           "canvas_fusion" — OCR + keystrokes drove the reconstruction
           "merged"        — record combines multiple sessions of different sources
       - confidence ∈ [0, 1]
       - context_summary ≤ 100 chars: describe the SCENE / SURFACE the user is
         on (inherit + refine from context_timeline's summary). Describe WHERE
         and WHAT KIND OF interface, NOT what the typed text says.
         GOOD: "Chatting on Discord with one peer" / "Drafting a long note in
               Apple Notes" / "Replying in a Slack channel" / "Editing Swift
               file in Xcode"
         BAD:  "Says it can store years of data" / "Discussing AI limits" /
               "Writing Python packaging notes" (these are CONTENT, not scene)
       - app, url: from group_meta
       - start_ts: earliest contributing session.start_ts
       - end_ts: latest contributing session.end_ts
       - reference_typing_event_ids: typing_events ids that contributed (JSON array)
       - reference_frame_ids: frame_ids that contributed (JSON array)
       - reference_keystroke_range: {start, end} ms range of keystrokes contributed

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "records": [
        { "text": "...", "edit_log": [...], "kind": "long_form|short_form|other",
          "source": "ax_cleaned|canvas_fusion|merged", "confidence": 0.85,
          "context_summary": "...", "app": "<bundle_id>", "url": <string|null>,
          "start_ts": <ms>, "end_ts": <ms>,
          "reference_typing_event_ids": [], "reference_frame_ids": [],
          "reference_keystroke_range": {"start": <ms>, "end": <ms>}
        }
      ]
    }

    HARD RULES (a violation makes the output invalid)
    - **JSON string escaping**: ANY `"` inside a JSON string value MUST be escaped
      as `\"`. Same for `\` (escape as `\\`) and newlines (escape as `\n`). User
      content containing nested quotes will break the parser if unescaped.
    - Every input session_id from raw_sessions MUST appear in at least one
      record's `reference_*_ids` (no `discarded` in this pass — Pass 3 handles it)
    - "kind" is EXACTLY one of: "long_form" | "short_form" | "other"
    - "source" is EXACTLY one of: "ax_cleaned" | "canvas_fusion" | "merged"
    - "context_summary" ≤ 100 chars per record
    - "kind" in edit_log entries is EXACTLY "commit" or "delete"
    - edit_log is sorted by ts ascending
    - AX-path output: text MUST EQUAL typing_events.text (do NOT modify content)
    - Respond with ONLY the JSON object, no markdown / prose / code fences

    EDGE CASES
    - Group has only OCR (no typing/keystroke) → still try to reconstruct from OCR
      and emit a record (Pass 3 will judge if it's user-produced)
    - One session contains multiple distinct sent messages → split into multiple
      records

    ────────────────────────────────────────────────────────────────────────
    EXAMPLES (illustrative — these specific apps / texts are NOT rules)
    ────────────────────────────────────────────────────────────────────────

    Example A — short chat reply, AX present:
      typing_events.text = "好的!"
      keystroke_text = "haode1!"  (pinyin + IME selection digit "1" + punctuation)
      → record { kind: "short_form", source: "ax_cleaned", text: "好的!" }

    Example B — chat-heavy session, AX exposes each message:
      typing_events = ["这是给我下载到哪", "怎么搞？", "有ffmpeg"]
      → 3 separate "short_form" records, one per typing_event (each Enter sent).

    Example C — long Chinese note via IME:
      typing_events.text = "先用apify找到爆款视频的链接\n下载视频\n..."
      keystroke_text contains spans like "xiany1 apify..." (pinyin + selection
      digits per phrase: e.g. "xian" then "1" picks 先, "yong" then a digit picks
      用, etc. — the digit choice depends on candidate position in the IME panel)
      → record { kind: "long_form", source: "ax_cleaned" }, KEEP.

    Example D — canvas editor, OCR only (AX returns empty):
      typing_events = [],  ocr_frames show a stable document growing over time,
      keystroke_count > 50, keystroke_text shows real input.
      → reconstruct text from latest OCR frame, record { source: "canvas_fusion" }.

    Example E — paste from external source:
      keystroke_log shortcut="paste", added 800 chars, no preceding cut/copy,
      keystroke_text has no IME backing for the pasted content.
      → §3a (b): drop or strip the pasted block.

    Example F — IME residue, no successful composition:
      text = "ox1prompt1moban1diyici1ch v11 flash"  (pinyin syllables + selection
      digits, no Chinese characters), keystroke_text shows abandoned input with
      many <BS>.
      → §3b: discarded with reason "pinyin residue, no IME composition".

    Example G — chat-app where AX exposes content but keystroke is sparse:
      typing_events.text = "啥意思"  (real Chinese message in a chat app),
      keystroke_text = ""  (the app swallowed keystrokes or used a custom IME).
      → still KEEP, source: "ax_cleaned". Sparse keystroke is not grounds to drop
        when AX content is a coherent message in user's language.

    Example H — version label that looks like gibberish but isn't:
      text = "PipelineA-v2"
      → KEEP. Code identifier / version tag in user's language.
    """#

    // MARK: - Pass 3 —— keystroke 支撑度过滤(records → kept / discarded)

    static let pass3KeystrokeSupport = #"""
    You are the FINAL filter gate. You receive writing_records that Pass 2 produced
    (Pass 2 translates without filtering — you decide what survives).

    Your single job: for each record, decide whether the period's KEYSTROKE
    EVIDENCE actually supports the user having produced this text. If not,
    DISCARD it. If yes, KEEP it.

    INPUT
    - records: array of candidate records from Pass 2. Per record you see:
      { record_id, text, kind, source, app, url, start_ts, end_ts,
        keystroke_text, keystroke_count, typing_events_text,
        has_paste_event, has_cut_event,
        ime_likely  // true if keystroke pattern looks like IME pinyin / kana }
      - keystroke_text  : every physical key the user pressed in the record's
                          window (sorted; <BS> shown for backspace; shortcut
                          presses excluded).
      - keystroke_count : total raw key presses in the window.
      - typing_events_text: AX-path text in the window (if any; "" if absent).
      - has_paste_event : ⌘V pressed > 100 chars (potentially external paste).
      - has_cut_event   : ⌘X pressed (user cut their OWN content).
      - ime_likely      : the keystroke pattern matches IME composition style.

    JUDGEMENT RULES

    KEEP a record when ANY of:
    - keystroke_count is roughly proportional to text.length (for ASCII
      languages: keystroke_count ≥ 0.6 × text.length is plenty);
    - ime_likely is true AND keystroke_count is reasonable for an IME
      composition of this text (Chinese pinyin: keystroke is the latin
      phonetic, ~1.5–3× the composed char count);
    - has_cut_event is true AND text matches what was cut (user re-pasted
      their own content);
    - typing_events_text contains the record.text (AX confirms user typed
      it into an input field), regardless of keystroke count;
    - The app is one where keystrokes are commonly swallowed (custom IME,
      web-based chat, canvas editor) AND AX or OCR backs the content with
      a coherent message in the user's language.

    CANVAS LONG-FORM EXEMPTION (read carefully — applies to source "canvas_fusion"
    / "merged" on a document editor like Google Docs / Notion / Word-on-web):
    - These apps expose NO keystroke/AX for the body. The record was reconstructed
      from OCR of the document on screen. The keystroke_text for the window WILL
      look unrelated (pinyin fragments, Chinese chat from a side window, paste
      events, or near-empty) — THIS IS EXPECTED and is NOT grounds to discard.
    - The keystroke_TEXT won't match the body char-for-char (IME pinyin, paste,
      canvas swallow) — that text mismatch alone is NOT a reason to discard.
    - BUT keystroke_COUNT is still a VOLUME check, and it is the deciding signal:
      did the user physically type enough to have AUTHORED this text?
        * Rough need: ASCII text ≈ 0.5× its length in keystrokes; IME/Chinese ≈
          1.5–3× the CJK char count (latin phonetic). Pasting one's OWN earlier
          draft also counts (has_cut_event, or has_paste_event of the user's own
          prior text).
        * If keystroke_count is FAR below that need AND there is no own-paste/cut
          evidence, the BULK of the on-screen text was NOT produced by the user.
          Canvas OCR grabbed whatever was on screen — an AI assistant's reply,
          a chat the user is reading, an article, search results → DISCARD.
        * If keystroke_count plausibly supports authoring (or own-paste/cut),
          KEEP — this is the user's own document, mismatched keystroke text and all.
    Do NOT pattern-match on wording or tone; decide by keystroke VOLUME vs text
    length. (A long screen of text with only a handful of keystrokes in the window
    is content the user was reading/receiving, not writing.)

    DISCARD a record when ALL of:
    - keystroke_count is far below what text.length would require AND not
      explained by IME; AND
    - typing_events_text does NOT contain or closely match record.text; AND
    - has_paste_event is true OR keystroke_text is sparse/empty
      → this is external paste / OCR residue / app chrome that leaked in.

    ALSO DISCARD:
    - Pure shortcut presses with no resulting meaningful text.
    - Empty / near-empty text with no clear user intent (single char, single
      space, repeated gibberish "aaaaa" without IME context).
    - OCR residue: text comes only from OCR with zero keystroke AND zero
      AX support AND the content reads like app chrome (e.g. UI labels,
      menu items, system notifications).

    DO NOT discard for length alone. Short legitimate replies are valid.
    DO NOT discard just because keystroke is missing — IME composition and
      keystroke-swallowing apps are real edge cases. Look at AX + content
      coherence.

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "kept": ["<record_id>", ...],
      "discarded": [
        { "record_id": "<id>", "reason": "<free text ≤ 120 chars>",
          "preview": "<≤ 200 chars sample of the record's text>" }
      ]
    }

    HARD RULES
    - **JSON string escaping**: escape `"` → `\"`, `\` → `\\`, newlines → `\n`.
    - EVERY input record_id appears EXACTLY ONCE — either in `kept` or in
      `discarded.record_id`. Never both.
    - "reason" is free text, no enum required.
    - Respond with ONLY the JSON object, no prose / code fences.
    """#

    // MARK: - Canvas window —— 一窗连续文档快照 → 编辑片段 + body

    /// 一个 subagent 只看 ONE canvas 文档的几张连续时间快照,产出这段的编辑
    /// 片段 + 最完整 body。多窗并发跑、结果合并(见 WritingCaptureCanvasAgent)。
    static let canvasWindow = #"""
    You are reconstructing the EDIT HISTORY of ONE document (Google Docs / Notion /
    web editor) from a few consecutive screen snapshots over time.

    INPUT
    - chrome_tokens: words that appear in nearly every snapshot (tab names, menu /
      toolbar labels, "saving/saved", file name, URL fragments). These are app /
      browser CHROME, NOT the user's writing. IGNORE them everywhere.
    - snapshots: time-ordered OCR snapshots of the screen, each {ts, text}. Each
      text contains chrome PLUS the document body. The body is the prose the user
      is writing.

    TASK — compare the DOCUMENT BODY across consecutive snapshots:
    1. edits: between each pair of consecutive snapshots, detect body changes:
       - "commit": a sentence/paragraph of real prose appears that wasn't there
         before. text = the new prose (trimmed of chrome).
       - "delete": a sentence/paragraph of real prose that was present is now gone,
         net removal > ~15 chars. text = the removed prose.
       Use the LATER snapshot's ts for each edit.
    2. body_text: the single most COMPLETE, CLEAN document body you can read across
       these snapshots (usually the last/longest). Strip ALL chrome — output only
       the user's prose, paragraphs in order.

    CRITICAL — DO NOT INVENT. Accuracy beats completeness:
    - If a change might be OCR jitter, word-order scramble, scrolling, or chrome
      churn, DO NOT emit an edit. A missed edit is fine; a fabricated one is not.
    - NEVER emit an edit whose text is made of chrome_tokens / UI labels / URLs.
    - If you are unsure, emit fewer edits (or none). Never pad with noise.

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "edits": [ { "ts": <ms>, "kind": "commit|delete", "text": "<prose>" } ],
      "body_text": "<cleanest full document body, chrome stripped>"
    }

    HARD RULES
    - JSON string escaping: escape `"` → `\"`, `\` → `\\`, newlines → `\n`.
    - "kind" is EXACTLY "commit" or "delete".
    - edits sorted by ts ascending.
    - Respond with ONLY the JSON object, no prose / code fences.
    """#
}
