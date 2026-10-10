"""
Wyoming STT benchmark client.

Usage:
  python bench.py --uri tcp://HOST:PORT [--runs N] [--tag LABEL]

For each WAV in audio/, connects to the Wyoming server, sends Transcribe ->
AudioStart -> AudioChunk(s) -> AudioStop, awaits Transcript.

Latency = wall-clock from AudioStop sent to Transcript received (matches what
Home Assistant measures for the `stt` stage).

The first run is treated as a cold run (model load + first inference); the
median of subsequent runs is the warm latency. WER and CER are computed
against references.json.

Results are appended to results/results.csv. A per-wav detail table and a
summary row are printed.
"""

import argparse
import asyncio
import csv
import json
import os
import statistics
import sys
import time

# Ensure UTF-8 output on Windows so non-ASCII summaries don't crash
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

AUDIO_DIR = os.path.join(os.path.dirname(__file__), "audio")
REFS_PATH = os.path.join(os.path.dirname(__file__), "references.json")
RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")
RESULTS_CSV = os.path.join(RESULTS_DIR, "results.csv")

CHUNK_SAMPLES = 1600  # 0.1 s at 16 kHz


def load_pcm_s16(path: str):
    """Return raw 16-bit PCM bytes from a WAV file at 16 kHz mono."""
    import soundfile as sf
    import numpy as np

    data, sr = sf.read(path, dtype="int16", always_2d=False)
    if sr != 16000:
        raise ValueError(f"{path}: expected 16 kHz, got {sr}")
    if data.ndim > 1:
        data = data[:, 0]
    return data.tobytes()


async def transcribe_once(uri: str, wav_path: str) -> tuple[str, float]:
    """Return (transcript, latency_seconds). Latency = AudioStop -> Transcript."""
    from wyoming.audio import AudioChunk, AudioStart, AudioStop
    from wyoming.asr import Transcribe, Transcript
    from wyoming.client import AsyncTcpClient

    pcm = load_pcm_s16(wav_path)
    chunk_bytes = CHUNK_SAMPLES * 2  # 2 bytes per int16 sample

    async with AsyncTcpClient.from_uri(uri) as client:
        await client.write_event(Transcribe(language="en").event())
        await client.write_event(
            AudioStart(rate=16000, width=2, channels=1).event()
        )

        # Stream chunks
        for i in range(0, len(pcm), chunk_bytes):
            chunk = pcm[i : i + chunk_bytes]
            await client.write_event(
                AudioChunk(rate=16000, width=2, channels=1, audio=chunk).event()
            )

        t_stop = time.perf_counter()
        await client.write_event(AudioStop().event())

        # Wait for Transcript
        while True:
            event = await client.read_event()
            if event is None:
                raise RuntimeError("Connection closed before Transcript received")
            if Transcript.is_type(event.type):
                t_transcript = time.perf_counter()
                transcript = Transcript.from_event(event)
                return transcript.text, t_transcript - t_stop


def compute_wer_cer(hypothesis: str, reference: str) -> tuple[float, float]:
    try:
        from jiwer import wer, cer

        h = hypothesis.lower().strip()
        r = reference.lower().strip()
        return wer(r, h), cer(r, h)
    except Exception:
        return float("nan"), float("nan")


