# My-Portrait 代码审查报告
> 多 agent 审查 + 对抗验证。审查 65 个候选,确认 **53** 个真 bug,剔除 12 个误报。
> 严重程度:🔴 critical 2 · 🟠 high 14 · 🟡 medium 17 · ⚪ low 20

---

## 🔴 CRITICAL

### 1. Imported screenpipe audio file_path stored as raw ~/.screenpipe absolute path → RetentionWorker later deletes the source files (read-only violation + data loss)
- **位置**: `Sources/MyPortrait/DB/ScreenpipeImporter.swift:807-815`  ·  分类: data-loss  ·  子系统: db-import/search/vectors
- **问题**: importAudio INSERTs My-Portrait audio_chunks with file_path = c.filePath, where c.filePath is the unmodified screenpipe path. Unlike video chunks (which are copied into ~/.portrait/raw_data/video and re-pathed), audio files are NOT copied — the absolute screenpipe path is stored verbatim. screenpipe stores absolute paths under ~/.screenpipe/data/ (verified: 'SELECT file_path FROM audio_chunks' returns '/Users/joyzhang14/.screenpipe/data/...mp4'). When RetentionWorker later runs, PortraitDBImpl.mediaPathsBefore resolves these rows via AssetPath.resolve (which returns the absolute path as-is when isAbsolutePath && the file exists), and RetentionWorker.deleteFiles calls fm.removeItem on each audioPath PLUS its '.meta.json' / '.transcript.json' siblings — i.e. it deletes files living inside ~/.screenpipe/data/.
- **影响/触发**: This violates the hard read-only constraint on ~/.screenpipe (the directory must never be written/moved/deleted) and silently destroys the user's original screenpipe audio recordings. It triggers reliably: the importer by design only brings in data OLDER than My-Portrait's earliest data, so imported audio_chunks have the smallest recorded_at_ms in the DB and are the FIRST rows whose recorded_at_ms < cutoffMs once any retention window (7/14/30/60/90 days) elapses. RetentionWorker runs automatically (5 min after cold start, then every 24h) whenever retentionDays != forever and autoDeleteMode != off, so a normal user with auto-delete enabled will have their screenpipe source audio (and sidecars) deleted with no warning.
- **修复建议**: Make imported audio behave like imported video: copy the screenpipe audio file into ~/.portrait and store a Storage.rootURL-relative path, so retention only ever deletes the My-Portrait copy and never touches ~/.screenpipe.

In importAudio (ScreenpipeImporter.swift, before the INSERT at 807): for each chunk, resolve the source URL (`c.filePath.hasPrefix("/") ? URL(fileURLWithPath: c.filePath) : sourceDir.appendingPathComponent(c.filePath)`), skip if missing, compute a day-bucketed dest under an audio raw dir (mirror the video logic: `imported_<basename>` under e.g. `raw_data/audio/<day>/`, day from c.firstTsMs in UTC), `fm.copyItem` if not already present, and INSERT `file_path` = the relative path string (e.g. "raw_data/audio/<day>/imported_<basename>") instead of `c.filePath`. Reuse-on-re-import: if the dest already exists, look up the existing audio_chunks row by that relative path and reuse its id (same pattern as importVideoChunks 483-497). This keeps AssetPath.resolve mapping the row into ~/.portrait and makes RetentionWorker.deleteFiles delete only the copy.

Note: importAudio currently has no sourceDir parameter (unlike importVideoChunks) — thread sourceDir through importAudio's signature and its call site at 349-353 (sourceDir is already in scope there).

Minimal alternative if copying is undesirable: have mediaPathsBefore (or deleteFiles) skip any audio path that is NOT under Storage.rootURL — i.e. never removeItem a path outside ~/.portrait. But that leaves stale absolute screenpipe paths in the DB pointing at read-only data; the copy-and-relativize approach (matching video) is the correct fix.

### 2. StorageView "Delete recent data" purges audio_transcriptions via a raw sqlite3 DELETE without the FTS5 tokenizer → silent data-loss / privacy failure
- **位置**: `Sources/MyPortrait/Settings/StorageView.swift:165-174`  ·  分类: data-loss  ·  子系统: settings-views-rest
- **问题**: The "Last 15 min / 30 min / hour" delete buttons call purge(seconds:) → TimelineDB().deleteAfter(cutoff). deleteAfter (TimelineDB.swift:669-689) opens a *raw* sqlite3 connection (sqlite3_open_v2, no GRDB, no registered tokenizer) and runs `DELETE FROM audio_transcriptions WHERE transcribed_at_ms >= ?` (TimelineDB.swift:683). audio_transcriptions is synchronized with the FTS5 virtual table `transcriptions_fts`, which is built with the custom FoundationTokenizer (`foundation_icu`) — see DB/Schema.swift:125-131. GRDB's synchronize() creates an AFTER DELETE trigger on audio_transcriptions that does `INSERT INTO transcriptions_fts(transcriptions_fts,'delete', OLD.rowid, OLD.text)`, which must tokenize OLD.text and therefore requires `foundation_icu` to be registered on the connection. On the raw sqlite3 connection that tokenizer is NOT registered, so the DELETE's AFTER-DELETE trigger fails (`no such tokenizer: foundation_icu`) and the statement errors out — exactly the documented landmine (CLAUDE.md constraint #4; TimelineDB.swift:1141-1142; RetranscribeQwenCLI.swift:10; FixSpeakersCLI.swift:12-13). Result: the audio transcripts the user asked to purge are NOT deleted (and the returned DeleteResult.error is swallowed at StorageView line 171 `_ = res`), so the UI reports success while sensitive transcribed speech remains on disk.
- **影响/触发**: This is a destructive, no-undo privacy action: the user clicks "Delete last 15 min" expecting their captured speech transcripts in that window to be gone. Because the DELETE hits the FTS5 AFTER-DELETE trigger on a connection without the foundation_icu tokenizer, the audio_transcriptions delete fails/rolls back and the data silently survives — a privacy/data-loss bug that triggers every time there is at least one transcription row in the chosen window. The frames DELETE (different statement, autocommit) may succeed while the audio delete fails, leaving the DB in a partially-purged state, and the error is never surfaced to the user.
- **修复建议**: Route deleteAfter (and the sibling deleteBefore at TimelineDB.swift:640-664, which has the identical raw `DELETE FROM audio_transcriptions` problem) through a GRDB connection that registers the tokenizer, exactly like RetranscribeQwenCLI / FixSpeakersCLI / the merge path at TimelineDB.swift:1141-1158. Simplest: open a GRDB DatabaseQueue/Pool with `config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }` and run the two DELETEs inside a `try db.inTransaction { ... }` (or reuse the existing PortraitDB pool). Alternatively, mirror ReOcrCLI: DROP the __transcriptions_fts_ad / __frames_fts_ad triggers on the raw connection before the deletes and recreate them after (uglier, leaves FTS index stale, not recommended). Either way also surface the error: stop discarding `res` in StorageView.purge() (line 171 `_ = res`) — if DeleteResult.error is non-nil, show it to the user instead of reporting silent success, since this is an irreversible privacy operation.

## 🟠 HIGH

### 3. bunAdd hangs forever: terminationHandler set AFTER run + undrained pipes deadlock
- **位置**: `Sources/MyPortrait/AI/PiInstaller.swift:135-138`  ·  分类: deadlock  ·  子系统: ai-agents/providers
- **问题**: `bunAdd` calls `try p.run()` on line 135 and only afterwards installs `p.terminationHandler` inside `withCheckedContinuation` (line 137). It also wires `stdout`/`stderr` to `Pipe()`s that are never drained until after the process exits (stderr is read on line 141, stdout never read).
- **影响/触发**: Two independent failure modes, both reachable on a normal `bun add @mariozechner/pi-coding-agent@0.60.0`: (1) Race — if the child terminates before line 137 runs (fast failure, e.g. bun arg error or cache hit), the handler attached to an already-exited Process never fires, so `withCheckedContinuation` never resumes and the install Task hangs forever (AISetup stays stuck in `.installingPi`, never `.ready` or `.error`). (2) Pipe-buffer deadlock — `bun add` of a package with transitive deps emits well over the ~64KB pipe buffer of combined stdout/stderr progress; with no reader draining the pipes, the child blocks on write, never exits, and the `await` hangs forever. Either way the first-run AI setup wedges with no error surfaced to the user.
- **修复建议**: Drain both pipes concurrently and reap the process race-free. Replace lines 130-143 with something like:

  let stderr = Pipe(); p.standardError = stderr
  let stdout = Pipe(); p.standardOutput = stdout

  // Read both pipes off-thread BEFORE/while the process runs so neither
  // can fill the ~64KB OS buffer and block the child on write().
  async let errData = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
  async let outData = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value

  try p.run()
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      // Set the handler BEFORE there is any chance of relying on it; but
      // since run() already happened, guard the already-exited case:
      p.terminationHandler = { _ in cont.resume() }
      if !p.isRunning { p.terminationHandler = nil; cont.resume() }
  }
  let errStr = String(data: await errData, encoding: .utf8) ?? ""
  _ = await outData
  guard p.terminationStatus == 0 else {
      throw InstallError.installFailed(errStr.isEmpty ? "exit \(p.terminationStatus)" : errStr)
  }

Cleaner alternative matching the sibling unzip() helper: keep readabilityHandler-based draining on background reads, then `p.waitUntilExit()` (which reaps regardless of timing, eliminating the race entirely) instead of the terminationHandler continuation. The two essentials: (a) never assign terminationHandler after run() without an already-exited guard, and (b) always drain stdout (and stderr) concurrently with process execution, not after termination.

### 4. applicationWillTerminate deadlocks the graceful shutdown — cleanup never runs
- **位置**: `Sources/MyPortrait/App.swift:625-631`  ·  分类: deadlock  ·  子系统: app-core/services
- **问题**: On Quit, the main thread blocks on a DispatchSemaphore while a detached Task tries to await Services.stopManagedLifecycle(), which is @MainActor-isolated. The detached task can only run that method by hopping onto the main actor (main thread) — but the main thread is parked inside sem.wait(). The semaphore is only signalled after stopManagedLifecycle() finishes, which it cannot, so it never runs within the 1s window.
- **影响/触发**: applicationWillTerminate is a non-isolated NSApplicationDelegate callback executing on the main thread. Services is declared `@MainActor final class Services` and stopManagedLifecycle() is a plain (main-actor-isolated) method — it directly touches main-actor stored properties (powerProfileTask, settingsCancellables, etc.). `await services?.stopManagedLifecycle()` therefore must reach the main executor, which is blocked by `sem.wait(timeout: .now() + 1.0)`. Result: the await suspends, the 1s timeout elapses, and the function returns having done NONE of the intended graceful teardown — coordinator.stop() (closing the SCStream), audio/systemAudio.stop(), compactor.stop(), transcriber.stop(), retentionWorker.stop(), powerWatcher.stop(), permissions.stop() all silently skipped. In-flight capture/transcription buffers that rely on these stop() paths to flush are dropped, and the SCStream is left for the OS to tear down. Triggers on every normal Cmd-Q quit.
- **修复建议**: Do not synchronously block the main thread on a continuation that itself needs the main actor. Two viable fixes:

(A) Pump the main run loop instead of blocking it, so the main-actor cleanup task can actually run:
    let done = DispatchSemaphore(value: 0)   // or a flag
    let services = self.services
    Task { @MainActor in
        await services?.stopManagedLifecycle()
        done.signal()
    }
    let deadline = Date().addingTimeInterval(1.0)
    while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
This keeps the main run loop draining so the @MainActor continuation executes, and still caps total time at ~1s.

(B) Better: move the off-main work out of the main-actor method. The actor `.stop()` calls (coordinator/audio/systemAudio/compactor/transcriber/retentionWorker) don't need the main thread; only the synchronous @MainActor bits do. Split stopManagedLifecycle so the actor stops run on a detached task (no main-actor hop) and only the few main-actor stop()/cancel/removeAll calls run via `await MainActor.run { … }`. Then the detached Task in applicationWillTerminate no longer needs to acquire the (blocked) main actor before doing the bulk of the flushing.

Either way, the core rule: never call `sem.wait()` on the main thread while the work you're waiting for is @MainActor-isolated.

### 5. DRM immediate-fallback can latch capture OFF forever (no clear path)
- **位置**: `Sources/MyPortrait/Capture/Coordinator/CaptureCoordinator.swift:266-271`  ·  分类: logic  ·  子系统: capture-lifecycle/health
- **问题**: captureOneFrame's inline DRM fallback sets drmActive=true directly, but the ONLY code that resets drmActive back to false is handleDRMState(false), which is fired exclusively by DRMWatcher on a true->false transition. DRMWatcher only yields when blocked != lastBlocked. If DRM content appears and disappears within a single 3s watcher poll gap, the watcher never observes blocked==true (lastBlocked stays false), so it never emits a false event. drmActive stays true permanently.
- **影响/触发**: Once drmActive latches true with no matching watcher transition, captureOneFrame returns at the top (line 246-248) for every subsequent trigger and the entire screen-capture pipeline is dead until the app is restarted. The comment on line 266 explicitly motivates this fallback for 'brief Netflix' scenarios — exactly the transient case that triggers the stuck state. It also desyncs IntentionalPauseState.drmActive (only handleDRMState updates that), so StallDetector won't even mark it as an intentional pause; instead attempts keep incrementing (recordAttempt at line 261 runs before the return) with zero persists, inflating silent_loss and potentially raising a spurious visionDbWrite stall too.
- **修复建议**: Make the inline fallback go through the same single source of truth as the watcher so both drmActive and lastBlocked stay in sync and a recovery transition is guaranteed. Minimal fix: in captureOneFrame replace the inline body with a call to handleDRMState(true) (so IntentionalPauseState is also updated), AND seed the watcher's lastBlocked to true so its next clear-poll emits a false transition. Concretely:

1) At lines 267-271, change to:
   if drm.isBlocked(focusInfo) {
       await handleDRMState(true)
       await drmWatcher.noteInlineBlock()   // new: sets lastBlocked = true
       return
   }
   (handleDRMState already calls screen.invalidateStream(), so drop the duplicate.)

2) Add to DRMWatcher an actor method:
   func noteInlineBlock() { lastBlocked = true }
   so the next poll that sees blocked==false fires the false transition → handleDRMState(false) → drmActive reset.

