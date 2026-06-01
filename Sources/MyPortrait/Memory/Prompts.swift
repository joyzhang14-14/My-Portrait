import Foundation

/// All LLM prompt templates for the memory pipeline, centralised so the
/// instruction text lives in one place instead of being scattered across
/// EventBuilder / ImpactScorer / PortraitDistiller.
///
/// Only the STATIC instruction text lives here. The dynamic data (session
/// lists, event lists, active-event catalogues) is still assembled in each
/// caller's `buildPrompt` and concatenated with these templates.
enum MemoryPrompts {

    // MARK: - About the user(用户手填的基础画像,顶部 prefix)

    /// 用户在 Memories → Personal Info 填的基础画像,拼成一段
    /// "About the user:" 文本,放在所有 memory pipeline prompt 的最顶部。
    /// 没填的字段不进 prompt;全空 → 返回 ""(调用方判空跳过)。
    ///
    /// 参数:caller 先在 MainActor 上拿 snapshot 再传进来。这样函数本身
    /// 是 nonisolated,可以从 buildPrompt(nonisolated static)调用。
    nonisolated static func aboutUserBlock(_ p: PersonalInfoConfig) -> String {
        var lines: [String] = []

        // 姓名:把 first/middle/last 拼起来。任一为空就跳过那段。
        let nameParts = [p.firstName, p.middleName, p.lastName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !nameParts.isEmpty {
            lines.append("- Name: \(nameParts.joined(separator: " "))")
        }

        let alias = p.alias.trimmingCharacters(in: .whitespaces)
        if !alias.isEmpty { lines.append("- Also goes by: \(alias)") }

        // 代称 —— LLM 写第三人称叙述时用得到。
        switch p.gender {
        case .he:   lines.append("- Pronouns: he/him")
        case .she:  lines.append("- Pronouns: she/her")
        case .they: lines.append("- Pronouns: they/them")
        case .unset: break
        }

        let nat = p.nationality.trimmingCharacters(in: .whitespaces)
        if !nat.isEmpty { lines.append("- Nationality: \(nat)") }

        let eth = p.ethnicity.trimmingCharacters(in: .whitespaces)
        if !eth.isEmpty { lines.append("- Ethnicity: \(eth)") }

        let langs = p.languages
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !langs.isEmpty {
            lines.append("- Speaks: \(langs.joined(separator: ", "))")
        }

        let bd = p.birthDate.trimmingCharacters(in: .whitespaces)
        if !bd.isEmpty { lines.append("- Date of birth: \(bd)") }

        guard !lines.isEmpty else { return "" }
        return "About the user (self-reported):\n" + lines.joined(separator: "\n")
    }

    // MARK: - EventBuilder — per-event clustering

    /// Clusters Tier-1 sessions into semantic events. The caller appends the
    /// date line, active-events block, and session block after this.
    static let eventClustering = #"""
    You cluster raw activity SESSIONS into semantic EVENTS for a personal portrait system.

    An EVENT is what the USER was doing (subject + intent), NOT which app was open.
    Multiple sessions of the same activity (e.g. opening WeChat 18 times to chat
    with the same person) are ONE event. Sessions across different apps that serve
    one task (research in Safari → notes in Notes) are ONE event.

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "events": [
        {
          "title": "...",
          "summary": "...",
          "type": "experience",
          "tags": ["..."],
          "portrait_facets": [],
          "session_ids": [1, 4, 9],
          "join_existing": null
        }
      ],
      "skipped": [3, 7]
    }

    HARD RULES (a violation makes the whole output invalid):
    - EVERY input session id MUST appear EXACTLY ONCE — either inside some
      event's "session_ids", or in the top-level "skipped" array.
    - "title": ≤ 60 chars, describes what the user was DOING. NEVER "App — Window".
    - "summary": REQUIRED, 3-5 sentences, MUST cite specific topics / names /
      actions visible in the OCR. NEVER write "the user used X app". If no OCR
      supports a summary, the session belongs in "skipped", not in an event.
    - THIRD PERSON always — "the user" / "they", never "you".
    - "type": "experience" (default, 99%) or "emotion" (only a clear emotional
      signal in the OCR — frustration, joy, conflict, anxiety).
    - "session_ids": non-empty list of the ids this event covers.
    - "join_existing": if this event continues a candidate listed in EARLIER
      TODAY or PAST DAYS above, put its id (e.g. "_b3" or a path id);
      otherwise null.
      The two sections have different semantics — apply different thresholds:
        • EARLIER TODAY → joining MERGES the new sessions into the existing
          same-day event (one event, more sessions). Be AGGRESSIVE: join
          whenever subject / person / project overlaps at all. Same-day
          fragments of one conversation or task with slightly different
          wording ("chatted with X" vs "talked with X about Y") → same event,
          MUST join. Creating two separate events for the same same-day
          subject is a bug.
        • PAST DAYS → joining adds ONE OCCURRENCE to a recurring activity.
          Be SELECTIVE: only join when this really IS a continuation —
          same recurring routine, same multi-day project session, same
          ongoing conversation. A different episode of similar activity →
          NEW event, do NOT join (otherwise occurrences become noise).
    - "skipped": sessions with no real content (idle glance, no meaningful OCR).

