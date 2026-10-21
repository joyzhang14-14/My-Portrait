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
| Event pipeline (build / classify / folder) | **Shipped**                               | **Cloud LLM**      | Per interval (between long idle gaps), staged for review before it lands.                        |
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

Five SwiftPM targets, one product:

| Target                | Kind           | Role                                                                                                                                                                                                                                                                                                    |
| --------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MyPortrait`          | executable     | The app. Everything below lives here.                                                                                                                                                                                                                                                                   |
| `GraphPhysics`        | library        | The Neural Graph force simulation, kept separate so it can be reasoned about (and iterated on) without dragging in the app. Pure simulation — no persistence, no app state.                                                                                                                             |
| `MyPortraitObjC`      | library (ObjC) | A `@try/@catch` shim. `AVAudioEngine.installTap` / `engine.start` throw `NSException` on format mismatch, which would terminate a Swift process; this converts it to `NSError`.                                                                                                                         |
| `PortraitSleepHelper` | executable     | Privileged root LaunchDaemon, launched on demand via `SMAppService`. Its only job is running `pmset disablesleep` so a lid-closed Mac on AC stays awake long enough to finish a long call — and **auto-resetting** when the app crashes, quits or is killed, so the machine is never left pinned awake. |
| `PortraitPremiumHelper` | executable     | Executable of the seal-check LaunchAgent (user level, `SMAppService.agent`). Runs `MyPortrait --premium-export --seal-check` from its own directory as its own TCC responsible process, forwards SIGTERM / SIGINT / SIGHUP to it and returns its exit code; Foundation only, so its CDHash stays stable across releases (§6.8). |

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
                                          per interval ┌──────────────────────────────┐
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

### 6.8 Premium offload (remote compute)

Any of the four nightly chains (event, portrait, personality, writing style) can run on Premium
(a remote server with a local model, shared by several users; shown in the app as **My Portrait Premium**) instead of in this process: pick
**My Portrait Premium** as that chain's provider (`[scheduler.<chain>] provider_id = "premium"`, model
`Premium`; the model rows are hidden for it, since the server picks the model). The Mac only packages inputs and applies results. Bundles go over HTTPS to the
ingress service on the Premium server (`[premium] server_url`; empty = `PremiumRemote.defaultServer`, the
Info.plist key `PremiumServerURL` set from `PREMIUM_SERVER_URL` in the gitignored
`Support/Premium.local.xcconfig` — empty in open-source builds, where the address is entered in
Connections; the card's avatar `PremiumAvatar.imageset` is gitignored the same way, and open-source
builds show the letter tile),
authenticated with a per-user key kept in SecretStore (`premium.key`); Premium keeps every
user's bundles and processes all of them in one run each night at 03:00 (a user's backlog merged
into one job, see *Server*). `SchedulerSettings.offloadedChains`
lists the offloaded chains; chat and cron jobs are unaffected.

**Provider.** `Provider.premium` is a marker, not a callable model: `MemoryAgentFactory.make`
and `PiAgent.init` trap on it, it has no Pi entry, and `Provider.from(integrationId:)` does not
map it, so chat and cron jobs cannot select it. It shows up in the pipeline provider pickers once
the Premium tile is connected.

**Connections → My Portrait Premium.** While the tile is not connected, the card takes the key, plus a server
address field only when the build has no built-in address (a built-in address is never shown in
the UI). **Connect** saves them, then calls `GET /v1/health` and `GET /v1/me`; the tile connects
only when the server answers and the key is valid. Once connected, the card shows the last upload
and last import, plus an "Offloaded: …" line listing the chains whose provider is Premium.
Disconnect deletes the key; to replace a key, disconnect and connect again. Connecting moves all
four chains to **My Portrait Premium** (`SchedulerSettings.moveAllToPremium`) and saves
each chain's previous provider and models in `[premium] previous_providers`; switching a chain
to any other provider in Memory settings returns it to this process. Disconnect
(`restoreFromPremium`) puts every chain still on Premium back on its saved provider when that
provider is connected, and leaves it unselected otherwise; chains changed by hand stay as they are.

**Event intervals.** The event chain (with impact and classify) works on *intervals*, not days:
half-open UTC-ms ranges `[start_ms, end_ms)` between long idle gaps, one row each in
`event_intervals` (portrait.sqlite, migration `v44_event_intervals`). Both the local path and
the Premium path read the same ledger (`EventIntervalStore`); statuses follow processing_log
semantics (`ProcessingStatus`, `retry_count`, `MemoryScheduler.backoffMs`) and advance only
from processing results (a local run or an imported Premium result), never from sending a bundle.

- *Gap seal* (`IntervalSegmenter.gapCuts`, `trigger = 'gap'`). Checked every 30 minutes. After
  the last cut, every gap of at least 2 h (`IntervalSegmenter.gapCutMs`) between non-idle frames
  (`capture_trigger` not `idle` / `manual`) is an interval boundary; it is sealed once it has
  ended, or while still open once now − the last non-idle frame ≥ 2 h. One check seals every such
  gap since the last cut, in time order, so the intervals depend only on the frame history, not
  on when checks run or how long the Mac slept. Inside a gap, the cut is the start of the first
  ≥ 5 min stretch with no frames at all, counted from the gap's opening non-idle frame (the ts of
  the frame before that stretch + 1 ms); with no such stretch (screen on, idle frames all the
  time) it is the opening non-idle frame + 1 ms. The cut is never later than now − 10 min. Frames are the
  event-chain frames (snapshot, video chunk or imported) with no row cap. Ledger rows stored with
  `trigger = 'nightly'` read as `gap`.
- *Run now* seals `[last cut, now − 60 s)` with `trigger = 'run_now'` (skipped when that range
  has no frames).
- *Backfill.* Before every seal, frames with `id` above every sealed interval's `max_frame_id`
  and a timestamp before the last cut (late inserts such as a Screenpipe import) become one
  `trigger = 'backfill'` interval over their time range. An interval's frames are those with
  `start_ms <= timestamp_ms < end_ms` and `after_frame_id < id <= max_frame_id`
  (`EventIntervalStore.intervalFrameSQL`); gap / run_now rows have `after_frame_id = 0`, so
  each frame belongs to exactly one interval.
- *T0.* The first seal check writes row `iv:origin` with `start_ms = end_ms = T0`: the end of the
  processing_log run of `event`+`impact` complete UTC days counted from the oldest row (the start
  of the first incomplete day, if any). Data before T0 stays in the processing_log history.
- `tz_offset_min` is the Mac's UTC offset at sealing time, pinned per interval; local days for
  that interval's events use it (`IntervalSegmenter.localDay` / `attributeDay`).

**Local event job.** A chain on a local (cloud) provider runs in `MemoryScheduler.runEventJob`.
A tick runs a chain locally only when its provider is known, is not Premium and is connected in
Connections (`MemoryScheduler.runsLocally`); otherwise the chain does nothing — no run, no failure
— and Needs attention leaves out its problems (`MemoryScheduler.localAttention`).
Sealing an interval does not start a run. At `[scheduler.event] time_of_day` (the first tick at
or after it on a day that has not run yet, so after sleep the first tick on wake) it processes
every needsWork interval, oldest first; a run cut short by sleep / quit, or skipped because the
scheduler is busy, does not count as that day's run, so the next tick starts it again. Other
ticks only retry intervals that have failed (`retry_count > 0`, or a stage left at `failed` /
`budget_deferred`, since hitting the quota or a quit does not count a retry) and whose backoff is
over, plus a failed folder classify or one that Retry now set back to pending
(`MemoryScheduler.localRunScope`, `pendingIntervals(scope: .retryOnly)`). Needs attention →
Retry now sets an interval back to pending with a retry count of at least 1, so the next tick
retries it; Run now seals `[last cut, now − 60 s)` and processes every pending interval at once.
Per interval, `Backfill.runInterval` reads every frame of the interval
(`TimelineDB.frames(fromMs:toMs:afterId:maxId:)`, no row cap), merges Tier-1 sessions, adds OCR
and calls `EventBuilder.clusterDay`; the prompt date and the 14-day active window use the
`attributeDay` of all the interval's frames. The catalog (events last seen within those 14 days)
is split once at interval start (`EventBuilder.splitCatalog`), in catalog order (latest
occurrence first, then path by UTF-8 bytes): events with an occurrence on a local day the
interval's frames touch are same-day events and all go into the prompt's EARLIER TODAY; the rest
are past events for PAST DAYS — all of them for a single batch (≤ 40 sessions), otherwise the top
20 per batch by `rankActive` (event tags ∩ the batch's app names, ties in catalog order). In a
batched interval EARLIER TODAY also carries the past events earlier batches joined (first-join
order; they leave PAST DAYS) and earlier batches' new events (`_bN`). A join into a past event
passes the join gate (`EventBuilder.gateJoins`): when the cluster has ≥ 10 frames and more than
3 × the target's current member frames (count at interval start plus joins already let through),
the join is dropped and the cluster becomes a new event with the title and summary the model
wrote (in a batched interval a `_bN` that later batches can join); the target file is untouched.
Joins into same-day events and `_bN` are not gated; rejections are logged as
`backfill.interval.join_gate`. Email addresses in titles, summaries and facet values become
`[email]` when the response is parsed (`EventBuilder.scrubEmails`, shared with distill, writing
style and personality). Each new event is dated by its member frames'
`attributeDay` (most frames → longer share of the session spans → earliest frame, at the pinned
offset) and written to `events/<local day>/<local day>_<slug>.md`; one date directory can take
events from several intervals, and file names dedupe (`_2` … `_100`) against disk and the current
run. A join records the joined sessions' local day. Writes go into an `EventOverlay` and are
committed only when the step succeeds; the commit first writes an undo journal
(`.staging/event_intervals/<id>.json`: created paths plus the original bytes of joined files), so
a failed step, a crash (stale heartbeat) or a quit (paused row) undoes exactly that interval's
writes — new files removed, joined files restored — and no other interval's. The impact step
scores only the interval's new and joined events (on a retry after an earlier successful event
step: the events whose `member_frame_ids` intersect the interval's frames). Weight pass, budget
and the `_distill_anchor` / `_classify_anchor` marks run once per job as before. Interval and
personality-day rows keep their heartbeat in `updated_at_ms`; runStep, `recoverStaleLocks`,
`pauseInProgressJobs`, Needs attention and Retry now address them by key (`iv:…` /
`pday:<day>`). processing_log still carries the two anchor rows; its date rows are history.

**Personality days.** Personality runs once per local day, tracked in `personality_days`. A day
is ready (`EventIntervalStore.readyPersonalityDays`) when it starts at or after T0, the last cut
is at or after its local 24:00, every interval overlapping it has event and impact complete, it
has frames, and it has no row yet or its row needs work and is past backoff. A Premium bundle that
also carries the event chain lists a day whose unfinished overlapping intervals are all in that
same bundle (`readyPersonalityDays(inBundle:)`); the server runs it after those intervals complete
in the same run. Its OCR-gate window is that local day's `[00:00, 24:00)` at the pinned offset.
The local personality job (`MemoryScheduler.runPersonalityJob`) runs in the same tick right after a
local event run and at `[scheduler.personality] time_of_day`, taking up to 7 ready days; other
ticks only retry failed days (same rule as intervals) past backoff, and Run now runs at once. It calls
`PersonalityRefresh.refresh(day:ocrWindow:)`: `day` is the local date stored as UTC midnight, so
`events/<day>/`, `last_modified` and `personality_daily/<day>.md` all use that date, and the gate
counts frames in the day window. Its denominator is the day's frames with more than 4 characters
of OCR text (`TimelineDB.ocrFrameCount`); a keyword matching more than 30 % of them
(`PersonalityRefresh.maxKeywordHitPct`: words always on screen, common substrings) is not
evidence, and a tag stays only when the frames matching any evidence keyword
(`TimelineDB.frameCount(fromMs:toMs:keywords:)`) number at least 15. The concept's OCR line
lists only the evidence keywords. A day whose snapshot tags were all dropped is marked failed and
retried, unless it has fewer than 50 text frames (`PersonalityRefresh.ocrDayTooSparse`), which is
a valid empty day.

**Dates in the UI.** Event dates are calendar dates. The Neural Graph timeline
(`EventTimeline.calendarDay`) maps them to the same day in the local calendar without a time-zone
conversion; Memories prints them as stored.

**When bundles are sent.**

- *Seal check* — a user-level LaunchAgent (`PremiumNightlyAgent`, plist
  `Contents/Library/LaunchAgents/com.joyzhang.myportrait.premium-export.plist`, label
  `com.joyzhang.myportrait.premium-export`) runs `PortraitPremiumHelper` (`Contents/MacOS/`, next to
  the app binary) at every :00 and :30 (`StartCalendarInterval`), whether or not the app is open;
  the helper runs `MyPortrait --premium-export --seal-check` from its own directory and exits with
  its exit code (128 + signal when it was killed), forwarding SIGTERM / SIGINT / SIGHUP to it and
  waiting for it to exit. It spawns the app with `posix_spawn` +
  `responsibility_spawnattrs_setdisclaim` (a libquarantine SPI looked up at run time), so the app
  process is its own TCC responsible process and uses the app's grants; when the SPI is missing or
  that spawn fails it falls back to `Process` (the helper is then the responsible process) and
  says so on stderr. launchd runs a missed check once on wake.
  `MemoryScheduler.tick()` (every 15 minutes while the app runs) calls the same entry
  (`PremiumExchangeExporter.runSealCheck`), which is what debug builds rely on. It takes the
  exchange lock, runs the seal check (a 2-hour gap after the last active frame seals what came
  before it), and — when any chain is offloaded — exports as soon as there is something new
  (`PremiumExchangeExporter.exportDue`): an interval was sealed since the last export (the ledger's
  cut moved past `last_export_cut_ms`), or the event chain is offloaded and still has intervals
  waiting. A bundle holds at most one day of intervals, oldest first
  (`PremiumExchangeExporter.oneDayOfIntervals`); with a backlog the same check keeps packing, one
  day per bundle, up to `maxBundlesPerCheck`. Earlier bundles still in flight do not block an
  export: intervals already sent (see *Upload ledger* below) are left out. The export needs Premium to be reachable
  (`PremiumRemote.unreachableReason`: `GET /v1/me` with the key); otherwise that check still
  imports and seals, packs nothing, and the helper logs `skipped: Premium not reachable (<reason>)`
  — the next check tries again. The bundle is written and packed under the locks, the ledger
  records it as `pending_upload`, and it is uploaded after the locks are released
  (`PremiumRemote.flushUploads`); a failed upload is retried on the next check. The helper
  imports waiting results first and waits up to 10 minutes for the lock; the tick gives up at
  once. The helper appends a line to `<data root>/logs/premium-export.log` when it sealed,
  exported or was blocked for a reason other than "not due". The CLI path runs from
  `MyPortraitApp.init` and exits before `applicationDidFinishLaunching`, so it never reaches the
  single-instance guard. `ConfigApplier` registers the agent (`SMAppService.agent`) once at
  launch, whether or not any chain is offloaded, since local chains need the seals too. Only the
  copy in `/Applications` registers (same rule as the sleep helper); other builds just show the
  current state. The app is self-signed (no Team ID), so BTM ties the registration's launch
  constraint (LWCR) to the helper's CDHash. `unregister()` keeps the BTM record (it only marks it
  disabled) and `register()` picks the same record up again, old constraint included. After the
  helper changes, its first launch is killed with a Launch Constraint Violation; on the next
  launch launchd asks for the constraint to be repaired and BTM replaces the record with one for
  the current helper, but the job still points at the old record and fails with exit code 78
  until it is submitted again. `PremiumNightlyAgent.sync()` keeps the sha256 of the bundled agent
  plist + helper binary in UserDefaults (`premiumAgentRegisteredFingerprint`). When it differs,
  when the agent is not registered, or when `launchctl print` shows the job `not running` with
  the last run killed by SIGKILL or exited with 78, sync runs `PremiumNightlyAgent.refresh`:
  unregister (only when `enabled`), register, then `launchctl kickstart` the job and read that
  run from `launchctl print` once its state is `running` or `not running` (while it is
  `spawn scheduled` / `xpcproxy` the exit status shown is still the previous run's) — killed →
  kickstart again; 78 → unregister + register, kickstart again; a run
  that lives 0.5 s or exits normally → done (at most 5 probes; a probe that runs is a regular
  seal check). The fingerprint is stored only after a run got through. When the status is
  `requiresApproval` (the user turned it off in System Settings → General → Login Items &
  Extensions) or register reports `kSMErrorLaunchDeniedByUser`, sync neither unregisters nor
  registers nor stores the fingerprint. Failures are logged, never shown. `--premium-selftest`
  drives `refresh` through injected status / probe sequences. `scripts/release/build.sh` reuses
  the signed helper binary from `build/helper-cache/` while `Sources/PortraitPremiumHelper`, its
  Info.plist, its entitlements, its target section in `project.yml`, the script's signing
  certificate and the helper's own signing identity (`CODE_SIGN_IDENTITY` in
  `Support/Signing.local.xcconfig`, name + certificate SHA-1) are unchanged (the sleep helper's
  mechanism), so the CDHash stays the same across releases and updates do not re-register.
- *No Run now on Premium* — a chain whose provider is Premium has no Run now button and no manual
  row (Memory settings): Premium processes every user's bundles at 03:00, so an upload cannot run
  sooner.
- *Run now (local)* — for an event chain on a local provider, Run now first seals a Run now
  interval (`MemoryScheduler.sealRunNow`, under the exchange lock), then runs the event job.

**Upload ledger** (`PremiumRemote`, `<data root>/.staging/premium_remote.json`). One entry per
uploaded bundle until its result is imported: `pending_upload` (packed, archive in
`.staging/premium_upload/<bundle_id>.tar.gz`), then the server's status — `queued` / `running` /
`done` / `failed` / `merged` / `cancelled` — refreshed on every check
(`GET /v1/bundles/<id>`). Each entry lists its event intervals; while it is `pending_upload`,
`queued`, `running`, `done` or `merged` those intervals are in flight (`State.sentIntervals`) and
are not exported again. `merged` = the server folded the bundle into a newer one of the same user
(`merged_into`); it leaves the ledger together with that bundle once its result is imported
(`State.drop`). `cancelled` and unknown (404) entries are dropped; `failed` is notified once,
noted in `last_import` and dropped together with the bundles merged into it, so their intervals
go out again on the next seal check. An
upload the server rejects (4xx other than 429) is dropped the same way. The ledger also keeps
`last_export`, `last_import` and `last_export_cut_ms`. Bundle ids are
`<UTC yyyyMMddTHHmmssZ>-<host>-<8 random hex>`.

**Server.** The ingress service exposes `GET /v1/health`, `GET /v1/me`, `PUT /v1/bundles/<id>` (tar.gz body,
`X-Content-SHA256`), `GET /v1/bundles/<id>`, `GET /v1/bundles/<id>/result`,
`POST /v1/bundles/<id>/ack` and `DELETE /v1/bundles/<id>`, with `Authorization: Bearer <key>`.
Every authenticated request also carries `X-MP-Names` (base64 JSON of the Personal Info first, last
and preferred names, `ConfigSnapshot.personalNames`) and `X-MP-Device` (`PremiumRemote.deviceId`, sha256
of the hardware UUID): one of the names must equal the name the key was issued for (trimmed,
case-insensitive), and the key is bound to the first Mac that connects with it; the server answers
403 otherwise, and the card shows its message.
It checks the archive (regular files only, no absolute paths / `..` / links, size and file-count
limits), the bundle (`DONE`, `schema_version`, every file the manifest names, `manifest.files`
hashes) and the per-key upload limit (48 per 24 hours). Bundles wait in the user's queue until
the nightly run (03:00): it takes every queued bundle, merges each
user's into one job (newest bundle's trees, union of intervals and personality days; the result
belongs to the newest bundle, the others become `merged`), and runs the pipeline one step at a
time across all jobs (event for every job, then portrait, and so on). Processed inputs are
archived on the server; results are deleted after the ack, or after 7 days. Keys are issued and revoked
in the MP admin web page, which also shows each user's bundles, the nightly runs and the archive, and resets a
key's device binding when its owner moves to a new Mac.

| File                              | Role                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------ |
| `Memory/IntervalSegmenter.swift`  | Pure sealing rules, T0, pinned-offset local days, `attributeDay`, session-cut test.              |
| `Memory/EventIntervalStore.swift` | `event_intervals` / `personality_days` ledger: seal, list needsWork, update status, heartbeat, T0, personality readiness. |
| `Memory/Backfill.swift`           | Local event step for one interval (`runInterval`) and `EventOverlay` (commit with undo journal).  |
| `Memory/PremiumExchange.swift`      | Manifest / db_ops models, `.partial` → rename writes, `DONE` = sha256 of `manifest.json`, bundle ids, exchange lock. |
| `Memory/PremiumRemote.swift`        | Ingress client (`Transport`, `HTTPTransport`), upload ledger, daily hour, pack / unpack (`/usr/bin/tar`), upload, status refresh, Connect probe. |
| `Memory/PremiumExchangeExporter.swift` | Seal check entry point and export rules; builds a bundle (frames jsonl per interval and per personality day, writing records, tree mirror, manifest with `files` hashes) and packs it for upload. |
| `Memory/PremiumExchangeImporter.swift` | Downloads done results, checks their sha256, applies them: three-way merge, db_ops, backup, rollback; acks after import. |
| `Memory/PremiumNightlyAgent.swift`  | Registers the seal-check LaunchAgent (again when the plist or helper changes); status for the Connections card. |
| `Support/com.joyzhang.myportrait.premium-export.plist` | The LaunchAgent plist (copied into the bundle by `project.yml`).                     |
| `Sources/PortraitPremiumHelper/main.swift` | The LaunchAgent's executable: runs `MyPortrait --premium-export --seal-check` from its own directory (disclaiming TCC responsibility), forwards SIGTERM / SIGINT / SIGHUP to it and returns its exit code. Foundation only. |
| `CLI-Tests/PremiumCLI.swift` | `--premium-export`, `--premium-import`, `--premium-rollback`, `--premium-selftest`.                      |
| `CLI-Tests/SegmentReplayCLI.swift` | `--segment-replay`: read-only replay of the sealing rules over the frame history.              |
| `CLI-Tests/IntervalSelfTestCLI.swift` | `--interval-selftest`: local interval event runs and personality days on a temp data root.   |

**Scheduler coupling.** `MemoryScheduler.tick()` imports Premium results first (when any chain is
offloaded), then runs the seal check, then the local chains on their schedule (above) while
skipping the offloaded ones (an offloaded event chain also skips folder classify). Export and import hold all
three scheduler locks plus the cross-process exchange lock (`flock` on
`<data root>/.staging/premium.lock`), and are skipped while a staged manual run or AI edit draft is
pending. Import gives up at once when the exchange lock is taken. Network calls
(upload, status, download, ack) run outside the locks.

**Export (manifest `schema_version = 2`).** Only offloaded chains contribute
(`PremiumExchangeExporter.computePending`): `pending.event_intervals` lists the needsWork intervals not yet in flight
(`id`, `start_ms`, `end_ms`, `tz_offset_min`, `trigger`, plus their current `event_status`,
`impact_status`, `retry_count`, `frame_count`, `after_frame_id`, `max_frame_id`);
`pending.personality_days` lists ready local days (intervals in flight count as covered), with their ledger rows (`day`,
`tz_offset_min`, `status`, `retry_count`) in top-level `personality_log`; `processing_log` holds
only `_distill_anchor` / `_classify_anchor`; `distill_pending`, `classify_pending` and the
writing-record count use the scheduler's own predicates. `frames/<interval_id>.jsonl` holds every
frame of an interval and `frames/pday_<day>.jsonl` every frame of that local day (no filter; the
OCR gate counts all frames), both without a row cap. For the seal-check bundle a chain whose
frequency is `off` contributes nothing. The manifest carries `trigger` (`"nightly"`) and `chains` — the chains
in this bundle (`event` / `portrait` / `personality` / `writing_style`), i.e. every offloaded
chain with pending work. Pending fields of chains not in `chains` are
empty / false: `event_intervals` and `classify_pending` belong to `event`, `distill_pending` to
`portrait`, `personality_days` to `personality`, `writing_style_enabled` and
`writing_records.jsonl` to `writing_style`. `manifest.files` maps every frame file and
`writing_records.jsonl` to its sha256; `DONE` is written last. No chain offloaded → no export. No
export when nothing is pending.

**Import — three-way merge per file.** A `done` result is downloaded to
`.staging/premium_download/`, checked against the server's sha256 and unpacked; it is imported once
it is complete: `DONE` matches its manifest, `db_ops.json` is present and every `result_trees`
file is on disk.
Base = result `base_trees`, premium = `result_trees`, mac = file on disk: mac == premium → nothing;
mac missing or mac == base → take Premium's; premium == base → keep Mac's; otherwise keep Mac's and
store Premium's under `.staging/premium_conflicts/<bundle_id>/`. `deleted` entries go only when
mac == base. db_ops are applied in one GRDB transaction: processing_log by column (never
touching the lock columns); `event_intervals` rows by `id`, overwriting `event_status` /
`impact_status` / `retry_count` (a row the Mac does not have is inserted when Premium echoes
`start_ms` / `end_ms`, otherwise the import fails); `personality_days` rows upserted by `day`;
`pipeline_runs.trigger = 'premium'`. A stage already `complete` on the Mac is never set back;
an interval with event and impact both complete is left as is, and so is a complete personality
day. A failure before the transaction commits restores the three trees from the backup and marks
the ledger entry `import_failed` (not retried automatically; `--premium-import` retries it). After a
successful import the Mac acks the bundle (the server deletes its result) and drops the ledger
entry; an ack that fails is retried, and the re-import is idempotent.

**Backup / rollback.** Every import snapshots `events/`, `portrait/`, `personality_daily/`, the
processing_log, event_intervals and personality_days rows it will overwrite, and its db_ops into
`.staging/premium_import_backup/<bundle_id>/` (newest 3 kept). `--premium-rollback <bundle_id>`
restores those trees and rows (rows the import created are removed) and un-marks the writing
records / run it added. It does not undo history rows (`distill_changelog`, `pipeline_runs`) or
journal text.

**CLI.**

```bash
MyPortrait --premium-export                                   # import results, then export + upload pending work now
                                                            # (no seal, no check for new intervals)