This guarantees: even if DRM disappears before the watcher's first true-poll, lastBlocked is already true, so the watcher emits the clearing false event on its next poll. It also fixes the IntentionalPauseState desync (no spurious stall) and the missing-UI-indicator. Note separately (out of scope of this finding but worth flagging): DRMWatcher.stop() calls _continuation.finish(), permanently killing the states AsyncStream, so after one capture toggle off/on the watcher can no longer deliver state to the coordinator at all — the watcher's stream/continuation should be rebuilt per start() like EventSources does, otherwise even the fixed recovery path stops working after a toggle cycle.

### 6. Duplicate cluster heads crash PersonalityMerger via Dictionary(uniqueKeysWithValues:)
- **位置**: `Sources/MyPortrait/Memory/PersonalityMerger.swift:414`  ·  分类: crash  ·  子系统: memory-personality/portrait
- **问题**: parseActions builds `Dictionary(uniqueKeysWithValues: clusters.map { ($0.head, $0) })` keyed on cluster.head. If two clusters share the same head string, this traps at runtime with a fatal duplicate-key error, killing the whole personality refresh.
- **影响/触发**: Duplicate heads are reachable. (1) PersonalityRefresh.refreshImpl emits TWO candidates per kept tag with the SAME tag.name — one source=.events and one source=.ocr (PersonalityRefresh.swift lines 91-100). (2) PersonalityClusterAgent.parseClusters does NOT dedup on head — the LLM can return two cluster objects with the same head string. (3) The orphan fallback in clusterWithRaw appends `PersonalityCluster(head: c.tag, members: [c])` (PersonalityClusterAgent.swift lines 95-98); if the LLM clusters the .events candidate under head="focus" but leaves the .ocr candidate (tag="focus") uncovered, the orphan wrap produces a SECOND cluster with head="focus". Either path yields `clusters` containing two heads equal to "focus", which flows unmodified from refresh → merger.merge → parseActions → the trapping Dictionary init. Impact: a normal multi-source day with a same-named tag can hard-crash the merge step.
- **修复建议**: Make the head→cluster map tolerant of duplicates instead of trapping. Replace line 414:
`let byHead = Dictionary(uniqueKeysWithValues: clusters.map { ($0.head, $0) })`
with a uniquing initializer that keeps the first (consistent with parseClusters' "first wins" member rule):
`let byHead = Dictionary(clusters.map { ($0.head, $0) }, uniquingKeysWith: { first, _ in first })`
Note: with duplicate heads, the orphan-default loop at lines 438-441 still iterates per-cluster on `!decided.contains(cl.head)`, so a same-head cluster not directly addressed by the LLM still gets a createNew default — acceptable. Optionally, also dedup heads upstream in PersonalityClusterAgent (parseClusters around line 159 and the orphan-wrap at lines 95-98) so head collisions never propagate, but the one-line uniquingKeysWith fix at line 414 is sufficient to remove the crash.

### 7. Re-OCR leaves frames_fts stale (search returns wrong content) — no reindex after dropping the FTS sync trigger
- **位置**: `Sources/MyPortrait/Memory/ReOcrCLI.swift:79-118`  ·  分类: data-loss  ·  子系统: memory-speech/misc
- **问题**: reocrToday() drops the __frames_fts_au trigger, then UPDATEs frames.full_text for every re-OCR'd frame, then re-CREATEs the trigger — but it never reindexes the rows that were updated while the trigger was absent. The frames_fts entries for those frames keep the OLD (chrome/tab-bar) tokens and the NEW page content is never indexed. The exact same pattern exists in reocrTodayMP4() (lines 155-203).
- **影响/触发**: frames_fts is an external-content FTS5 table kept in sync only by the AFTER UPDATE trigger. With the trigger dropped during the UPDATEs, no FTS row is rewritten. After re-CREATE the trigger only affects FUTURE updates, so every frame this CLI touched is permanently mis-indexed: full-text search still matches the stale chrome text and never matches the real re-OCR'd content. This is exactly what the CLI was built to fix, yet search stays broken. Compare EmbedDumpCLI which runs INSERT INTO frames_fts(frames_fts) VALUES('rebuild') after recreating triggers — ReOcrCLI does not.
- **修复建议**: The frames_fts index must be reindexed for the rows updated while the trigger was absent. But because this SwiftPM CLI does NOT register the foundation_icu tokenizer (per the lines 76-78 comment), a plain `INSERT INTO frames_fts(frames_fts) VALUES('rebuild')` would itself throw a tokenizer-not-found error. Correct fix: (a) register the FoundationTokenizer on the GRDB DatabasePool used by ReOcrCLI (the same registration PortraitDBImpl does — see FoundationTokenizer.swift), then (b) do NOT drop the trigger at all (let it sync normally), OR keep the drop/recreate but add `try db.execute(sql: "INSERT INTO frames_fts(frames_fts) VALUES('rebuild')")` immediately after re-CREATEing the trigger. Apply to BOTH reocrToday() (after line 118) and reocrTodayMP4() (after line 203). If a full table 'rebuild' is too heavy, instead re-emit the per-row sync for just the touched ids: for each updated rowid run `INSERT INTO frames_fts(frames_fts,...) VALUES('delete', old...)` then `INSERT INTO frames_fts(rowid,...) VALUES(new...)`. Either way the tokenizer must be registered first.

### 8. Interrupted re-OCR permanently disables frames_fts update sync app-wide
- **位置**: `Sources/MyPortrait/Memory/ReOcrCLI.swift:79-118`  ·  分类: data-loss  ·  子系统: memory-speech/misc
- **问题**: The DROP of __frames_fts_au and its re-CREATE are not protected by any defer/cleanup. If the process is killed (user quits, Ctrl-C, crash) or the CREATE TRIGGER statement throws after the DROP succeeds, the AFTER UPDATE trigger stays dropped permanently. Same in reocrTodayMP4().
- **影响/触发**: Normal app operation does `UPDATE frames` in many places (PortraitDBImpl.swift:77/149/553) and relies on __frames_fts_au to keep frames_fts in sync. With that trigger gone, every subsequent normal frame update silently fails to update the search index, so full-text search drifts out of date indefinitely. There is no startup self-heal that recreates this trigger (only the manual --rebuild-frames-fts CLI does). The window between DROP and CREATE spans the entire OCR loop (potentially minutes over many frames), making interruption realistic.
- **修复建议**: Guarantee the trigger is restored even on the error path, and (ideally) self-heal at startup. Two complementary fixes:

1) Make restore robust against thrown errors in both reocrToday() and reocrTodayMP4(): extract the CREATE TRIGGER into a helper and call it from both the success path and a catch, e.g.

   func restoreFtsTrigger(_ dbPool: DatabasePool) async throws {
       try await dbPool.write { db in try db.execute(sql: "CREATE TRIGGER IF NOT EXISTS __frames_fts_au AFTER UPDATE ON \"frames\" BEGIN ... END") }
   }
   ...
   try await dbPool.write { db in try db.execute(sql: "DROP TRIGGER IF EXISTS __frames_fts_au") }
   do { /* OCR loop */ } catch { try? await restoreFtsTrigger(dbPool); throw error }
   try await restoreFtsTrigger(dbPool)

   (Swift `defer` cannot `await`, so use do/catch rather than defer; use CREATE TRIGGER IF NOT EXISTS for idempotency.)

2) Because a hard process-kill mid-loop can still leave the trigger dropped, add a startup self-heal in PortraitDBImpl.init (after migrate): query sqlite_master for type='trigger' AND name='__frames_fts_au'; if missing, recreate it (the same body already present in EmbedDumpCLI.swift:66-72). This is the only change that closes the SIGKILL window. Keep it minimal — a single existence check + one CREATE — consistent with the user's "least code" preference.

### 9. Raw sqlite3 UPDATE of audio_transcriptions.speaker_id fires the FTS5 sync trigger with no registered tokenizer (silent rollback)
- **位置**: `Sources/MyPortrait/TimelineDB.swift:909`  ·  分类: data-loss  ·  子系统: landmine-sweep
- **问题**: upsertVoiceTrainedSpeaker opens a bare sqlite3 connection (sqlite3_open_v2 at line 871, no FoundationTokenizer registered) and, when merging duplicate same-name speakers, runs a raw prepared statement `UPDATE audio_transcriptions SET speaker_id = ? WHERE speaker_id = ?`. audio_transcriptions has an external-content FTS5 sync (Schema.swift:127 `t.synchronize(withTable: "audio_transcriptions")` with a custom FoundationTokenizer at :128), so GRDB installed AFTER UPDATE triggers that re-tokenize old/new text via FoundationTokenizer. On a connection where that tokenizer was never registered, the trigger errors and the statement (plus its implicit transaction) rolls back.
- **影响/触发**: Violates the known constraint #4: a RAW sqlite3 write to audio_transcriptions hits the FTS5 custom-tokenizer trigger, which errors and silently rolls back. The whole speaker-merge reassignment is silently lost. This path is reachable: VoiceTrainer.swift:172 calls upsertVoiceTrainedSpeaker on every voice training, and the branch fires whenever duplicateIds.count > 1 (the exact duplicate-'Joy' scenario the surrounding comment is fixing). The codebase elsewhere (FixSpeakersCLI.swift:48-52, mergeSpeaker at TimelineDB.swift:1141-1158 which explicitly does `db.add(tokenizer: FoundationTokenizer.self)`, and RetranscribeQwenCLI.swift:210-216) deliberately routes the identical write through a GRDB connection with the tokenizer registered, proving this raw site is the miss.
- **修复建议**: Route the duplicate-merge reassignment through the existing GRDB-based mergeSpeakers path instead of raw sqlite3, so the FoundationTokenizer is registered and all three statements run in one transaction. Concretely, in upsertVoiceTrainedSpeaker replace the raw block at TimelineDB.swift:901-922 with a call to the already-correct mergeSpeakers(keep: keeperId, merge: dupeId) for each duplicateIds.dropFirst() (it already does the speaker_embeddings UPDATE + audio_transcriptions UPDATE + DELETE FROM speakers inside queue.write with db.add(tokenizer:)). That removes the bare-connection FTS5 trigger failure, restores transactional atomicity, and eliminates the orphaned-speaker_id corruption — and reuses existing code rather than re-registering the tokenizer on the bare handle. (If avoiding a second connection is required, the minimal alternative is to wrap the three statements in BEGIN/COMMIT and check sqlite3_step results, but that still cannot register the FTS5 custom tokenizer on a bare sqlite3 handle, so the GRDB route is the real fix.)

### 10. Raw sqlite3 DELETE FROM audio_transcriptions fires the FTS5 sync trigger with no registered tokenizer (silent rollback / retention no-op)
- **位置**: `Sources/MyPortrait/TimelineDB.swift:656`  ·  分类: data-loss  ·  子系统: landmine-sweep
- **问题**: deleteBefore opens a bare sqlite3 connection (sqlite3_open_v2 at line 639, no FoundationTokenizer registered) and runs `DELETE FROM audio_transcriptions WHERE transcribed_at_ms < ?` via a raw prepared statement. The external-content FTS5 sync on audio_transcriptions installs an AFTER DELETE trigger that issues an FTS5 'delete' command, which re-tokenizes old.text via the custom FoundationTokenizer. On this untokenized connection the trigger errors and the DELETE rolls back.
- **影响/触发**: Violates constraint #4. The DELETE silently fails/rolls back, so the retention/storage-cleanup never actually removes the audio transcriptions it reports deleting (result.audio is computed from sqlite3_changes after a step that errored). At best the data is not purged as the user expects; at worst the surrounding multi-statement cleanup is left in an inconsistent state. The FTS DELETE trigger re-tokenizes old.text exactly like the INSERT/UPDATE case the constraint calls out.
- **修复建议**: Route deleteBefore and deleteAfter through a GRDB DatabaseQueue whose Configuration.prepareDatabase registers FoundationTokenizer, exactly as mergeSpeakers already does (TimelineDB.swift:1149-1165). Wrap the DELETE FROM frames and DELETE FROM audio_transcriptions in queue.write { db in try db.execute(sql: "DELETE FROM frames WHERE timestamp_ms < :c", arguments: ["c": cutoffMs]); ... } and read sqlite3-style change counts via db.changesCount or RETURNING/SELECT changes(). Use dict-form arguments per constraint #1. Drop the bare sqlite3_open_v2 path entirely for these two functions. (Note: the frames DELETE on the bare connection fails for the same reason — frames_fts also uses foundation_icu — so both DELETEs must move onto the tokenizer-registered GRDB connection.)

