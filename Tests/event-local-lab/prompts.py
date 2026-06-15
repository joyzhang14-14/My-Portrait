"""五个窄 prompt。原则:14B 每次只回答一个小问题,输出一个小 JSON。
指令英文(模型遵从度高),数据中英混排原样喂。"""
import json


def _sess_card(row, ocr_chars=400):
    t0 = row["start_ms"] // 1000
    dur_min = max(1, (row["end_ms"] - row["start_ms"]) // 60000)
    # Phase B 清洗过的 digest 优先(信号密度高);没有就退回原始 OCR。
    body = ""
    try:
        body = row["digest"] or ""
    except (KeyError, IndexError):
        pass
    label = "activity_digest" if body else "screen_text"
    body = body or row["ocr"][:ocr_chars]
    return (f"app: {row['app']}\nwindow: {row['window'] or '(none)'}\n"
            f"url: {row['url'] or '(none)'}\n"
            f"start_epoch_s: {t0} · duration≈{dur_min}min\n"
            f"{label}: {body}")


def _event_card(row, summary_chars=200):
    tags = ", ".join(json.loads(row["tags"]))
    return (f"[{row['id']}] {row['title']}\n"
            f"    summary: {row['summary'][:summary_chars]}\n"
            f"    tags: {tags}")


SYSTEM = (
    "You are the event-clustering engine of a personal memory system. "
    "The user's screen activity is captured as sessions (app + window + OCR text). "
    "Content is mixed Chinese/English. Always answer with ONE JSON object only."
)


def decide(session_row, candidate_event_rows):
    cards = "\n".join(_event_card(e) for e in candidate_event_rows)
    user = f"""A new activity session:

{_sess_card(session_row)}

Existing events from the SAME day (candidates):

{cards}

Does this session belong to one of these events (same real-world activity, \
continued), or is it a different activity that deserves a new event?
Joining is right when the user is clearly continuing the same task/topic, \
even in a different app. When unsure, prefer "new".

Answer JSON: {{"decision": "join", "event_id": <id>}} or {{"decision": "new"}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def describe(session_row):
    user = f"""Create an event record for this activity session:

{_sess_card(session_row, ocr_chars=500)}

Rules:
- title: short snake_case English identifier (e.g. fixed_timeline_arrow_lag)
- summary: 1-2 sentences, what the user actually DID (use the session's own \
language for proper nouns; Chinese content may be summarized in Chinese)
- type: "experience" (doing something) or "emotion" (emotional moment)
- tags: 3-6 lowercase keywords
- facets: [] usually; only add from [skills, habits, interests, social, \
background, preferences, goals] when the session is a STABLE identity signal

Answer JSON: {{"title": "...", "summary": "...", "type": "...", \
"tags": [...], "facets": [...]}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def summarize(event_row, member_rows):
    cards = "\n---\n".join(_sess_card(m, ocr_chars=250) for m in member_rows[:12])
    user = f"""An event currently titled "{event_row['title']}" was built from \
{len(member_rows)} sessions:

{cards}

Rewrite the final record. Keep the title unless it is clearly wrong.
Answer JSON: {{"title": "...", "summary": "..."}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def merge(event_a, event_b):
    user = f"""Two events from the same day:

A: {_event_card(event_a)}
B: {_event_card(event_b)}

Are they the SAME real-world activity that should be one event?
Answer JSON: {{"merge": true}} or {{"merge": false}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def join_historical(event_row, hist_card):
    tags = ", ".join(hist_card["tags"])
    user = f"""Today's event:

{_event_card(event_row)}

A past event from {hist_card['day']}:

title: {hist_card['title']}
summary: {hist_card['summary']}
tags: {tags}

Is today's event a CONTINUATION of that same ongoing activity/project \
(not merely similar topic)?
Answer JSON: {{"same_ongoing": true}} or {{"same_ongoing": false}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def clean(session_row):
    """Phase B:原始 OCR → 活动 digest。小模型任务(默认 4B)。
    v3 #4:加背景 app + chrome 标签的**具体**否定规则(4B 靠列举不靠推理)。"""
    t0 = session_row["start_ms"] // 1000
    dur_min = max(1, (session_row["end_ms"] - session_row["start_ms"]) // 60000)
    try:
        bg = session_row["bg_media"]
    except (KeyError, IndexError):
        bg = 0
    bg_note = ("\nNOTE: app is a media player but the screen shows real work — "
               "music is BACKGROUND. Describe the work, NOT the music.\n"
               if bg else "")
    user = f"""Raw OCR text captured from the user's screen during one session.
(UI chrome like menu bars and clocks was already stripped; text below is mostly
real content.)

app: {session_row['app']}
window: {session_row['window'] or '(none)'}
url: {session_row['url'] or '(none)'}
duration≈{dur_min}min · start_epoch_s: {t0}{bg_note}
--- SCREEN TEXT ---
{session_row['ocr']}
--- END ---

Distill what the user was actually DOING. Concrete rules:
- If `app` is a media player (Spotify/Music/iTunes) but the text is code,
  terminal output, file paths, or project names → the real activity is THAT
  work; music is background. Do NOT say the user "used Spotify".
- Generic UI labels are NOT user content, ignore them: "Public Playlist",
  "Liked Songs", "Untitled", "No Title", "New Tab".
- KEEP concrete technical anchors (high recall value, NOT sensitive): commit
  hashes, file/function/class names, error strings, code identifiers, numeric
  IDs (e.g. "chunk 3402"), line numbers, versions, and project/product names —
  spell project/product names EXACTLY as written, never approximate or garble.
- REDACT only genuinely sensitive specifics: OTHER people's real names, emails,
  phone numbers, money amounts, passwords/API keys, postal addresses, and
  message/chat body text. Describe the activity ("a WeChat transfer from a
  contact", "replied to a message") WITHOUT the sensitive value — but always
  record that the activity happened; never drop a whole interaction.

Answer JSON:
{{"doing": "<1-3 sentences, what the user did; '' if pure chrome/noise>",
"keywords": ["3-8 lowercase terms"]}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


# ---------------- v2:day-outline(章节化) ----------------

def outline_window(day, digest_lines, prev_chapters, carry_note):
    """滑窗:~40 个 session digest + 上一窗章节接力 → 划章节。
    digest_lines: [(session_id, "HH:MM app | digest首行")]"""
    prev = "\n".join(f"- [{c['seq']}] {c['title']}: {c['narrative'][:120]}"
                     for c in prev_chapters[-6:]) or "(none yet)"
    sess = "\n".join(f"s{sid}: {line}" for sid, line in digest_lines)
    user = f"""You are segmenting one day ({day}) of a user's screen activity into
narrative chapters (coherent real-world activities, like diary sections).

Chapters established so far (you may CONTINUE the last one):
{prev}
{carry_note}

Next sessions in time order (sN = session id):
{sess}

Rules:
- A chapter = one coherent activity (e.g. "developing My Meeting transcription,
  including recording a TV show as test material"). Interleaved sessions of the
  same activity belong to ONE chapter.
- Infer the META-activity: if the user records/transcribes content inside a dev
  tool, the activity is the dev/testing work — not the content on screen.
- A session tagged [bg] is BACKGROUND music — never let it define a chapter
  topic or title. A media app (Spotify/Music) appearing in only a few sessions
  among many dev sessions is background; name the chapter after the dev work.
- Typos / one-off glances / fleeting windows are NOT chapters; fold them into
  the surrounding chapter.
- Do NOT pile unrelated activities into one giant chapter. When the activity
  genuinely shifts (e.g. coding → a different project → reading docs), start a
  NEW chapter. Prefer several focused chapters over one sprawling one.
- continue_last only when the next sessions truly continue the SAME activity as
  the last chapter — not just "also at the computer".

Answer JSON:
{{"continue_last_with": ["s1", …] or [],
  "chapters": [{{"title": "short_snake_case", "narrative": "1-3 sentences,
what the user was really doing", "sessions": ["s2", "s3", …]}}]}}
Every sN must appear exactly once (in continue_last_with or one chapter)."""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def describe_chapter(chapter, member_rows, prev_ch, next_ch):
    """章节 → 事件。带前后章上下文,孤证消失。"""
    cards = "\n---\n".join(_sess_card(m, ocr_chars=200) for m in member_rows[:10])
    ctx = ""
    if prev_ch:
        ctx += f"\nPrevious chapter: {prev_ch['title']} — {prev_ch['narrative'][:100]}"
    if next_ch:
        ctx += f"\nNext chapter: {next_ch['title']} — {next_ch['narrative'][:100]}"
    user = f"""A chapter of the user's day ({len(member_rows)} sessions):

chapter_narrative: {chapter['narrative']}{ctx}

Sample sessions:
{cards}

Create the event record. The chapter narrative is the best statement of what
the user was REALLY doing — session screen content may be material/test data.
Rules:
- title: short snake_case English identifier
- summary: 1-3 sentences. Write in English; keep proper nouns as-is.
- type: "experience" or "emotion"
- tags: 3-6 lowercase keywords
- facets: [] usually; only from [skills, habits, interests, social, background,
  preferences, goals] for STABLE identity signals

Answer JSON: {{"title": "...", "summary": "...", "type": "...",
"tags": [...], "facets": [...]}}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]