async def run_bench(uri: str, runs: int, tag: str) -> dict:
    if not os.path.exists(REFS_PATH):
        print(f"ERROR: {REFS_PATH} not found. Run gen_test_audio.py first.")
        sys.exit(1)

    with open(REFS_PATH, encoding="utf-8") as f:
        references = json.load(f)

    wav_files = sorted(
        f for f in os.listdir(AUDIO_DIR) if f.endswith(".wav") and f in references
    )

    if not wav_files:
        print(f"ERROR: No matching WAV files found in {AUDIO_DIR}")
        sys.exit(1)

    print(f"\n{'='*70}")
    print(f"Benchmark: {tag}")
    print(f"URI: {uri}  |  runs per WAV: {runs}")
    print("="*70)

    all_cold_latencies = []
    all_warm_latencies = []
    all_wers = []
    all_cers = []

    detail_rows = []

    for wav_name in wav_files:
        wav_path = os.path.join(AUDIO_DIR, wav_name)
        ref = references[wav_name]
        latencies = []
        last_transcript = ""

        for run_idx in range(runs):
            try:
                transcript, latency = await transcribe_once(uri, wav_path)
                latencies.append(latency)
                last_transcript = transcript
                mark = "(cold)" if run_idx == 0 else f"run {run_idx+1}"
                print(f"  {wav_name} {mark}: {latency:.3f}s | '{transcript[:60]}'")
            except Exception as e:
                print(f"  {wav_name} run {run_idx+1}: ERROR {e}")
                latencies.append(float("nan"))

        cold = latencies[0]
        warm = statistics.median(latencies[1:]) if len(latencies) > 1 else cold
        w, c = compute_wer_cer(last_transcript, ref)

        all_cold_latencies.append(cold)
        all_warm_latencies.append(warm)
        all_wers.append(w)
        all_cers.append(c)

        detail_rows.append(
            {
                "tag": tag,
                "wav": wav_name,
                "cold_s": round(cold, 3),
                "warm_median_s": round(warm, 3),
                "wer": round(w, 4),
                "cer": round(c, 4),
                "transcript": last_transcript,
                "reference": ref,
            }
        )

    # Aggregate
    def safe_median(lst):
        clean = [x for x in lst if x == x]  # filter NaN
        return statistics.median(clean) if clean else float("nan")

    summary = {
        "tag": tag,
        "uri": uri,
        "cold_median_s": round(safe_median(all_cold_latencies), 3),
        "warm_median_s": round(safe_median(all_warm_latencies), 3),
        "warm_max_s": round(max((x for x in all_warm_latencies if x == x), default=float("nan")), 3),
        "wer_mean": round(sum(w for w in all_wers if w == w) / max(1, sum(1 for w in all_wers if w == w)), 4),
        "cer_mean": round(sum(c for c in all_cers if c == c) / max(1, sum(1 for c in all_cers if c == c)), 4),
        "n_wavs": len(wav_files),
        "runs": runs,
    }

    # Print summary
    print(f"\n{'-'*70}")
    print(f"SUMMARY [{tag}]")
    print(f"  Cold median:  {summary['cold_median_s']:.3f}s")
    print(f"  Warm median:  {summary['warm_median_s']:.3f}s")
    print(f"  Warm max:     {summary['warm_max_s']:.3f}s")
    print(f"  WER mean:     {summary['wer_mean']:.1%}")
    print(f"  CER mean:     {summary['cer_mean']:.1%}")
    print(f"{'-'*70}\n")

    # Write CSV
    os.makedirs(RESULTS_DIR, exist_ok=True)
    fieldnames = list(detail_rows[0].keys())
    write_header = not os.path.exists(RESULTS_CSV)
    with open(RESULTS_CSV, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        if write_header:
            w.writeheader()
        w.writerows(detail_rows)

    print(f"Results appended to {RESULTS_CSV}")
    return summary


def main():
    parser = argparse.ArgumentParser(description="Wyoming STT benchmark")
    parser.add_argument("--uri", required=True, help="Wyoming server URI, e.g. tcp://127.0.0.1:10301")
    parser.add_argument("--runs", type=int, default=4, help="Runs per WAV (first is cold)")
    parser.add_argument("--tag", default="", help="Label for this config in the results CSV")
    args = parser.parse_args()

    if not args.tag:
        # Auto-derive a tag from the URI
        args.tag = args.uri.replace("tcp://", "").replace("/", "_")

    summary = asyncio.run(run_bench(args.uri, args.runs, args.tag))
    return summary


if __name__ == "__main__":
    main()