MyPortrait --premium-export --seal-check                      # what the LaunchAgent runs at :00 / :30
MyPortrait --premium-export --dry-run-dir DIR --interval-from <ms> --interval-to <ms>
                                                            # v2 test bundle (trigger nightly): [from, to) as one
                                                            # unprocessed interval, local days fully inside it as
                                                            # personality days; event / portrait / personality,
                                                            # plus writing_style unless its frequency is off;
                                                            # no ledger writes, nothing uploaded
MyPortrait --premium-import                                   # download + import every done result (import_failed too)
MyPortrait --premium-rollback <bundle_id>
MyPortrait --premium-selftest                                 # segmenter branches, interval ledger, personality
                                                            # readiness (same-bundle intervals), v2 bundle,
                                                            # packing, importer, per-chain pending, export rules
                                                            # (new interval / backlog, one day per bundle, in-flight
                                                            # intervals), upload ledger against an in-process fake
                                                            # server (sealed but not packed while offline, upload
                                                            # retry, new bundle while one is queued, merged, rejected / 404),
                                                            # download sha check + ack, incomplete results, finished
                                                            # rows kept on a repeat result, exchange lock, Detect,
                                                            # on a temp root + temp DBs
MyPortrait --segment-replay [--from yyyy-MM-dd] [--db PATH] # read-only replay: checks every :00 / :30, a frame
                                                            # counts from its created_at_ms; prints intervals,
                                                            # one-interval-per-frame check, Tier-1 session cuts
                                                            # vs UTC / local midnight, intervals per local day,
                                                            # frames per interval
CFFIXED_USER_HOME=$(mktemp -d .build/ivhome.XXXX) MyPortrait --interval-selftest
                                                            # local event step per interval (fake clustering, no
                                                            # LLM): events across two local days, a second interval
                                                            # into the same date dir, joins, failed-interval undo
                                                            # (step failure / crash / commit error), no frame cap,
                                                            # personality once per local day, OCR day window,
                                                            # calendar dates, local run timing (time_of_day,
                                                            # retry after backoff, Run now); needs an empty temp
                                                            # home that is not under /tmp or /var (symlinked
                                                            # paths break joins)
```

CLI processes share the exchange lock with a running app but not its scheduler locks — quit the
app before running `--premium-export` / `--premium-import` by hand while local chains may be running.

**Known limits.** A dry-run bundle keeps the current tree mirror, so events the chosen range
already produced are still in it.

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