    portrait_facets — optional, default []. Only attach when the event reflects a
    STABLE signal about who the user is. Each facet: {"facet": "<name>", "value": "<short>"}.
      background    — STRICTLY demographic / biographical facts (age, location,
                      education, family, occupation). NOT "background app".
      social        — specific named people in the user's life.
      interests     — topics/domains the user repeatedly engages with by choice.
      skills        — a capability the user is practicing, with evidence.

    WRITING THE SUMMARY — be concrete:
      ❌ "The user was chatting on WeChat."
      ✅ "The user discussed the AP exam schedule with a friend, confirming the
         May 12 calculus session and asking about the review sheet."
    """#

    // MARK: - ImpactScorer — long-term importance scoring

    /// Scores an event's long-term importance 0.0-5.0. The caller appends the
    /// numbered event list after this header.
    static let impactScoring = #"""
    You score the long-term IMPORTANCE of each user activity event for the user's PERSONAL PROFILE. Scale: 0.0-5.0 (float).

    CALIBRATION PRIOR
    - The distribution is heavily skewed low. ~80% of events should score 0.0-2.0.
    - 4.0+ is rare. 4.5+ is exceptional.

    ANCHORS — calibrate strictly. Most events should be 0-2.
      0.0-0.9  pointless. Examples: scrolling Finder, checking the time, idle background app.
      1.0-1.9  trivial / passive. Examples: replying to a few messages, glancing at a dashboard, brief tab switching, a song playing in the background.
      2.0-2.9  routine engagement, focused activity worth noting later. Examples: chatting with someone for a while, reading a short article, finishing homework, looking something up, normal browsing, coping with school stuff.
      3.0-3.5  noteworthy activity. A solid completed engagement. "I did X" — describes the action. Examples: an hour of focused coding on a specific feature, a substantive phone call, making an appointment, reading a chapter the user cares about.
      3.6-4.0  noteworthy with weight. Something shifted or was achieved. "X mattered" — describes a result, decision, or change. Examples: completing a project milestone, a conversation that revealed something new, real progress on a stuck problem.
      4.1-4.8  pivotal event the user might remember for a year, life slightly changed. Examples: deciding on a tech approach, an emotionally significant exchange, a meeting where a real decision was made, a breakthrough realization.
      4.9-5.0  real change of life. Examples: a life-changing relationship, a life-changing career opportunity, a life-changing event, a life-changing decision. Those who have experienced it will never forget it.

    RULES (read carefully):
    - Score from the EVENT SUMMARY content, NOT from the app or duration. Long sessions in Finder/Code/Safari that did nothing memorable are 1.
    - If summary describes a routine browsing/idle/glance pattern, ALWAYS 1-2 regardless of duration or app.
    - Music note: song titles alone cap at ~1.2. Climb higher only if the summary explicitly shows the user's engagement (e.g. "paused work to focus on this album", "looped the same song for an hour", "this song came up right after the breakup mention").
    - 4.0+ requires a concrete outcome, decision, milestone, or emotional weight visible in the summary.
    - To distinguish 3.0-3.5 from 3.6-4.0: 3.0-3.5 uses verbs like did/spent/read/chatted; 3.6-4.0 uses verbs like finished/decided/realized/breakthrough.
    - Repeated days (high occurrences_days) only mildly raise the score. A daily routine is still a routine.
    - The `evidence` field MUST quote or paraphrase a SPECIFIC fragment from the summary that justifies the score. If you cannot point to specifics, the score is ≤ 2.0.

    EXAMPLES:

    Input: User had Slack open in the background for 3 hours; sent two short replies. Otherwise watched a YouTube video on cooking.
    Output: {"id": 1, "evidence": "two short replies, otherwise watched a cooking video", "impact": 1.2}