### 11. Raw sqlite3 DELETE FROM audio_transcriptions in deleteAfter fires the FTS5 sync trigger with no registered tokenizer (silent rollback)
- **位置**: `Sources/MyPortrait/TimelineDB.swift:683`  ·  分类: data-loss  ·  子系统: landmine-sweep
- **问题**: deleteAfter opens a bare sqlite3 connection (sqlite3_open_v2 at line 672, no FoundationTokenizer registered) and runs `DELETE FROM audio_transcriptions WHERE transcribed_at_ms >= ?` via a raw prepared statement. Same mechanism as deleteBefore: the external-content FTS5 AFTER DELETE sync trigger re-tokenizes old.text through the unregistered custom FoundationTokenizer, errors, and rolls back the DELETE.
- **影响/触发**: Violates constraint #4 and is directly user-reachable: StorageView.swift:169 calls TimelineDB().deleteAfter(cutoff) from the storage-management UI. When the user trims data after a cutoff, the audio_transcriptions DELETE silently fails/rolls back, so the transcripts are not actually deleted even though the UI reports success (result.audio from sqlite3_changes). Silent data-retention failure.
- **修复建议**: Route both deleteAfter() and deleteBefore() through a GRDB DatabaseQueue whose Configuration registers the tokenizer, exactly like mergeSpeakers (TimelineDB.swift:1148-1165). Concretely: build `var config = Configuration(); config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }`, open `try DatabaseQueue(path: dbPath, configuration: config)`, and inside `queue.write { db in ... }` run the frames DELETE and the audio_transcriptions DELETE via `db.execute(sql:..., arguments: ["cutoff": cutoffMs])` (dict-form per constraint #1), capturing `db.changesCount` for the result. This makes the audio_transcriptions DELETE actually commit (FTS sync trigger finds foundation_icu). Apply to BOTH functions, since deleteBefore at line 656 has the same bug. (The frames DELETE alone could stay on raw sqlite, but moving the whole function to one GRDB write is simpler and keeps it atomic.)

### 12. Raw sqlite3 UPDATE on audio_transcriptions triggers FTS5 tokenizer failure + silent rollback
- **位置**: `Sources/MyPortrait/TimelineDB.swift:909-914`  ·  分类: data-loss  ·  子系统: db-read (TimelineDB)
- **问题**: upsertVoiceTrainedSpeaker opens a RAW sqlite3 connection (sqlite3_open_v2, line 871) and issues `UPDATE audio_transcriptions SET speaker_id = ? WHERE speaker_id = ?` directly via sqlite3_step. This connection never registers the custom FTS5 tokenizer `foundation_icu` (FoundationTokenizer).
- **影响/触发**: audio_transcriptions has an FTS5 contentless table `transcriptions_fts` synchronized via `t.synchronize(withTable: "audio_transcriptions")` (Schema.swift:127), which installs an AFTER UPDATE trigger that re-tokenizes the row on ANY update (even one that only changes speaker_id). A raw sqlite3 connection has no `foundation_icu` tokenizer registered, so the trigger errors and the statement's implicit transaction is rolled back — the speaker reassignment is silently lost. This is the exact failure documented for the GRDB-based path in mergeSpeakers (line 1141-1144) and FixSpeakersCLI.swift:12-13, which deliberately use a GRDB connection with the tokenizer registered. upsertVoiceTrainedSpeaker does the same UPDATE via raw sqlite3, so the dedup-merge of duplicate speakers' transcriptions never actually takes effect.
- **修复建议**: Route the dupe-merge UPDATE on audio_transcriptions through a GRDB connection that registers FoundationTokenizer (mirroring mergeSpeakers, which already does exactly this), instead of the raw sqlite3 connection. Simplest: in the `duplicateIds.count > 1` branch, for each dupeId call the existing `mergeSpeakers(keep: keeperId, merge: dupeId)` (TimelineDB.swift:1145) — it already wraps the audio_transcriptions + speaker_embeddings reassignment + speakers DELETE in a tokenizer-registered GRDB write transaction — and remove the raw UPDATE/DELETE at L903-919. That deletes ~17 lines and reuses correct code. If staying on the raw connection is required for atomicity with the rest of upsertVoiceTrainedSpeaker, then this whole function's writes must move to a GRDB DatabaseQueue opened with `config.prepareDatabase { $0.add(tokenizer: FoundationTokenizer.self) }`. Either way, do NOT leave the speaker_id UPDATE on a raw, tokenizer-less handle. Also do not silently DELETE the dupe speakers row before confirming the transcription reassignment succeeded.

### 13. upsertVoiceTrainedSpeaker performs multi-table merge with no transaction → partial/inconsistent writes
- **位置**: `Sources/MyPortrait/TimelineDB.swift:901-922`  ·  分类: data-loss  ·  子系统: db-read (TimelineDB)
- **问题**: The duplicate-speaker merge runs three separate auto-committing statements per dupe: UPDATE speaker_embeddings (reassign), UPDATE audio_transcriptions (reassign), DELETE FROM speakers (delete the dupe). There is no BEGIN/COMMIT wrapping them, and the return values of sqlite3_step are discarded (`_ = sqlite3_step(...)`).
- **影响/触发**: Because the audio_transcriptions UPDATE fails and rolls back (see finding above), but the surrounding statements are NOT in a shared transaction, the embeddings UPDATE and the speakers DELETE still commit. Result: the dupe speaker row is deleted and its embeddings are moved to the keeper, but its audio_transcriptions rows are left pointing at a now-deleted speaker_id — dangling foreign references and lost speaker attribution. Even ignoring the tokenizer issue, any mid-sequence failure leaves the DB in a half-merged state because nothing is atomic and no error is checked.
- **修复建议**: Reuse the existing correct path. The whole merge loop already exists, done right, in mergeSpeakers (line 1146): a GRDB DatabaseQueue with config.prepareDatabase { db.add(tokenizer: FoundationTokenizer.self) } wrapping the three statements in a single queue.write{} transaction. Replace the raw-sqlite merge block in upsertVoiceTrainedSpeaker (lines 901-922) with calls to mergeSpeakers(keep: keeperId, merge: dupeId) for each id in duplicateIds.dropFirst(), and only proceed to the keeper upsert if every merge returned true (mergeSpeakers is @discardableResult and returns Bool). That makes the audio_transcriptions UPDATE go through a tokenizer-registered connection (no trigger error) and makes the three-table reassign+delete atomic per dupe, eliminating the dangling-reference state. Note mergeSpeakers opens its own DatabaseQueue on dbPath; ensure it is not nested inside the raw db handle's lifetime in a way that holds a write lock — it is fine here since the raw db handle has no open transaction at that point. Do NOT just wrap the raw statements in BEGIN/COMMIT: that alone still fails because the bare connection lacks the foundation_icu tokenizer; the GRDB tokenizer registration is the essential part.

### 14. Raw sqlite3 UPDATE on audio_transcriptions in voice-training upsert triggers FTS5 tokenizer error + silent data loss
- **位置**: `Sources/MyPortrait/TimelineDB.swift:909-919`  ·  分类: data-loss  ·  子系统: speaker-diarization
- **问题**: upsertVoiceTrainedSpeaker (the production sink for VoiceTrainer.assign, VoiceTrainer.swift:172) merges duplicate same-name speaker rows by doing a RAW sqlite3 `UPDATE audio_transcriptions SET speaker_id = ? WHERE speaker_id = ?` on a plain SQLITE_OPEN_READWRITE connection that never registers the FoundationTokenizer.
- **影响/触发**: audio_transcriptions is synchronized to the FTS5 virtual table transcriptions_fts using the custom `foundation_icu` tokenizer (Schema.swift:125-131). Any UPDATE fires the FTS sync trigger, which re-tokenizes via FoundationTokenizer. A raw sqlite3 connection has no such tokenizer registered, so the trigger errors. The codebase documents this exact hazard and the correct fix everywhere else: mergeSpeakers (TimelineDB.swift:1141-1164) and FixSpeakersCLI.swift:48 perform the identical merge through a GRDB DatabaseQueue whose prepareDatabase registers FoundationTokenizer. Here the UPDATE return value is discarded (`_ = sqlite3_step(stmt)`), and there is NO enclosing transaction, so the failed/rolled-back reassign is swallowed while the dupe speaker row is still DELETEd two lines later (line 915). Result: audio_transcriptions rows keep a speaker_id pointing at a now-deleted speaker (dangling reference / orphaned attribution). Triggers every time a user re-trains a name that already has >1 speaker row.
- **修复建议**: Replace the manual raw-sqlite merge block (TimelineDB.swift:901-922) — or at minimum the three reassign/delete statements — with the existing mergeSpeakers() path, which already uses a GRDB DatabaseQueue whose prepareDatabase registers FoundationTokenizer and runs all three statements inside one queue.write transaction. Concretely, inside the `if duplicateIds.count > 1` branch loop, call `_ = self.mergeSpeakers(keep: keeperId, merge: dupeId)` instead of the three hand-rolled prepare/step blocks (lines 903-919). This both registers the tokenizer (so the audio_transcriptions UPDATE trigger succeeds) and wraps the embeddings-update + transcriptions-update + speaker-delete in a single transaction so a failure rolls back atomically instead of deleting the speaker while leaving dangling transcription rows. (mergeSpeakers also correctly uses the dict-form arguments required by the GRDB deadlock invariant.)

### 15. Data race on KeystrokeLedger.charLogger between tap thread and MainActor
- **位置**: `Sources/MyPortrait/Typing/KeystrokeLedger.swift:75, 441-444`  ·  分类: concurrency  ·  子系统: typing
- **问题**: `var charLogger: KeystrokeCharLogger?` is an unsynchronized strong reference that is READ on the CGEventTap background thread inside the C callback (`if let charLogger = ledger.charLogger`) but WRITTEN on the MainActor by `TypingObserver.start()` (`ledger.charLogger = charLogger`) and `TypingObserver.stop()` (`ledger.charLogger = nil`). Unlike `lastPasteMs`/`buffer`/etc., this property is never guarded by `os_unfair_lock` (lock).
- **影响/触发**: Concurrent read/write of an ARC reference from two threads is undefined behavior: the read on the tap thread performs a retain while the MainActor store performs a release. In `TypingObserver.stop()` the line `ledger.charLogger = nil` runs while the tap thread is still live (it executes BEFORE `ledger.stop()`), so a keystroke arriving at that exact moment can read a half-stored / being-released pointer and over-release or read garbage, crashing the app. Same window exists at `start()` (charLogger assigned after `ledger.start()`? actually before, but the symmetric teardown race at stop is the live crash). Triggers on app shutdown / typing-capture toggle-off while the user is typing.
- **修复建议**: Two equally small options:

Option A (preferred — match the existing pattern): guard charLogger with the same os_unfair_lock used for every other shared field. In KeystrokeLedger, make `charLogger` private and add accessors that lock:
  func setCharLogger(_ l: KeystrokeCharLogger?) { os_unfair_lock_lock(&lock); charLogger = l; os_unfair_lock_unlock(&lock) }
and in the callback snapshot it under the lock before use:
  os_unfair_lock_lock(&lock); let cl = ledger.charLogger; os_unfair_lock_unlock(&lock)
  if let cl { ... cl.ingest(...) }
This makes the pointer load/store atomic w.r.t. each other and pairs the retain with a consistent value.

Option B (minimal — close the live window): in TypingObserver.stop(), reorder so the tap is fully torn down before the reference is cleared — call `ledger.stop()` (which disables the tap and joins the tap thread) FIRST, then set `ledger.charLogger = nil`. After ledger.stop() returns, no callback can run, so the nil-store is uncontended. i.e. swap lines 159 and 160. Option A is more robust (also covers any future early-keystroke window); Option B is the one-line fix for the specific crash.

### 16. VoiceTrainingTestCLI triggers a RAW-sqlite UPDATE on audio_transcriptions (FTS5 tokenizer rollback / silent data loss)
- **位置**: `Sources/MyPortrait/VoiceTrainingTestCLI.swift:75`  ·  分类: data-loss  ·  子系统: clis
- **问题**: `VoiceTrainingTestCLI.run` calls `TimelineDB().upsertVoiceTrainedSpeaker(name: "Test-CLI", embedding:)`. When a same-named speaker already exists (i.e. on the 2nd+ run of the CLI, or any time "Test-CLI"/the chosen name already has a non-hallucination row), `upsertVoiceTrainedSpeaker` enters its dedup-merge branch and runs `UPDATE audio_transcriptions SET speaker_id = ? WHERE speaker_id = ?` on a RAW sqlite3 connection (opened at TimelineDB.swift:871 via sqlite3_open_v2, with NO FoundationTokenizer registered). This is exactly the forbidden pattern in known constraint #4.
- **影响/触发**: The FTS5 virtual table `transcriptions_fts` is created with `t.synchronize(withTable: "audio_transcriptions")` + `t.tokenizer = FoundationTokenizer.tokenizerDescriptor()` (Schema.swift:125-130). GRDB's `.synchronize` installs an AFTER UPDATE trigger that fires on ANY column change (including speaker_id): it deletes+reinserts the FTS row, re-tokenizing `text` with the custom `foundation` tokenizer. On a raw sqlite3 connection that tokenizer is unregistered → the trigger errors → the whole UPDATE/merge transaction rolls back silently. The project itself documents this exact hazard for the identical statement in `TimelineDB.mergeSpeakers` (TimelineDB.swift:1141-1144, which deliberately uses a GRDB connection with the tokenizer). Impact: the speaker merge silently fails, duplicate speakers persist, and the CLI still prints `upserted speaker id=... PASS`, hiding the failure.
- **修复建议**: Route the merge writes in `upsertVoiceTrainedSpeaker` (TimelineDB.swift:868-983) through a GRDB DatabaseQueue whose `prepareDatabase` registers the FoundationTokenizer, mirroring `mergeSpeakers` (TimelineDB.swift:1146-1159). Concretely: either (a) replace the whole raw-sqlite body with a GRDB `queue.write { db in ... }` using dict-form arguments (e.g. `arguments: ["keep": keeperId, "merge": dupeId]`), or (b) at minimum, for the dupe-merge branch, call the existing tokenizer-aware `mergeSpeakers(keep: keeperId, merge: dupeId)` for each dupe instead of the raw `UPDATE audio_transcriptions` at line 909-913. Do not keep any raw `UPDATE/INSERT/DELETE` touching audio_transcriptions on the bare `sqlite3_open_v2` handle. The non-audio_transcriptions writes (speakers, speaker_embeddings) are safe on raw sqlite, but consolidating onto the tokenizer-aware GRDB connection is cleanest.

## 🟡 MEDIUM

### 17. abort() leaves in-flight tool/thinking blocks stuck as isRunning=true and persists them
- **位置**: `Sources/MyPortrait/AI/ChatController.swift:139-147`  ·  分类: logic  ·  子系统: ai-chat
- **问题**: abort() flushes pending text, sets isStreaming=false, clears assistantMessageID, and persists — but unlike the .agentEnd and .error handlers it never calls closeRunningPartsOnCurrentAssistant(). Any tool block (.tool isRunning=true) or thinking block (.thinking isRunning=true) that was in flight when the user hit Cancel is left in the running state and then written to disk by persist().
- **影响/触发**: If the user aborts while a bash/read tool or a thinking block is still running, that block keeps isRunning=true. The .agentEnd/.error paths exist specifically to force-close such blocks so the UI doesn't spin forever; abort() bypasses that. Worse, abort() runs synchronously and clears assistantMessageID BEFORE any late agent_end could arrive, so even if Pi emits agent_end afterwards, closeRunningPartsOnCurrentAssistant() no-ops (no current assistant id) and the stuck block is never closed. persist() then saves the isRunning=true block, so on reload the bubble shows a perpetual 'Running…' / 'Thinking…' spinner.
- **修复建议**: In abort() (ChatController.swift:139-147), call closeRunningPartsOnCurrentAssistant() BEFORE clearing assistantMessageID, mirroring the .agentEnd/.error handlers:

  func abort() {
      try? agent?.abort()
      flushPending()
      closeRunningPartsOnCurrentAssistant()   // <-- add, before nil-ing the id
      isStreaming = false
      endStreamingActivity()
      assistantMessageID = nil
      activeTextPartID = nil
      persist()
  }

This force-closes any in-flight tool/thinking block (sets isRunning=false) so persist() writes a clean state and the reloaded bubble shows the finished/idle indicator instead of a perpetual spinner.

### 18. regenerate()/editAndResend() drop the agent but not its persisted session, so the removed turn survives in agent memory
- **位置**: `Sources/MyPortrait/AI/ChatController.swift:110-119`  ·  分类: correctness  ·  子系统: ai-chat
- **问题**: Both regenerate() and editAndResend() remove the user turn (and everything after) from the local messages array, then set agent=nil to 'force a fresh conversation on Pi's side', and call send(). But ensureAgent() re-spawns the agent reusing the persisted session: for Pi it reads store.piSessionPath(for:) and passes `--session <path>` (pi replays the full jsonl history), and for Claude Code it reads store.claudeSessionId(for:) and resumes with `-r <sid>`. Neither piSessionPath nor claudeSessionId is cleared on regenerate/edit.
- **影响/触发**: The on-disk pi session jsonl (and the Claude session) still contain the dropped turn. When the new agent spawns it replays that history, so the regenerated/edited answer is produced with the OLD (supposedly removed) user message + assistant reply still in context. This directly contradicts the code's own comment ('Tearing down the agent forces a fresh conversation on Pi's side — otherwise Pi has its own memory of the dropped turn') and yields duplicated/contradictory context: the user edits a question but the model still sees the original phrasing and its prior answer.
- **修复建议**: Before re-sending, discard the persisted session for the current conversation so ensureAgent() spawns a truly fresh agent. Factor a small helper and call it in both regenerate() and editAndResend() right after `agent = nil`:

    private func resetPersistedSession() {
        guard let convId = currentConvId else { return }
        // Pi: delete the jsonl so a new empty session is created on respawn.
        if let p = store.piSessionPath(for: convId) {
            try? FileManager.default.removeItem(atPath: p)
            // keep the path row (ensureAgent reuses it; file now absent → pi creates fresh)
        }
        // Claude Code: clear stored sid so the next spawn starts a new session (no -r).
        store.updateClaudeSessionId(convId, nil)
    }

