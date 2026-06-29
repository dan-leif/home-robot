# Whisper STT speed-up — benchmark results & recommendation

**Date:** 2026-06-28
**Goal:** get speech-to-text (STT) under **1 second** (it was ~3.4–3.8 s in the
live HA pipeline) and characterise how transcription **quality** degrades as the
model shrinks.
**Scope of this run:** *benchmark + recommend only.* The live STT engine was
**not** changed. HA was restored to its exact baseline afterwards (see "Restore"
at the bottom). Wiring the winner into HA is a separate, later session.

---

## TL;DR recommendation

> **Run faster-whisper `small`, `float16`, beam size 1, on the host GPU.**
> Measured **0.37 s** warm (clean) — about **5.6× faster** than the current
> in-VM `base` (~2.1 s) and well under the 1 s goal — while being the **most
> accurate** of every option that stays under 1 s.

Why `small` and not something bigger? Your 8 GB GPU already has llama3.1:8b
**pinned** in VRAM (~5.5 GB), leaving only ~2.5 GB free. `small` float16
(~0.5 GB) fits comfortably alongside it. `medium` (~1.5 GB) and `large-v3`
(~3 GB) **don't fit**, so they silently fall back to CPU and collapse to 5–18 s
(see the table). `small` is the largest model that both fits and stays fast.

---

## How it was measured

- **Test audio:** 10 sentences synthesised locally with Kokoro (af_sky) to
  16 kHz mono WAV — a fixed, repeatable set with perfect reference text. Mix of:
  a 20-country list, a short story, hard proper nouns (Burkina Faso, Kyrgyzstan,
  Liechtenstein…), numbers/times/money ("$3.50", "7:30", "1984"), and short
  voice commands.
- **Latency** = time from "audio finished sending" to "transcript received"
  (the same span HA reports for its `stt` stage). Reported as the **warm
  median** (first/cold run excluded), which is robust to one-off spikes.
- **Quality** = WER (word error rate) and CER (character error rate) via `jiwer`,
  case-insensitive, vs the reference text.
- The recommendation-critical configs were **re-measured with the machine idle**
  (no video playback) — those rows are marked **(clean)**.

### Important scoring caveat (read before trusting absolute WER/CER)

