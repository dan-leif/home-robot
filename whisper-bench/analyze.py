"""
Aggregate results/results.csv into the tables used in RESULTS.md.

Prints:
  1. Per-config summary (warm median latency, mean WER, mean CER), sorted by latency.
  2. Per-config CER on the two "hard" sentence groups (proper nouns, numbers/money),
     which is the sensitive signal for quality drop-off.

Latency per config = median over wavs of each wav's warm_median_s.
WER/CER per config  = mean over wavs.
"""

import csv
import os
import statistics
from collections import defaultdict

RESULTS_CSV = os.path.join(os.path.dirname(__file__), "results", "results.csv")

# Optional "true WER" — re-scores with OpenAI's Whisper text normalizer, which
# canonicalises the number-format mismatch (e.g. "five minutes" == "5 minutes",
# "three dollars and fifty cents" == "$3.50") so only genuine recognition errors
# count. Falls back gracefully if the libs aren't installed.
try:
    from whisper_normalizer.english import EnglishTextNormalizer
    from jiwer import wer as _wer, cer as _cer

    _NORM = EnglishTextNormalizer()

    def true_wer_cer(reference: str, hypothesis: str):
        r, h = _NORM(reference), _NORM(hypothesis)
        if not r:
            return None, None
        return _wer(r, h), _cer(r, h)
except Exception:  # libs missing — skip the normalized columns
    def true_wer_cer(reference: str, hypothesis: str):
        return None, None

HARD_PROPER = {"proper_nouns.wav", "countries.wav", "mixed_hard.wav"}
HARD_NUMBERS = {"numbers_times.wav", "money_math.wav", "year_2026.wav"}


def fnum(x):
    try:
        v = float(x)
        return v if v == v else None  # filter NaN
    except (ValueError, TypeError):
        return None


def main():
    rows = defaultdict(list)
    with open(RESULTS_CSV, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows[r["tag"]].append(r)

    summary = []
    for tag, rs in rows.items():
        warm = [fnum(r["warm_median_s"]) for r in rs]
        warm = [w for w in warm if w is not None]
        wer = [fnum(r["wer"]) for r in rs]
        wer = [w for w in wer if w is not None]
        cer = [fnum(r["cer"]) for r in rs]
        cer = [c for c in cer if c is not None]

        cer_proper = [fnum(r["cer"]) for r in rs if r["wav"] in HARD_PROPER]
        cer_proper = [c for c in cer_proper if c is not None]
        cer_numbers = [fnum(r["cer"]) for r in rs if r["wav"] in HARD_NUMBERS]
        cer_numbers = [c for c in cer_numbers if c is not None]

        # "True" WER/CER after canonicalising number formatting (one transcript
        # per wav is enough — they're deterministic across runs).
        seen_wavs = {}
        for r in rs:
            seen_wavs.setdefault(r["wav"], r)
        true_w, true_c = [], []
        for r in seen_wavs.values():
            tw, tc = true_wer_cer(r.get("reference", ""), r.get("transcript", ""))
            if tw is not None:
                true_w.append(tw)
                true_c.append(tc)

        summary.append({
            "tag": tag,
            "warm_median_s": statistics.median(warm) if warm else float("nan"),
            "wer_mean": sum(wer) / len(wer) if wer else float("nan"),
            "cer_mean": sum(cer) / len(cer) if cer else float("nan"),
            "cer_proper": sum(cer_proper) / len(cer_proper) if cer_proper else float("nan"),
            "cer_numbers": sum(cer_numbers) / len(cer_numbers) if cer_numbers else float("nan"),
            "true_wer": sum(true_w) / len(true_w) if true_w else float("nan"),
            "true_cer": sum(true_c) / len(true_c) if true_c else float("nan"),
            "n": len(rs),
        })

    summary.sort(key=lambda s: (s["warm_median_s"] if s["warm_median_s"] == s["warm_median_s"] else 9e9))

    print("\n=== Per-config summary (sorted by warm latency) ===")
    print("(trueWER/trueCER = scored after canonicalising number formatting — "
          "real recognition errors only)")
    print(f"{'config':32} {'warm_s':>8} {'WER':>7} {'trueWER':>8} {'trueCER':>8} {'CER_prop':>9}")
    for s in summary:
        print(f"{s['tag']:32} {s['warm_median_s']:8.3f} {s['wer_mean']:7.1%} "
              f"{s['true_wer']:8.1%} {s['true_cer']:8.1%} {s['cer_proper']:9.1%}")
    print()


if __name__ == "__main__":
    main()