Note: simply nil-ing piSessionPath in the store is NOT enough, because ensureAgent() (537-543) would then re-derive the same `<convId>.jsonl` path which still exists on disk and pi would replay it — so the file itself must be removed (or rewritten to only the kept prefix). Removing the file is the minimal correct fix and matches the existing deleteConversation cleanup at ChatStore.swift:63-64. If preserving the surviving earlier turns matters, a more precise fix would rewrite the jsonl to only the messages kept in `messages`, but file-delete (fresh replay from the trimmed in-memory transcript via send()) is the smallest change that honors the existing comment's intent.

### 19. decodeCadence accepts an unvalidated weekday, causing an out-of-range crash in Cadence.label
- **位置**: `Sources/MyPortrait/AI/CronJobFile.swift:51-55`  ·  分类: crash  ·  子系统: ai-cron/net/secrets
- **问题**: decodeCadence parses `weekly <d> at <h>` with `Int(parts[1])` and constructs `.weeklyOn(weekday: d, hour: h)` with NO range check on d. Cadence.label (TemplateLibrary.swift:131-133) renders a weeklyOn cadence by indexing a fixed 8-element array `names[d]` (valid indices 0...7). A cron_job.md containing e.g. `schedule: weekly 8 at 9`, `weekly 0 at 9`, or a negative/garbage weekday — hand-edited file, corrupted sidecar, or a value produced by another tool/agent — decodes to weekday 8 and crashes with an Array index out of range the moment that cron job is shown in the UI.
- **影响/触发**: parseMarkdown reads arbitrary on-disk files at app startup (load() iterates every <slug>/cron_job.md). One bad `weekly N` line where N is outside 1...7 turns into a hard fatal index crash in Cadence.label, which the Cron Jobs list view calls to render the schedule. This bricks the whole cron UI / app launch from a single malformed file.
- **修复建议**: Clamp/validate the weekday at the decode boundary so a malformed value degrades gracefully instead of trapping. Minimal fix in CronJobFile.decodeCadence (CronJobFile.swift:53): only accept the weeklyOn case when d is in 1...7, otherwise fall through to .never (consistent with how the function already returns .never for unparseable input):

  case "weekly":
      if parts.count == 4, let d = Int(parts[1]), (1...7).contains(d),
         let h = Int(parts[3]) {
          return .weeklyOn(weekday: d, hour: h)
      }

Optionally also harden the render site as defense-in-depth (TemplateLibrary.swift:132-133) by bounds-checking the index, e.g. `let name = names.indices.contains(d) ? names[d] : "?"`. The decode-side clamp is the essential change; the render-side guard prevents any other path (e.g. a future Codable-decoded value) from trapping.

### 20. Data race on sawTurnEnd between stdout handler and terminationHandler
- **位置**: `Sources/MyPortrait/AI/PiAgent.swift:213, 316-337`  ·  分类: concurrency  ·  子系统: ai-agents/providers
- **问题**: `sawTurnEnd` is a plain `var Bool` written from `dispatchInner` (lines 316 and 337), which runs on the stdout-pipe `readabilityHandler` queue, and read in `process.terminationHandler` (line 213), which runs on a different GCD queue. There is no lock or other happens-before relationship guarding `sawTurnEnd` (bufLock guards stdoutBuffer only; the terminationHandler never takes bufLock).
- **影响/触发**: The two closures execute on distinct dispatch queues with no synchronization, so the read of `sawTurnEnd` in terminationHandler can observe a stale value relative to the writes in dispatchInner. Concrete impact: after a successful turn the terminationHandler may still read `false` and emit a spurious `.error` + extra `.agentEnd` into the chat stream; conversely it could miss emitting the needed crash error, leaving ChatController spinning on 'thinking…'. It is also undefined behavior under the Swift memory model (TSan would flag it).
- **修复建议**: Establish a happens-before relationship for sawTurnEnd between the two queues. Cheapest robust option: serialize access under the existing bufLock. (a) Make the writes hold bufLock — they already do, since dispatchInner is called from inside appendStdout which is wrapped in bufLock.lock()/unlock() (L278/287), so the writes at L316/L337 are already under bufLock. (b) Make the terminationHandler read under the same lock: `self.bufLock.lock(); let done = self.sawTurnEnd; self.bufLock.unlock(); if !done { ... }`. This gives a real memory barrier and removes both the visibility race and the UB. Even better, also drain remaining stdout deterministically before reading: in terminationHandler, set `stdoutPipe.fileHandleForReading.readabilityHandler = nil` and run one final `appendStdout(stdoutPipe.fileHandleForReading.availableData)` (under bufLock) so any trailing agent_end/message_end is parsed before checking the flag — this fixes both the spurious-error and missed-error directions. (Marking sawTurnEnd as atomic would also stop the UB but would not, by itself, guarantee the final line is parsed first.)

### 21. Merged speech segment keeps only the first sub-segment's embedding, defeating the centroid enroll-length safeguard
- **位置**: `Sources/MyPortrait/Capture/Audio/Speaker/SpeakerSegmenter.swift:126-137`  ·  分类: logic  ·  子系统: speaker-diarization
- **问题**: When adjacent same-local-speaker segments are merged, `prev.samples` is extended (line 129) but `prev.embedding` is left as the FIRST sub-segment's vector and never recomputed. The merged segment's reported sample count no longer corresponds to its embedding.
- **影响/触发**: In OnnxSpeakerDiarizer.diarize, the per-local-speaker representative is chosen by largest `samples.count` and then resolveSpeaker(embedding: best.embedding, speechSamples: best.samples.count) gates DB enrollment/centroid-update on speechSamples >= minEnrollSamples (32000 = 2s). After merging, best.samples.count is the concatenated length (can be long) while best.embedding may have been computed from a sub-2s sub-segment. So a noisy/short embedding can pass the 'only long, reliable segments update the centroid' check and get folded into a speaker's centroid (addEmbeddingToSpeaker) or used to enroll a new speaker — exactly the contamination the length gate was meant to prevent. The embedding and the length it is judged by are mismatched.
- **修复建议**: Keep the embedding consistent with the sample count it will be judged by. Minimal cheap fix: on merge, adopt the embedding of whichever sub-segment is longer instead of always keeping prev's. In SpeakerSegmenter.swift around line 127-130:

    if prev.localSpeaker == seg.localSpeaker {
        if seg.samples.count > prev.samples.count { prev.embedding = seg.embedding }
        prev.end = seg.end
        prev.samples.append(contentsOf: seg.samples)
        current = prev
    }

This guarantees the representative chosen later by max samples.count carries the embedding of its longest contributing sub-segment (the most reliable one), so the 2s length gate actually reflects the embedding's provenance. The fully-correct (but costlier) alternative is to re-run embedding.embed(prev.samples) on the merged buffer; choose that only if even the longest sub-segment can be too short for a trustworthy vector. Either way the embedding/length mismatch is resolved without weakening the gate.

### 22. System-audio tap callback spawns unordered Task per buffer — same out-of-order hazard
- **位置**: `Sources/MyPortrait/Capture/Audio/SystemAudioCaptureService.swift:588-596`  ·  分类: concurrency  ·  子系统: audio-capture (CoreAudio)
- **问题**: Identical pattern to the mic service: each tap buffer is handed to a new unstructured `Task { await self?.performConversion(buffer:) }`. Actor task ordering is not FIFO, so loopback audio buffers can be converted and yielded out of order.
- **影响/触发**: Out-of-order processing scrambles the system-audio sample stream fed to VADRecorder, corrupting recorded segments. It additionally pollutes the silence watchdog's wdPeak/wdCallbacks accounting, since those are updated inside performConversion whose execution order no longer matches buffer arrival.
- **修复建议**: Stop spawning a Task per buffer. Preserve order by funneling raw frames into a single serial consumer instead of N competing root Tasks. Two concrete options:

Option A (smallest change): make the tap block extract the float frames synchronously inside the callback (which AVAudioConverter conversion already needs the actor for — so instead push the raw, copied input frames), then yield into a bounded continuation that a single ordered task drains and converts in arrival order. The existing `samplesTask` (line 623) already demonstrates the single-consumer pattern.

Option B (minimal): keep a private serializing Task chain so each buffer awaits the previous one, e.g. capture-and-copy the buffer's samples synchronously in the callback (also fixes the buffer-recycle race), enqueue them into an AsyncStream<[Float]>-style raw-input channel, and have one actor-driven loop pull from that channel and call performConversion in FIFO order. Do NOT rely on per-buffer `Task { await ... }` for ordering.

Either way: also copy the buffer contents inside the render callback before returning, rather than holding the AVAudioPCMBuffer reference across an await. Apply the same fix to AudioCaptureService.swift:211-216, which shares the identical pattern.

### 23. CompactionWorker NULLs snapshot_path for frames whose JPG was skipped from the MP4
- **位置**: `Sources/MyPortrait/Capture/Compaction/CompactionWorker.swift:150-174`  ·  分类: data-loss  ·  子系统: capture-lifecycle/health
- **问题**: In compactChunk, frames whose JPG fails to load are logged and skipped via 'continue' (line 151-154), so they are never appended to the encoder. But frameOffsets is built from the FULL frames array (line 173), and replaceFramesWithVideoChunk sets video_chunk_id, offset_ms AND snapshot_path=NULL for every one of those frame ids. The original JPGs are then all deleted (line 191-192).
- **影响/触发**: A frame that was skipped during encoding ends up with snapshot_path=NULL and an offset_ms pointing into a video chunk that does not actually contain that frame's pixels. The DB metadata row survives but its image is now silently mapped to an unrelated position in the MP4 (whatever frame sits nearest that timestamp). Combined with deleting the source JPG, the original frame's visual is irrecoverably lost / mismapped. A transiently unreadable JPG (e.g. write still in flight, partial file) thus turns into permanent corruption of that frame's timeline image.
- **修复建议**: In compactChunk, only null snapshot_path / delete the JPG for frames that were actually encoded. Collect the encoded frame ids and build both frameOffsets and the delete loop from that set. Concretely: start with `var encoded: [FrameForCompaction] = [firstFrame]`, and in the dropFirst loop append `frame` to `encoded` right after a successful `encoder.append(...)` (inside the else-skip branch, do nothing). Then build `frameOffsets` from `encoded` (not `frames`) at line 173, and change the JPG-delete loop at line 191 to iterate `encoded` instead of `frames`. This leaves any skipped frame with its snapshot_path and JPG intact so it can be retried on a later compaction pass, eliminating the silent loss. (Optional: also handle the edge case where every non-first frame is skipped — current behavior of a 1-frame chunk is already fine.)

### 24. FTS5 tokenizer recomputes UTF-8 prefix length per word → O(n²) on every frame insert and query
- **位置**: `Sources/MyPortrait/DB/FoundationTokenizer.swift:53-56`  ·  分类: performance  ·  子系统: db-write/schema
- **问题**: Inside enumerateSubstrings(.byWords), the byte offset of each token is computed by materializing the entire prefix substring from index 0 to range.location and counting its UTF-8 bytes: `let prefix = ns.substring(with: NSRange(location: 0, length: range.location)); let iStart = prefix.utf8.count`. range.location grows monotonically toward the document length, so this is O(range.location) per word, i.e. O(n²) total over a document of length n.
- **影响/触发**: This tokenizer runs on the FTS5 write path for every frames insert/update (app_name, window_name, browser_url, full_text are all tokenized) and on every FTS query. `full_text` is a whole-screen OCR/AX merge — routinely several KB to tens of KB (TimelineDB filters length>4 and snippets go to 600 chars; full docs are far larger). At ~10k+ chars the per-frame tokenize becomes quadratic: each word re-walks the entire preceding text and re-encodes it to UTF-8 + allocates a substring. With continuous frame capture this is repeated work on the hot insert path and stalls FTS search. The code comment claims `n=range.location 通常很小` (usually small), but range.location reaches the full document length by the last word, so the assumption is false for large OCR text.
- **修复建议**: Track the UTF-8 byte offset incrementally instead of recomputing the prefix per word. Walk a single cursor that advances by the UTF-8 byte length of the gap+token consumed so far. Concretely, replace lines 52-56 with an O(n) approach, e.g. maintain a running iStart by converting only the *new* slice since the last word:

    var lastUTF16 = 0      // UTF-16 index already accounted for
    var byteOffset = 0     // UTF-8 bytes already accounted for
    ns.enumerateSubstrings(in: ..., options: .byWords) { substring, range, _, stop in
        guard let substring, !substring.isEmpty else { return }
        // advance byteOffset over the gap [lastUTF16, range.location)
        if range.location > lastUTF16 {
            let gap = ns.substring(with: NSRange(location: lastUTF16, length: range.location - lastUTF16))
            byteOffset += gap.utf8.count
            lastUTF16 = range.location
        }
        let iStart = byteOffset
        let iEnd = iStart + substring.utf8.count
        byteOffset = iEnd
        lastUTF16 = range.location + range.length
        ...emit token with iStart/iEnd...
    }

