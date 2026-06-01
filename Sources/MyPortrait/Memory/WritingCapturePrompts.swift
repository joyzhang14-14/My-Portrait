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
        • You may name the actual app from the given app metadata, but describe the
          SURFACE generically — do NOT special-case or assume any particular app in
          this prompt ("a messaging window", "a long-form document editor", "a code
          editor with multiple tabs", "a repo page on a code host", "a terminal").
        • DO NOT include the user's typed content, the conversation topic,
          or what their document is about.
          BAD: "Says it can store years of data" / "Discussing AI usage limits"
          GOOD: "Chatting with one peer in a messaging window"
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

    // MARK: - Pass 3 —— per-(app, URL) group 多源融合 → writing_records

    static let pass3Fusion = #"""
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

    CANVAS EDIT-HISTORY RECONSTRUCTION (document-style editors where AX exposes nothing)
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

    1. ONE UNIT = ONE RECORD (pre-segmented), TRANSCRIBE ONLY WHAT THE USER TYPED
       Each AX-path session has ALREADY been segmented (pass2-2, by typing_event)
       to ONE unit the user produced — one sent message. Canvas/OCR sessions are
       whole documents. So:
       - DEFAULT: emit ONE record per session. Do not merge sessions. Only split a
         session into 2+ records in the RARE case its single unit obviously holds
         multiple distinct sent messages.
       - First read keystroke_text / keystroke_log — ground truth for what the user
         physically produced. Use it to anchor the record, then confirm against AX.
       - AUTHORSHIP TEST — only the user's own input becomes a record. In chat /
         canvas / any app whose screen also shows text the user did NOT type — an
         assistant's reply, a received message, earlier conversation history, a
         page being read — that text has little or no backing keystroke activity.
         Do NOT transcribe it. A record's text must be a stretch that
         keystroke_text / typing_events actually account for.
       - Source priority per stretch: keystroke (truth of what was typed) →
         typing_events.text when AX has meaningful content matching the keystrokes
         (trust AX text, lightly fix only where it disagrees with keystrokes) →
         ocr_frames only when typing_events is empty (canvas / keystroke-swallowing
         apps), and even then keep ONLY the portion the user authored (keystroke
         volume in that window confirms authorship; on-screen text with zero
         corresponding keystrokes is reading/received content, not the user's).

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
       Translate every session you receive into a record. A separate Pass 4
       gate decides what to drop based on keystroke-support evidence. Your
       job here is purely transcription + segmentation + cleanup.
       - If a session is noisy BUT user-typed (keystroke residue, odd/short
         wording, self-paste): STILL emit a record — Pass 4 decides quality.
         "Noisy user input" ≠ "not the user's content".
       - A session that is PURELY non-user content (assistant reply, received
         message, a page being read — zero user authorship per the AUTHORSHIP
         TEST above) yields NO record. That is not discarding the user's writing;
         it was never the user's writing.
       - Do not include `discarded` in your output. Output `records` only.
       - Every session WHERE THE USER AUTHORED SOMETHING must appear in at least
         one record's `reference_*_ids`.

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
       For AX path (typing_events.text is the source):
       - text = typing_events.text, but FIX small AX-capture flaws using the
         keystroke evidence (keystroke is ground truth for what was typed):
         * IME phonetic that never composed: if the field shows a latin pinyin
           fragment where a character belongs (e.g. text ends "...什么dian" while the
           keystrokes show the user typed the pinyin for 店), COMPLETE it to the
           character the user clearly meant → "...什么店".
         * Drop stray trailing phonetic residue / half-composed tokens the keystrokes
           show were abandoned.
         Only fix what the keystrokes CLEARLY support. Do NOT invent, rephrase, or
         "improve" wording — keep the user's exact phrasing and typos.
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
         Describe the surface generically — do NOT special-case any app.
         GOOD: "Chatting with one peer in a messaging app" / "Drafting a long note
               in a notes app" / "Replying in a team chat channel" / "Editing Swift
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
      record's `reference_*_ids` (no `discarded` in this pass — Pass 4 handles it)
    - "kind" is EXACTLY one of: "long_form" | "short_form" | "other"
    - "source" is EXACTLY one of: "ax_cleaned" | "canvas_fusion" | "merged"
    - "context_summary" ≤ 100 chars per record
    - "kind" in edit_log entries is EXACTLY "commit" or "delete"
    - edit_log is sorted by ts ascending
    - AX-path output: text MUST EQUAL typing_events.text (do NOT modify content)
    - Respond with ONLY the JSON object, no markdown / prose / code fences

    EDGE CASES
    - Group has only OCR (no typing/keystroke) → still try to reconstruct from OCR
      and emit a record (Pass 4 will judge if it's user-produced)
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

    // MARK: - Pass 4 —— 内容审查(records → kept / discarded)

    static let pass4ContentReview = #"""
    You are the FINAL content-review gate. Earlier algorithmic steps already removed
    pasted / OCR-orphan / no-edit content. Your job now is purely SEMANTIC: read each
    record's TEXT and decide whether it is the user's own natural-language writing
    worth keeping. Each record also carries `keystroke_count` = how many keys the user
    physically pressed to produce it — use it as hard evidence of authorship.

    We want to KEEP the user's natural-language writing: messages, chat replies,
    notes, essays, posts, questions, journal-like prose — anything the user composed
    in words. Be GENEROUS: short messages count, casual replies count, text that
    naturally mixes the user's languages counts. When a record reads as something a
    person wrote, KEEP it. (Judge "real language" by whether it reads as coherent
    human writing in ANY language — never assume one specific language.)

    INPUT
    - records: [{ record_id, text, kind, source, app, url, keystroke_count,
      context_summary }]
      context_summary = what the user was doing then (scene), from Pass 1.
      keystroke_count = physical keys the user pressed in this record's time window.
    - user_rejected_examples (optional): records the user manually rejected before,
      with their reason. Treat new records that match these patterns the same way.

    AUTHORSHIP — keystroke_count is decisive for "is this the user's own writing":
    - keystroke_count > 0 means the user PHYSICALLY TYPED this text. Then it IS the
      user's own writing — KEEP it even if it LOOKS like a heading / title / short
      label / page-like phrase (e.g. a doc title the user is typing). A typed title is
      still the user's writing. NEVER discard a typed record as "page/title text shown
      in the browser" or "something shown to them" — that only applies to text the
      user did NOT type.
    - keystroke_count ≈ 0 means the text appeared on screen without the user typing
      (a page title, a received message, an AI reply, an article being read) → that is
      what rule 2 below targets.
    - (This does NOT override rules 1/3/4: typed CODE/commands, typed gibberish, or
      typed matches of a rejected pattern are still discarded.)

    DISCARD a record when its TEXT is any of:
    1. CODE / COMMANDS / CONFIG — source code, shell/terminal commands, config, or
       program output. Tells: `uv install`, `cd`, `git`, `npm`, `pip`, brackets/
       semicolons/`def`/`func`/`import`/`=>`, JSON/YAML, file paths, or text clearly
       inside a code editor / terminal surface. We only want natural-language writing,
       so drop code even though the user typed it. (Mostly-prose with an inline code
       token → KEEP.)
    2. NOT THE USER'S WRITING (almost always keystroke_count ≈ 0) — an AI assistant's
       reply / coaching addressed to the user, a received chat message from someone
       else, a UI label / username banner / tab name / app chrome / page or document
       title shown on screen, or an article/page the user was only reading. Use
       context_summary + the text's voice + keystroke_count (did the user TYPE it, or
       was it shown TO them?). If keystroke_count > 0, it was typed → do NOT discard
       under this rule.
    3. NOT REAL LANGUAGE — uncomposed IME residue (loose pinyin/romaji that never
       became words, e.g. "ei qu a xi", "uan x b sei"), random char soup, masked
       secrets ("•••"), a bare autofilled email/name, empty / whitespace-only /
       single stray char / repeated gibberish.
    4. MATCHES a user_rejected_example pattern (same kind of junk the user rejected
       before).

    Otherwise KEEP. Bias toward KEEP for anything that reads as the user's own words.

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
    You are reconstructing the EDIT HISTORY of ONE document (a document-style editor
    whose field exposes no accessibility text) from a few consecutive screen
    snapshots over time.

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
    2. body_text: the single most COMPLETE document body you can read across these
       snapshots (usually the last/longest). Strip ONLY chrome (menus / tabs / URLs);
       keep the user's prose, paragraphs in order.

    CRITICAL — TRANSCRIBE VERBATIM. Do NOT "fix" or polish the user's writing:
    - Copy the body EXACTLY as it appears on screen. Preserve the user's spelling,
      grammar, typos, capitalization, numerals, contractions, and punctuation as shown.
      Do NOT correct grammar, fix misspellings, spell digits out into words, add /
      remove / reorder words, change capitalization, or otherwise "improve" the prose.
      The user's imperfect wording and style ARE the data we want — normalizing it
      DESTROYS it.
    - "Strip chrome" means remove UI furniture only (menus / tabs / URLs); it does NOT
      mean grammar-correct, rephrase, pluralize, re-number, or improve readability.
    - NARROW OCR EXCEPTION — repair ONLY pure glyph-shape misreads, never the user's
      words. The scanner sometimes garbles letter SHAPES, yielding a NON-WORD whose
      intended common word is obvious: e.g. "rn"↔"m", "l"↔"I"↔"1", "cl"↔"d", a doubled
      letter, a quote / paren scanned as a stray symbol, or full-width vs half-width
      punctuation. You MAY repair such a glyph-mangle with a MINIMAL character swap.
      You may NOT touch anything a person could plausibly have typed themselves — real
      typos (wrong tense, a missing / extra word), grammar, word choice, a digit vs.
      spelled-out number, casual punctuation. Test each oddity: "could a human have
      typed THIS on purpose or by a normal slip?" If yes → KEEP verbatim. Only when it
      reads as the scanner mangling letter shapes → repair. When unsure → KEEP.

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

    /// Canvas 多窗 body 合并 —— 各窗只看到文档一个滚动片段(标题在早窗、结尾在
    /// 晚窗),把它们拼成整篇。只合并/去重,不发明。
    static let canvasMerge = #"""
    You are given several reconstructions of the SAME document. Each was recovered
    from a different time-window of screen snapshots; because the user scrolled while
    writing, each fragment may be PARTIAL — one holds the opening (title / heading /
    intro), another the middle paragraphs, another the ending. They overlap.

    Produce the SINGLE most COMPLETE version of the document body:
    - UNION all distinct prose, in natural reading order: title/heading first (if any
      fragment has one), then the body paragraphs in order, then the ending.
    - Where fragments overlap (the same passage appears in two), MERGE them into one —
      never duplicate a repeated sentence/paragraph.
    - Keep the user's EXACT wording, punctuation, language, line breaks. Do NOT
      translate, rephrase, summarize, reorder sentences, or INVENT any sentence that is
      not present in at least one fragment. Accuracy beats completeness.
    - TRANSCRIBE VERBATIM — never grammar-correct or polish. Preserve the user's exact
      spelling, typos, capitalization, and numerals as written; do not add, remove, or
      reorder words. When two fragments render the same passage differently, prefer the
      one matching the user's raw imperfect wording, NOT the "cleaner" / corrected one.
    - Drop any leftover UI / chrome lines (menu labels, tab names, URLs, "saving…").

    OUTPUT — respond with ONLY this JSON object, no prose / markdown fences:
    { "body_text": "<the single most complete document body>" }
    - JSON escaping: `"` → `\"`, `\` → `\\`, newlines → `\n`.
    """#

    // MARK: - Pass 2 —— 切割 + AX 真伪判断(judgment only)

    /// Pass 2 只判断、不转写:把一个 session 的 typing_events 切成单元 + 判每条
    /// AX 真伪。轻量模型可胜任。keystroke + OCR 是不会说谎的对照物,只判 AX。
    static let axCleanup = #"""
    You FIX small input-capture flaws in short user messages. Each item gives the
    captured `text` and the `keystroke` the user physically pressed (<BS>=backspace,
    <CR>=Return; for IME this is the latin phonetic the user typed).

    The ONLY thing you fix: IME phonetic that never composed into a character — the
    text shows a latin pinyin/romaji fragment where a character belongs. Using the
    keystrokes, COMPLETE it to the character the user clearly meant.
      e.g. text "这是一家什么dian", keystroke "...shi yi jia shen me dian" → "这是一家什么店"
    Also drop abandoned trailing phonetic residue the keystrokes show was deleted.

    DO NOT "complete" a latin token that is plausibly a PROPER NAME (person / place /
    product), an English word the user wrote ON PURPOSE, or an intentional romanization
    — leave those EXACTLY as typed. Only complete when the latin is UNAMBIGUOUSLY
    leftover pinyin the IME failed to turn into the ONE obviously-intended common word
    in context. A romanized foreign name stays as typed — NEVER guess it into homophone
    characters. When in ANY doubt whether a latin run is residue vs. intended latin,
    LEAVE IT UNCHANGED (a kept romanization beats a wrong guess).

    HARD limits — do NOT do anything else:
    - Do NOT translate, rephrase, summarize, reorder, merge, split, censor, or
      "improve". Keep the user's EXACT wording, typos, punctuation, language, emoji.
    - Fix ONLY what the keystrokes clearly support. If unsure, leave it UNCHANGED.
    - If nothing needs fixing, return the text UNCHANGED.
    - Return EVERY input id exactly once with its (fixed or unchanged) text.

    Also rate `confidence` ∈ [0,1] — how sure you are this is clean, complete user
    writing that the keystrokes account for. ~0.95+ when the keystrokes clearly
    produced the text and it reads as a finished message; ~0.75–0.9 with IME
    ambiguity / some residue you had to judge; ~0.6 when keystroke support is thin or
    the text looks like an unfinished fragment.

    OUTPUT — respond with ONLY this JSON object, no prose / fences:
    { "fixed": [ { "id": "<id>", "text": "<text>", "confidence": <0..1> }, ... ] }
    - JSON escaping: `"` → `\"`, `\` → `\\`, newlines → `\n`.
    """#

    static let pass2Segment = #"""
    You are a JUDGE for ONE activity session. You decide two things:
    (1) ROUTE — is the user's real input in AX (typing_events) or only on screen (OCR)?
    (2) CUT — split the user's input into individual units (one sent message, or one
        continuously-composed piece).
    You output event_ids + route ONLY. You do NOT rewrite or produce final text.

    SOURCES:
    - typing_events (AX): [{id, ts, text}] in time order — what the input field
      exposed. Usually the user's typing, but can be autofill / paste / program-
      inserted text shown as if typed.
    - keystroke_text / keystroke_count: physical keys the user actually pressed
      (<BS>=backspace, <CR>=Return/Enter/submit; pure shortcuts excluded). For IME
      (e.g. pinyin) this is the LATIN phonetic, ~1.5–3× the composed CJK length.
      Keystrokes cannot lie about what was physically typed.
    - ocr_excerpt: text seen on screen (cross-check).

    Judge everything from the EVIDENCE (AX vs keystroke vs OCR correspondence).
    NEVER decide from which app it is — the same rules apply to every app.

    TASK 0 — ROUTE ("ax" | "ocr"), decide FIRST:
    - "ax" (the normal case): typing_events contain coherent text in the user's
      language that the keystrokes plausibly account for (ASCII ≈ length; IME latin
      phonetic ≈ 1.5–3× CJK chars). The field exposed what the user typed. The OCR may
      ALSO show received messages / an assistant's reply / other on-screen text —
      IGNORE all of that; only typing_events are the user's own input.
    - "ocr": typing_events are empty OR incoherent junk (stray/invisible chars,
      mojibake, fragments) that does NOT correspond to the keystrokes, AND the user
      clearly composed real content that appears only in ocr_excerpt — i.e. AX failed
      for a document-style editor and the real writing is on screen.
    - When unsure → "ax".

    TASK 1 — CUT INTO UNITS (when route = "ax"):
    - One unit = one thing the user produced: usually ONE sent message, or ONE
      continuously-edited piece.
    - DEFAULT: each typing_event is its OWN unit (one event = one sent message).
      Two distinct messages are NEVER merged, even if sent seconds apart. MERGE two
      events into one unit ONLY when a later event is literally the SAME text growing
      (an unsent draft being extended — later text starts with / contains the earlier).
      When in doubt, DO NOT merge (more units is safer than fewer).
    - Decide each boundary YOURSELF from the evidence. Do NOT assume Return always
      ends a unit, and do NOT assume only time gaps separate units. Weigh BOTH:
      · a Return/submit (<CR> in keystroke_text, or the field clears afterward) often
        ends a sent message — but a multi-line message contains Returns mid-unit;
      · a large TIME GAP between consecutive events' ts often separates two messages —
        but two quick messages may have almost no gap;
      · consecutive events whose text GROWS the same piece (later extends earlier) are
        ONE unit.
      Use the actual content to judge which signal wins for each boundary.
    - Every typing_event id goes into exactly one unit. Do NOT drop anything here;
      cleanup and discarding happen in later passes.

    OUTPUT — respond with ONLY this JSON object, no prose / markdown fences:
    {
      "primary_source": "ax" | "ocr",
      "units": [ { "event_ids": [<id>, ...] } ]
    }
    - route "ocr": units may be [] — the OCR path reconstructs the content.
    - route "ax": every typing_event id appears EXACTLY ONCE across units;
      each unit's event_ids are time-ordered.

    HARD RULES
    - JSON string escaping: `"` → `\"`, `\` → `\\`, newlines → `\n`.
    - Respond with ONLY the JSON object, no prose / code fences.
    """#
}
