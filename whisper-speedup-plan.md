# Plan: Get Whisper (STT) under 1 second

## Context

Speech-to-text is the only slow stage in the voice assistant. Measured in HA's
pipeline debug, `stt.faster_whisper` takes ~3.4–3.8s while the LLM and TTS are
fast. Root cause: the Whisper add-on runs **inside the VirtualBox VM on the CPU**
(VirtualBox can't pass through the RTX 4060), whereas Ollama and Kokoro run on the
Windows host and use the GPU. The goal is to get STT **under 1 second** (faster if
possible) and, as a bonus, characterize how transcription **quality** degrades as
the model gets smaller.

Approach the user approved: (1) baseline the current in-VM add-on, (2) tweak its
HA settings and re-measure, (3) stand up a GPU-accelerated faster-whisper on the
host and compare, (4) measure the quality/speed drop-off across model sizes.

**User decisions for this run:**
- **Test audio = Kokoro-generated** (synthesize known sentences locally → perfect
  reference text, fully repeatable; accuracy is slightly optimistic vs a real mic
  but model-vs-model comparison is valid).
- **End goal = benchmark + recommend only.** Do NOT change the live STT engine.
  Produce a results table + recommendation. Wiring the winner into HA (and its one
  admin firewall step) is explicitly deferred to a later session.

## Verified preconditions (checked read-only during planning)

- GPU: RTX 4060 Laptop, 8 GB, driver 576.80, CUDA 12.9.
- Python 3.12.10 at `C:\Users\Dev\AppData\Local\Programs\Python\Python312\python.exe`;
  already has `wyoming` 1.9.0, `kokoro-onnx` 0.5.0, `soundfile`, `numpy`.
- Chrome extension connected (deviceId `5bab8aac-…`) → the agent can drive the HA web UI.
- **In-VM Whisper port 10300 is NOT reachable from the host** (HA keeps the add-on
  on its internal Docker network). Benchmarking the real add-on therefore requires
  temporarily publishing that port — see Phase 1. Reverted in Phase 5.
- Host service map: Ollama 11434, Kokoro 10200, HA/VM at `192.168.1.188` (host
  `192.168.1.187`). New host GPU Whisper will use port **10301** (localhost only).

## Prerequisite to running this (the user runs "Start Robot" first)

HA + the Whisper add-on must be up for Phases 1–2 (double-click **Start Robot**).
Kokoro's *running server* is NOT needed — audio generation loads `kokoro-onnx`
directly from the model files in `kokoro/`.

---

## Phase 0 — Scaffolding (host, fully autonomous)

Create a self-contained `whisper-bench/` folder (mirrors the `kokoro/` pattern).

1. **Install packages** into the Python 3.12 above:
   `faster-whisper` (pulls `ctranslate2`), `wyoming-faster-whisper`, `jiwer`
   (WER/CER scoring), `soxr` (clean 24k→16k resample), and the CUDA runtime wheels
   `nvidia-cublas-cu12` + `nvidia-cudnn-cu12` (CTranslate2 GPU needs cuDNN 9).
2. **`whisper-bench/gen_test_audio.py`** — uses `kokoro-onnx` (af_sky) to synthesize
   a fixed sentence set to **16 kHz mono 16-bit WAV** (Wyoming ASR format), writing
   `audio/*.wav` + `references.json` (filename → exact text). Sentence set mixes:
   - the user's real examples (the 20-country list; the hen story),
   - hard proper nouns (Burkina Faso, Eritrea, Kazakhstan…),
   - numbers/times/money ("$3.50", "7:30", "the year 2026"),
   - a couple of short everyday commands.
3. **`whisper-bench/bench.py`** — reusable Wyoming STT client. Args: `--uri`,
   `--runs N`. For each WAV: connect, send `Transcribe`→`AudioStart`→`AudioChunk`s
   →`AudioStop`, await `Transcript`. Records **latency = AudioStop-sent →
   Transcript-received** (matches HA's `stt` stage) plus the wall-clock total.
   Reports the **first (cold) run separately** from the median of warm runs, and
   computes **WER + CER** (jiwer) against `references.json`. Writes a per-config
   row to `results/results.csv` and prints a summary.
4. **`whisper-bench/run_whisper_gpu.ps1`** — launcher mirroring `kokoro/run_kokoro.ps1`:
   starts `python -m wyoming_faster_whisper --uri tcp://0.0.0.0:10301 --device cuda`
   with params (`--model`, `--beam-size`, `--compute-type`, `--data-dir`). Prepends
   the `nvidia/*/bin` DLL dirs to PATH so CTranslate2 finds cuDNN/cuBLAS.

Sanity gate: run `bench.py` once against the host GPU server with `--model tiny`
to confirm the GPU path works before the full sweep.

---

## Phase 1 — Baseline: the in-VM add-on as-is (drive HA UI via Chrome)

1. Via the Chrome extension: confirm Whisper add-on settings are the known-good
   baseline (`model=base`, `stt_library=auto`, `custom_model_type=faster-whisper`,
   `language=en`, `beam_size=0`).
2. In the add-on's **Configuration → Network** section, **publish container port
   10300** to a host port, Save, restart the add-on. Confirm `192.168.1.188:10300`
   is now reachable from the host.
3. Run `bench.py --uri tcp://192.168.1.188:10300 --runs 6`. Capture the **cold**
   first-call number and the **warm** median. This is the number to beat (~3.5s).

---

## Phase 2 — In-VM tweak sweep (CPU; HA UI + re-bench each)

For each config: change settings via Chrome → restart add-on → `bench.py`. Record
latency (cold/warm) + WER/CER. Configs (one variable at a time):

| Model | Beam | Purpose |
|-------|------|---------|
| base | 0 | baseline (Phase 1) |
| base | 1 | beam-size lever alone |
| base-int8 | 1 | quantization + beam |
| tiny-int8 | 1 | smallest/fastest CPU |
| small-int8 | 1 | accuracy ceiling on CPU (likely too slow) |

(Note `distil-small.en` etc. are English-only — excluded because Chinese is a
planned future step; multilingual models only.)

Expected finding: CPU tweaks help but realistically land ~1.5–2.5s — i.e. they
probably can't reach the <1s goal alone. That motivates Phase 3.

---

## Phase 3 — Host GPU sweep (the real fix; localhost only)

Run `run_whisper_gpu.ps1` per config → `bench.py --uri tcp://127.0.0.1:10301`.
This is the **same faster-whisper library** as the add-on, just on the GPU, so it's
an apples-to-apples comparison. Sweep:

| Model | Compute | Beam | Notes |
|-------|---------|------|-------|
| tiny | float16 | 1/5 | speed floor |
| base | float16 | 1/5 | |
| small | float16 | 1/5 | likely the sweet spot |
| medium | float16 | 1/5 | |
| large-v3 | float16 | 1/5 | quality ceiling; check if still <1s |

Goal: identify the **largest/most-accurate model that still transcribes the test
set in under 1s** on the 4060. (Short utterances on a 4060 are typically
~0.1–0.5s even for medium/large, so the constraint is likely accuracy-driven, not
speed-driven.)

---

## Phase 4 — Quality drop-off analysis

From the Phase 2+3 rows, produce a single table sorted by latency showing
**WER and CER per model size**, so the accuracy cost of going smaller is explicit.
Call out where proper nouns / numbers start breaking (CER on the hard sentences is
the sensitive signal). This directly answers the "how does quality drop off" ask.

---

## Phase 5 — Report, recommend, and RESTORE live setup

1. **Restore HA to baseline**: set the add-on back to `model=base`, `beam_size=0`,
   **un-publish port 10300** (revert the Network change), restart, confirm healthy
   and that the live "Robot" pipeline still uses the in-VM add-on unchanged.
2. **Stop** the host GPU Whisper test server (it was only for measuring). Leave the
   `whisper-bench/` scripts + venv in place for the future wire-in.
3. Write **`whisper-bench/RESULTS.md`**: the full table (latency cold/warm, WER,
   CER per config) + a plain-English recommendation. Expected recommendation: a
   **host GPU faster-whisper** (likely `small` or `medium` float16) gets STT well
   under 1s with accuracy ≥ the current `base`; note the deferred wire-in steps it
   would need (firewall rule for VM→host:10301, then HA Wyoming integration +
   pipeline STT swap — an admin step, left for a later session per this run's scope).
4. Update `CLAUDE.md` + `memory/project-state.md` with the outcome.

## Files created (none of the live config is modified permanently)

- `whisper-bench/gen_test_audio.py`, `bench.py`, `run_whisper_gpu.ps1`
- `whisper-bench/audio/*.wav`, `references.json`, `results/results.csv`, `RESULTS.md`
- Edits: `CLAUDE.md`, `memory/project-state.md` (status notes only)

## Verification

- Phase 0 gate: `bench.py` returns a correct transcript from the GPU `tiny` server.
- Each phase: `results.csv` gains rows with non-empty transcripts + sane timings.
- End state: HA add-on back on `base`/beam `0`, port 10300 un-published, add-on
  "Running" and RAM > 0; the live Robot pipeline behaves exactly as before this run.

## Risks / notes

- **cuDNN on Windows** is the main setup risk for GPU CTranslate2. Mitigation: the
  `nvidia-cudnn-cu12`/`nvidia-cublas-cu12` wheels + adding their `bin` to PATH in the
  launcher. Fallback if GPU won't init: report CPU-host int8 numbers and flag the
  cuDNN issue rather than blocking.
- Kokoro TTS audio is cleaner than a real mic → absolute WER is optimistic. The
  ranking across models is still valid; a real-clip reality check can be added later
  (user chose Kokoro-only for now).
- All HA UI changes are reversible and explicitly restored in Phase 5; nothing here
  changes the live STT engine.

---

## Notes for the executing agent (context this plan assumes)

- **Stack control:** "Start Robot" / "Stop Robot" desktop shortcuts run
  `start-robot.ps1` / `stop-robot.ps1` (Ollama 11434 → Kokoro 10200 → HA VM). The VM
  is VirtualBox "HomeAssistant"; never hard power-off (it has corrupted the FS before
  — use ACPI shutdown only).
- **HA web UI** is at `http://homeassistant.local:8123` (fallback `http://192.168.1.188:8123`).
  Drive it with the connected Claude-in-Chrome extension. The Whisper add-on page is
  `config/app/core_whisper/config` (Configuration) and `.../logs` (Log).
- **Kokoro template:** `kokoro/kokoro_wyoming.py` + `kokoro/run_kokoro.ps1` show the
  established native-Windows Wyoming-server pattern to mirror for the GPU launcher.
- **Known-good Whisper baseline to restore to:** model `base`, stt_library `auto`,
  custom_model_type `faster-whisper`, language `en`, beam_size `0`.
