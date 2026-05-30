# DEVELOPER.md

Developer-facing guide for **My-Portrait** — a macOS-native Swift app that runs a 24/7 personal capture pipeline and distills it into a long-term "portrait" you can chat with. This is the engineering companion to the user-facing [README](./README.md); read that first for what the app *does*, then read this for how it's *built*.

---

## Architecture

### Module map

| Directory | Role |
| --- | --- |
| `Sources/MyPortrait/Capture/` | 24/7 perf-first capture layer (mirrors screenpipe). Sub-dirs: `Screen/` (`ScreenCaptureService`, `FrameComparer`, `SnapshotWriter`, DRM/ignore/permission gates), `Audio/` (`AudioCaptureService`, `SystemAudioCaptureService`, `SileroVAD`, `VADSegmenter`, `WhisperKitWrapper`, `Qwen3ASRWrapper`, `CloudTranscriber`, `TranscriptionScheduler`, `Speaker/` — pyannote + wespeaker diarization via ONNX), `OCR/` (`OCRService` + `OCRCache`), `Compaction/` (JPG→HEVC MP4 `CompactionWorker`), `Events/` (capture triggers, idle/workspace/pasteboard watchers), `Coordinator/` (`CaptureCoordinator` + `CaptureConfig`), `Health/` (`CaptureMetrics`, `StallDetector`), `Power/` (`PowerMonitor`, `PowerWatcher`), `DB/` (`PortraitDB` protocol). |
| `Sources/MyPortrait/Memory/` | Event→portrait distillation pipeline. `EventBuilder`/`EventClassifier`/`EventFolder` build semantic events; `PortraitDistiller` + `Personality*` agents + `SpeechStyle*` + `OCRToTags`/`PortraitToTags` agents distill the long-term portrait; `MemoryScheduler`/`MemoryBudget`/`MemoryStaging` orchestrate; `PortraitPaths`/`PortraitFileIO` own the `~/.portrait/portrait`+`events` file tree; `ImpactScorer`/`PortraitWeight`/`Archiver` score & age entries. |
| `Sources/MyPortrait/AI/` | Multi-provider chat + agents + cron. `ChatAgent`/`ChatController`/`ChatStore`, `PiAgent` (+ `PiInstaller`/`BunInstaller`, spawning a bun/pi-coding-agent subprocess) & `ClaudeCodeAgent`, `Provider`/`ConnectionCredentials`/`ChatGPTOAuth`/`SecretStore` (`secrets.sqlite`), `CronJob*` + `ScheduleRunner`, `PIIRedactor`, `SMTPClient`, `MPQuerySkill` (mp-query CLI bridge), `TimelineContext`/`SuggestionEngine`. |
| `Sources/MyPortrait/DB/` | GRDB + SQLite + WAL + FTS5 persistence. `PortraitDBImpl` (implements `Capture/DB`'s `PortraitDB` protocol), `Schema`, `Records/` (`FrameRow`, `VideoChunkRow`, `AudioChunkRow`, `TranscriptionRow`), `Search/` (`FTSSearchEngine` + `SearchEngine`), `Vectors/` (`VectorMath` + `EmbedDumpCLI`), `FoundationTokenizer`, `RetentionWorker`, `ScreenpipeImporter`. |
| `Sources/MyPortrait/Settings/` | Settings panes (SwiftUI) + TOML config read/write. `ConfigStore`/`ConfigSchema`/`ConfigSnapshot`/`ConfigApplier` own `~/.portrait/config.toml`; per-pane views (General, AIModels, Capture, CaptureHealth, Display, Import, Memory, Notifications, Privacy, Storage, Usage); `Speakers*` views for speaker organization/merge. |
| `Sources/MyPortrait/Typing/` | Typing capture & replay. `TypingObserver` + AX snapshots, `IMEStateMachine`(+`Registry`) for composition handling, `KeystrokeCharLogger`/`KeystrokeLedger`, `TextDiff`/`RawEdit`/`EditDraft`, `PasteboardMonitor`, `TypingPrivacyFilter`, `TypingEventStore`/`TypingRecordWriter`. |
| `Sources/MyPortrait/Notifications/` | In-app + system notifications. `NotificationCenterService` + `NotificationOverlay`. |
| `Sources/MyPortrait/Onboarding/` | First-run onboarding flow (`OnboardingView`). |
| `Sources/MyPortrait/Updater/` | Sparkle auto-update wrapper. `UpdaterService` wraps `SPUStandardUpdaterController`; UI hook in `Settings/GeneralView`. |
| `Sources/MyPortraitObjC/` | ObjC helper target (separate SwiftPM target). A try/catch wrapper that turns `NSException` (from `AVAudioEngine.installTap` / `engine.start` on format mismatch) into `NSError` so Swift isn't killed. `MyPortraitObjC.m` + `include/`. |
| `Sources/MyPortrait/` (root files) | App shell & shared UI. `App.swift` (entry point), `ContentView`/`HomeView`/`TimelineView`/`TimelineSidebar`/`TimelineDB`/`ConnectionsView`/`CronJobsView`, `DesignSystem` (glass + blue-gradient tokens), `Storage.swift` (single source of truth for the `~/.portrait` layout), `Models`, `Services`, `StatusBarMenu`, `PathMigration`, plus CLI entry shims (`MPQueryCLI`, `EventPromptTest`, `SchedulerTestCLI`, `VoiceTrainingTestCLI`, …). |

### Data layout (`~/.portrait/`)

All app data lives under the hidden root `~/.portrait/`. The single source of truth for the layout is `Sources/MyPortrait/Storage.swift` (`Storage.rootURL`); the AI subsystem reuses the same root via `AIPaths.supportDir`. `Storage.ensureExists()` creates the directories idempotently at launch and drops a `.metadata_never_index` marker at the root so Spotlight skips the whole tree (borrowed from screenpipe). `PathMigration` moves files from older locations into this layout on startup.

```
~/.portrait/
├── config.toml                      # user-editable TOML config (Settings/ConfigStore; template at docs/config.example.toml)
├── portrait.sqlite                  # frames / video_chunks / OCR / audio / transcriptions / FTS  (DB/PortraitDBImpl)
├── secrets.sqlite                   # provider creds / tokens  (AIPaths.secretsDB)
├── chat.sqlite                      # conversations  (AIPaths.chatDB)
├── portrait/                        # long-term distilled portrait (sub-dirs = seed categories)
├── events/<yyyy-MM-dd>/             # raw semantic event files
├── personality_daily/<YYYY-MM-DD>.md
├── journal/                         # append-only action log
├── logs/                            # daily raw JSON
├── raw_data/
│   ├── frames/<YYYY-MM-DD>/{ts_ms}_m{monitor}.jpg     # hot JPG tier
│   └── video/<YYYY-MM-DD>/m{id}_{startTs}.mp4         # HEVC compaction tier
├── audio_queue/                     # VAD-segmented WAV + deferred-transcription queue
├── voice_training/<speaker_id>.wav
├── bin/mp-query                     # shell wrapper that exec's the main binary with --mp-query (NOT a symlink — see Lessons)
├── bun/                             # bundled bun runtime
├── pi-agent/                        # pi-coding-agent node_modules + models.json
├── agent_sessions/<convId>.jsonl    # per-conversation pi session
├── cron_jobs/<slug>/                # cron_job.md + runs.json
└── models/                          # local model cache
```

All three SQLite databases run GRDB + SQLite in **WAL** mode. All timestamps are stored as **INTEGER UTC milliseconds** (see Lessons).

### End-to-end flow: capture → DB → memory → AI

The **Capture** layer records the screen and audio 7×24. `ScreenCaptureService` grabs frames, `FrameComparer` drops near-duplicates, `SnapshotWriter` writes the JPG and returns immediately while OCR (Vision) and the DB write fan out concurrently; audio is VAD-segmented and queued for transcription (WhisperKit / Qwen3-ASR / cloud), with diarization assigning speakers. Everything lands in **`portrait.sqlite`** plus `raw_data/`, and older JPGs are later compacted to HEVC MP4. The **Memory** pipeline reads that captured signal to build semantic events (`EventBuilder`/`EventClassifier`) and distills them into the long-term portrait file tree under `~/.portrait/portrait` and `events/` (`PortraitDistiller` + personality/speech-style agents), scheduled and budgeted by `MemoryScheduler`. The **AI** layer then exposes that portrait through multi-provider chat, the `mp-query` CLI bridge, cron jobs, and suggestion/timeline features, reading from the databases and the distilled portrait tree.

---

## Build & run

### Prerequisites

- **macOS 15+** (deployment target is macOS 15.0).
- **Xcode 16+** (swift-tools-version 6.0).
- **XcodeGen** (`brew install xcodegen`) — the `.xcodeproj` is a generated artifact, never hand-edited.

### Canonical commands

```bash
# 1. (Re)generate the Xcode project from project.yml — required after any .swift add/delete/rename
xcodegen generate

# 2. Build the real signed .app and launch it standalone
./build-app.sh --run
```

`swift build` is fine for quick compile checks, but the **real app must be built through Xcode / `build-app.sh`** (see why below).

### Why launch standalone, not Xcode ⌘R

TCC (macOS's Transparency, Consent & Control privacy system) attributes permission prompts to the process that *triggers* them. If you run via Xcode's ⌘R, the screen-recording and microphone prompts get attributed to **Xcode**, not to My-Portrait — so the app never actually receives stable permissions. `build-app.sh --run` builds the `.app` and launches it on its own, so TCC attributes screen/mic permissions to the app itself.

### Signing & why ad-hoc breaks TCC across rebuilds

TCC keys a granted permission to the app's code-signing identity (its **cdhash** / Team-ID-backed designated requirement). With ad-hoc signing, the cdhash changes on every rebuild, so macOS treats each new build as a *different* app and silently revokes previously granted screen/mic permissions — you'd have to re-approve in System Settings after every build. To get a stable identity, set your signing team via the override file:

```
Support/Signing.local.xcconfig
```

(`bundleIdPrefix` is `com.joyzhang`; the signing team is overridable through this local xcconfig.)

### After changing files

After adding/removing/renaming **any** `.swift` file — or editing `project.yml` — re-run `xcodegen generate` and have Xcode reload the project. SwiftPM auto-scans `Sources/` and doesn't need this; the `.xcodeproj` does (see Dual build system).

---

## Dual build system

Same source, compiled two ways. Both manifests are maintained **in parallel**, and `project.yml` deliberately pins newer dependency versions than `Package.swift`.

| | Track 1 — SwiftPM | Track 2 — XcodeGen |
| --- | --- | --- |
| Manifest | `Package.swift` (swift-tools-version 6.0, macOS 15) | `project.yml` (source of truth, ~7.8KB) |
| Produces | `swift build` compile checks / CI | `MyPortrait.xcodeproj` → signed `.app` |
| File list | Auto-scans `Sources/` — new files just work | **Static** — must regenerate after file changes |
| Targets | `MyPortrait` (links sqlite3, excludes per-module `README.md`) + `MyPortraitObjC` | Same, plus signing/TCC-stable bundle config |
| Dep pins | GRDB ≥7.0.0, WhisperKit ≥0.9.0, mlx-swift ≥0.18.0 | GRDB ≥7.10.0, WhisperKit ≥0.14.1, mlx-swift ≥0.21.3, qwen3-asr-swift exact 0.0.19 |

> **The one gotcha:** the `.xcodeproj` carries a static file list and does **not** auto-detect filesystem changes. After adding/removing/renaming any `.swift` file, you **must** run `xcodegen generate`, or the Xcode build fails with `Cannot find 'Xxx' in scope` (SwiftPM is unaffected). Editing `project.yml` config requires re-running it too. Never hand-edit the generated `.xcodeproj`.

---

## Tech stack

| Dependency | Purpose | Transitive notes |
| --- | --- | --- |
| [**GRDB.swift**](https://github.com/groue/GRDB.swift.git) | SQLite ORM / persistence (WAL + FTS5) for `portrait.sqlite`, `chat.sqlite`, `secrets.sqlite`. Backs `DB/PortraitDBImpl`, `Records`, `FTSSearchEngine`. | SwiftPM pins from 7.0.0; `project.yml` from 7.10.0. |
| [**WhisperKit**](https://github.com/argmaxinc/WhisperKit) | On-device speech-to-text (Whisper) — default/fallback transcription engine (`Capture/Audio/WhisperKitWrapper`). | Pulls `swift-transformers` (Tokenizers/Hub) and `swift-argument-parser` transitively — there is **no** direct `swift-transformers` dependency anymore. SwiftPM from 0.9.0; `project.yml` from 0.14.1. |
| [**mlx-swift**](https://github.com/ml-explore/mlx-swift.git) | Apple-MLX runtime for on-device ML (MLX/MLXNN/MLXFast products). Underpins the MLX-based audio engine; embeds `default.metallib`. | The former `mlx.embeddings` (bge-m3) usage was **removed**; only the core MLX/MLXNN/MLXFast products are linked. SwiftPM from 0.18.0; `project.yml` from 0.21.3. |
| [**qwen3-asr-swift**](https://github.com/ivan-digital/qwen3-asr-swift.git) | Qwen3-ASR native transcription engine (MLX-backed), used by `Capture/Audio/Qwen3ASRWrapper` + `TranscriptionScheduler` as an alternative ASR engine. Only the `Qwen3ASR` product is linked (its bundled TTS / hummingbird server are intentionally unused). | Pinned **EXACT 0.0.19** (0.0.x churns fast — exact pin keeps builds reproducible). Drags in a large transitive graph: `swift-transformers`, `swift-jinja`, `hummingbird`/`hummingbird-websocket`, `async-http-client`, the `swift-nio` stack, `swift-crypto`/`certificates`/`asn1`, `swift-collections`/`algorithms`/`numerics`, etc. (see `Package.resolved`). |
| [**onnxruntime-swift-package-manager**](https://github.com/microsoft/onnxruntime-swift-package-manager) | ONNX Runtime for speaker work + VAD: pyannote diarization + wespeaker CAM++ embeddings (`Capture/Audio/Speaker/SpeakerOnnx`) and `SileroVAD`. | from 1.24.0. |
| [**TOMLKit**](https://github.com/LebJe/TOMLKit.git) | TOML 1.0 codec for the user-editable `~/.portrait/config.toml` (`Settings/ConfigStore` round-trips UI ⇄ file). | from 0.5.0. |
| [**Sparkle**](https://github.com/sparkle-project/Sparkle) | macOS auto-update framework (appcast.xml hosted on GitHub Pages). Wrapped by `Updater/UpdaterService`, UI in `Settings/GeneralView`. | from 2.6.0. |

---

## Lessons learned (经验教训)

The most important section. These are hard-won; preserve the detail.

### Database & FTS

**GRDB `arguments:` must be a dict, never an array literal**
- *Symptom:* The app randomly freezes/hangs. A GRDB reader thread pins 100% CPU stuck in `StatementArguments.append(contentsOf:)` → `Array.append` → `swift::_getWitnessTable` → `<deduplicated_symbol>`; the main thread then stalls on SwiftUI updates and the whole app appears dead. Only catchable via Activity Monitor → Sample.
- *Why:* An array literal like `[v1, v2]` is implicitly bridged to `[any DatabaseValueConvertible]`. The Swift runtime intermittently infinite-loops in `_getWitnessTable` resolving protocol conformance for that existential array — a known libswiftCore edge case, unrelated to GRDB.
- *Rule:* Always pass `arguments:` as a dict with named placeholders (`arguments: ["a": v1]`), never a positional array literal. Explicitly cast `Int` → `Int64` (dict form has no implicit conversion: `["limit": Int64(limit)]`). For dynamic variadic `IN` clauses that must keep an array, wrap it as `StatementArguments(args)` (a different API path), not a literal. If the app ever "mysteriously freezes", suspect a leftover array-literal `arguments:` site first.

**System SQLite has FTS5 but no ICU / no LOAD_EXTENSION — use the Foundation custom tokenizer**
- *Symptom:* Relying on an ICU FTS5 tokenizer or loading a SQLite extension fails on macOS's bundled sqlite3.
- *Why:* macOS's system SQLite is compiled with FTS5 only — no ICU tokenizer, no LOAD_EXTENSION.
- *Rule:* Do word segmentation via the project's `FTS5CustomTokenizer` built on `String.enumerateSubstrings(.byWords)` (internally ICU on Darwin), giving ICU-equivalent results without ICU compiled into SQLite. Both `frames_fts` and `transcriptions_fts` must use this same tokenizer.

**Updating ANY column of `audio_transcriptions` requires GRDB, never raw sqlite3**
- *Symptom:* Any `UPDATE audio_transcriptions` (even just `speaker_id`) run via the `sqlite3` CLI or a bare sqlite3 connection makes the FTS5 sync trigger fail and rolls back the whole transaction.
- *Why:* `audio_transcriptions` has an `AFTER UPDATE ON` FTS5 sync trigger (`__transcriptions_fts_au`, fires on **any** column) that re-tokenizes via the custom tokenizer `foundation_icu`. That tokenizer is only registered in GRDB's `prepareDatabase`, so any connection lacking it errors inside the trigger.
- *Rule:* Reassign transcription ownership (e.g. merge speakers) only through GRDB (`mergeSpeakers`, `TimelineDB.swift`) or in-app buttons. CLI data fixes may only touch `speakers` / `speaker_embeddings` (no FTS trigger). To surface a speaker's name on historical transcripts, set `speakers.hallucination=0` (name is JOINed at read time) instead of reassigning rows.

**Migrations are append-only; removed columns stay as dead columns**
- *Symptom:* Tempting to delete/rewrite old migrations or drop now-unused columns (e.g. `frames.embedding`, `audio_transcriptions.embedding` from the removed semantic-search subsystem).
- *Why:* A shipped `DatabaseMigrator` migration must never be edited (clients have already applied it); migrations can only be appended. So removed-feature columns remain in schema.
- *Rule:* Never modify a published migration — add a new one. Leave dead columns in place (unused BLOBs live on SQLite overflow pages, so not reading them = 0 cost). Don't confuse the dead text-embedding columns with the **live** speaker-voiceprint vectors (`speakers.centroid` / `speaker_embeddings.embedding`), which are in active use.

**Never `SELECT *` — name columns to skip heavy overflow-page blobs**
- *Symptom:* Queries get slow/heavy when `frames` includes large per-row columns like `ocr_words_json` (KB-scale per frame).
- *Why:* Large columns spill to SQLite overflow pages; SQLite only pays I/O for columns you actually read.
- *Rule:* Never `SELECT *`; always list explicit column names so unread overflow-page columns cost nothing.

**Timestamps are INTEGER UTC milliseconds everywhere**
- *Symptom:* Mixing ISO strings or seconds-based timestamps with the DB causes slow indexing and conversion bugs.
- *Why:* The project standardizes all timestamps as INTEGER UTC ms — fast to index, no ISO parsing, one-line conversion.
- *Rule:* Store and compare all timestamps as INTEGER UTC ms; convert with `Date(timeIntervalSince1970: ms/1000)`.

**SearchEngine shares the DB's single GRDB `DatabasePool`**
- *Symptom:* Spinning up a second `DatabasePool` for search would create redundant connections and break WAL concurrency assumptions.
- *Why:* `FTSSearchEngine` is constructed with the same pool as the DB (`FTSSearchEngine(dbPool: dbImpl.dbPool)`); WAL gives concurrent reads with a single writer through one pool. The `SearchEngine` protocol is the stable seam, so UI calls `services.searchEngine.*` unchanged even if the implementation is swapped.
- *Rule:* Reuse the existing `DatabasePool` for search; keep UI calling through the `SearchEngine` protocol.

**DB writes only touch `portrait.sqlite` / `raw_data/`; the screenpipe source library is read-only**
- *Symptom:* Importing screenpipe history risks mutating the source library or duplicating media files.
- *Why:* `ScreenpipeImporter` imports via read-only copy and writes only into `portrait.sqlite`'s `frames` table, tagging imported rows `device_name='imported'` instead of copying media.
- *Rule:* When importing, only write to `portrait.sqlite` / `raw_data/`; never mutate the screenpipe source library; distinguish imported rows via `device_name='imported'`. (More broadly: never write, move, or delete anything under `~/.screenpipe` — `cp`, never `mv`. The screenpipe daemon owns those files.)

### Build & dependencies

**Dual-track build: run `xcodegen generate` after any add/delete/rename of a `.swift` file**
- *Symptom:* `swift build` works fine, but the Xcode build fails with `Cannot find Xxx in scope` for the newly added file/symbol.
- *Why:* SwiftPM (`Package.swift`) auto-scans all `.swift` under `Sources/` so new files just work; the `.xcodeproj` is a generated artifact (XcodeGen from `project.yml`) that does not auto-sense filesystem changes, so a stale project doesn't include the new file.
- *Rule:* After every add/delete/rename of a `.swift` file (or any `project.yml` config change), run `xcodegen generate`, then reopen the project in Xcode. Don't hand-edit the `.xcodeproj`.

**Trust `swift build`'s "Build complete", not SourceKit's in-module errors**
- *Symptom:* SourceKit reports "Cannot find type …" within the same module, but the code actually compiles.
- *Why:* SourceKit's "Cannot find type" errors for same-module symbols are frequently false positives.
- *Rule:* Verify with `swift build` and treat "Build complete" as the source of truth; ignore SourceKit same-module noise. (Pure data changes under `~/.portrait/` need only an in-app reload/restart; code changes need a rebuild.)

**`mlx.embeddings` (bge-m3) pinned old `swift-transformers`/`mlx-swift` and blocked Qwen3-ASR**
- *Symptom:* Couldn't add the native Qwen3-ASR Swift package (its `Package.swift` requires `swift-transformers` from 1.1.6 / mlx-swift from 0.30.0); SwiftPM resolution failed on incompatible transitive pins.
- *Why:* `mzbac/mlx.embeddings` (the bge-m3 semantic-search subsystem) was the single blocker in the graph — its old, now-historical upper-bound pins on `swift-transformers`/`mlx-swift` (roughly `swift-transformers <0.2` / mlx-swift `<0.26`, approximate since the dependency has since been deleted and can't be re-verified) held the whole graph down.
- *Rule:* When a transitive pin blocks a needed package, trace the conflict to the offending direct dependency and consider removing it if its feature is expendable. Removing the bge-m3 subsystem (`BGEM3VectorEmbedder`/`EmbeddingWorker`/`HybridSearchEngine`/`NLEmbedding`/RRF; search fell back to pure FTS5) let mlx-swift rise and unblocked qwen3-asr-swift (exact 0.0.19). Commits `420c784` (remove bge-m3) + `482894a` (add Qwen).

### Capture & permissions

**Capture/ is performance-first — concrete throughput/latency rules**
- *Symptom:* Convenience abstractions or per-frame overhead silently balloon CPU/battery/disk because the layer runs 7×24 (an extra 10ms/frame ≈ ~14 min CPU/day at 86,400 frames).
- *Why:* The capture layer is hard-constrained on CPU/battery/disk; tradeoffs always favor performance over elegance.
- *Rule:* In priority order — prefer zero-copy (pass `CGImage`/`CVPixelBuffer`/`IOSurface`, never `Data→CGImage→Data`); dedupe before OCR (cache key `appName::title + imageHash`); encode JPG via ImageIO `CGImageDestination` (not `NSImage`/`NSBitmapImageRep`); hash images with Accelerate vDSP; feed Vision OCR luma8 grayscale not RGBA; DB writes async + batched in one transaction; never call `@MainActor` on the capture path (push UI via `AsyncStream`); avoid String interpolation on hot paths (use `os.Logger` format strings); wrap each frame's processing in `autoreleasepool` (Vision/ScreenCaptureKit leak ObjC temporaries — without the pool RSS grows large and unbounded); don't add protocol/abstraction layers on hot paths (prefer struct over class/actor). Targets: end-to-end <200ms median, steady RSS <300MB (excl. transcription model), avg CPU <5%.

**Capture pipeline: write JPG first and return immediately; OCR + DB run concurrently**
- *Symptom:* Blocking the capture loop on OCR or DB insert stalls frame throughput.
- *Why:* `SnapshotWriter.enqueue` returns the JPG URL immediately; OCR (Vision) and `PortraitDB.insertFrameWithOCR` run concurrently, with `updateFrameOCR` patching the row if a placeholder frame was inserted first. `FrameComparer` (Hellinger histogram) drops near-duplicates first.
- *Rule:* Keep the loop non-blocking: enqueue the JPG and return, dedupe with `FrameComparer.shouldKeep`, fan out OCR + DB writes concurrently rather than serially.

**`FocusProbe` hot path must be read-only cached (actor over NSWorkspace)**
- *Symptom:* Querying app/window/url focus synchronously on the hot path adds latency.
- *Why:* `FocusProbe` is an actor that listens to NSWorkspace notifications and serves the hot path from a read-only cache.
- *Rule:* Read focus (app/window/url) from `FocusProbe`'s cached state on the hot path; update the cache from NSWorkspace notifications, not by probing per frame.

**Two-stage frame storage: P1 writes JPG, P3 compacts to HEVC MP4 then deletes JPG (only after commit)**
- *Symptom:* Deleting source JPGs before the DB transaction commits risks data loss if compaction fails.
- *Why:* `CompactionWorker` batches JPGs older than 10 min into HEVC MP4 (VideoToolbox hardware encode), then `replaceFramesWithVideoChunk` runs as a transaction repointing `frames` rows to MP4 + `offset_ms`. JPG deletion is the caller's responsibility, done **only after commit**. Compaction skips on battery and accelerates (5s loop) only on AC with a large backlog (5000+).
- *Rule:* Delete original JPGs only after `replaceFramesWithVideoChunk`'s transaction commits; skip compaction on battery.

**Power-aware scheduling: battery = record + VAD only, never Whisper/Compaction**
- *Symptom:* Running WhisperKit transcription or HEVC compaction on battery drains power / spikes CPU on a 24×7 app.
- *Why:* Design decision — on battery keep CPU <3% by only recording + VAD; heavy transcription and JPG→MP4 compaction are deferred until AC. `PowerWatcher` exposes the event-driven `AsyncStream<PowerState>` (`.states`), while `PowerMonitor.currentState()` is the synchronous one-shot query. `TranscriptionScheduler` subscribes to `PowerWatcher.states` (event-driven, with a 60s fallback poll) and runs pending chunks when AC connects, stopping after the current segment finishes when unplugged; `CompactionWorker` gates itself with the synchronous `PowerMonitor.currentState()`.
- *Rule:* Gate WhisperKit transcription and Compaction on `PowerState.ac`; on battery only record + VAD. When unplugged, let the in-flight segment finish then stop.

**Crash recovery for transcription uses DB status as source of truth**
- *Symptom:* A crash or power loss mid-transcription could orphan a segment in `in_progress` forever.
- *Why:* A segment's lifecycle is tracked by `audio_chunks.status` (`pending`/`in_progress`/`done`/`failed`); worst-case loss is the single segment currently transcribing (<90s). The DB status, not in-memory state, is authoritative.
- *Rule:* On restart, scan `audio_chunks` for `status='in_progress'`, treat them as crashed, and reset to `pending` to re-run.

**`notImplemented` stubs must be loud, never silently swallowed**
- *Symptom:* The worst failure mode is a stub silently reaching production — the feature isn't running but nothing surfaces the error.
- *Why:* Stubs are temporary placeholders; if `try? throws_notImplemented()` swallows them, a missing implementation can ship undetected.
- *Rule:* Model the error with component + file/line: `case notImplemented(component: String, file: String = #file, line: Int = #line)`. Route every throw through a single reporter (`UnimplementedReporter`) that logs at `os.Logger` WARN, increments a count, and flips a `@Published hasUnimplementedStubs`. Show a (default-hidden) `NSStatusItem` red dot when triggered. Add `testNoUnimplementedInProductionFlow()` asserting `count==0` on the main path in CI, plus a release-script grep step. Never use `try?` to swallow it.

### Models (MLX / ASR)

**`swift build` does not compile the MLX Metal shader library; Xcode does (~3.6MB)**
- *Symptom:* Command-line `swift build` binaries running MLX inference fail at runtime with "Failed to load default metallib" / "MLX error: library not found". The same code works in the Xcode-built `.app`.
- *Why:* CLI `swift build` doesn't compile mlx-swift's Metal shader library. Xcode auto-compiles a small `default.metallib` (~3.6MB, verified at `.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`) and embeds it into the `.app`. Since the user builds in Xcode, no extra step is needed.
- *Rule:* Treat CLI-only MLX runtime failures as the expected missing-metallib case, not a real bug — verify in the Xcode `.app`. Do **not** add a custom build step or treat qwen3-asr-swift's `scripts/build_mlx_metallib.sh` standalone `mlx.metallib` full compile as the relevant size — that full standalone compile is much larger and unnecessary here; the auto-compiled embedded `default.metallib` is only ~3.6MB.

**Use a shell-wrapper `exec`, not a symlink, for the `mp-query` CLI entry**
- *Symptom:* Launching the main binary via a symlink in `~/.portrait/bin/` makes mlx-swift's `Bundle.module` fail to locate the embedded `default.metallib` → "MLX error: library not found", exit 255.
- *Why:* A symlink makes `Bundle.main` resolve `bundlePath` to the symlink's directory (`~/.portrait/bin/`), so the metallib embedded inside the `.app` is no longer found. A shell wrapper that `exec`s the absolute path of the `.app`'s main binary keeps `argv[0]` pointing inside the `.app`, so Bundle resolution works.
- *Rule:* When exposing an in-app binary as an external CLI entry point, `exec` it via a shell wrapper using the absolute executable path (rewritten each launch, since the path changes on upgrade), not a symlink — otherwise bundled resources like the MLX metallib break.

### Agents & LLM

**Writing-capture LLM model is locked to `sonnet` (200K) — never `sonnet[1m]`**
- *Symptom:* Bumping `WritingCapturePass1Agent` / `WritingCapturePass2Agent` to `"sonnet[1m]"` requires the user to pay-enable 1M-context "Usage credits", which the user explicitly refuses.
- *Why:* 1M context is a paid add-on; 200K is empirically sufficient — Pass 2 is grouped/concurrent by `(app, url)` so each prompt is small, and Pass 1 is only ~23k chars after a full day of OCR pre-compaction.
- *Rule:* Keep the model default `"sonnet"`; never change it back to `"sonnet[1m]"`.

**Canvas edit-history reconstruction: window fanout, not single-call; chrome via frequency, not geometry**
- *Symptom:* A single `claude --print` call fed all snapshots hangs (40 frames = 27 min; 12 frames = 8 min); geometry-based chrome stripping (`top<0.18`) doesn't adapt across resolutions/zoom; adjacent-frame diff algorithms produce all-noise output.
- *Why:* Algorithms can't distinguish UI chrome from body text (chrome jitter looks like mid-content edits; unchanged body looks like a common suffix to strip) — the LLM can. And a single agent's context is a cost/granularity bottleneck.
- *Rule:* Identify chrome via cross-frame frequency (>85% of frames = UI, adaptive, no per-app hardcoding); split snapshots into overlapping token-budgeted windows (≤6 frames / 25k chars, 1-frame overlap) and run one subagent per window concurrently (cap ~5), then merge. Do **not** revert to a single all-snapshots call (hangs), to relaxed dedup (more frames ≠ clearer process), or to geometric chrome cropping.

### Working in this repo

**Parallel Claude sessions write the work tree — never blind-add**
- *Symptom:* A concurrent session committed this session's uncommitted files into unrelated commits, so commit messages no longer matched their contents.
- *Why:* Multiple Claude sessions operate on the same working tree simultaneously.
- *Rule:* Run `git status` before any large change, and twice before committing. Never `git add .` / `git add -A` — always list explicit paths. If you see a `Co-Authored-By: Claude` commit that isn't yours, stop and tell the user; never reset/amend. Never touch unexpected dirty files you didn't create.

---

## Going deeper

Each capture/DB sub-area has its own README with the full design rationale:

- `Sources/MyPortrait/Capture/README.md` — capture layer overview, budgets, the perf-first hot-path rules.
- `Sources/MyPortrait/Capture/Audio/README.md` — audio capture, VAD, transcription engines, speaker diarization.
- `Sources/MyPortrait/Capture/Compaction/README.md` — two-stage frame storage (JPG → HEVC MP4).
- `Sources/MyPortrait/Capture/Events/README.md` — capture triggers and watchers.
- `Sources/MyPortrait/Capture/Power/README.md` — power-aware scheduling and crash recovery.
- `Sources/MyPortrait/DB/README.md` — schema, FTS5 custom tokenizer, migrations, search engine, importer.
