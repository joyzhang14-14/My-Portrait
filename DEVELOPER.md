# DEVELOPER.md

Engineering guide for **My Portrait** — a macOS-native Swift app that runs a 24/7 personal
capture pipeline and distills it into a long-term "portrait" you can chat with.

This is the companion to the user-facing [README](./README.md): read that first for _what the
app does_, then read this for _how it is built, where it currently stands, and how to debug it_.

> **Scale, for calibration:** ~90k lines of Swift across 4 SwiftPM targets, 277 source files.
> The two heaviest modules are `Memory/` (70 files) and `Capture/` (66 files).

---

## 1. Goals and non-goals

### The one goal that drives every design decision

**The whole system, end to end, with no cloud API at all — on a single Apple-silicon Mac with
16 GB of memory.** Your data never leaves the device.

Where that stands today:

- **The capture half is already fully local** and always has been. Screen OCR (Vision), audio
  transcription (WhisperKit / Qwen3-ASR via MLX), speaker diarization (ONNX), and keystroke/AX
  capture all run on-device.
- **The understanding half is not.** Turning raw signal into events, reconstructing what you
  actually wrote, distilling the portrait, learning personality and writing style — those steps
  currently call a cloud LLM with the user's own API key. **Closing this gap is the project's
  main open work.**

Everything else — schema choices, the staged-review flow, the perf budgets in `Capture/` — is
downstream of that goal. When a design decision is ambiguous, the tiebreaker is usually "which
option survives being moved on-device later".

### Explicit non-goals

| Non-goal                           | Why                                                                                                                                                                                                                                          |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Intel (x86_64) support on `main`   | Core transcription depends on MLX (Apple silicon only), and the x86_64 slice does not even compile (whole-module optimization of the VAD code OOMs the compiler). `main` is arm64-only and stays clean of `#if arch(x86_64)` special-casing. |
| Notarization / Developer ID        | The project ships self-signed. First launch therefore needs `xattr -d com.apple.quarantine`. Sparkle auto-updates bypass Gatekeeper, so upgrades are unaffected.                                                                             |
| Cross-platform / server components | Everything is local by construction. There is no backend to write.                                                                                                                                                                           |
| A plugin or extension API          | Not yet. Abstraction layers are added when a second concrete case exists, not before.                                                                                                                                                        |

---

## 2. Status (进度)

Read this before picking something up — it is the difference between "add a feature" and
"finish a half-migrated subsystem".

### Subsystem maturity

| Subsystem                                  | State                                     | Where it runs      | Notes                                                                                            |
| ------------------------------------------ | ----------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------ |
| Screen capture + OCR                       | **Shipped, stable**                       | On-device          | Perf-critical; hot path has hard budgets (§6).                                                   |
| Frame compaction (JPG → HEVC)              | **Shipped, stable**                       | On-device          | Two-stage storage; AC-power gated.                                                               |
| Audio capture + VAD + transcription        | **Shipped**                               | On-device          | Three engines: WhisperKit, Qwen3-ASR (MLX), optional cloud.                                      |
| Speaker diarization                        | **Shipped, accuracy is the open problem** | On-device          | pyannote + speaker-embedding ONNX. Cluster→identity quality is the weak link, not the plumbing.  |
| Typing capture (keystrokes + AX)           | **Shipped**                               | On-device          | The trickiest correctness area in the repo: IME composition, paste-vs-typed, deletion semantics. |
| Timeline UI + search                       | **Shipped, stable**                       | On-device          | SQLite FTS5 with a custom Foundation tokenizer.                                                  |
| Event pipeline (build / classify / folder) | **Shipped**                               | **Cloud LLM**      | Per-UTC-day, staged for review before it lands.                                                  |
| Portrait distillation                      | **Shipped**                               | **Cloud LLM**      | Per-category, incremental (create / update / no-change).                                         |
| Personality refresher                      | **Shipped**                               | **Cloud LLM**      | Gated on on-screen evidence — the strictest filter in the system.                                |
| Writing-style distiller                    | **Shipped, newest**                       | **Cloud LLM**      | Consumes rebuilt writing records, not raw keystrokes.                                            |
| Neural Graph                               | **Shipped**                               | On-device          | Custom force-directed engine in its own target (`GraphPhysics`).                                 |
| Chat, agents, cron jobs                    | **Shipped**                               | Provider-dependent | Multi-provider; agents shell out to a bundled runtime.                                           |
| Dev mode                                   | **Shipped** (developer tool)              | —                  | See §5.4.                                                                                        |
| **Local-model migration**                  | **In progress — the main open work**      | —                  | See below.                                                                                       |