This makes each iteration cost proportional only to the unprocessed gap+token, so total work is O(n) instead of O(n²), while producing identical FTS5 byte offsets. Validate snippet()/highlight offsets are unchanged with a mixed CJK+ASCII test string.

### 25. Archiver aborts the whole run and leaves a 'ghost' file if moveItem hits an existing destination
- **位置**: `Sources/MyPortrait/Memory/Archiver.swift:130-139`  ·  分类: data-loss  ·  子系统: memory-events
- **问题**: In the execute loop each plan first stamps archived_at and writes it back to plan.source, then createDirectory, then fm.moveItem(at: source, to: destination). FileManager.moveItem throws if the destination already exists (e.g. a same-named file was archived in a prior run). The throw propagates out of run(), so: (a) the current file is now stamped archived_at != nil but still sits in its live category dir, and (b) all remaining plans never execute.
- **影响/触发**: A file stamped archived_at but not moved is permanently skipped on every future run (line 97: `if file.archivedAt != nil { skipped += 1; continue }`), so it is silently treated as archived while physically remaining in the live tree, and the rest of that run's archival is abandoned. Triggers on any destination-name collision between a current candidate and a previously-archived file (re-created portrait file with the same slug, or two runs producing the same dest).
- **修复建议**: Two complementary fixes in the execute loop (Archiver.swift 130-139):
1. Move AFTER, stamp only on success, and guard the destination. Reorder so the file is moved first (or compute success first), then stamp; and skip/handle an already-existing destination instead of throwing the whole run. Minimal version:

  for plan in plans {
      if fm.fileExists(atPath: plan.destination.path) {
          // dest already archived from a prior run -> skip this plan, log it; do NOT stamp/abort
          continue
      }
      try fm.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      var file = try PortraitFileIO.read(from: plan.source)
      file.archivedAt = now
      try PortraitFileIO.write(file, to: plan.source)
      do {
          try fm.moveItem(at: plan.source, to: plan.destination)
      } catch {
          // roll back the stamp so the ghost cannot become a permanent live-but-"archived" file,
          // and continue with remaining plans instead of aborting the run
          file.archivedAt = nil
          try? PortraitFileIO.write(file, to: plan.source)
          continue
      }
  }

(Also exclude skipped/failed plans from writeJournal so the journal stays truthful.) Optionally, fix the root cause too: have writeNewPortrait (PortraitDistiller.swift ~337) also check <category>/_archive/<slug>.md and route to update/un-archive instead of creating a colliding live file.

### 26. Per-batch LLM timeout can hang forever instead of timing out
- **位置**: `Sources/MyPortrait/Memory/EventBuilder.swift:197-209`  ·  分类: deadlock  ·  子系统: memory-events
- **问题**: The timeout race in runLLM uses withThrowingTaskGroup with one child awaiting coordinator.awaitTurn() (a non-throwing, non-cancellable withCheckedContinuation) and one child that throws BuilderError.agentTimeout after perBatchTimeout. When the timeout child throws, the group's implicit drain must await the awaitTurn child, which is blocked on a continuation that is ONLY resumed by coordinator.handle(.agentEnd/.error). cancelAll() does not resume a withCheckedContinuation. agent.stop() (which would finish the stream and unblock it) runs in an outer defer that only fires AFTER runLLM returns — i.e. after the group has drained. So if the spawned agent process stays alive but emits no terminal event, the 'timeout' never actually completes and the call hangs indefinitely.
- **影响/触发**: The whole purpose of perBatchTimeout is to bound a stuck LLM call. Because the awaiting child task can never be unblocked by cancellation (only by an agent event), a genuinely wedged agent process defeats the timeout and the Backfill day-loop (and the MainActor scheduler step holding the lock + heartbeat) blocks forever. Triggers whenever the agent process hangs without exiting/erroring.
- **修复建议**: Do not rely on the task-group draining a non-cancellable child. Two viable fixes: (1) Race a cancellable timeout but on timeout explicitly call agent.stop() BEFORE returning so the event stream finish()es and the consumer/awaitTurn unblocks — e.g. restructure so the timeout branch invokes agent.stop() (which finish()es eventContinuation, ending the for-await and letting you resume awaitTurn) rather than leaving it to the outer defer. (2) Make awaitTurn cancellation-aware: store the continuation and, on cancellation, resume it (e.g. wrap in withTaskCancellationHandler and have the handler call a coordinator method that resume()s pending with the partial buffer). Option (1) is the minimal change and also guarantees the wedged subprocess is actually killed on timeout. Apply the identical fix to EventClassifier.swift:380-392.

### 27. Budget pass increments rebalanceCount on 'restored' (no-op) days, freezing events prematurely
- **位置**: `Sources/MyPortrait/Memory/MemoryBudget.swift:234-238`  ·  分类: logic  ·  子系统: memory-speech/misc
- **问题**: MemoryBudget.apply increments rebalanceCount for both .rebalanced and .restored. A .restored plan is produced for every in-window rebalancable event on a day whose rawImpact sum is UNDER budget (line 197), i.e. the impact didn't actually change. Yet each such run still bumps rebalanceCount toward maxRebalances (default 5).
- **影响/触发**: Because MemoryBudget_applyToDisk runs on a schedule, an event sitting in a quiet window gets a 'restored' touch every run. After maxRebalances runs (e.g. 5 daily ticks) it is classified .frozen (line 125) and can NEVER be scaled down again — even if a genuinely busy day later should compress it. So events that were never actually compressed exhaust their rebalance budget doing nothing, defeating the daily-budget crowding-out the module exists to enforce. Note rebalancableRawSum was only accumulated for the pre-pass (line 131), so the freeze counter advances purely from no-op restores.
- **修复建议**: Only increment rebalanceCount when the budget pass actually changed the impact (i.e. genuine compression), not on no-op restores. Simplest correct fix in MemoryBudget.apply (lines 234-237): split the cases so `.restored` sets impact but does NOT bump the counter, while `.rebalanced` does both:

  case .rebalanced:
      file.impact = plan.newImpact
      file.rebalanceCount = (file.rebalanceCount ?? 0) + 1
  case .restored:
      file.impact = plan.newImpact   // no rebalanceCount bump

This preserves the once-per-day safeguard's intent and ensures rebalanceCount only counts real compressions, so an event freezes only after it has genuinely been scaled maxRebalances times. (Note: callers in MemoryBudget_applyToDisk already skip `.outsideWindow`/`.frozen`; restored still needs the impact write for the very first restore after a prior compression, so keep `file.impact = plan.newImpact`.) Optionally also guard the write to only run when abs(cur - newImpact) > epsilon to avoid pointless disk writes on true no-ops.

### 28. EMA weight decay bypassed in applyActions — lastModified set before computing decay
- **位置**: `Sources/MyPortrait/Memory/PersonalityMerger.swift:342-346`  ·  分类: logic  ·  子系统: memory-personality/portrait
- **问题**: For an existing personality concept, the code sets `file.lastModified = today` and only THEN computes `ema.afterMerge(stored: file.weight, daysSinceModified: file.daysSinceModified(now: today))`. Because daysSinceModified reads the just-overwritten lastModified, it always returns 0, so afterMerge applies no decay and simply does `stored + 1` every time.
- **影响/触发**: WeightEMA.afterMerge is documented as 'decay the old value to today, then +1' (WeightEMA.swift lines 22-25), relying on daysSinceModified reflecting time elapsed since the LAST merge. PortraitFile.daysSinceModified returns `now.timeIntervalSince(lastModified)/86400`, which is 0 when lastModified == today (PortraitFile.swift lines 236-239). Since line 342 sets lastModified=today BEFORE line 344-346 reads it, decay is always 0. Result: a concept's stored weight grows by +1 on every refresh with no time decay ever applied, so frequently-merged concepts accumulate unbounded weight and never age out, breaking the archive/ranking model. (Compare MemoriesView.swift lines 457-459, which correctly decays using the stored lastModified.)
- **修复建议**: Compute the decayed weight BEFORE overwriting lastModified. Reorder so the afterMerge call (using the stored prior lastModified) runs first, then set file.lastModified = today:

    if exists {
        file.weight = ema.afterMerge(
            stored: file.weight,
            daysSinceModified: file.daysSinceModified(now: today))
    } else {
        file.weight = 1.0
    }
    file.lastModified = today

This way daysSinceModified is measured against the prior merge's timestamp (correct decay), then lastModified is advanced to today for the next cycle. For the createNew branch, weight=1.0 is unaffected by ordering.

### 29. Flow-array parser splits on commas inside quoted elements, corrupting values
- **位置**: `Sources/MyPortrait/Memory/PortraitFileIO.swift:407-409`  ·  分类: data-loss  ·  子系统: memory-personality/portrait
- **问题**: parseFlowArray splits the inner contents on every `,` with `inner.split(separator: ",")`, ignoring quotes. The serializer quotes any element containing a comma (needsQuotes at line 461-463 returns true for `,`). On read, a quoted element like "foo, bar" is split into the two tokens `"foo` and `bar"`. requireStringArray (lines 298-303) only strips quotes when a token both starts AND ends with `"`, so neither fragment is cleaned: the single value round-trips into two corrupted strings (`"foo` and `bar"`).
- **影响/触发**: This silently corrupts any flow-array field (tags, aliases, distilled_into, evidence_event_ids, portrait_facets values) whose element contains a comma. Although most current values are kebab-case/slugs without commas, LLM-supplied tags/aliases are free text and can contain commas, at which point the data is permanently mangled on the next read/write cycle (one tag becomes two, with stray quote characters). The serializer explicitly anticipates commas by quoting, but the parser cannot reverse it.
- **修复建议**: Make parseFlowArray quote-aware so it does not split on commas inside quoted elements. Replace the body of parseFlowArray (PortraitFileIO.swift:402-410) with a small scanner that walks `inner` char by char, tracking an `inQuotes` flag toggled on un-escaped `"`, and only splits on `,` when not inside quotes. Pseudocode:

  var out: [String] = []
  var cur = ""
  var inQuotes = false
  var it = inner.makeIterator()
  while let c = it.next() {
      if c == "\"" { inQuotes.toggle(); cur.append(c); continue }
      if c == "," && !inQuotes {
          out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
      } else { cur.append(c) }
  }
  let last = cur.trimmingCharacters(in: .whitespaces)
  if !last.isEmpty || !out.isEmpty { out.append(last) }
  return out

This keeps `"foo, bar"` as a single token, which requireStringArray/facetArray then correctly strip to `foo, bar`. (Note: this fix does not address escaped quotes within a quoted element, but formatStringArray never escapes inner quotes — it only wraps — so the simple toggle is sufficient for round-tripping current writer output.) No other change needed; the writer side is already correct.

### 30. DateFormatter missing en_US_POSIX locale → wrong date math under non-Gregorian regional calendars
- **位置**: `Sources/MyPortrait/Memory/WritingCaptureStore.swift:856-865`  ·  分类: correctness  ·  子系统: writing-capture-core (IN FLUX)
- **问题**: utcDayRangeMs() builds a DateFormatter with dateFormat "yyyy-MM-dd" and UTC timeZone but never sets `locale`. With no explicit locale, DateFormatter uses the user's current locale, including its calendar. On a device whose region uses a non-Gregorian calendar (Buddhist/Japanese/etc.), `yyyy` is interpreted in that calendar, so `fmt.date(from: "2026-05-30")` resolves to the wrong absolute instant (or fails entirely), making the [start,end) millisecond window for the day wrong.
- **影响/触发**: The date strings passed in come from SQL `date(ts/1000,'unixepoch')` which always emits Gregorian YYYY-MM-DD. Parsing them with a non-Gregorian-calendar formatter yields the wrong UTC day window → typingEventsForDay/keystrokesForDay/framesForDay/hasTypingEvents read the wrong day's raw data (or throw invalidDate). Every other fixed-format DateFormatter in this same module (PortraitPaths, EventBuilder, MemoryScheduler, MemoriesView, InputCaptureView, Archiver, etc.) sets `f.locale = Locale(identifier: "en_US_POSIX")` exactly to prevent this; these two are the only omissions. Concrete impact: a user in such a region silently gets no/wrong writing-capture day-run output.
- **修复建议**: Add `fmt.locale = Locale(identifier: "en_US_POSIX")` to utcDayRangeMs (line ~857) immediately after constructing the DateFormatter, matching every other fixed-format formatter in the module. Apply the identical one-line fix to the second locale-unset formatter at line 758 (dayStatus), which has the same defect in the formatting direction.

