<div align="center">
  <img src=".github/icon.png" alt="My Portrait" width="128" height="128" />

  <h1>My Portrait</h1>

  <p><b>A long-term digital portrait of you, built on your Mac.</b></p>

  <p>It quietly captures your screen, voice, and keystrokes, and over months and years distills them into a portrait of you — what you work on, who you spend time with, what you can do, and how you decide. <b>Everything stays on your Mac.</b></p>

  <a href="https://github.com/joyzhang14-14/My-Portrait/releases/latest">
    <img src="https://img.shields.io/github/v/release/joyzhang14-14/My-Portrait?label=download&style=flat-square" alt="latest release" />
  </a>
</div>

---

## How it works

```mermaid
flowchart TB
  subgraph CAP["1 · Capture · on your Mac"]
    direction LR
    subgraph SCR["Screen"]
      T["Triggers<br/>app switch, click, Return,<br/>typing burst, scroll stop"] --> PG["Privacy gates<br/>password fields,<br/>private windows"] --> DD["Dedup<br/>hash + histogram"] --> OCR["Apple Vision OCR<br/>Chinese + English"]
    end
    subgraph AUD["Audio"]
      M["Mic + system audio"] --> VAD["Silero VAD"] --> ASR["Qwen3-ASR / Whisper"] --> DZ["Diarization<br/>pyannote + CAM++"]
    end
    subgraph KB["Typing"]
      K["Keystrokes<br/>listen-only event tap,<br/>input-method text kept"] --> SD["Send detection<br/>bare Return + input box cleared<br/>→ a sent message"]
      AX["AX text capture<br/>focused text field,<br/>diffed per field"] --> SD
    end
    OCR --> DB[("~/.portrait<br/>capture DB")]
    DZ --> DB
    SD --> DB
  end

  subgraph ES["2 · EventSession · local"]
    direction RL
    SP["Sessions by window identity<br/>+ frame selection"] --> OBS["Per-frame observation<br/>Qwen3.5-9B VLM, QAD 4-bit"] --> SR["Session record<br/>what was done, with whom,<br/>outcome"]
  end

  subgraph EM["3 · Events · in development"]
    direction LR
    R1["EmbeddingGemma recall<br/>top 4 + latest"] --> Q1["Narrow questions<br/>anything done?<br/>same event?"] --> W1["One narrative<br/>per event"] --> LIB["Cross-day library<br/>vectors + tags<br/>+ last 48 h"]
  end

  subgraph PT["4 · Portrait · being rebuilt"]
    direction RL
    R2["Recall<br/>vectors + BM25<br/>+ title overlap"] --> Q2["Narrow questions<br/>evidence?<br/>counter-example?"] --> W2["Entries: title, detail,<br/>evidence IDs"]
  end

  CAP --> ES --> EM --> PT -.-> AG(["Proactive agent · the goal"])

  style CAP fill:#f9731626,stroke:#f97316,stroke-width:2px
  style ES fill:#3b82f626,stroke:#3b82f6,stroke-width:2px
  style EM fill:#3b82f614,stroke:#3b82f6,stroke-width:2px,stroke-dasharray:5 4
  style PT fill:#3b82f614,stroke:#3b82f6,stroke-width:2px,stroke-dasharray:5 4
  style AG fill:#a855f714,stroke:#a855f7,stroke-dasharray:5 4
```

Solid boxes run in the app today; dashed boxes are in development.

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

The goal is a **proactive agent** that knows you well enough to act for you: it suggests, plans and does things in the way you would. It stands on a digital portrait that keeps growing with you for years, built with **no cloud API at all** — your data **never** leaves your device: every step, end to end, on an Apple silicon Mac with 16 GB of memory. Work in progress toward that:

- local models sized to fit 16 GB alongside everything else that's running (the session layer already runs this way);
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
