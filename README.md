<div align="center">
  <img src=".github/icon.png" alt="My Portrait" width="128" height="128" />

  <h1>My Portrait</h1>

  <p><b>A long-term digital portrait of you, built on your Mac.</b></p>

  <p>It quietly captures your screen, voice, and writing, and over months and years distills them into a portrait of you — what you do, who you spend time with, how you think and write. <b>Everything stays on your Mac.</b></p>

  <a href="https://github.com/joyzhang14-14/My-Portrait/releases/latest">
    <img src="https://img.shields.io/github/v/release/joyzhang14-14/My-Portrait?label=download&style=flat-square" alt="latest release" />
  </a>
</div>

---

## How it works

```mermaid
flowchart TB
  subgraph CAP["Capture"]
    A1["Screenshots on interaction events"] --> B1["OCR"]
    A2["Mic + system audio"] --> B2["Transcribe + diarize"]
    A3["Keystrokes / AX"]
    A1 --> TL["Timeline"]

    TL --> MT[("~/.portrait<br/>Capture DB")]
    B1 --> MT
    B2 --> MT
    A3 --> MT
  end

  subgraph UND["Understanding"]
    S["Session records<br/>local 9B model"] --> E["Events<br/>in development"]
    E --> P["Portrait<br/>being rebuilt"]
  end

  MT --> S

  style CAP fill:#f9731626,stroke:#f97316,stroke-width:2px
  style UND fill:#3b82f626,stroke:#3b82f6,stroke-width:2px
  style E stroke-dasharray:4 3
  style P stroke-dasharray:4 3
```

## The Neural Graph

As My Portrait keeps running, the events it finds grow into a graph that belongs only to you.

<div align="center">
  <img src=".github/media/event-graph.gif" alt="The event graph changing over time" width="100%" /><br/>
  <sub>The event graph, played back over time.</sub>
</div>

## Install

1. Download the `.dmg` from [the latest release](https://github.com/joyzhang14-14/My-Portrait/releases/latest).
2. The app is self-signed, so Gatekeeper will block it. Pick one:

   **Option A — strip quarantine (no prompts):**

   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/MyPortrait_*.dmg
   ```

   Open the DMG, drag **My Portrait** into `Applications` — first launch just works.

   **Option B — approve once:**
   Open the DMG, drag into `Applications`, then **right-click the app → Open → Open** in the warning dialog.

> **Requires an Apple silicon Mac with 16 GB of memory, on macOS 15 or later.** Updates ship automatically via [Sparkle](https://sparkle-project.org).

## Where it's going

**The capture system is fully local.** Screen OCR, audio transcription and speaker diarization all run on your Mac. Keystrokes / AX (macOS accessibility APIs — what you actually typed) never leave it either.

**Session understanding is local too.** A Qwen3.5-9B vision-language model, distilled and quantized to 4 bits, turns each working session into a structured record on your Mac while it is charging and idle.

**Two layers are still in progress:** merging sessions into events across days (research code in [`research/event-merge`](research/event-merge)), and the portrait, which is being rebuilt. Until they run locally, these call a cloud LLM with your own API key.

## Our Goal

The goal is a digital portrait that keeps growing with you for years, built with **no cloud API at all** — your data **never** leaves your device: every step, end to end, on an Apple silicon Mac with 16 GB of memory. Work in progress toward that:

- local models sized to fit 16 GB alongside everything else that's running;
- telling apart what was merely _on screen_ from what you were actually _doing_;
- keeping the portrait anchored to real evidence instead of inventing the missing parts.

## Acknowledgements

My Portrait's screen capture, audio capture, and timeline all draw on the approach worked out by **[screenpipe](https://github.com/mediar-ai/screenpipe)** — how to record continuously in the background without getting in the way, and how to turn a day of raw activity into something you can scroll back through. Huge thanks to Louis Beaumont and the mediar-ai team for working that out in the open — go take a look at what they're building.

## Credits

- **[screenpipe](https://github.com/mediar-ai/screenpipe)** — screen capture, audio capture, and timeline approach.
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** · **[Qwen3-ASR](https://github.com/ivan-digital/qwen3-asr-swift)** · **[mlx-swift](https://github.com/ml-explore/mlx-swift)** · **[GRDB](https://github.com/groue/GRDB.swift)** — on-device AI on macOS, made practical.

---

<div align="center">
  <sub>Building from source or contributing? See <a href="DEVELOPER.md">DEVELOPER.md</a>.</sub>
</div>