### 31. File-system watcher dies after first self-write — hot-reload silently stops working
- **位置**: `Sources/MyPortrait/Settings/ConfigStore.swift:433-443`  ·  分类: concurrency  ·  子系统: settings-config
- **问题**: handleFileChange() early-returns (consuming the suppress flag) WITHOUT re-arming the DispatchSource when the event came from the store's own atomic write. After that, the watcher's fd points at a deleted inode and never fires again, so external edits (vim/sync) stop hot-reloading.
- **影响/触发**: writeNow() (line 259-273) writes with `atomically: true`, which writes a temp file then renames it over config.toml. The watcher fd was opened via `open(path.path, O_EVTONLY)` (line 408) and is bound to the ORIGINAL inode. The atomic rename-over deletes/replaces that inode, delivering a .rename/.delete event to the watched fd. Because writeNow set `suppressNextWatchEvent = true` (line 267), handleFileChange hits the `if suppressNextWatchEvent { ...; return }` branch and returns BEFORE the cancel/startWatching re-arm at lines 439-441. The fd now references the deleted old file forever. Concretely: any normal UI change → debounced writeNow → atomic replace → watcher dead. From then on `loadFromDisk()` is never called for external edits, so editing ~/.portrait/config.toml in vim no longer hot-reloads (the documented feature in the class header, lifecycle step 4). This also breaks on the very first run: startWatching() creates/opens an empty file (line 405-408), then the seed writeNow atomically replaces it, killing the watcher on the empty inode immediately. The non-suppressed (genuine external edit) path correctly re-arms, but it can only ever fire once because the first self-write already orphaned the fd.
- **修复建议**: Re-arm the watcher on the suppressed path too, since the atomic write orphans the fd regardless of who wrote it; just skip the disk re-read (we already hold the in-memory truth). Replace the early return with a re-arm-then-return:

    private func handleFileChange() {
        // Our own atomic write ALSO replaces the inode and orphans the fd,
        // so we must re-arm the watcher even when suppressing our own event.
        watchSource?.cancel()
        watchSource = nil
        startWatching()
        if suppressNextWatchEvent {
            suppressNextWatchEvent = false
            return            // skip loadFromDisk — in-memory is already current
        }
        loadFromDisk()
    }

(Note: startWatching() opens a fresh fd on the now-live config.toml inode, restoring hot-reload. Verify swift build after the change.)

### 32. mergePlan can crash via cosineSimilarity precondition on mismatched centroid dimensions
- **位置**: `Sources/MyPortrait/Settings/SpeakersView.swift:224-226`  ·  分类: crash  ·  子系统: settings-speakers
- **问题**: In mergePlan, the keep-centroid kc and each candidate centroid rc are passed straight to VectorMath.cosineSimilarity without verifying they have the same dimension. cosineSimilarity begins with `precondition(a.count == b.count, "vector dim mismatch")`, which traps (aborts the process) when the lengths differ.
- **影响/触发**: Centroids are written by multiple code paths / embedding engines (voice training vs diarization; the project history references whisper, qwen3-asr, and formerly bge-m3 — see TimelineDB.swift:927/944 and PortraitDBImpl.swift:310/342). Two speakers that happen to share a name (the exact case mergePlan targets) can have centroids of different lengths. When that happens, the precondition fires and crashes the whole app. This runs on the main actor inside runOrganize's Task, so it takes down the UI. Notably similarSpeakers() guards against exactly this with `guard item.vec.count == t.count else { return nil }` (TimelineDB.swift:1130), but mergePlan omits the same guard.
- **修复建议**: Add the same dimension guard the sibling call sites use. In SpeakersView.swift mergePlan (line 224-226), change the compactMap body to skip mismatched centroids instead of crashing:

  let mergeIds: [Int64] = group.compactMap { r in
      guard r.id != keep.id, let rid = Int64(r.id), let rc = centroids[rid],
            rc.count == kc.count else { return nil }
      return VectorMath.cosineSimilarity(kc, rc) >= simThreshold ? rid : nil
  }

