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
      Pre-processed: adjacent frames with >85% Jaccard similarity have been deduped,
      and frames where total text < 20 chars have been filtered out.
      Format: [{frame_id, start_ts, end_ts, app, url, text}, ...]

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
      [{session_id, start_ts, end_ts, typing_events, keystroke_log, ocr_frames}, ...]
        - typing_events[*]: PRE-PROCESSED AX path data (v14 splice algorithm).
          `text` is the FINAL user-perceived content. DO NOT modify it.
          `edit_log` contains commit/delete events.
        - keystroke_log[*]: raw keystrokes [{ts, char, bs, mods}].
          - `char` for Chinese IME = LATIN pinyin letters — NOT composed Chinese
          - `bs` = backspace/delete pressed
          - `mods` = "cmd" / "cmd+shift" / etc.; nil = no modifier. Use this to
            detect shortcuts:
              {char:"x", mods:"cmd"}  = ⌘X (Cut) — content went to pasteboard
              {char:"z", mods:"cmd"}  = ⌘Z (Undo)
              {char:"v", mods:"cmd"}  = ⌘V (Paste)
              {char:"\b", mods:"cmd"} = ⌘+Backspace (delete whole line)
            Shortcut-driven actions are NOT user "typing" the literal letter.
        - ocr_frames[*]: pre-processed OCR text [{frame_id, start_ts, end_ts, text}].
          Already Jaccard-deduped and short-content-filtered.

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
       Use free-text reason describing why.
       DO NOT drop just because content is short — short messages are SIGNAL.
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