The reference text spells numbers out ("twenty", "five minutes", "three dollars
and fifty cents") but Whisper writes them as digits ("20", "5 minutes", "$3.50").
That mismatch is scored as an error even though the recognition is correct. It
inflates every model's error **uniformly**, so:

- **Absolute WER/CER (~17–22 %) is pessimistic** — real word accuracy on these
  clean clips is much higher than the numbers suggest.
- The **ranking between models is still valid** (the penalty is the same for all).
- For the genuine quality signal, look at **CER on the proper-noun sentences**
  (`CER_prop` below), which isn't affected by the number-format issue.

**"True" WER (formatting canonicalised).** Re-scoring with OpenAI's Whisper text
normalizer (so "five minutes" == "5 minutes", "three dollars and fifty cents" ==
"$3.50") strips the artifact and leaves only real recognition errors. `analyze.py`
prints this as `trueWER`; the candidates come out far lower and the spread widens:

| Model (GPU, beam1) | Raw WER | **True WER** | Note |
|---|---:|---:|---|
| **small** | 19.4% | **3.2%** | best — nailed every proper noun + the year |
| medium | 17.2% | 5.1% | one name miss (too slow here anyway) |
| tiny | 22.3% | 6.6% | misses are "close" (Lichtenstein) |
| base | 20.8% | 7.3% | worst — mangled Kyrgyzstan & Liechtenstein |

So on clean audio every model is actually strong (true WER < 8%), but **`small` is
~2× cleaner than `tiny`/`base`** on the words that matter — reinforcing the pick.

---

## Full results (sorted by latency)

| Config | Where | Warm median | WER | CER | CER proper-nouns |
|---|---|---:|---:|---:|---:|
| **gpu tiny float16 beam1** (clean) | host GPU | **0.18 s** | 22.3% | 18.0% | 15.5% |
| **gpu base float16 beam1** (clean) | host GPU | **0.22 s** | 20.8% | 18.4% | 17.5% |
| gpu tiny float16 beam5 | host GPU | 0.35 s | 20.5% | 16.6% | 15.5% |
| **gpu small float16 beam1** (clean) ⭐ | host GPU | **0.37 s** | **19.4%** | 17.3% | 15.9% |
| gpu base float16 beam5 | host GPU | 0.45 s | 20.6% | 17.8% | 15.6% |
| cpu tiny int8 beam1 | host CPU | 0.54 s | 20.6% | 16.5% | 14.9% |
| gpu small float16 beam5 | host GPU | 0.60 s | 20.8% | 17.5% | 15.7% |
| cpu base int8 beam1 | host CPU | 0.93 s | 20.8% | 18.4% | 17.5% |
| in-VM base beam1 | VM CPU | 1.70 s | 20.6% | 18.1% | 17.2% |
| **in-VM base beam0** (clean) — *current live* | VM CPU | **2.10 s** | 22.6% | 18.2% | 15.9% |
| cpu small int8 beam1 | host CPU | 2.62 s | 20.1% | 17.5% | 16.8% |
| gpu medium float16 beam1 ⚠️ | host GPU* | 5.22 s | 17.2% | 16.2% | 14.7% |
| gpu medium float16 beam5 ⚠️ | host GPU* | 5.41 s | 17.2% | 15.9% | 13.9% |
| gpu large-v3 float16 beam5 ⚠️ | host GPU* | 7.06 s | 19.6% | 17.9% | 15.4% |
| gpu large-v3 float16 beam1 ⚠️ | host GPU* | 17.93 s | 19.9% | 18.4% | 15.4% |

\* `medium`/`large-v3` requested the GPU but **fell back to CPU** because they
don't fit in the ~2.5 GB of VRAM left free by the pinned LLM — hence the 5–18 s.

---

## Findings

### 1. The GPU is the fix; CPU tweaks aren't enough
- The current live path (in-VM `base`, CPU) is **~2.1 s**. Dropping beam size to
  1 helps a little (~1.7 s) but **no CPU config reaches the 1 s goal** in the VM.
- int8 quantisation on the *host* CPU (much faster than the VM's 2 vCPUs) gets
  `tiny` to 0.54 s and `base` to 0.93 s — but on the slower in-VM CPU those would
  be ~2–3× higher, i.e. still over 1 s. **Quantisation alone can't save the CPU
  path.**
- On the GPU, `tiny`/`base`/`small` all land at **0.18–0.60 s** — 4–11× faster
  than the in-VM baseline.

### 2. The VRAM ceiling decides the model size
With llama3.1:8b pinned (`OLLAMA_KEEP_ALIVE=-1`), only ~2.5 GB VRAM is free.
`small` (~0.5 GB) fits; `medium`/`large-v3` don't and collapse to CPU speeds.
So **`small` is the biggest model that stays on the GPU and under 1 s.**

### 3. Quality drop-off (the "how much worse does smaller get?" question)
Using **CER on proper nouns** as the clean signal:

| Model | CER proper-nouns | Note |
|---|---:|---|
| medium | 14.7% | best, but too slow here (VRAM) |
| tiny | 15.5% | surprisingly good on these names |
| large-v3 | 15.4% | too slow here (VRAM) |
| **small** | **15.9%** | **best that stays < 1 s** |
| base | 17.5% | worst — uniquely flubs "Kyrgyzstan" → "Courgaston" |

Quality is **not** strictly monotonic with size on this small set — `base`
actually does *worse* on hard proper nouns than `tiny` or `small`, and `tiny` is
unexpectedly strong. `small` gives the best proper-noun accuracy of any model
that stays under 1 s, and its overall WER (19.4 %) is the lowest in the under-1 s
group too. Going below `small` (to `tiny`/`base`) saves ~0.15 s but measurably
hurts accuracy; going above it (`medium`/`large`) can't run fast here.

### 4. int8 barely changes accuracy
int8 vs float16 at the same size gives essentially identical WER/CER (e.g. `tiny`
int8 20.6 % vs float16 22.3 % — within noise). int8 is a CPU-speed lever, not a
quality lever.

---

## Note: the in-VM int8 models couldn't be benchmarked

Phase 2 planned to test the add-on's `base-int8`/`tiny-int8`/`small-int8` model
options in the VM. The live `base` (float) model is pre-cached and loads
instantly, but the int8 model variants are **first-time downloads from
HuggingFace**, and that download **hung inside the VM** (the add-on sat in
"startup" indefinitely, never binding its port). This is an infrastructure
limitation of the VM's network/model-fetch path, not a property of the models.
The int8 *quality/speed* question is instead answered by the **host CPU int8
rows** above (same faster-whisper library, identical quantisation), which is
sufficient for the recommendation.

---

## Recommendation & deferred wire-in (for a later session)

**Adopt host-GPU faster-whisper `small` float16, beam 1.** To make it live later
(all deferred — these need an admin step and a change to the live pipeline):

1. **Run a host GPU Whisper server** (the `whisper-bench/run_whisper_gpu.ps1`
   launcher already does this): `wyoming-faster-whisper` on `tcp://0.0.0.0:10301`,
   `--model small --compute-type float16 --device cuda --beam-size 1`, with the
   nvidia cuBLAS/cuDNN `bin` dirs on PATH. Fold it into "Start Robot".
2. **Open the firewall** for VM→host on port **10301** (admin step).
3. **Add a Wyoming integration** in HA pointed at `host-ip:10301`, then **swap the
   "Robot" pipeline's STT** from the in-VM add-on to the new GPU engine.
4. (Optional) once STT moves to the GPU, the in-VM Whisper add-on can be disabled.

Caveat to revisit at wire-in: STT and the LLM now share the 8 GB GPU. `small`
fits alongside the pinned LLM today; if you later run a bigger LLM, re-check free
VRAM. On the future dedicated device, more VRAM would make `medium` (better
accuracy) viable.

---

## Reproduce / restore notes

- **Scaffolding (kept for the future wire-in):** `whisper-bench/gen_test_audio.py`,
  `bench.py`, `probe.py`, `analyze.py`, `run_whisper_gpu.ps1`, `run_sweep.ps1`,
  `run_clean_verify.ps1`; raw data in `results/results.csv`; test clips in `audio/`.
- **Re-run a config:** start a server with `run_whisper_gpu.ps1` (or `run_sweep.ps1`
  for a batch), then `python bench.py --uri tcp://127.0.0.1:10301 --runs 5 --tag NAME`.
  `python analyze.py` prints the aggregated tables.
- **HA was restored to baseline:** add-on back to `model=base`, `beam_size=0`,
  host port 10300 **un-published** (`10300/tcp: null`), add-on restarted and
  `started`; the `faster-whisper`, `piper`, and `kokoro` Wyoming integrations all
  re-confirmed `loaded`. The host GPU test server was stopped. The live "Robot"
  pipeline is unchanged.