    Input: User spent 90 minutes coding a new ranking algorithm for the search feature; finally got the unit tests passing after fixing a subtle off-by-one in the merge step.
    Output: {"id": 2, "evidence": "got the unit tests passing... fixing an off-by-one", "impact": 3.7}

    Input: User accepted a job offer from a startup in Tokyo over a long video call with the founder; planning to move next month.
    Output: {"id": 3, "evidence": "accepted a job offer... planning to move next month", "impact": 4.9}

    OUTPUT FORMAT:
    Return ONLY a JSON array. No prose, no markdown fences.
    [{"id": <int>, "evidence": "<quoted fragment>", "impact": <float>}, ...]

    EVENTS TO SCORE:
    """#

    // MARK: - PersonalityAgent — daily personality snapshot

    /// 单日 personality 提取的指令文本。caller 在前面追加日期 + events 列表，
    /// 末尾接 OUTPUT JSON 例子由此模板自带。
    static let personalityDailySnapshot = #"""
    You analyze a day's user activity events and TAG the most distinct
    behavioral patterns observed — single-noun tags, not sentences.

    SCAN MULTIPLE DIMENSIONS — before tagging, scan EVERY event across:
      - How they work — focus, attention, problem-solving style.
      - How they relate to others — social activity threaded through work.
      - What they need to function — background audio, time-of-day rhythm,
        context-switching, recovery / regulation habits.
      - What they care about beyond utility — curiosity, taste, values.

    OUTPUT 1 to 3 tags for the most distinct patterns. Output FEWER if
    today's events only support 1-2 dimensions — NEVER force 3.

    Each tag MUST be:
    - A single noun OR hyphenated noun phrase: "verification", "multitasking",
      "background-audio", "time-boxing".
    - Lowercase. kebab-case for multi-word (no spaces, ever).
    - An observable behavior pattern, not an identity / type label.
    - Concrete enough to recur tomorrow ("verification" recurs; "genius" does not).

    BAD tags — do NOT output:
    - Verbs / verb phrases: "verifies workflows", "cross-checks details".
    - Identity / type labels: "introvert", "creative", "INTP", "smart".
    - Vague abstractions: "parallel", "thoughtful", "organized".

    GOOD tag examples:
      verification, multitasking, time-boxing, background-audio,
      micro-iteration, social-check-ins, end-to-end-execution,
      pragmatic-tuning, tool-research.

    SELF-CHECK before finalizing: if every tag describes work methodology,
    stop — what social, focus, sensory, or value pattern did today's events
    ALSO show? Revise only if a real signal was missed (do not invent one).

    Each tag carries an "evidence" list — the event slugs from below that
    support it. 1 to N slugs per tag. A slug MAY appear under multiple tags.

    Each tag ALSO carries an "ocr_keywords" list of 3-6 short search terms
    (single words / short phrases) that would plausibly appear in the user's
    on-screen text if this trait is real, e.g.:
      verification    → ["verify", "double-check", "confirm", "review"]
      multitasking    → ["switch", "tab", "window", "context"]
      background-audio → ["spotify", "music", "playlist", "queue"]
    Keywords are matched substring on full_text (case-insensitive). Use the
    tag's CONCEPT, not the tag string itself. Mix English / native language
    naturally — whatever would actually show up in app UI / chat / code.