### The open work, concretely

1. **On-device screenshot understanding.** Replacing the cloud call that turns a day of OCR
   into semantic events. The hard part is not the model, it is telling apart what was merely
   _on screen_ from what the user was actually _doing_.
2. **On-device typing-event computation.** Same idea for the writing pipeline.
3. **Fitting inside 16 GB** alongside capture, transcription and the OS. Model choice is
   constrained by that budget, not by benchmark scores.
4. **Keeping memories anchored to evidence.** A model asked "what is this person like?" will
   always produce a fluent answer. The personality pipeline's on-screen-evidence gate exists
   because of this; any local replacement must keep an equivalent gate or the output degrades
   into flattery.

### Deliberately deferred

- **Semantic / vector search.** The bge-m3 embedding subsystem was removed (it pinned the
  dependency graph and blocked Qwen3-ASR). Search is pure FTS5 today. Dead embedding columns
  remain in the schema by design — see §6.1.
- **The `emotions` portrait category.** Removed from the UI; the pipeline, graph canvas and
  existing on-disk data still reference it. Finish the removal before adding categories.
- **Test target.** `Tests/` is excluded from version control (it holds fixtures derived from
  real captured data) and the SwiftPM/XcodeGen test targets were removed accordingly — leaving
  them in made a fresh clone fail to build. There is currently **no CI test suite**; correctness
  work is done through the CLI harness in §5.2.

---

## 3. Repo structure (技术版)

### Targets

Four SwiftPM targets, one product:

