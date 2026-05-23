import Foundation

/// 写作采集 worker 的 LLM prompt 模板。
///
/// 这里只放静态指令文本(英文,跟 MemoryPrompts 风格一致)。运行时数据
/// (OCR 帧列表 / Pass 1 输出 / 候选集...)由各 agent 的 `buildPrompt` 拼接。
///
/// prompt 文本完整版见 `canvas-editor-capture-design-final.md` §8。
enum WritingCapturePrompts {

    // MARK: - Pass 1 —— Context Timeline 提取(整天 1 次,OCR-only)

    static let pass1ContextTimeline = #"""
    You analyze a day's worth of OCR data and produce a TIMELINE of what the user was DOING throughout the day.

    INPUT (all timestamps in unix ms, sorted ascending)
    - ocr_frames: list of OCR text frames per time range, with focused app/URL metadata.
      Pre-processed: adjacent frames with >95% Jaccard similarity have been deduped,
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

    // MARK: - Pass 2 —— 多源融合 → writing_records(整天 1 次)

    static let pass2Fusion = #"""
    You consolidate a day's writing into final writing_records, using a Pass-1 context
    timeline plus raw multi-source data grouped by session.

    INPUT
    - context_timeline: Pass 1 output, segments describing what user was doing per time range.
      Format: [{start_ts, end_ts, app, url, intent_type, summary}, ...]
    - raw_sessions: list of sessions, each with all its multi-source data:
      [{session_id, app, url, start_ts, end_ts,
        typing_events, keystroke_log, ocr_frames}, ...]
        - typing_events[*]: PRE-PROCESSED AX path data (v14 splice algorithm).
          `text` is the FINAL user-perceived content. DO NOT modify it.
          `edit_log` contains commit/delete events (may include IME intermediate pinyin commits).
        - keystroke_log[*]: raw keystrokes [{ts, char, bs, mods}]. IMPORTANT:
          - `char` for Chinese IME = LATIN pinyin letters (n, i, h, a, o, space, digit
            selection keys) — NOT composed Chinese.
          - `bs` = true means user pressed Backspace/Delete key (single press; 1 bs
            ≠ 1 char deleted when there was a selection).
          - `mods` = modifier-key combo: "cmd" / "opt" / "ctrl" / "shift" or combos like
            "cmd+shift". nil/absent = no modifier. USE THIS TO DETECT SHORTCUTS:
            * {char:"x", mods:"cmd"}  = ⌘X (Cut) — content is on the pasteboard, NOT typed
            * {char:"z", mods:"cmd"}  = ⌘Z (Undo) — earlier edits got reverted
            * {char:"a", mods:"cmd"}  = ⌘A (Select all) — next bs/letter affects whole field
            * {char:"v", mods:"cmd"}  = ⌘V (Paste) — content from pasteboard, not typed
            * {char:"\b", mods:"cmd"} = ⌘+Backspace (delete whole line) — multi-char delete
            Shortcut-driven actions are NOT user "typing" the literal letter.
        - ocr_frames[*]: pre-processed OCR frames [{frame_id, start_ts, end_ts, text}].
          Jaccard-deduped, throwaway-filtered.
    - merge_candidates: precomputed groups of session_ids sharing same app + same URL + gap < 30 min.
      Format: [[sess_id, ...], [sess_id, ...], ...]
      The LLM may merge ONLY WITHIN a group.

    TASK

    For each merge_candidates group, decide what writing_records to produce, using context_timeline
    to inform decisions about INTENT.

    1. THROWAWAY FILTER — drop sessions into "discarded" where user was NOT creatively writing.
       Use context_timeline.intent_type as a STRONG signal:
       - intent_type = "writing"              → KEEP as record
       - intent_type = "search" / "command"   → likely throwaway
       - intent_type = "chat"                 → likely throwaway (short responses) — but if a session
                                                 has > 200 chars of substantive composing, keep
       - intent_type = "reading" / "other"    → judge by content

       Reference categories for discarded.reason (prefix REQUIRED, free-text suffix allowed):
       - "search_query: ..."    — "量子力学", "how to fix gradient descent"
       - "short_response: ..."  — "ok", "好的", "嗯嗯"
       - "shell_command: ..."   — "ls", "cd ~", "git status"
       - "address_bar: ..."     — "https://...", "docs.google.com"
       - "filler_text: ..."     — "aaaaa", "test test"
       - "repeated_input: ..."  — same word typed over and over
       - "no_intent: ..."       — ≥ 20 chars but obviously not creative writing
       - "other: ..."           — describe in free-text

       Length is NOT the sole criterion. 50-char self-narration like
       "我去查一下量子力学是什么后来发现是这样的" is still a search-style throwaway.
       CORE TEST: was there CREATIVE INTENT? Writing article / message / notes = yes.
       Searching / form-filling / responding / running commands = no.