    SKIP CONDITION:
    - Input events are already filtered upstream to high-weight ones. Even
      a single strong event can support 1 tag. Only return an empty "tags"
      array when truly nothing recurrent/dispositional is observable.

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "date": "<YYYY-MM-DD>",
      "tags": [
        { "name": "<single-noun-tag>",
          "evidence": ["<event-slug>", "..."],
          "ocr_keywords": ["<keyword>", "..."] }
      ]
    }
    """#

    // MARK: - PersonalityClusterAgent — pre-cluster 同义 tag

    /// 在 merger 之前先做语义聚类:把表面不同但意思相同的 tag 归一组。
    /// caller 在后面拼上 `INDEXED TAGS` 列表。结果是 [{head, members:[idx]}]。
    static let personalityCluster = #"""
    You group SEMANTICALLY SIMILAR personality tags into clusters.

    INPUT — a list of tags indexed 0..N-1. Tags may differ in surface form
    but describe the same behavioral disposition.

    CLUSTER WHEN — two or more tags describe the same disposition:
      GOOD: ["systems-builder", "systems-thinking", "systems-obsession",
             "framework-design", "architecture-planning"]
      GOOD: ["tool-research", "tool-assisted-learning", "tool-fluency"]
      GOOD: ["context-switching", "multitasking", "parallel-execution"]
      GOOD: ["background-audio", "ambient-music", "sensory-anchor"]

    DO NOT CLUSTER — related-but-distinct patterns stay separate:
      BAD: ["verification", "methodology"]      — different scope
      BAD: ["focus", "flow-state"]              — related but different
      BAD: ["learning", "teaching"]             — different roles
      BAD: ["iterative-shipping", "perfectionism"] — opposite mindsets

    RULES:
    - Every input index MUST appear in exactly one cluster.
    - Singleton clusters are fine for genuinely unique tags.
    - Prefer fewer larger clusters when synonymy is clear — the whole point
      of this pass is to collapse duplicates before downstream merge.
    - Pick `head` as the most CONCRETE behavioral phrase in the cluster
      (kebab-case, lowercase).

    OUTPUT — JSON array. No prose, no markdown:
    [
      { "head": "<canonical-kebab-case>", "members": [<index>, <index>, ...] }
    ]
    """#

    // MARK: - PersonalityMerger — cluster → existing concept 决策

    /// 拿到聚类后的 cluster,一个 cluster 一个决策:mergeInto 现有 concept
    /// 还是 createNew 或 skipCluster。caller 后面拼现有 concepts 列表 +
    /// cluster 列表(head + 成员 tag 预览)。
    static let personalityMerge = #"""
    You decide how each PERSONALITY TAG CLUSTER maps onto the user's existing
    PERSONALITY CONCEPTS. One decision per cluster.

    Each cluster is a group of synonymous tags already deduplicated upstream.
    Concepts ARE tags — there is no prose body; evidence is tracked elsewhere.

    For EACH cluster, choose exactly one action:

    - mergeInto: the cluster's head OR any of its members matches an existing
      concept's primary_label or aliases (synonym / near-synonym). Provide
      conceptSlug only — the cluster members will be added to that concept's
      aliases automatically.

    - createNew: a genuinely new disposition, no existing concept covers it.
      No additional fields needed — the cluster head becomes the new concept.

    - skipCluster: the cluster is too vague / not personality-relevant
      (topic / identity / app name). Provide reason.

    MERGE STRICTNESS — moderate. When in doubt, createNew rather than
    over-merge. Examples of merge-worthy synonymy:
      verification ↔ checking, validation, cross-checking
      multitasking ↔ context-switching, parallel-execution
      background-audio ↔ ambient-music, sensory-anchor
    Examples that should NOT merge:
      verification vs methodology      — different scope
      focus vs flow-state              — related but different
      multitasking vs distractibility  — positive vs negative framing

    DESCRIPTION — for **every** mergeInto / createNew decision, also output a
    one-sentence `description` explaining what the tag actually means, so a
    reader who only sees the title `verification` or `multitasking` can still
    grasp it. Wording / phrasing / language are up to you — just keep it
    one sentence, third person, and short enough to read at a glance.
    Examples (style, not template):
      verification    → "The user repeatedly double-checks results before moving on."
      multitasking    → "The user works on multiple tasks in parallel rather than serially."
      background-audio → "The user plays ambient music or background audio while focused on tasks."
    skipCluster decisions do NOT need a description.

    OUTPUT — JSON array, one object per cluster. No prose, no markdown:
    [
      { "head": "<the cluster head, verbatim>",
        "action": "mergeInto" | "createNew" | "skipCluster",
        "conceptSlug": "...",      // mergeInto only
        "description": "...",      // mergeInto + createNew (omit for skipCluster)
        "reason": "..." }          // skipCluster only
    ]
    """#

    // MARK: - PortraitToTagsAgent — portrait → personality tag

    /// 给一批 portrait(社交/技能/兴趣/等)抽 personality tag。caller 在前面
    /// 拼上每个 portrait 的 `[slug] title — body`。
    static let portraitToTags = #"""
    You analyze the user's existing PORTRAIT entries (social, skills, interests,
    experiences, background, emotions) and extract PERSONALITY
    TAGS — single-noun or kebab-case behavioral / dispositional words that
    these portraits imply about the user.

    For EACH portrait below, output 0–3 tags.

    Each tag MUST be:
    - A single noun or hyphenated noun phrase: "verification", "tool-research",
      "systems-builder", "hands-on-debugging".
    - Lowercase, kebab-case for multi-word (no spaces).
    - A behavioral / dispositional pattern, NOT a topic or identity:
        GOOD: "iterative-shipping", "live-coordination", "background-audio"
        BAD:  "swift" (topic), "introvert" (identity), "smart" (judgmental)
    - Concrete enough to recur in someone else's portrait.

    If the portrait is too generic / topic-only / doesn't imply a personality
    pattern → return an empty tags array for that portrait.

    OUTPUT — JSON array, one object per portrait. No prose, no markdown:
    [
      { "portrait": "<the portrait's relative path, verbatim>",
        "tags": ["<tag>", "<tag>"] }
    ]
    """#

    // MARK: - OCRToTagsAgent — daily OCR → personality tag

    /// 给一天的屏幕 OCR 文本抽 personality tag。caller 在前面拼上当天 OCR 的
    /// 拼接文本(截断防爆)。
    static let ocrToTags = #"""
    You analyze ONE DAY of the user's screen OCR text (raw on-screen content
    captured throughout the day) and extract PERSONALITY TAGS — single-noun
    or kebab-case behavioral / dispositional words that the patterns in this
    OCR imply about the user.

    Output 0–5 tags for the day. Skip topical noise (app names, URLs,
    proper nouns). Look for HOW the user works / interacts patterns visible
    in the text: repeated terms, command vocabulary, message tone, etc.

    Each tag MUST be:
    - A single noun or hyphenated noun phrase, kebab-case, lowercase.
    - A behavioral / dispositional pattern, NOT a topic / identity / app name:
        GOOD: "command-fluency", "terse-messaging", "live-debugging"
        BAD:  "discord" (app), "git" (tool), "studious" (judgmental)

    If the day's OCR is mostly noise / no clear pattern → return empty array.

    OUTPUT — JSON object. No prose, no markdown:
    { "tags": ["<tag>", "<tag>"] }
    """#

    // MARK: - PortraitDistiller — event → portrait distillation

    /// Opening line of the distill prompt.
    static let distillIntro =
        "You are distilling raw EVENTS into long-term PORTRAIT entries about the user."

    /// One-line definition of what a given portrait category means.
    static func distillDefinition(for category: String) -> String {
        switch category {
        case "personality":  return "- personality = stable traits, working style, decision style. NOT one-off events."
        case "social":       return "- social = relationships, recurring contacts, group memberships."
        case "background":   return "- background = biographical facts: schooling, region, family, life history."
        case "experiences":  return "- experiences = significant past events that shaped the user."
        case "interests":    return "- interests = topics/domains the user repeatedly engages with by choice."
        case "skills":       return "- skills = capabilities the user has demonstrated, with evidence."
        case "emotions":     return "- emotions = recurring emotional patterns and triggers."
        default:             return "- generic personal-portrait entry."
        }
    }

    /// Output spec + rules — appended after the existing/source-events blocks.
    /// `evidenceThreshold` 是配置可调的"改写一个已沉淀条目所需的新事件数"
    /// （Memory 设置里的 Portrait evidence threshold）。
    static func distillOutputSpec(evidenceThreshold: Int) -> String {
        #"""
        Decide what portrait entries should exist for this category. Respond with ONLY a JSON array (no prose, no markdown fences).
        Each object is one decision:
          { "action": "create" | "update" | "noop",
            "slug": "snake_case_short",   // for update, must match an existing slug
            "title": "Human-readable title",
            "body": "Markdown body, multiple sentences, third person about the user. Cite specific evidence from events. Use \n for newlines.",
            "derived_from": ["<event id>", "<event id>"]
          }

        WEIGHTED MERGE — how to UPDATE a settled entry:
        An existing portrait entry is SETTLED knowledge built from earlier events.
        When you UPDATE one, MERGE — do not rewrite from scratch:
        - Preserve what is still true. Fold new evidence into the existing text
          rather than replacing it.
        - A SUBSTANTIAL rewrite (overturning or significantly reframing the settled
          content) is justified ONLY when at least \#(evidenceThreshold) source
          events created AFTER the entry's "last updated" date, each with
          meaningful weight, support the change.
        - A single new event — or a handful of low-weight ones — refines wording or
          appends at most one sentence. It does NOT overturn settled content.
        - `weight` is decayed importance; `created` tells you which events are new
          relative to the entry. Events created on/before "last updated" are already
          reflected — treat them as context, not new evidence.
        - If the new events add nothing the entry doesn't already say, return "noop".

        Rules:
        - ONLY return entries the evidence actually supports. If nothing strong enough, return [].
        - Prefer UPDATE over duplicate CREATE if an existing slug covers the same trait.
        - Multiple distinct portrait entries per category are fine.
        - Slugs use snake_case and ≤40 chars (e.g. swift_ui_development, personal_ai_research, late_night_focus).
        - Each body should be a real summary citing concrete signals — not 'the user used X app'.
        """#
    }
}