| Target                | Kind           | Role                                                                                                                                                                                                                                                                                                    |
| --------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MyPortrait`          | executable     | The app. Everything below lives here.                                                                                                                                                                                                                                                                   |
| `GraphPhysics`        | library        | The Neural Graph force simulation, kept separate so it can be reasoned about (and iterated on) without dragging in the app. Pure simulation — no persistence, no app state.                                                                                                                             |
| `MyPortraitObjC`      | library (ObjC) | A `@try/@catch` shim. `AVAudioEngine.installTap` / `engine.start` throw `NSException` on format mismatch, which would terminate a Swift process; this converts it to `NSError`.                                                                                                                         |
| `PortraitSleepHelper` | executable     | Privileged root LaunchDaemon, launched on demand via `SMAppService`. Its only job is running `pmset disablesleep` so a lid-closed Mac on AC stays awake long enough to finish a long call — and **auto-resetting** when the app crashes, quits or is killed, so the machine is never left pinned awake. |

### Module map

| Path                                        | Files | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------------- | ----: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Capture/`                                  |    66 | 24/7 perf-first capture. `Screen/` (capture service, frame dedupe, snapshot writer, DRM/ignore/permission gates), `Audio/` (mic + system audio, Silero VAD, WhisperKit / Qwen3-ASR / cloud engines, transcription scheduler, `Speaker/` diarization via ONNX), `OCR/`, `Compaction/` (JPG→HEVC), `Events/` (triggers, idle/workspace/pasteboard watchers), `Coordinator/`, `Health/` (metrics, stall detection), `Power/`, `DB/` (the `PortraitDB` **protocol** — implementation lives in `DB/`, dependency inversion). |
| `Memory/`                                   |    70 | The understanding layer. Event building/classification/foldering; portrait, personality and writing-style distillers; `WritingCapture*` (the multi-pass rebuild of what you actually typed); `MemoryScheduler` / `MemoryBudget` / `MemoryStaging` (orchestration + the approve/reject flow); `PortraitPaths` / `PortraitFileIO` (the on-disk portrait tree); weight/decay/archival; `Graph/` (Neural Graph rendering, hit-testing, camera, scene building).                                                             |
| `AI/`                                       |    36 | Chat + agents + cron. Multi-provider chat, agent runners (bundled JS runtime subprocess, and a CLI-based agent), credentials in `secrets.sqlite`, cron job store/executor/scheduler, PII redaction, timeline-context building.                                                                                                                                                                                                                                                                                          |
| `Settings/`                                 |    26 | SwiftUI settings panes + the TOML config layer (`ConfigStore` / `ConfigSchema` / `ConfigApplier` own `~/.portrait/config.toml`).                                                                                                                                                                                                                                                                                                                                                                                        |
| `DB/`                                       |    13 | GRDB + SQLite + WAL + FTS5. `PortraitDBImpl` (implements `Capture/DB`'s protocol), schema + migrations, row types, FTS search engine, retention worker, screenpipe importer.                                                                                                                                                                                                                                                                                                                                            |
| `Typing/`                                   |    14 | Keystroke and AX capture, IME state machine, text diffing, pasteboard monitoring, privacy filtering.                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `CLI-Tests/`                                |    18 | Maintenance and diagnostic entry points (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `CLI-Skills/`                               |     4 | CLI bridges the _agents_ call (`mp-query`, `mp-folders`, cron管理).                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `Onboarding/`, `Notifications/`, `Updater/` |     4 | First-run flow; in-app + system notifications; Sparkle wrapper.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| root `*.swift`                              |    21 | App shell and shared UI: `App.swift`, `ContentView`, `HomeView`, `TimelineView` + `TimelineSidebar` + `TimelineFeed`, `ConnectionsView`, `CronJobsView`, `DesignSystem`, `Storage.swift`, `DevMode.swift`, `Services`, `StatusBarMenu`, `PathMigration`.                                                                                                                                                                                                                                                                |

Six sub-modules carry their own design docs — see §7.

### On-disk layout

`Storage.swift` is the single source of truth for paths. `Storage.ensureExists()` creates the
tree idempotently at launch and drops a `.metadata_never_index` marker at the root so Spotlight
skips it (a GB-scale OCR corpus being full-text indexed by `mdworker` is not free).

```
~/.portrait/
├── config.toml                     # user-editable TOML  (Settings/ConfigStore)
├── portrait.sqlite                 # frames / video_chunks / OCR / audio / transcriptions / FTS
├── secrets.sqlite                  # provider credentials
├── chat.sqlite                     # conversations
├── portrait/<category>/            # long-term distilled portrait (one dir per category)
├── events/<yyyy-MM-dd>/            # semantic event files (one .md per event)
├── personality_daily/<date>.md
├── journal/                        # append-only action log
├── logs/                           # daily raw JSON
├── raw_data/
│   ├── frames/<date>/{ts_ms}_m{monitor}.jpg    # hot JPG tier
│   └── video/<date>/m{id}_{startTs}.mp4        # HEVC compaction tier
├── audio_queue/                    # VAD-segmented WAV + deferred-transcription queue
├── voice_training/<speaker_id>.wav
├── bin/mp-query                    # shell wrapper that exec's the app binary (NOT a symlink — §6.4)
├── bun/, pi-agent/                 # bundled agent runtime
├── agent_sessions/<convId>.jsonl
├── cron_jobs/<slug>/               # cron_job.md + runs.json
└── models/                         # local model cache
```

All three SQLite databases run **WAL**. All timestamps are **INTEGER UTC milliseconds** (§6.1).

### End-to-end dataflow

```
Screen ──► dedupe ──► JPG (returns immediately) ──┬──► OCR (Vision) ──┐
                                                  └──► DB insert ─────┤
Mic + system audio ──► VAD ──► queue ──► transcribe ──► diarize ──────┼──► portrait.sqlite
Keystrokes + AX ──► IME state machine ──► diff ──► writing records ───┘        + raw_data/
                                                                                    │
                                                                                    ▼
                                          per-UTC-day  ┌──────────────────────────────┐
                                                       │ Event pipeline (LLM)         │
                                                       │  build → classify → folder   │
                                                       └──────────────┬───────────────┘
                                                                      │ events/<day>/
                             ┌────────────────────────────────────────┼────────────────────┐
                             ▼                     ▼                  ▼                    ▼
                    Portrait distiller    Personality refresher   Writing style      Neural Graph
                       (per category)     (on-screen evidence      distiller          (read-only
                             │              gate)                      │               rendering)
                             └──────────────► portrait/<category>/ ◄───┘
                                                    │
                                                    ▼
                                       Chat / agents / cron jobs
```

Every LLM-producing stage writes to a **staging area first** and waits for approval
(`MemoryStaging`, plus a DB-backed equivalent for writing style). Nothing an LLM produced lands
in your memory tree without passing through a review step — that is a deliberate property, not
a UI nicety.

---

## 4. Build and run

### Prerequisites

- **macOS 15+** (deployment target 15.0), Apple silicon.
- **Xcode 16+** (swift-tools-version 6.0).
- **XcodeGen** (`brew install xcodegen`) — the `.xcodeproj` is a generated artifact.

### The two commands

```bash
xcodegen generate          # required after ANY .swift add/delete/rename, or project.yml edit
./build-app.sh --run       # build the real .app and launch it standalone
```

`swift build` is fine — and fast — for compile checks. The **real** app must go through
Xcode / `build-app.sh`.

### Why standalone, never Xcode ⌘R

macOS TCC attributes a permission prompt to the process that _triggers_ it. Under ⌘R that is
**Xcode**, so screen-recording and microphone grants never attach to My Portrait and capture
silently does nothing. `build-app.sh --run` builds the `.app` and `open`s it with no debugger
attached, so TCC attributes permissions correctly. (It also `pkill`s any previous instance
first — two capture processes on one database is its own bad time.)

### Signing, and why ad-hoc breaks permissions

TCC keys a grant to the app's code-signing identity (cdhash / designated requirement). Ad-hoc
signing produces a new cdhash on every build, so macOS treats each rebuild as a different app
and silently drops the previous grants — you would re-approve screen recording after every
build. Set a stable signing identity in the local override:

```
Support/Signing.local.xcconfig      # gitignored
```

### Dual build system

Same sources, two manifests, maintained in parallel. `project.yml` deliberately pins newer
dependency versions than `Package.swift`.

|           | SwiftPM                      | XcodeGen                                    |
| --------- | ---------------------------- | ------------------------------------------- |
| Manifest  | `Package.swift`              | `project.yml` (source of truth for the app) |
| Produces  | `swift build` compile checks | `MyPortrait.xcodeproj` → signed `.app`      |
| File list | **auto-scans** `Sources/`    | **static** — must regenerate                |

> **The gotcha that bites everyone once:** the `.xcodeproj` carries a static file list. Add a
> `.swift` file and `swift build` works while the Xcode build fails with
> `Cannot find 'Xxx' in scope`. Run `xcodegen generate`. Never hand-edit the `.xcodeproj`.

### Dependencies

| Package             | Purpose                                                                                                                                                            |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **GRDB.swift**      | SQLite persistence (WAL + FTS5) for all three databases.                                                                                                           |
| **WhisperKit**      | On-device Whisper transcription (default engine).                                                                                                                  |
| **mlx-swift**       | Apple MLX runtime; embeds `default.metallib` (§6.4).                                                                                                               |
| **qwen3-asr-swift** | Alternative on-device ASR engine. Pinned **exact** — the 0.0.x line churns, and it drags a large transitive graph (swift-transformers, NIO stack, hummingbird, …). |
| **onnxruntime**     | Speaker diarization + embeddings, and Silero VAD.                                                                                                                  |
| **TOMLKit**         | `config.toml` round-trip.                                                                                                                                          |
| **Sparkle**         | Auto-update (appcast on GitHub Pages).                                                                                                                             |

---

## 5. Debugging (调试方法)

### 5.1 Pick the right build

| You are changing…                 | Build with                      | Why                                                                                                                                      |
| --------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Anything, quick syntax/type check | `swift build`                   | Seconds. Trust **"Build complete"**, not SourceKit — same-module `Cannot find type` errors in the editor are frequently false positives. |
| UI / settings / graph             | `./build-app.sh --run`          | Needs the real app bundle.                                                                                                               |
| Capture, permissions, TCC         | `./build-app.sh --run` **only** | ⌘R misattributes permissions (§4).                                                                                                       |
| MLX / ASR runtime                 | Xcode `.app` **only**           | `swift build` does not compile the MLX Metal shader library (§6.4).                                                                      |
| Data under `~/.portrait/` only    | nothing                         | Reload in-app or restart.                                                                                                                |

### 5.2 The CLI harness

The app binary doubles as a maintenance CLI: `App.swift` intercepts `--flags` **before** any
SwiftUI or AppDelegate setup. This is the primary way to exercise pipelines without the GUI.

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/MyPortrait-*/Build/Products/Debug/MyPortrait.app"
"$APP/Contents/MacOS/MyPortrait" --sched-dump
```

There are ~80 of them (82 at time of writing). The families that matter:

| Family            | Examples                                                                                     | Use for                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Scheduler         | `--sched-dump`, `--sched-would-process`, `--sched-recover`, `--sched-reset`, `--sched-lock`  | "Why didn't the pipeline run for day X?" — this is almost always the first thing to check. |
| Pipeline dry-runs | `--event-prompt-test <day>`, `--personality-prompt-test`, `--distill-selftest`, `--dump-day` | Inspect the exact prompt/response for one day without writing anything.                    |
| Staged review     | `--event-staged`, `--distill-staged`, `--writing-style-list/-run/-approve/-reject`           | Drive the approve/reject flow headlessly.                                                  |
| Writing capture   | `--writing-capture-run`, `--writing-capture-list`, `--writing-capture-backlog`               | The multi-pass typing rebuild.                                                             |
| Speakers          | `--diarize-session`, `--rematch-speakers`, `--reenroll-speaker`, `--fix-speakers`            | Diarization work. All support `--apply` (default is dry-run).                              |
| Backfill / repair | `--ocr-backfill`, `--rebuild-frames-fts`, `--retranscribe-qwen`, `--repair-portrait`         | One-off data surgery.                                                                      |

Two conventions worth knowing:

- **Dry-run by default.** Most destructive flags do nothing until you add `--apply`. Keep that
  convention in new CLIs.
- **Some flags deliberately skip `Services`.** `--rebuild-frames-fts` and friends open only the
  database, because constructing `Services` while the GUI app is running would start a _second_
  set of background workers — marking the in-flight writing run failed, resetting in-progress
  audio chunks (causing duplicate transcription), and running a second compactor. If you add a
  CLI that only needs the DB, follow that pattern.

### 5.3 Logs

Everything goes through `os.Logger`. Subsystems:

```bash
# everything
log stream --predicate 'subsystem BEGINSWITH "com.myportrait"' --style compact

# one area:  .capture  .memory  .db  .ai  .diag
log stream --predicate 'subsystem == "com.myportrait.capture"' --level debug

# after the fact (last 30 min)
log show --last 30m --predicate 'subsystem BEGINSWITH "com.myportrait"' --style compact
```

Capture-path logging uses format strings rather than string interpolation on purpose — see the
hot-path rules in §6.3.

### 5.4 Dev mode

A developer-only demo environment. One click in Settings → General switches the **UI** to a
fabricated dataset in `~/.portrait-dev/` (a fake persona, made-up events and portrait), while
**capture and all scheduled pipelines keep reading and writing your real data**. It exists for
two things: debugging the first-run experience without wiping your own data, and recording
screenshots/demos without exposing anything real.

It only appears if `~/.portrait-dev/` exists — regenerate it with:

```bash
python3 scripts/gen_dev_seed.py --force      # only ever writes ~/.portrait-dev
```

Most demo content is plain JSON/Markdown on disk and is re-read on every access, so you can edit
it and see the change without rebuilding.

**The rule you must not break:** the split is _per data class_, not per call site.

| Follows dev mode                             | Always real                                     |
| -------------------------------------------- | ----------------------------------------------- |
| `Storage.uiRootURL` — events, portrait, chat | `Storage.rootURL` — the capture DB, `raw_data/` |
| UI-facing config sections                    | `cron_jobs/`, credentials (`secrets.sqlite`)    |

Two paths that must not disagree are the classic bug source here: cron jobs live in the _real_
root but chat conversations follow dev mode, so a background job writing a conversation through
the UI-facing store lands in the wrong database (§6.5). When you touch a background writer, ask
which root it belongs to and use the explicit accessor — never `uiRootURL` by default.

### 5.5 Poking the database

Read-only is always safe:

```bash
sqlite3 "file:$HOME/.portrait/portrait.sqlite?mode=ro" \
  "SELECT id, timestamp, app_name FROM frames ORDER BY timestamp DESC LIMIT 5;"
```

**Writing is not.** `audio_transcriptions` and `frames` carry FTS5 sync triggers that call a
custom tokenizer registered only inside GRDB — a bare `sqlite3` write fails inside the trigger
and rolls the transaction back. See §6.1.

### 5.6 Triage table

| Symptom                                | Look here first                                                                                                                                     |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| App freezes / beachballs, no crash     | A `arguments:` array literal in a GRDB call (§6.1). Confirm with Activity Monitor → Sample; the reader thread will be pinned in `_getWitnessTable`. |
| Xcode build fails, `swift build` fine  | Stale `.xcodeproj` — run `xcodegen generate`.                                                                                                       |
| Capture records nothing                | Launched under ⌘R (TCC), or the app was rebuilt with an unstable signing identity (§4).                                                             |
| "MLX error: library not found"         | Running the CLI binary directly, or via a symlink (§6.4).                                                                                           |
| A pipeline never runs for a day        | `--sched-dump` and `--sched-would-process`; then the day's row in the processing log.                                                               |
| Nothing appears for approval           | The run may have produced only mechanical weight changes — those are filtered out of the review list by design.                                     |
| Something looks wrong only in dev mode | A path that should be real is following `uiRootURL`, or vice versa (§5.4, §6.5).                                                                    |

---

## 6. Gotchas (注意事项)

The most important section. These are hard-won; preserve the detail when editing.

### 6.1 Database and FTS

**GRDB `arguments:` must be a dict, never an array literal.**

```swift
// ❌ intermittently hangs the whole app
try Row.fetchAll(db, sql: "... WHERE a = ? AND b = ?", arguments: [v1, v2])

// ✅
try Row.fetchAll(db, sql: "... WHERE a = :a AND b = :b", arguments: ["a": v1, "b": v2])
```

_Symptom:_ the app randomly freezes. A GRDB reader thread pins 100% CPU inside
`StatementArguments.append(contentsOf:)` → `Array.append` → `swift::_getWitnessTable`; the main
thread then stalls on SwiftUI updates and the app looks dead. Only visible via Activity Monitor
→ Sample. _Cause:_ the array literal is implicitly bridged to `[any DatabaseValueConvertible]`,
and the Swift runtime intermittently infinite-loops resolving conformance for that existential
array — a libswiftCore edge case, nothing to do with GRDB. _Rule:_ always named placeholders +
dict; cast `Int` → `Int64` explicitly (`["limit": Int64(limit)]`, the dict form has no implicit
conversion); for dynamic `IN` clauses that need an array, wrap it as `StatementArguments(args)`
— a different API path — not a literal. 48 sites were fixed in one sweep; do not reintroduce it.

**System SQLite has FTS5 but no ICU and no LOAD_EXTENSION.** Word segmentation goes through the
project's custom tokenizer built on `String.enumerateSubstrings(.byWords)` (ICU-backed inside
Foundation), giving ICU-equivalent results without ICU inside SQLite. Both `frames_fts` and
`transcriptions_fts` must use that same tokenizer.

**Updating any column of `audio_transcriptions` (or `frames`) requires GRDB, never bare
sqlite3.** An `AFTER UPDATE` FTS5 sync trigger fires on _any_ column and re-tokenizes through
the custom tokenizer, which is registered only in GRDB's `prepareDatabase`. Any other connection
errors inside the trigger and rolls back. CLI data fixes may only touch tables with no FTS
trigger (e.g. `speakers`, `speaker_embeddings`).

**Migrations are append-only.** A shipped `DatabaseMigrator` migration must never be edited —
clients have already applied it. Removed-feature columns therefore stay as dead columns; unused
BLOBs live on overflow pages, so not reading them costs nothing. Do not confuse the dead
text-embedding columns with the **live** speaker voiceprint vectors.

**Never `SELECT *`.** Name columns explicitly so large overflow-page columns (e.g. per-frame OCR
word JSON, KB-scale) are not paid for on queries that do not need them.

**Timestamps are INTEGER UTC milliseconds everywhere.** Fast to index, no ISO parsing.

**Search shares the single `DatabasePool`.** A second pool would break the WAL
single-writer/many-reader assumption. UI calls through the `SearchEngine` protocol so the
implementation stays swappable.

**The screenpipe source library is read-only.** The importer copies and writes only into
`portrait.sqlite` / `raw_data/`, tagging imported rows so they are distinguishable. Never write,
move or delete anything under `~/.screenpipe` — `cp`, never `mv`.

### 6.2 Build and dependencies

**Run `xcodegen generate` after any `.swift` add/delete/rename.** SwiftPM auto-scans; the
`.xcodeproj` does not.

**Trust `swift build`, not SourceKit** for same-module symbol errors.

**Release builds go through `scripts/release/build.sh` only — never Xcode's Product → Archive.**
GUI archives force every SwiftPM package to build a x86_64 slice (project-level `ARCHS` /
`ONLY_ACTIVE_ARCH` do not propagate to packages), and `qwen3-asr-swift` uses `Float16`, a type
that does not exist on macOS x86_64 — so a GUI archive fails to compile. The script passes
`ARCHS=arm64` on the `xcodebuild` command line, which does reach packages. Known and accepted;
the app is arm64-only.

**When a transitive pin blocks a package you need, trace it to the offending direct dependency
and consider dropping it.** Precedent: the bge-m3 embedding package held old upper bounds on
swift-transformers / mlx-swift and single-handedly blocked adding native Qwen3-ASR. Removing
that subsystem (search fell back to pure FTS5) unblocked the whole graph.

### 6.3 Capture is performance-first

The capture layer runs 24/7: an extra 10 ms per frame is roughly 14 minutes of CPU per day at
86,400 frames. Tradeoffs favor performance over elegance, always.

In priority order: prefer zero-copy (pass `CGImage` / `CVPixelBuffer` / `IOSurface`, never
`Data → CGImage → Data`); dedupe before OCR; encode JPG through ImageIO's `CGImageDestination`,
not `NSImage`; hash with Accelerate vDSP; feed Vision luma8 grayscale, not RGBA; batch DB writes
into one async transaction; **never touch `@MainActor` on the capture path** (push to UI via
`AsyncStream`); no string interpolation on hot paths (use `os.Logger` format strings); wrap each
frame in `autoreleasepool` — Vision and ScreenCaptureKit leak ObjC temporaries and RSS grows
unbounded without it; no protocol/abstraction layers on hot paths (struct over class/actor).

Budgets: end-to-end < 200 ms median, steady RSS < 300 MB excluding transcription models, average
CPU < 5%.

Related invariants:

- **Write the JPG and return immediately**; OCR and the DB insert fan out concurrently.
- **Focus (app/window/URL) is read from a cached actor**, updated by NSWorkspace notifications —
  never probed per frame.
- **Delete source JPGs only after the compaction transaction commits.** Compaction is skipped on
  battery entirely.
- **On battery: record + VAD only.** Transcription and compaction wait for AC. When unplugged,
  the in-flight segment finishes, then it stops.
- **Crash recovery reads DB status, not memory.** Segments are tracked by
  `audio_chunks.status`; on restart, anything left `in_progress` is treated as crashed and reset
  to `pending`. Worst case loses the single segment being transcribed (< 90 s).
- **`notImplemented` stubs must be loud** — logged at WARN through a single reporter, surfaced
  as a status-bar indicator. Never `try?` them away.

### 6.4 Models and CLI entry points

**`swift build` does not compile the MLX Metal shader library; Xcode does.** A CLI-built binary
running MLX inference fails with "Failed to load default metallib". Xcode compiles a ~3.6 MB
`default.metallib` into the `.app`. Treat CLI-only MLX failures as expected, not as a bug — and
do not add a custom build step for it.

**Expose in-app binaries as a shell wrapper that `exec`s the absolute path, never a symlink.**
Through a symlink, `Bundle.main` resolves to the symlink's directory and the embedded metallib
is no longer found (exit 255). The wrapper is rewritten each launch because the `.app` path
changes on upgrade.

### 6.5 Dev mode path discipline

`Storage.uiRootURL` follows dev mode; `Storage.rootURL` never does. The split is the whole point
— but it means two subsystems can legitimately sit on opposite sides, and code that assumes they
agree breaks in a way that is invisible until you look at the data.

Real example (fixed): cron jobs live under the always-real root, while chat conversations follow
the UI root. A cron run therefore wrote its conversation into the _demo_ database while
recording the run in the _real_ `runs.json`. Two consequences, both silent: history entries that
open to nothing, and — when the history cap trimmed an entry, deleting a conversation that did
not exist in the demo database — real conversations surviving with no owning run, so they
resurfaced in the normal chat list. The fix was an explicit always-real store for background
writers.

**Rule:** when writing from a background/scheduled path, name the root explicitly. Reserve
`uiRootURL` for code that is rendering something a human is looking at.

### 6.6 UI

**Window dragging is opt-in, not opt-out.** `isMovableByWindowBackground` is off. AppKit decides
window-drag from the hit view's `mouseDownCanMoveWindow`, and SwiftUI-drawn buttons have no
NSView of their own to say no — so with it on, dragging any button moved the window. Instead,
`WindowDragGesture()` is attached to the backdrop layers and the main pane, and cards attach
`.blocksWindowDrag()`. Buttons are immune automatically (they claim the drag); `Menu` and
`Picker` are **not** — they only claim clicks, so any new dropdown outside a card needs
`.blocksWindowDrag()`.

**`.background(Color)` bleeds into the safe area; `.background(Shape().fill())` does not.**
Relevant whenever something must (or must not) extend under the title bar.

**`.disabled()` on a container also disables scrolling** inside it on macOS.

### 6.7 Working in this repo

**Multiple agent sessions may share the working tree.** Run `git status` before a large change
and twice before committing. Never `git add .` / `git add -A` — list explicit paths. If you see
a commit that is not yours, stop and ask; never reset or amend it. Do not touch dirty files you
did not create.

**Local-only files.** `Tests/`, `CLAUDE.md` / `AGENTS.md`, and the release runbooks are
gitignored on purpose (fixtures derived from real captured data; personal notes). Do not add
them back, and do not put anything derived from real capture data into the repo.

---

## 7. Going deeper

Sub-module design docs, each with the full rationale:

- `Sources/MyPortrait/Capture/README.md` — capture overview, budgets, hot-path rules
- `Sources/MyPortrait/Capture/Audio/README.md` — VAD, transcription engines, diarization
- `Sources/MyPortrait/Capture/Compaction/README.md` — two-stage frame storage
- `Sources/MyPortrait/Capture/Events/README.md` — capture triggers and watchers
- `Sources/MyPortrait/Capture/Power/README.md` — power-aware scheduling, crash recovery
- `Sources/MyPortrait/DB/README.md` — schema, FTS5 tokenizer, migrations, search, importer

In-app, every memory pipeline page carries an interactive "How it works" diagram showing each
step, which model it uses, and what it writes — often the fastest way to get oriented before
reading the code.
