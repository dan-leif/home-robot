# home-robot

A local voice assistant built on Home Assistant, replacing Google/Nest Gemini
with a fully self-hosted stack running on a Windows laptop. The key design
goal: brief answers, **never asks follow-up questions**.

## Status

**Step 1 (typed input) ✅ and Step 2 (voice) ✅ are done.**
You can speak to it and it answers out loud via a high-quality local TTS voice.

Next: Step 3 (Chinese / Mandarin), then web search, music, and eventually
moving to a dedicated always-on device.

## Architecture

```
[You] ──► Home Assistant Assist pipeline (VM: homeassistant.local:8123)
              │
              ├─ STT: faster-whisper (HA add-on, port 10300)
              ├─ LLM: Ollama on Windows host (llama3.1:8b, port 11434)
              └─ TTS: Kokoro af_sky Wyoming server on Windows host (port 10200)
```

Everything runs locally. No paid APIs.

**Host machine:** Lenovo Legion Slim 5 — Ryzen 7 7840HS, 16 GB RAM,
RTX 4060 8 GB (Ollama runs 100% on GPU, ~47 tok/s).

**HA VM:** VirtualBox 7.2.x, HA OS 18.0, 4 GB RAM, 4 CPUs, bridged networking.

## Getting started

### Prerequisites

- [VirtualBox](https://www.virtualbox.org/) 7.2+
- [Ollama](https://ollama.com/) with `OLLAMA_HOST=0.0.0.0` set as a user env var
- Python 3.12 with `pip install kokoro-onnx wyoming soundfile numpy`
- HA OS 18.0 VDI (not in this repo — download from
  [Home Assistant](https://www.home-assistant.io/installation/windows))
- Kokoro model files (not in this repo — download `kokoro-v1.0.onnx` and
  `voices-v1.0.bin` from the
  [kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0)
  and place them in `kokoro/`)

### Starting the stack

Double-click **`Start Robot.cmd`** (or run `start-robot.ps1` in PowerShell).

This starts Ollama, Kokoro TTS, and the HA VM (skipping anything already
running), waits for HA to come online, then opens it in your browser.

### Kokoro TTS server

`kokoro/kokoro_wyoming.py` is a minimal
[Wyoming Protocol](https://github.com/rhasspy/wyoming) TTS server that wraps
[kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx). It serves the
`af_sky` (US English female) voice on `tcp://0.0.0.0:10200` at 24 kHz mono
16-bit PCM.

Start it via `kokoro/run_kokoro.ps1` (also called automatically by
`Start Robot.cmd`). Requires the two model files in `kokoro/` (see above).

## Roadmap

1. ~~Typed input to local LLM~~ ✅
2. ~~Voice (wake word / STT / TTS)~~ ✅
3. Chinese (Mandarin) — Qwen model + Whisper zh + Chinese TTS voice
4. Live web search
5. Music
6. Move to a dedicated always-on device (mini PC or Raspberry Pi)
