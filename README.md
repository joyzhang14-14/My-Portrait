# My-Portrait

A 24/7 personal AI database that runs locally — native macOS Swift app.

Captures your screen (screenshots + OCR), audio (Whisper transcription), typing,
and focus changes in the background. Distills raw events into a "personal
portrait" (personality / portrait / writing-style). Feeds that portrait into an
LLM so the AI actually knows who you are. All data stays on your machine.

> Status: WIP, not released. `Capture/` is still in P0 stub stage — calls flash
> a red dot in the status bar. See `BEFORE_SHARING.md` for things that must be
> fixed before any release.

---

## Install

1. Grab the latest **`MyPortrait-x.x.x.dmg`** from [Releases](https://github.com/joyzhang14-14/My-Portrait/releases).
2. **Before opening the `.dmg`**, strip Gatekeeper's quarantine flag from it in Terminal:

   ```bash
   xattr -d com.apple.quarantine ~/Downloads/MyPortrait-*.dmg
   ```

3. Open the `.dmg`, drag **My Portrait** into **Applications**, launch normally.

> **Alternative (no Terminal)**: If you skip step 2 and just double-click the app, macOS will refuse with "can't verify the developer". Open **System Settings → Privacy & Security**, scroll down to "MyPortrait was blocked", click **Open Anyway**.

Why any of this is needed: Apple charges $99/year for notarization, and I'm not paying. The app is still **signed** (Apple Development cert) and runs with **hardened runtime + entitlements** — same security posture as a notarized build, just without Apple's seal of approval. Auto-updates via Sparkle work as expected once you're past the first launch.

> Requires macOS 15+ on Apple Silicon (M1 / M2 / M3 / M4).

---

## Inspired by [screenpipe](https://github.com/screenpipe/screenpipe)

My-Portrait owes its architecture and philosophy to **[screenpipe](https://github.com/screenpipe/screenpipe)**
by mediar-ai. screenpipe pioneered the "24/7 local-first context layer" idea
and proved the engineering pattern — continuous screen + audio capture, on-device
OCR / transcription, an FTS-indexed SQLite store, and LLM integrations on top.

Key things borrowed:

- **Capture pipeline shape** — frame comparer → snapshot writer → async OCR →
  event stream, mirrors screenpipe's Rust pipeline
- **Storage model** — SQLite + WAL + FTS5 for full-text search across frames,
  transcripts, and UI events (screenpipe uses SQLx, we use GRDB)
- **Two-stage frame storage** — JPG hot tier → background MP4 compaction
- **Ignored-apps / system-privacy defaults** — `IgnoredAppPicker`'s system
  entry list is taken straight from screenpipe's default ignore list
- **The whole "your data is yours" stance** — everything local, no cloud
  required, user owns the database file

If you want a mature, cross-platform, well-tested version of this idea, use
screenpipe. My-Portrait is a Swift-native take focused on macOS + personal
portrait distillation, optimized for one user (me).

---

## Run it

**Prerequisites:** macOS 15+, Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate          # generates .xcodeproj from project.yml
./build-app.sh --run       # builds + launches the .app standalone
```

⚠️ **Must launch standalone** (not Xcode's ⌘R). When the app runs under the
Xcode debugger, macOS TCC attributes screen-recording / microphone permission
prompts to Xcode itself — My-Portrait never gets authorized.
`build-app.sh` handles this correctly.

Day-to-day, ⌘B in Xcode is fine for compile checks; just use `./build-app.sh --run`
when you actually need Capture to work.

### After adding / removing / renaming a `.swift` file

```bash
xcodegen generate
```

SwiftPM auto-scans `Sources/`, but `.xcodeproj` carries a static file list —
without regenerating, Xcode builds fail with `Cannot find 'Xxx' in scope`.

---

## Configuration

User config lives at `~/.portrait/config.toml` (template:
`docs/config.example.toml`). The UI and direct file edits are equivalent — both
sync.

Data locations:

- `~/.portrait/` — config, cron jobs, portraits, conversations
- `~/Library/Application Support/MyPortrait/` — secrets, caches, DB
- `~/.screenpipe/` — **read-only reuse** (copy from, never `mv`)

---

## Code map

```
Sources/MyPortrait/
├── Capture/      Screen / audio / typing / focus capture (perf-first, mirrors screenpipe)
├── Memory/       Event → portrait distillation (personality, portrait, Tier1 merge, impression EMA)
├── AI/           Multi-provider chat, cron scheduling, agents, PII redaction, OAuth, SMTP
├── DB/           GRDB + SQLite + WAL + FTS5
├── Settings/     Settings panes + TOML config read/write
├── Typing/       Typing capture & replay
├── Notifications/ Notifications / push
├── DesignSystem.swift   Glass + blue-gradient theme tokens
├── ContentView.swift    Main window (sidebar + main pane)
├── HomeView.swift / TimelineView.swift / ConnectionsView.swift / ...
└── App.swift            Entry point
```

Most subdirectories carry their own `README.md` with deeper detail (e.g.
`Capture/README.md` has the full call graph).

---

## Tech stack

| Purpose | Dependency |
|---|---|
| SQLite ORM (persistence) | [GRDB.swift](https://github.com/groue/GRDB.swift) |
| On-device speech-to-text | [WhisperKit](https://github.com/argmaxinc/WhisperKit) |
| On-device LLM / embeddings | [mlx-swift](https://github.com/ml-explore/mlx-swift) + [mlx-embeddings](https://github.com/mzbac/mlx.embeddings) |
| Speaker diarization (pyannote + wespeaker) | [onnxruntime](https://github.com/microsoft/onnxruntime-swift-package-manager) |
| TOML config | [TOMLKit](https://github.com/LebJe/TOMLKit) |
| Tokenizer | [swift-transformers](https://github.com/huggingface/swift-transformers) |

UI: SwiftUI + `.ultraThinMaterial` (glass) + `.symbolEffect(.bounce)` (icon
animations).

---

## Dual build system

| | Used for | Entry point |
|---|---|---|
| **SwiftPM** | `swift build` / CI / compile checks | `Package.swift` |
| **Xcode** | Real signed `.app`, TCC, daily use | `MyPortrait.xcodeproj` (generated from `project.yml` by XcodeGen — do not edit by hand) |

Same source, both build. The one gotcha: `.xcodeproj` doesn't auto-detect
filesystem changes — adding, removing, or renaming any `.swift` requires
`xcodegen generate`.

---

## Credits

- **[screenpipe](https://github.com/screenpipe/screenpipe)** (MIT) — architecture,
  capture pipeline shape, FTS storage model, "your data is yours" stance, and
  the default system-app ignore list (see `IgnoredAppPicker.systemEntries`).
  This project would not exist without it. Go star it.
- All the upstream libraries listed under [Tech stack](#tech-stack) — especially
  WhisperKit, MLX-Swift, and GRDB, which make on-device AI on macOS practical.
