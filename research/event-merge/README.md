# Event merge (research)

This directory turns EventSession's session records into **events**: one thing the user did, written as a narrative. Events are then fused across days into a long-term library. It is research code. It is not wired into the app yet, and the small model it is meant to run on has not been fine-tuned for these questions yet.

An event is one task, one conversation thread, or one piece of work with a single goal. Its narrative says what happened, who did which part (the user, an AI assistant, another person), and the last state shown. It makes no judgments about the person.

## Approach: retrieve, then ask narrow questions

A small model is unreliable at "group this whole day". It does much better when each question is narrow and the candidates are already short-listed. Each step below asks one small question at a time.

**Within a day** (`merge_day.py`), sessions are processed in time order:

1. *Did anything happen?* For each session: if nothing was done (a blank or loading screen, a switcher passed through, a window that was only open), skip it. Otherwise name the task it serves.
2. *Candidates.* Each session's `activity` is embedded on the Mac with EmbeddingGemma 2 (MLX). The candidates are the `PAIR_K` (4) most similar events so far, plus the most recently active one.
3. *Is this session part of this event?* Ask one candidate at a time, most similar first. The model sees the event's title, how long ago it was last active, and its member session most similar to the new one. The first "yes" joins the session to that event; if every answer is "no", a new event starts.
4. *Same-day deduplication.* Each event is compared with its `DEDUP_K` (5) most similar events: "are these the same event?". Merges are applied from the most similar pair down, and two groups never merge if any pair between them was judged different. This keeps A=B and B=C from chaining A and C together.
5. *Write.* Each event gets a title and a narrative written from all its sessions. Large events are summarized in groups of `GROUP` (10) sessions first, then the summaries are merged. Numbers and English words in the narrative that appear in none of the sessions trigger one rewrite.

**Tags** (`tag_day.py`): each written event gets portrait domains, named objects copied verbatim from the narrative (checked by code), and one to three topics.

**Across days** (`fuse_day.py`), days are processed in order:

1. *Candidates.* They come from the sections of earlier days and are the union of three sources: the `VEC_K` (8) most similar sections, sections sharing an object tag (up to `KW_K`, 5), and similar sections from the previous two days. Sections are grouped by library event and ranked by their best section, and the top `ASK_K` (5) are asked.
2. *Is today's event a continuation of this library event?* A continuation means the same assignment, document, feature, bug, download or request picked up on a later day. Another task in the same project, or a routine revisit of the same page, is not one. The first "yes" attaches the event; otherwise a new library event starts.
3. *Rewrite.* When an event is attached, the library event's title and one- or two-sentence overview are rewritten to include today, with earlier progress compressed so the overview does not grow day by day.

On my own data, retrieval is not the bottleneck: under 1% of correct within-day targets fall outside the candidates. The weak point is the small model's yes/no judgment. The next step is to fine-tune it on these narrow questions, using answers written by a stronger teacher model.

## Input

A SQLite database of EventSession session records:

- `days(day TEXT, tz TEXT)`, where `tz` is JSON with `utc_offset` such as `"-08:00"`;
- `sessions(day, key, start_ms, end_ms, focus_ms, app, window, url, activity, context_in_app, who_json, specifics_json, method)`, where `who_json` and `specifics_json` are JSON lists, and `method = '屏蔽app'` marks blocked-app spans, which are skipped.

## Running

```sh
pip install -r requirements.txt

# Model: any OpenAI-compatible server (for example vLLM) ...
export EVENT_MERGE_LLM_URL=http://127.0.0.1:8000/v1
export EVENT_MERGE_LLM_KEY=...            # optional
# ... or --llm mac to run Qwen3.5-9B 4-bit locally with mlx-lm.

python merge_day.py --db sessions.sqlite --out out 2026-01-05 2026-01-06
python tag_day.py   --out out 2026-01-05 2026-01-06
python fuse_day.py  --out out 2026-01-05 2026-01-06   # days in order
```

Every model call is cached under `out/llm_cache/` by prompt hash, so an interrupted run resumes where it stopped. Malformed JSON is repaired first (stray quotes, truncation, a missing opening quote) and retried only if it still fails validation.

Outputs:

- `out/<day>/events.json`: events with their titles, narratives and member sessions;
- `decisions.jsonl` and `dedup.jsonl`: every within-day judgment;
- `tags.json`: each event's tags;
- `fuse.jsonl`: every cross-day judgment;
- `out/library.json`: the long-term library.

All of them stay local.
