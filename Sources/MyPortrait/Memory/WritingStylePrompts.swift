import Foundation

/// writing_style 提炼链路的 LLM prompt 模板。
///
/// 输入数据由 WritingStyleAgent.buildPrompt 拼接 —— records / edit_log /
/// 已有 portrait/writing_style/ 现存条目。
enum WritingStylePrompts {

    /// 主提炼 prompt —— 让 LLM 看一批 records(含 edit_log 时序),归纳出
    /// "用户的写作 / 表达风格" 维度的多个独立 facet,每个 facet 一个文件。
    /// 跟 PortraitDistiller 风格保持一致 —— create / update / noop 决策模式。
    static let distill = #"""
    You analyze a batch of writing_records — every record is a piece of TEXT
    the user actually typed (chat reply, doc paragraph, commit message, etc.)
    — and extract long-term WRITING STYLE entries about the user.

    WRITING STYLE = how the user WRITES across contexts. Two layers:

    **(A) General dimensions** — describe HOW the user writes overall:
      - register & tone (casual / formal / terse / verbose)
      - language mixing (Chinese + English code-switching patterns)
      - signature phrasings, recurring openers / closers, emoji habits
      - punctuation habits (Chinese vs English quotes, ellipses, …)
      - editing rhythm visible in edit_log (write-once vs heavy-revision,
        delete-bursts before send, fragmentary drafts)
      - **input method** — infer from the final text + edit_log timing:
        * Pinyin IME: bursts of Latin letters in edit_log that get
          replaced by Chinese characters in one commit (candidate-pick);
          short pinyin runs (`zhongguo` → `中国`); occasional wrong-pick
          recoveries that delete a Chinese char then re-pick
        * Direct English: per-character commits of Latin letters, no
          delete-bursts of Latin → CJK substitutions
        * Wubi / Shape-based: very short Latin code (1-4 chars) → single
          CJK commit, rarely candidate-switching
        * Mixed / IME-switching habit: alternating runs (中文 then English
          then 中文) with brief pause between language switches in commit
          timestamps
        Only emit this facet if there's enough Chinese-language evidence
        to tell — skip for English-only batches.

    **(B) App / context / recipient-specific habits** — describe WHAT
        the user does in SPECIFIC situations. These are concrete,
        narrative-style observations like:
          * "user keeps replies to <person> in <chat-app> extremely
            short — single-clause sentences, often with light humor"
          * "user writes prompts to Claude in highly structured form —
            numbered steps + explicit constraints + example I/O"
          * "user's commit messages are 1-line imperatives, never
            multi-paragraph, even for big diffs"
        Each habit must name (a) the app or recipient, (b) the specific
        behavior, (c) what differentiates it from the user's other voices.

    **You MUST emit at least 1-2 (B)-type habits per run if the batch
    contains records from clearly different recipients / apps / tasks.**
    General (A) facets are useful but a portrait with only abstract
    "tone & register" entries is too vague — the user wants specific
    "I do X with Y" observations they'd recognize.

    Each record carries:
      - text          — the final written content
      - kind          — long_form / short_form / other
      - app, url      — where it was written
      - context_summary — what they were doing
      - edit_log      — JSON array of {kind:"commit"|"delete", text, ts}
                        in chronological order. Use it to read the EDITING
                        RHYTHM (lots of delete-bursts? one-shot writes?
                        revising a sentence repeatedly?).

    THE EDIT_LOG IS UNIQUE SIGNAL — pure OCR / final text cannot show
    revision rhythm. Read it carefully; behaviors like "writes a draft,
    deletes half, rewrites differently" or "types continuously without
    deletes" are real writing-style traits worth capturing when consistent.

    APP + CONTEXT ARE DIFFERENT VOICES — critical for accurate facets:
    The SAME user uses different voices in different contexts. Treat them
    as separate signals, don't conflate.

    Each record carries `app` (bundle id), often `url`, and a `context`
    line (a short one-sentence summary of what the user was doing —
    produced upstream by writing capture's own LLM pass over the typing
    + AX tree, so it already reflects the actual situation). Use
    `app` + `url` + `context` together to infer the voice/situation —
    DO NOT rely on a fixed app-to-context mapping. The same app can host
    different contexts (a code editor used to write a blog post, a
    browser used for both chat and search), and the user's app stack
    changes over time.

    Once you've inferred the situation, group records that share a
    coherent voice into the same facet, and keep records from clearly
    different situations in separate facets. A facet that mixes
    casual chat tone with structured technical prompts produces vague
    descriptions the user won't recognize.

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences.
    Top level is a JSON array (no wrapping object). Each item is one decision:
    [
      {
        "action":            "create" | "update" | "noop",
        "slug":              "snake_case_short",
        "title":             "Human-readable title",
        "body":              "Markdown body. **Open with a short one-line definition** of what this facet means so a reader who only sees the title can grasp it — wording / language / length is up to you, just make it read like a real definition rather than evidence. Then 2-4 sentences citing specific evidence — short quotes from text or descriptions of edit_log patterns. Third person about the user. Use \n for newlines.",
        "source_record_ids": [123, 124, 125],
        "existing_slug":     null
      }
    ]

    DECISION RULES:
    - "create" — a NEW style facet, no existing entry covers it. Leave
      existing_slug = null. Slug = snake_case ≤ 40 chars. Examples:
      * General (A): "chat_brevity", "delete_burst_revision",
        "bilingual_register_split", "pinyin_ime_candidate_pick"
      * Specific (B): "chat_with_sarah_terse_humor",
        "claude_prompts_structured", "git_commits_one_line_imperative"
      For (B), include the app/recipient in the slug itself.
    - "update" — the new evidence REFINES an existing entry. Set
      existing_slug = the target slug from the EXISTING ENTRIES block.
      Merge into existing prose; do not rewrite from scratch. Body should
      represent the merged, final state of the entry after this update.
    - "noop" — nothing strong enough to write about this batch in this
      direction. Skip. Do NOT pad output with noop items just to be polite —
      only emit noop if there's a meaningful reason to record one.

    HARD RULES (violations make the output invalid):
    - Third person always — "the user" / "they". Never "you".
    - body MUST cite specific evidence. NO generic claims like "the user
      writes casually." Quote a phrase, describe an edit_log pattern, or
      contrast across multiple records.
    - source_record_ids: include every record id that supports this
      decision. A record id MAY appear under multiple decisions if it
      genuinely supports multiple style facets.
    - slug uses snake_case, ≤ 40 chars, lowercase.
    - Only emit a decision when the evidence in THIS BATCH actually
      supports it. Don't echo the existing entries unchanged.
    - JSON string escaping: any `"` inside a string value MUST be `\"`,
      `\` → `\\`, newlines → `\n`.

    EDGE CASES:
    - Batch is mostly noise (single-word commits, identical fragments) →
      output a single-element noop or an empty array []. Empty array is
      acceptable.
    - An entry in EXISTING ENTRIES is now wrong / overstated and this
      batch contradicts it → emit an "update" that softens / corrects
      that entry's body.
    """#
}