    2. CROSS-SESSION MERGE — only WITHIN merge_candidates groups.
       - Content continuous (user writes article, replies to a message, returns to article) → MERGE
       - Same doc but unrelated topics → KEEP SEPARATE
       - Cross-group: NEVER merge (different app / URL / > 30 min gap)
       - Group with single session → 1 record, no merge needed

    3. SOURCE LABELING per output record:
       - typing_events.text non-empty AND scales with OCR body length (gap < 50 chars
         OR ax_value_length ≈ keystroke-derived length) → "ax_cleaned"
       - typing_events empty OR much shorter than OCR / keystroke count
         (gap > 50 chars OR keystroke_count >> ax_value_length) → "canvas_fusion"
       - Merged sessions of different sources → "merged"

    4. CONTENT RECONSTRUCTION

       For AX path ("ax_cleaned"):
       - text = typing_events.text (DO NOT modify — v14 splice already cleaned it)
       - edit_log = filter intermediate events from typing_events.edit_log:
         * DROP ASCII-letter commits immediately followed by Chinese commit in the same window
           (these are IME intermediates: "j" → "ji" → "jin" → delete → "今")
         * KEEP final Chinese / English commits
         * COALESCE continuous backspace runs into 1 "delete" entry, text = the deleted content
         * COALESCE continuous "commit" entries with no delete between into 1 "commit"

       For canvas path ("canvas_fusion"):
       - text = reconstructed from OCR (Step-0-deduped) + keystroke timing
       - Strip IME residue from OCR text tail: if AX value ends with ASCII letters matching
         recent keystrokes but no subsequent Chinese commit / backspace → residue → drop.
         Example: OCR shows "今天天气真好,我们 wen f", keystrokes show w-e-n-space-f typed
         without a digit selection key → "wen f" is residue → text = "今天天气真好,我们"
       - edit_log = synthesized from OCR diff between frames + keystroke backspace clusters

    5. FIELDS per record:
       - text, edit_log, source: per above
       - confidence: AX path with clean data → high (0.8+); canvas with clean OCR + matching
         keystrokes → high (0.7+); merged sessions → take MIN of constituents (conservative);
         heavy noise / sources strongly disagree → low (< 0.5)
       - context_summary: pull from context_timeline segment matching the record's time range;
         if record spans multiple context segments, synthesize ≤ 100 chars
       - app, url: shared by the merge group
       - start_ts: earliest session.start_ts in the merge
       - end_ts: latest session.end_ts in the merge
       - reference_typing_event_ids: concatenated typing_event ids from all merged sessions
       - reference_frame_ids: concatenated frame ids from all merged sessions
       - reference_keystroke_range: {start: earliest keystroke ts, end: latest keystroke ts}

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "records": [
        {
          "text": "...",
          "edit_log": [
            {"kind": "commit", "text": "今天天气真好", "ts": 1716393600000},
            {"kind": "delete", "text": "今天", "ts": 1716393605000}
          ],
          "source": "ax_cleaned",
          "confidence": 0.85,
          "context_summary": "Personal journal entry about weather",
          "app": "md.obsidian",
          "url": null,
          "start_ts": 1716393600000,
          "end_ts":   1716393700000,
          "reference_typing_event_ids": [123, 124],
          "reference_frame_ids":        [456, 457],
          "reference_keystroke_range":  {"start": 1716393600000, "end": 1716393700000}
        }
      ],
      "discarded": [
        {
          "reason":       "search_query: looked up quantum mechanics",
          "session_ids":  ["sess_abc"],
          "preview":      "量子力学"
        }
      ]
    }

    HARD RULES (a violation makes the output invalid)
    - Every input raw_session_id from merge_candidates appears EXACTLY ONCE — either inside
      some record (via reference_*_ids of its constituent sessions) or in "discarded.session_ids"
    - A session_id NEVER appears in both records and discarded
    - "source" is EXACTLY one of: "ax_cleaned" | "canvas_fusion" | "merged"
    - "discarded.reason" prefix MUST start with one of:
        "search_query:" | "short_response:" | "shell_command:" | "address_bar:" |
        "filler_text:" | "repeated_input:" | "no_intent:" | "other:"
      followed by ≤ 200 chars free-text description
    - "context_summary" ≤ 100 chars per record
    - "kind" in edit_log is EXACTLY "commit" or "delete"
    - edit_log is sorted by ts ascending
    - AX path output: text MUST EQUAL typing_events.text (do NOT modify)
    - Respond with ONLY the JSON object, no markdown / prose / code fences

    EDGE CASES
    - Whole group is throwaway → all sessions in "discarded", no record from this group
    - Group with no typing_events AND no usable OCR → put all sessions in discarded with reason "no_intent: empty session"
    - Sources conflict badly → output the most likely version + low confidence + still include the record
    """#
}
