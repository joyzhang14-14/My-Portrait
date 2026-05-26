import Foundation

/// speech_style 提炼链路的 LLM prompt 模板。
///
/// 输入数据由 SpeechStyleAgent.buildPrompt 拼接 —— records / edit_log /
/// 已有 portrait/speech_style/ 现存条目。
enum SpeechStylePrompts {

    /// 主提炼 prompt —— 让 LLM 看一批 records(含 edit_log 时序),归纳出
    /// "用户的写作 / 表达风格" 维度的多个独立 facet,每个 facet 一个文件。
    /// 跟 PortraitDistiller 风格保持一致 —— create / update / noop 决策模式。
    static let distill = #"""
    You analyze a batch of writing_records — every record is a piece of TEXT
    the user actually typed (chat reply, doc paragraph, commit message, etc.)
    — and extract long-term SPEECH STYLE entries about the user.

    SPEECH STYLE = how the user TALKS / WRITES across contexts:
      - register & tone (casual / formal / terse / verbose)
      - language mixing (Chinese + English code-switching patterns)
      - signature phrasings, recurring openers / closers, emoji habits
      - punctuation habits (Chinese vs English quotes, ellipses, …)
      - editing rhythm visible in edit_log (write-once vs heavy-revision,
        delete-bursts before send, fragmentary drafts)
      - voice differences across contexts (chat-app voice vs editor voice)

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
    deletes" are real speech-style traits worth capturing when consistent.

    APP + CONTEXT ARE DIFFERENT VOICES — critical for accurate facets:
    The SAME user uses different voices in different contexts. Treat them
    as separate signals, don't conflate.

    Each record carries `app` (bundle id), often `url`, and an
    `ocr_context` snippet (what was on screen at the time — given for
    short text records to disambiguate the situation). Use these to infer
    the situation yourself — DO NOT rely on a fixed app-to-context
    mapping. The same app can host different contexts (a code editor used
    to write a blog post, a browser used for both chat and search), and
    the user's app stack changes over time. Read `app` + `url` +
    `ocr_context` together each time.

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
        "body":              "Markdown body, multiple sentences, third person about the user. Cite specific evidence — short quotes from text or descriptions of edit_log patterns. Use \n for newlines.",
        "source_record_ids": [123, 124, 125],
        "existing_slug":     null
      }
    ]

    DECISION RULES:
    - "create" — a NEW style facet, no existing entry covers it. Leave
      existing_slug = null. Slug = snake_case ≤ 40 chars (e.g.
      "chat_brevity", "delete_burst_revision", "bilingual_register_split").
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
