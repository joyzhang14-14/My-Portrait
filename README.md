<div align="center">
  <img src=".github/icon.png" alt="My Portrait" width="128" height="128" />

  <h1>My Portrait</h1>

  <p>A local-first AI memory system for macOS. It watches what you do, hears what you say, reads what you write — and builds a long-term portrait that, over time, becomes a digital version of you. <b>Everything stays on your Mac.</b></p>

  <a href="https://github.com/joyzhang14-14/My-Portrait/releases/latest">
    <img src="https://img.shields.io/github/v/release/joyzhang14-14/My-Portrait?label=download&style=flat-square" alt="latest release" />
  </a>
</div>

---

## What it does

- **Captures your day** — screen (OCR), microphone + system audio, and what you type, continuously in the background.
- **Transcribes on-device** — Whisper or Qwen3-ASR with speaker diarization. No audio ever leaves your Mac.
- **Builds a portrait** — distills it all into an evolving picture of who you are: personality, habits, writing style.
- **Chat with your memory** — ask across everything you've seen, said, and written, using your own LLM keys.
- **Yours, locally** — one SQLite file under `~/.portrait/`. No cloud, no account.

## Install

1. Download `MyPortrait-X.Y.Z.dmg` from [the latest release](https://github.com/joyzhang14-14/My-Portrait/releases/latest).
2. The app is self-signed, so Gatekeeper will block it. Pick one:

   **Option A — strip quarantine (no prompts):**
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/MyPortrait-*.dmg
   ```
   Open the DMG, drag **My Portrait** into `Applications` — first launch just works.

   **Option B — approve once:**
   Open the DMG, drag into `Applications`, then **right-click the app → Open → Open** in the warning dialog.

> Requires macOS 15+ on Apple Silicon (M). Updates ship automatically via [Sparkle](https://sparkle-project.org).

## Configuration

Tune everything in the app's Settings, or edit `~/.portrait/config.toml` directly — the two stay in sync. All your data lives under `~/.portrait/`.

## Inspired by screenpipe

My Portrait owes its architecture and "your data is yours" philosophy to **[screenpipe](https://github.com/screenpipe/screenpipe)** by mediar-ai — the 24/7 local-first context layer, the capture-pipeline shape, the FTS-indexed SQLite store, and the default app-ignore list. If you want a mature, cross-platform take on the idea, use screenpipe. Go star it.

## Credits

- **[screenpipe](https://github.com/screenpipe/screenpipe)** (MIT) — the foundation this is built on.
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** · **[Qwen3-ASR](https://github.com/ivan-digital/qwen3-asr-swift)** · **[mlx-swift](https://github.com/ml-explore/mlx-swift)** · **[GRDB](https://github.com/groue/GRDB.swift)** — on-device AI on macOS, made practical.

---

<div align="center">
  <sub>Building from source or contributing? See <a href="DEVELOPER.md">DEVELOPER.md</a>.</sub>
</div>