This mirrors TimelineDB.swift:1130 (`guard item.vec.count == t.count else { return nil }`) and PortraitDBImpl.swift:295/355, turning the abort into a conservative skip (a centroid of a different dimension simply isn't merged), consistent with mergePlan's documented "缺质心的簇保守跳过" policy.

### 33. "Clear all cron job history" only deletes the capped/filtered subset, orphaning the rest
- **位置**: `Sources/MyPortrait/TimelineSidebar.swift:315-329, 506-510`  ·  分类: data-loss  ·  子系统: timeline-views
- **问题**: The Clear-all-history action deletes `cronJobHistoryConversations`, but that computed property is BOTH truncated by `cronJobHistoryLimit` (lines 324-328) and filtered by the active `cronHistorySearch` query (lines 316-323). The button label and dialog message claim it deletes every cron-job run conversation.
- **影响/触发**: If there are more cron-run conversations than `general.cronJobHistoryLimit` (cap > 0), cronJobHistoryConversations returns only the first `cap` of them. Clicking "Clear all history" then deletes only those `cap` conversations. The remaining cron-run conversations are NOT deleted, are filtered out of RECENTS (filteredConversations excludes cronJobConvIds, line 307), and are beyond the history cap — so they become unreachable in the UI yet still occupy the DB. The dialog explicitly promises "This permanently deletes every cron job run conversation", which is false. (Search also narrows the set, so "Clear all" with a search query active deletes only matches while still claiming "all".)
- **修复建议**: Make "Clear all cron job history" operate on the true full set, not the capped/filtered view. Compute the deletion targets directly from cronJobConvIds (the unfiltered, uncapped source) rather than cronJobHistoryConversations. For example, in the dialog button:

    let ids = Set(chatStore.conversations.map { $0.id })
        .intersection(cronJobConvIds)
    let active = chat.currentConvId
    for id in ids { chatStore.deleteConversation(id) }
    if let a = active, ids.contains(a) { chat.switchTo(nil) }

(or expose an unfiltered/uncapped helper, e.g. `allCronJobHistoryConversations`, and map over that.) Either keep the dialog wording "every cron job run conversation" honest by deleting all of them, OR — if the intent is truly "only what's currently shown" — change the button label and the message to say "Clear the N shown run(s)" / "deletes the runs currently listed (filtered/capped)". Given the per-job vs. flattened cap mismatch, also consider whether the sidebar should cap the flattened list at all, or cap per-job to match runs.json semantics.

## ⚪ LOW

### 34. OAuth callback never validates the `state` parameter (CSRF / code-injection)
- **位置**: `Sources/MyPortrait/AI/ChatGPTOAuth.swift:101-130, 327-335`  ·  分类: security  ·  子系统: ai-cron/net/secrets
- **问题**: login() generates a random `state` and sends it in the authorize URL, but CallbackListener.waitForCode() only extracts the `code` query item and never checks the returned `state` against the one that was sent. The local listener on 127.0.0.1:1455 will accept and exchange ANY request that hits /auth/callback?code=..., regardless of state.
- **影响/触发**: The whole point of the OAuth `state` value is to bind the callback to the request that initiated it. Because the listener accepts any code and the loopback port is fixed/known (1455), a malicious local page or another local process can hit the listener during the 120s window with an attacker-controlled `code`, and the app will exchange it and persist the attacker's tokens (login CSRF / account-fixation). At minimum a stale/duplicate callback from a previous attempt is accepted silently.
- **修复建议**: Thread the generated `state` into the listener and reject any callback whose `state` doesn't match. Pass `state` into waitForCode (e.g. `func waitForCode(expectedState: String) async throws -> String`), and in the guard at lines 329-335 also extract `comps.queryItems?.first(where: { $0.name == "state" })?.value` and require it equals `expectedState` (constant-time compare); on mismatch respond 400 and throw, same as the existing no-code path. Update the call site at line 122 to `listener.waitForCode(expectedState: state)`. PKCE already provides the main protection, so this is primarily standards-compliance / defense-in-depth and stale-callback rejection.

### 35. PII rule ordering mislabels Anthropic keys as openai-key
- **位置**: `Sources/MyPortrait/AI/PIIRedactor.swift:30-31`  ·  分类: logic  ·  子系统: ai-cron/net/secrets
- **问题**: The rules array runs `openai-key` (pattern `sk-[A-Za-z0-9_-]{20,}`) before `anthropic-key` (`sk-ant-[A-Za-z0-9_-]{20,}`). Anthropic keys begin with `sk-ant-`, so the broader openai-key pattern matches first and replaces them with `[REDACTED:openai-key]`; the anthropic-key rule then never fires. The comment at line 17 explicitly says 'run the longest / most specific patterns first', but here the more specific (anthropic) rule is placed second.
- **影响/触发**: Not a redaction failure (the secret is still removed), but the label is wrong, which contradicts the stated design and can mislead any audit/diagnostics that rely on the redaction kind. Low impact because the value is still scrubbed.
- **修复建议**: Swap the two rules so the more specific anthropic-key rule runs first:
  .init(label: "anthropic-key", pattern: #"sk-ant-[A-Za-z0-9_-]{20,}"#),
  .init(label: "openai-key",    pattern: #"sk-[A-Za-z0-9_-]{20,}"#),
This makes `sk-ant-...` keys get the correct `[REDACTED:anthropic-key]` label while `sk-...` (non-ant) keys still fall through to openai-key, restoring the "most specific first" invariant stated in the line 15-17 comment. No other change needed; both rules still fully scrub the secret either way.

### 36. STARTTLSSession leaks the socket fd when init() throws after TCP connect
- **位置**: `Sources/MyPortrait/AI/SMTPClient.swift:267-279, 313-322, 464-467`  ·  分类: resource-leak  ·  子系统: ai-cron/net/secrets
- **问题**: STARTTLSSession opens a POSIX socket in connectPlain() (sets self.fd) and then runs plainHandshakeAndUpgrade(). If the handshake fails (wrong greeting code 220, EHLO != 250, STARTTLS != 220, or the TLS handshake fails) init() throws. STARTTLSSession has no deinit, and the caller's `defer { session.close() }` only runs once the `try await ...Session(...)` expression has SUCCESSFULLY produced a session — when init throws, no session value is bound, so close() is never invoked and the already-open fd is leaked.
- **影响/触发**: Every failed STARTTLS verification attempt (bad credentials, server that rejects STARTTLS, TLS negotiation failure) leaks one file descriptor. A user repeatedly tapping 'Test connection' against a misconfigured 587/25 server will accumulate leaked fds until the process hits its descriptor limit. The implicit-TLS path (NWImplicitTLSSession) is unaffected because NWConnection is GC'd; raw fds are not.
- **修复建议**: Ensure the fd/SSLContext are released whenever init fails. Simplest: add a deinit that calls close(), so a discarded throwing instance still cleans up:

    deinit { close() }

(close() at 464-467 is already idempotent/guarded: it only SSLClose if sslContext != nil and only Darwin.close if fd >= 0.) Alternatively, guard the init body so the fd is closed on any throw:

    init(host: String, port: Int) async throws {
        self.host = host
        do {
            try await Task.detached(priority: .userInitiated) { [self] in
                try connectPlain(host: host, port: port)
                try plainHandshakeAndUpgrade(host: host)
            }.value
        } catch {
            close()      // release fd/sslContext before rethrowing
            throw error
        }
    }

The deinit approach is the least-code fix and also covers any future code path that drops the object without calling close().

### 37. Tap callback spawns unordered Task per buffer — audio chunks processed out of order
- **位置**: `Sources/MyPortrait/Capture/Audio/AudioCaptureService.swift:211-217`  ·  分类: concurrency  ·  子系统: audio-capture (CoreAudio)
- **问题**: The installTap callback fires on the realtime audio thread and, for each buffer, spawns a fresh unstructured `Task { await self?.performConversion(buffer:) }`. Separately-created Tasks that hop onto an actor are NOT guaranteed to execute in the order they were enqueued.
- **影响/触发**: Under load (or simply because the actor is busy when several callbacks fire in quick succession), buffer N+1's Task can run before buffer N's. performConversion then yields the converted samples to the AsyncStream out of order, so VADRecorder.feed() receives time-scrambled audio. The result is corrupted/garbled speech inside recorded segments and degraded VAD/transcription accuracy. There is no sequence number or serial queue to preserve order (confirmed: no DispatchQueue/sequence handling around these Tasks).
- **修复建议**: Preserve ordering without per-buffer Tasks. Cleanest fix: do the conversion synchronously inside the tap callback (it's pure CPU, no await needed) and push directly to the continuation, removing the actor hop entirely — e.g. make a nonisolated converter helper and call `cont.yield(convert(buffer))` straight from the callback (the continuation yield is already thread-safe). If actor isolation must be kept, replace the fan-out of independent Tasks with a single long-lived consumer: have the tap callback enqueue raw buffers into one AsyncStream<AVAudioPCMBuffer>, and a single `for await buffer in bufferStream { await performConversion(buffer) }` loop drains it in strict order. Either approach guarantees buffer N is fully processed/yielded before N+1. Apply the same fix to SystemAudioCaptureService.swift:589-594.

### 38. activeUID never cleared on stop — UI shows phantom 'recording from' device
- **位置**: `Sources/MyPortrait/Capture/Audio/AudioCaptureService.swift:125-164`  ·  分类: logic  ·  子系统: audio-capture (CoreAudio)
- **问题**: start() sets AudioDevicesMonitor.shared.setActiveUID(activeUID) (line 225) when the engine starts, but stop() never resets it back to "". setActiveUID is only ever called from the start path (confirmed: no reset call exists anywhere).
- **影响/触发**: When the user toggles mic capture off (Services.applyAudioCapture(enabled:false) → audio.stop()), AudioDevicesMonitor.activeUID keeps the last device UID. The UI 'Currently recording from' indicator (CaptureView.swift:525-535 lights green and shows the device when activeUID is non-empty) stays lit/green even though nothing is being recorded, misleading the user about capture state.
- **修复建议**: In AudioCaptureService.stop() (AudioCaptureService.swift, just before the final `logger.info("AudioCaptureService stopped")` at line 163), reset the live indicator: `Task { @MainActor in AudioDevicesMonitor.shared.setActiveUID("") }`. This keeps the documented invariant (activeUID empty == not capturing). It is safe w.r.t. restartIfRunning/restartForDeviceChange because both call stop() then immediately start() — start() re-sets activeUID at line 225; the brief empty window is harmless and those restart decisions only read activeUID while samplesTask != nil (i.e. before stop()).

### 39. Bluetooth buffer-size heuristic queries system default, not the actually-bound input device
- **位置**: `Sources/MyPortrait/Capture/Audio/AudioCaptureService.swift:206`  ·  分类: logic  ·  子系统: audio-capture (CoreAudio)
- **问题**: The tap buffer size is chosen by Self.defaultInputIsBluetooth(), which reads kAudioHardwarePropertyDefaultInputDevice's transport type. But the engine may have just been bound to a user-locked preferredInputDeviceUID (bindPreferredInputDevice at line 181) that is a different device from the system default.
- **影响/触发**: If the user locks a wired/built-in mic while a Bluetooth device is the system default (or vice versa), the buffer size is sized for the wrong device. The larger 8192 buffer is meant to absorb Bluetooth jitter; using 4096 for a locked BT mic (because system default is wired) can cause input overruns/dropouts, while using 8192 for a wired mic adds needless latency. The heuristic should inspect the device the tap is actually bound to.
- **修复建议**: Size the buffer based on the device the tap is actually bound to, not the system default. After bindPreferredInputDevice (line 181) the AUHAL's CurrentDevice is already set, so add a static helper that reads the inputNode's bound device transport type and use it at line 206. Concretely:

  nonisolated private static func boundInputIsBluetooth(inputNode: AVAudioInputNode) -> Bool {
      guard let au = inputNode.audioUnit else { return false }
      var did = AudioDeviceID(0)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &did, &size) == noErr, did != 0
      else { return false }
      var transport: UInt32 = 0
      var tsize = UInt32(MemoryLayout<UInt32>.size)
      var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
      guard AudioObjectGetPropertyData(did, &taddr, 0, nil, &tsize, &transport) == noErr
      else { return false }
      return transport == kAudioDeviceTransportTypeBluetooth
          || transport == kAudioDeviceTransportTypeBluetoothLE
  }

Then change line 206 to:
  let bufferSize: AVAudioFrameCount = Self.boundInputIsBluetooth(inputNode: inputNode) ? 8192 : 4096

This reuses the existing CoreAudio query pattern (currentInputDeviceUID already reads the same CurrentDevice property) and correctly reflects the locked device. Given the low impact and narrow trigger, this is a nice-to-have correctness fix rather than urgent.

### 40. AC-only mid-batch guard logs but never stops the loop
- **位置**: `Sources/MyPortrait/Capture/Audio/TranscriptionScheduler.swift:197-204`  ·  分类: logic  ·  子系统: audio-transcription
- **问题**: In processQueueOnce, when power switches to battery mid-batch the code only logs 'stopping after current segment' but does not break/return; it goes on to transcribe the next chunk anyway.
- **影响/触发**: The inline comment (line 199: '当前段跑完即停(仅 AC-only 模式下)') and the log message both promise the batch stops after the current segment once AC is lost, but there is no break/return after the log. With queueBatchLimit=2 this means up to 1 extra full segment (can be a ~60s VADRecorder maxSegmentSeconds chunk) gets transcribed on battery, doing exactly the heavy CPU/Neural-Engine work the AC-only mode is meant to avoid. Bounded but a real intent/behavior mismatch and battery drain.
- **修复建议**: Add a `break` after the log so the remaining chunks in the batch are left pending and deferred to the next scheduler tick (which already early-returns on battery via the lines 172-178 guard):
    for chunk in chunks {
        if Task.isCancelled { return }
        // 中途变电池 → 当前段跑完即停(仅 AC-only 模式下)。
        if acOnly && !PowerMonitor.isOnAC {
            logger.info("power switched to battery mid-batch, stopping after current segment")
            break
        }
        await transcribeOne(chunk: chunk)
    }
This makes the actual control flow match the comment/log: the chunk currently being transcribed finishes, and no further chunk is started on battery. The skipped chunks stay 'pending' and are picked up when back on AC.

### 41. Transcript sidecar hardcodes engine='whisperkit' regardless of actual engine
- **位置**: `Sources/MyPortrait/Capture/Audio/TranscriptionScheduler.swift:378`  ·  分类: correctness  ·  子系统: audio-transcription
- **问题**: writeTranscriptSidecar always writes "engine": "whisperkit" into the sidecar JSON even when the chunk was transcribed by qwen, deepgram, or the custom OpenAI-compatible engine.
- **影响/触发**: transcribeOne knows the real engine (settings.engine, already stored on each TranscriptionRecord and passed to DiagLog), but the sidecar JSON unconditionally records 'whisperkit'. Any tooling, debugging, or re-transcription logic that reads the sidecar to learn which engine produced the text will be misled (e.g. attributing a Deepgram/Qwen result to WhisperKit). The DB row has the correct engine, so this is metadata drift rather than data loss, hence low severity.
- **修复建议**: Thread the real engine into the sidecar instead of hardcoding it. writeTranscriptSidecar already runs inside transcribeOne, which has `settings` in scope — add an `engine: String` parameter and pass `settings.engine`:

  writeTranscriptSidecar(wavPath: chunk.filePath, text: fullText, chunk: chunk, engine: settings.engine, transcribedAtMs: nowMs)

and in writeTranscriptSidecar:
  "engine": engine,   // was "whisperkit"

This makes the sidecar consistent with the DB row (TranscriptionRecord.engine) and the diag log, which all use settings.engine.

### 42. frameEvents AsyncStream finished in stop() and never recreated — dead after toggle
- **位置**: `Sources/MyPortrait/Capture/Coordinator/CaptureCoordinator.swift:180`  ·  分类: logic  ·  子系统: capture-lifecycle/health
- **问题**: frameEvents and _continuation are 'let' created once in init (lines 47-48, 71-75). stop() calls _continuation.finish() (line 180), which permanently terminates the AsyncStream. start()/stop() are documented as idempotent and are driven by the screen-capture toggle (Services.applyScreenCapture calls coordinator.start()/stop() on the SAME instance). After one stop->start cycle, _continuation.yield(event) at line 356 is a no-op forever.
- **影响/触发**: This is the exact bug class the team already fixed for EventSources (see EventSources.swift:14-17 comment: 'AsyncStream 一旦 finish() 就永久死了... coordinator stop->start 第二轮拿到的是已 finished 的死流'). EventSources was redesigned to build a fresh stream per start(); CaptureCoordinator's own output stream still finishes-once. So after the user toggles screen capture off then on again, the pipeline captures/OCRs/inserts to DB but never emits any FrameEvent to subscribers — a silent functional dead-end for any frameEvents consumer.
- **修复建议**: Align the output stream lifecycle with start/stop, mirroring the EventSources fix. Make frameEvents/_continuation `var` and rebuild a fresh stream at the top of start() (before yielding any event), e.g.:
```swift
private var _continuation: AsyncStream<FrameEvent>.Continuation
private(set) var frameEvents: AsyncStream<FrameEvent>
...
func start() async throws {
    guard captureTask == nil else { return }
    // rebuild dead-after-stop output stream
    var c: AsyncStream<FrameEvent>.Continuation!
    frameEvents = AsyncStream<FrameEvent> { cont in c = cont }
    _continuation = c
    ...
}
```
Note frameEvents is currently `nonisolated let`; making it actor-isolated `var` means a future subscriber must `await coordinator.frameEvents`. Since there is no subscriber today, this is safe to change now. Alternatively, keep frameEvents as a stable facade and swap only an internal continuation — but the simplest correct fix is rebuild-on-start. Given there is currently NO consumer, the lowest-cost option is simply to defer this until a frameEvents subscriber is actually added; if you do add one, you MUST apply the rebuild-on-start fix or the subscriber will go dead after the first toggle.

### 43. FocusProbe throttle uses wall-clock time; backward clock jump can wedge focus refresh
- **位置**: `Sources/MyPortrait/Capture/Screen/FocusProbe.swift:137-139`  ·  分类: logic  ·  子系统: screen+ocr
- **问题**: refresh() throttles using Date()-derived wall-clock milliseconds compared against a stored lastRefreshAtMs. If the system wall clock jumps backward (NTP correction, user manually setting the clock, DST/TZ change applied to the epoch source), nowMs becomes smaller than lastRefreshAtMs, so nowMs - lastRefreshAtMs is negative and always < refreshMinIntervalMs.
- **影响/触发**: While the clock is behind the recorded lastRefreshAtMs, every refresh() returns early at line 138 without ever updating the cached FocusInfo, so app/window/URL focus metadata silently freezes on a stale value until the wall clock advances past the old timestamp again. Frames captured in that window get attributed to the wrong app/title (wrong DB rows, wrong incognito/ignore decisions). A monotonic clock would not have this failure mode.
- **修复建议**: Use the monotonic clock the rest of the file already uses, instead of wall-clock. Replace line 137:
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
with:
    let nowMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
DispatchTime.now().uptimeNanoseconds is a monotonic counter (does not move on NTP/clock changes), so the delta can never go negative and the throttle stays correct across clock adjustments. lastRefreshAtMs default 0 is still fine since uptime nanoseconds since boot is always > 0 and the first delta is huge (always passes). No other changes needed.

### 44. Edit-and-resend silently drops attachments (and tweaked chips) the user added during edit
- **位置**: `Sources/MyPortrait/HomeView.swift:278-290`  ·  分类: logic  ·  子系统: home-view
- **问题**: In send(), the captured attachmentsToSend and chipsToSend are passed to chat.send on the normal path, but on the editingMessageId path the code calls chat.editAndResend(id, newText:) which receives neither. editAndResend re-reads the OLD chips via contextChipsByMessage[messageId] and accepts no attachments at all, so any attachment the user pasted/dropped while editing (the input bar is fully live during edit) and any chip edits are discarded with no feedback.
- **影响/触发**: Reachable in normal use: click pencil to edit a past user message (sets editingMessageId at lines 89-95), then drop/paste an image or change context chips, then press Enter. The attachments are captured into attachmentsToSend (line 279) and then thrown away because the edit branch ignores them. The user sees their attachment vanish from the resent turn with no error -- silent loss of user intent. The guard at line 277 even allows sending with only attachments (empty text), so an attachments-only edit resend ends up sending the literal '(attachments only)' string (line 286) with zero attachments.
- **修复建议**: Thread both the live chips and attachments through the edit path so edit-and-resend mirrors a normal send.

1. Change the signature in ChatController.swift:124 to accept them:
   func editAndResend(_ messageId: UUID, newText: String,
                      chips: [ContextChip] = [], attachments: [Attachment] = []) {
   ...and at line 134 forward them:
       send(newText, chips: chips, attachments: attachments)
   (Drop the local `let chips = contextChipsByMessage[messageId] ?? []` at line 127, or keep it only as a fallback when the caller passes an empty chips array.)

2. In HomeView.swift:286 pass the captured values:
       chat.editAndResend(id, newText: trimmed.isEmpty ? "(attachments only)" : trimmed,
                          chips: chipsToSend, attachments: attachmentsToSend)

This keeps the change minimal (matches the user's "smallest change" preference), reuses the existing send() attachment plumbing (attachmentsByMessage receipt + the `[User attached files...]` prompt section), and makes an attachments-only edit actually carry its attachments instead of sending the bare "(attachments only)" string.

### 45. mp-query audio --limit > 60 is silently capped at 60 (hardcoded LIMIT in the reused DB helper)
- **位置**: `Sources/MyPortrait/MPQueryCLI.swift:630-636`  ·  分类: correctness  ·  子系统: clis
- **问题**: `searchTranscripts` fetches rows via `db.audioTranscripts(around: mid, before: half, after: half)`, but that TimelineDB helper has a hardcoded `LIMIT 60` and `ORDER BY ac.recorded_at_ms ASC` (TimelineDB.swift:383-384). The CLI's own `limit` (e.g. `audio --limit 200`) is only applied afterward as `if out.count >= limit { break }`, so it can never exceed the 60 rows the helper already returned.
- **影响/触发**: For the `audio` subcommand a user/agent passing `--limit 100`/`--limit 200` will silently get at most 60 transcripts — and specifically the earliest 60 in the window (ASC), not the most recent or most relevant. The result_count looks legitimate, so the truncation is invisible to the caller. The default `--limit 60` happens to mask this, but any larger explicit limit produces wrong/incomplete results.
- **修复建议**: Thread the caller's limit into the helper. Add an optional `limit` parameter to TimelineDB.audioTranscripts(around:before:after:) defaulting to 60 (so ContextPickerView.swift:157 is unaffected), bind it in place of the hardcoded `LIMIT 60`: change the SQL last line to `LIMIT ?` and `sqlite3_bind_int64(stmt, 3, Int64(limit))` (or `sqlite3_bind_int`). Then in MPQueryCLI.searchTranscripts line 636 pass `limit:` through: `db.audioTranscripts(around: mid, before: half, after: half, limit: limit)`. Note that because searchTranscripts also post-filters by q/speaker before the `out.count >= limit` break, when those filters are active you may want to fetch more than `limit` rows from the DB (e.g. fetch a larger cap) so the post-filter can still reach `limit`; for the `audio` subcommand q is nil and speaker is usually nil, so passing limit directly is sufficient there. Separately consider whether `ORDER BY ... ASC` is the desired truncation direction — if the user expects the most recent transcripts, DESC + reverse would be more intuitive, but that is a behavior choice, not required for the fix.

### 46. WritingCaptureRecord decoder throws if LLM omits edit_log, dropping the entire group's records
- **位置**: `Sources/MyPortrait/Memory/WritingCapturePass3Agent.swift:43-48`  ·  分类: data-loss  ·  子系统: writing-capture-agents (IN FLUX)
- **问题**: WritingCaptureRecord.init(from:) decodes edit_log via nestedUnkeyedContainer(forKey:.editLog), which throws DecodingError.keyNotFound if the LLM omits the edit_log key entirely. Because parse() decodes the whole Pass3Response in a single try, one record missing edit_log makes the entire response decode fail, so every record (and discarded) for that (app,url) group is lost (caught at line 505-508, re-thrown as malformedJSON).
- **影响/触发**: The same struct's own comment (line 38) and custom decoder were written specifically to TOLERATE LLM field omissions ('LLM 偶发对 delete 类目省略 text 字段' -> EditEntryTolerant defaults missing entry-level text to ""). But a record-level omission of the whole edit_log array is NOT tolerated and is exactly the kind of LLM imperfection the code anticipates elsewhere. I verified with a minimal repro that nestedUnkeyedContainer on a missing snake_case key throws keyNotFound. Impact: whenever WritingCapturePass3Agent.run/parse is exercised (tests, legacy/non-canvas LLM path) and the model emits a record without edit_log, the whole group's transcription is discarded instead of degrading gracefully.
- **修复建议**: Make edit_log decoding tolerant of an omitted or null key, mirroring the file's existing tolerance pattern. Replace line 43 `var rawArray = try c.nestedUnkeyedContainer(forKey: .editLog)` and its loop with a guarded version, e.g.: `var entries: [EditEntry] = []` then `if var rawArray = try? c.nestedUnkeyedContainer(forKey: .editLog) { while !rawArray.isAtEnd { let raw = try rawArray.decode(EditEntryTolerant.self); entries.append(EditEntry(ts: raw.ts, kind: raw.kind, text: raw.text ?? "")) } }` then `editLog = entries`. Using `try?` on the container fetch defaults a missing OR null edit_log to []. Add a regression test asserting parse() succeeds on a record with no `edit_log` key (and on `"edit_log": null`). Note: low urgency because the current live worker never calls Pass3Agent.run/parse (makePass3 closure is unused) — only fix is needed if/when that path is reactivated.

### 47. hasTypingEvents error silently swallowed → whole day-run becomes a silent no-op
- **位置**: `Sources/MyPortrait/Memory/WritingCaptureWorker.swift:89-93`  ·  分类: logic  ·  子系统: writing-capture-core (IN FLUX)
- **问题**: runUnprocessedDays filters candidate days with `(try? store.hasTypingEvents(date: d)) == true`. hasTypingEvents calls utcDayRangeMs which can throw StoreError.invalidDate. The `try?` converts any throw to nil, so a day that errors is silently dropped from `days` and never processed, with no error surfaced (only an info log of the skip count attributed to 'no typing').
- **影响/触发**: This compounds the locale bug above: if utcDayRangeMs throws for a date (e.g. invalidDate under a non-Gregorian calendar, or any future schema/parse error), every day gets silently filtered out. The user sees '0 days with typing' and the entire writing-capture day pipeline does nothing, with the real cause (a thrown error) hidden. A genuine failure is misreported as 'no typing data'.
- **修复建议**: Don't use `try?` to mean "false"; let a thrown error from hasTypingEvents propagate (the closure is already inside a `try await Task.detached`), or at minimum log it instead of silently bucketing it as "no typing". E.g.:
    let days = try await Task.detached(priority: .userInitiated) { [store] in
        try candidate.filter { d in try store.hasTypingEvents(date: d) }
    }.value
This way a real invalidDate / DB error surfaces as a thrown error (and the catch at runUnprocessedDays' caller / the per-day loop can report it) rather than being misreported in the "skipped: no typing" count. Separately, giving utcDayRangeMs's DateFormatter an explicit `fmt.locale = Locale(identifier: "en_US_POSIX")` would make invalidDate truly unreachable for the SQLite-generated date strings.

### 48. updateCountdown auto-install banner is suppressed/never created if appUpdates toggle is off path differs — countdown depends solely on an on-screen, hover-pausable card tick
- **位置**: `Sources/MyPortrait/Notifications/NotificationOverlay.swift:317-335 (consumed via NotificationCenterService.swift 81-87, 123-128)`  ·  分类: logic  ·  子系统: onboarding/notif/updater
- **问题**: The 10s auto-update countdown's install action (box.h() -> silent install + relaunch) fires only when NotificationCardView.startTick() reaches notification.timeout. startTick is gated by .onAppear/.onChange(of: hover): the tick is cancelled (stopTick) whenever hover is true and never advances. If the pointer rests over the countdown card, elapsed never increases and the update never installs. There is no wall-clock fallback; pausing on hover applies to the auto-install countdown the same as to an ordinary banner.
- **影响/触发**: For a normal toast, pause-on-hover is fine. But here the same mechanism gates an unattended auto-update install the user opted into (autoDownloadUpdates). A user who simply leaves the cursor parked over the banner (or whose cursor happens to land there) silently and indefinitely defers the update with no indication, and the only other install path is the next app quit. The behavior is also fragile: the install timing is wall-clock-inaccurate because elapsed is incremented by a fixed 0.05 per ~50ms sleep regardless of real scheduling delay.
- **修复建议**: Give the auto-install countdown a wall-clock floor that hover cannot defer beyond a bound, while keeping pause-on-hover for ordinary toasts. Minimal options: (a) In NotificationCardView, when the notification carries an onTimeout (i.e. it's an updateCountdown), do NOT stopTick() on hover — let the countdown run regardless of hover (change the onChange at NotificationOverlay.swift:309-312 to skip pausing when notification.onTimeout != nil). (b) Or record an absolute deadline = createdAt + timeout for updateCountdown notifications and compute elapsed from Date() instead of accumulating 0.05/tick, so hover only pauses the visual but the install fires at the real deadline. Either keeps the existing hover-pause UX for normal banners while ensuring the opted-in update installs on schedule.

### 49. Input Monitoring probe re-enters the main run loop synchronously every 3s, blocking the UI
- **位置**: `Sources/MyPortrait/Onboarding/OnboardingView.swift:406-451 (driven from 370-378, 282-286)`  ·  分类: performance  ·  子系统: onboarding/notif/updater
- **问题**: probeInputMonitoringTap() installs a CGEventTap, posts a null event, then busy-spins the MAIN run loop with CFRunLoopRunInMode(.defaultMode, 0.01, false) in a loop until a 100 ms deadline. It is invoked from refreshExtraPerms(), which runs both in onAppear and in a @MainActor poll Task every 3 seconds (Task.sleep(3_000_000_000)). So while the Permissions onboarding step is visible, the main thread synchronously re-enters its own run loop for up to 100 ms every 3 seconds.
- **影响/触发**: Reentering CFRunLoopRunInMode on the MainActor pumps nested run-loop sources/timers while SwiftUI is mid-update. This both (a) janks the UI with a recurring up-to-100ms stall and (b) risks reentrancy: nested run-loop processing can deliver other main-queue blocks/animation callbacks while checkInputMonitoring() is on the stack. The cost is paid every 3s even when the permission is already known-granted (probe runs whenever IOHIDCheckAccess != denied).
- **修复建议**: Stop spinning the main run loop synchronously. Two clean options: (a) Skip the round-trip probe entirely when IOHIDCheckAccess == kIOHIDAccessTypeGranted and only treat that as granted (drop the daemon-cache distrust for the steady-state poll), so the 3s poll never re-enters the run loop in the common granted case; or (b) make probeInputMonitoringTap() asynchronous — after posting the null event, schedule the tap-cleanup and result read on a DispatchWorkItem ~100ms later via DispatchQueue.main.asyncAfter (or an awaitable continuation) instead of `while Date() < deadline { CFRunLoopRunInMode(...) }`, so the main thread is never blocked and the run loop is never re-entered. Either removes the recurring synchronous stall and the nested-run-loop reentrancy. Also consider running the poll on a lower cadence or only while the row shows non-granted.

### 50. reassignInputTranscriptionsToSpeaker writes audio_transcriptions via raw sqlite3 (FTS5 tokenizer rollback)
- **位置**: `Sources/MyPortrait/TimelineDB.swift:1042-1059`  ·  分类: data-loss  ·  子系统: speaker-diarization
- **问题**: reassignInputTranscriptionsToSpeaker opens a raw SQLITE_OPEN_READWRITE connection (no FoundationTokenizer registered) and runs `UPDATE audio_transcriptions SET speaker_id = ? WHERE audio_chunk_id IN (...)`.
- **影响/触发**: Same FTS5 hazard as the voice-training upsert: the UPDATE fires the transcriptions_fts sync trigger which needs the foundation_icu tokenizer; a raw connection has none, so the trigger errors and the UPDATE fails/rolls back. The function only checks `sqlite3_step == SQLITE_DONE` and returns 0 on failure, so the caller silently sees 'no rows reassigned' — the speaker attribution write is silently dropped. mergeSpeakers / FixSpeakersCLI explicitly document that this exact statement MUST go through a GRDB connection.
- **修复建议**: Route the UPDATE through a GRDB connection with the tokenizer registered, exactly like mergeSpeakers (TimelineDB.swift:1146-1170). Replace the raw sqlite3 body of reassignInputTranscriptionsToSpeaker with:

  var config = Configuration()
  config.prepareDatabase { db in db.add(tokenizer: FoundationTokenizer.self) }
  let queue = try DatabaseQueue(path: dbPath, configuration: config)
  let n = try queue.write { db -> Int in
      try db.execute(sql: """
          UPDATE audio_transcriptions SET speaker_id = :sid
          WHERE audio_chunk_id IN (
              SELECT id FROM audio_chunks
              WHERE is_input = 1 AND recorded_at_ms BETWEEN :from AND :to)
          """, arguments: ["sid": speakerId, "from": fromMs, "to": toMs])
      return db.changesCount
  }
  return n

Use dict-form arguments (per the project's GRDB deadlock rule). Do the same for the raw UPDATE audio_transcriptions at TimelineDB.swift:909-913 (in the live upsertVoiceTrainedSpeaker path), which has the identical tokenizer-rollback hazard but IS reachable at runtime. Since reassign is currently dead code, prioritize the 909-913 fix.

### 51. TimelineSidebar.reload() launches uncancelled overlapping Tasks; slower stale result can clobber newer one
- **位置**: `Sources/MyPortrait/TimelineSidebar.swift:101-104, 597-622`  ·  分类: concurrency  ·  子系统: timeline-views
- **问题**: reload() is invoked from four reactive triggers (onAppear, onChange of focusIndex, frames.count, and selection) and each one spawns an unstructured `Task { }` that awaits two DB queries and then writes self.activeApps / self.audioItems on the main actor. There is no task token / cancellation, so completion order is not guaranteed to match request order.
- **影响/触发**: When the user scrubs the timeline quickly, focusIndex changes fire many reload() calls in sequence. The DB queries (activeAppsAround / audioTranscriptsAround) can finish out of order, so an earlier query for an older focus moment can complete after the latest one and overwrite the sidebar with stale Active-Apps / Audio context that no longer matches the currently focused frame. It is not a crash, but it shows wrong data for the selected moment until the next reload.
- **修复建议**: Add a monotonic request token so only the latest Task's result is committed. Minimal change inside TimelineSidebar:

  @State private var reloadToken = 0

  private func reload() {
      guard selection == .timeline, let moment = focusedTimestamp else { activeApps = []; audioItems = []; return }
      guard let db = services?.db else { activeApps = []; audioItems = []; return }
      reloadToken &+= 1
      let token = reloadToken
      loading = true
      Task {
          let apps = (try? await db.activeAppsAround(timestamp: moment, windowSeconds: 45)) ?? []
          let audio = (try? await db.audioTranscriptsAround(timestamp: moment, beforeSeconds: 120, afterSeconds: 30)) ?? []
          await MainActor.run {
              guard token == reloadToken else { return }   // drop stale result
              self.activeApps = apps
              self.audioItems = audio
              self.loading = false
          }
      }
  }

(Token compare/mutation both happen on the main actor — reload() runs on MainActor as a SwiftUI View method and the check is inside MainActor.run — so no extra synchronization is needed. Alternatively, store the Task in @State and cancel the previous one before spawning, but the token guard is simpler and sufficient since the work is just two awaits.)

### 52. Cross-day timeline seek silently ignores the requested moment (pendingSeek never consumed)
- **位置**: `Sources/MyPortrait/TimelineView.swift:23-31, 172-186`  ·  分类: logic  ·  子系统: timeline-views
- **问题**: TimelineState.seek(to:) sets `pendingSeek = t` when the target falls on a different day, intending the frame loader to snap focusIndex to the nearest frame once that day's frames arrive. But nothing ever reads `pendingSeek`: TimelineView.reload() (the only place frames are loaded) unconditionally sets `state.focusIndex = max(fetched.count - 1, 0)`, i.e. the LAST frame of the day, and never checks pendingSeek.
- **影响/触发**: ContentView calls `timeline.seek(to:)` from the `.navigateToTimelineAt` notification (clicking a cron-job/event link that points at a moment on another day). seek() switches selectedDay and queues pendingSeek, .task(id: state.selectedDay) fires reload(), but reload() overwrites focusIndex with the end-of-day frame and drops pendingSeek. The user lands at the end of the wrong day instead of the moment they clicked — the deep-link navigation is broken for any cross-day target. Same-day seek works (snapFocus), so the bug only manifests across days, making it easy to miss.
- **修复建议**: Make reload() honor pendingSeek. In the async Task in reload() (around line 181-184), after setting state.frames = fetched, branch on pendingSeek before defaulting to the last frame:

    let fetched = (try? await db.framesForDay(day)) ?? []
    state.frames = fetched
    if let target = state.pendingSeek {
        state.snapFocus(to: target)   // picks nearest frame; guards empty internally
        state.pendingSeek = nil
    } else {
        state.focusIndex = max(fetched.count - 1, 0)
    }
    state.loading = false

snapFocus already guards against empty frames (returns early, leaving focusIndex at 0), so an empty target day degrades gracefully. Clearing pendingSeek after consumption prevents a stale target from hijacking a later same-day reload (e.g. the .timelineFramesChanged refetch).

### 53. RealAppIcon keeps showing the previous app's icon when reused for a known-miss app name
- **位置**: `Sources/MyPortrait/TimelineView.swift:502-511`  ·  分类: correctness  ·  子系统: timeline-views
- **问题**: RealAppIcon.load() does not reset @State realIcon before resolving the new appName. When the view instance is reused for a different appName, line 504 returns early on a known-miss WITHOUT clearing realIcon, and line 510 only assigns on success — so the stale image from the previous appName stays on screen.
- **影响/触发**: RealAppIcon is used inside LazyHStack columns (FrameColumn, line 629) and ActiveAppRow (line 730), both of which reuse view instances. When a column previously showing app A's resolved icon is reused for app B whose icon resolution previously missed (isKnownMiss == true), load() returns at line 504 leaving realIcon = A's icon, so the timeline shows A's icon labeled as B. The sibling IntegrationIcon.tryLoadRealIcon (ConnectionsView.swift line 779) documents and fixes exactly this bug by clearing realIcon first; RealAppIcon was never given the same fix.
- **修复建议**: In RealAppIcon.load() (TimelineView.swift:502), clear stale state before resolving — mirror the sibling fix in IntegrationIcon.tryLoadRealIcon. Concretely, on a known-miss, set the icon to nil instead of returning bare, and make the resolve path assign unconditionally:
  private func load() async {
      if let cached = AppNameIconCache.shared.get(appName) { self.realIcon = cached; return }
      if AppNameIconCache.shared.isKnownMiss(appName) { self.realIcon = nil; return }
      self.realIcon = nil                       // clear before async resolve
      let name = appName
      let img = await Task.detached(priority: .userInitiated) {
          AppIconLoader.icon(forAppName: name)
      }.value
      AppNameIconCache.shared.store(img, for: appName)
      self.realIcon = img                        // assign unconditionally (nil falls back to placeholder)
  }
This guarantees realIcon reflects the current appName on every code path.
