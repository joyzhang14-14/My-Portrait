import Foundation

/// All LLM prompt templates for the memory pipeline, centralised so the
/// instruction text lives in one place instead of being scattered across
/// EventBuilder / ImpactScorer / PortraitDistiller.
///
/// Only the STATIC instruction text lives here. The dynamic data (session
/// lists, event lists, active-event catalogues) is still assembled in each
/// caller's `buildPrompt` and concatenated with these templates.
enum MemoryPrompts {

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
    - "join_existing": if this event continues an ACTIVE EVENT listed above, put
      its id (e.g. "evt_03" or a path id); otherwise null. Only join when the
      subject matter is genuinely the same thread of work / conversation.
    - "skipped": sessions with no real content (idle glance, no meaningful OCR).

    portrait_facets — optional, default []. Only attach when the event reflects a
    STABLE signal about who the user is. Each facet: {"facet": "<name>", "value": "<short>"}.
      background    — STRICTLY demographic / biographical facts (age, location,
                      education, family, occupation). NOT "background app".
      social        — specific named people in the user's life.
      speech_style  — vocabulary, tone, language preference.
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
    You analyze a day's user activity events to extract PERSONALITY TRAITS —
    behavioral patterns visible in HOW the user acts, not what they did.

    SCAN MULTIPLE DIMENSIONS — personality is more than work style.
    Before deciding traits, scan EVERY event for signals across:
      - How they work — focus, attention, debugging / problem-solving style.
      - How they relate to others — social activity threaded through focused
        work; when they reach out vs. withdraw.
      - What they need to function — background music, time-of-day rhythm,
        context-switching, recovery / regulation habits.
      - What they care about beyond utility — curiosity, taste, values that
        show through in what they choose to do.
    Do NOT force coverage: if today's events genuinely only support one
    dimension, output fewer traits. But actively look for the non-obvious
    signal in EVERY event before concluding.

    STRICT RULES — a violation makes the output invalid:

    observedTraits (3 to 5 items, OR empty per skip condition below):
    - 3 to 8 words each.
    - Describe BEHAVIORAL PATTERNS / action style. Verb-led when possible.
    - GOOD examples:
        "asks why before how"
        "withdraws when interrupted by notifications"
        "circles back to old ideas while debugging"
    - BAD examples — do NOT produce:
        "smart" (judgmental)
        "introvert" (identity label)
        "INTP" (type label)
        "creative person" (vague)
        "hardworking" (one-word judgment)

    summary (2-3 sentences):
    - Third person ("the user" / "they" / "she"), descriptive not judgmental.
    - MUST cite SPECIFIC events. NEVER write "the user showed X today" generic.
    - Example shape: "While debugging the Memory pipeline she paused at
      conflicting logs to verify rather than guess; later, she walked away
      from the Discord notification mid-thought instead of context-switching."

    evidenceEventIds:
    - MUST be a subset of the event slugs listed below. NO made-up ids.
    - One id per trait minimum when traits non-empty.

    SELF-CHECK before finalizing:
    - If 3 or more of your traits all describe work methodology, STOP and ask:
      what habit, social pattern, focus/attention pattern, emotional state, or
      value cue does today's data ALSO reveal? Revise if a real signal was
      missed. (Do not invent one — only revise if the events genuinely show it.)

    SKIP CONDITION:
    - If fewer than 5 events OR every event has impact < 1.5, return
      observedTraits = [] and summary = "Not enough activity today to read
      personality." Don't force traits when evidence is thin.

    OUTPUT — respond with ONLY this JSON object. No prose, no markdown fences:
    {
      "date": "<YYYY-MM-DD>",
      "summary": "...",
      "observedTraits": ["...", "..."],
      "evidenceEventIds": ["<event-slug>", "..."]
    }
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
        case "speech_style": return "- speech_style = how the user talks/writes (formality, language mix, idioms)."
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
