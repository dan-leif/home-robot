"""
Generate test audio for the Whisper STT benchmark.
Uses kokoro-onnx (af_sky voice) to synthesize a fixed sentence set to
16 kHz mono 16-bit WAV files that Wyoming ASR expects.

Output:
  audio/<slug>.wav   — one WAV per sentence
  references.json    — {slug: reference_text} for WER/CER scoring
"""

import json
import os
import re
import sys

import numpy as np
import soundfile as sf

AUDIO_DIR = os.path.join(os.path.dirname(__file__), "audio")
REFS_PATH = os.path.join(os.path.dirname(__file__), "references.json")

# Fixed sentence set:
# - real user examples (long proper-noun list, narrative story)
# - hard proper nouns (countries that trip up smaller models)
# - numbers / times / money
# - short everyday commands
SENTENCES = {
    "countries": (
        "Name twenty countries: Afghanistan, Brazil, Canada, Denmark, Egypt, "
        "Finland, Germany, Hungary, India, Japan, Kenya, Lithuania, Mexico, "
        "Nigeria, Oman, Portugal, Qatar, Romania, Sweden, Thailand."
    ),
    "hen_story": (
        "Once upon a time, a little red hen found a grain of wheat. "
        "She asked the dog, the cat, and the duck who would help her plant it, "
        "but they all refused. So she planted it herself, and in due time the "
        "wheat grew tall and golden."
    ),
    "proper_nouns": (
        "Burkina Faso, Eritrea, Kazakhstan, Kyrgyzstan, Liechtenstein, "
        "Mozambique, Turkmenistan, and Zimbabwe are all sovereign nations."
    ),
    "numbers_times": (
        "The total comes to three dollars and fifty cents. "
        "The meeting is at seven thirty in the morning. "
        "She was born in nineteen eighty four."
    ),
    "money_math": (
        "Inflation rose two point seven percent last quarter. "
        "A dozen eggs costs four ninety nine at the local store. "
        "The budget deficit reached one point two trillion dollars."
    ),
    "commands_short": "Set a timer for five minutes.",
    "commands_medium": "What is the weather like in San Francisco today?",
    "commands_lights": "Turn off the living room lights please.",
    "year_2026": "The year two thousand and twenty six has been quite eventful so far.",
    "mixed_hard": (
        "On the twelfth of February twenty twenty five, Kyrgyzstan and "
        "Liechtenstein signed a treaty worth eight hundred million dollars."
    ),
}

TARGET_SR = 16000


def slug_to_filename(slug: str) -> str:
    return re.sub(r"[^a-z0-9_]", "_", slug.lower()) + ".wav"


def main():
    try:
        from kokoro_onnx import Kokoro
    except ImportError:
        print("ERROR: kokoro-onnx not installed. Run: pip install kokoro-onnx")
        sys.exit(1)

    try:
        import soxr
    except ImportError:
        print("ERROR: soxr not installed. Run: pip install soxr")
        sys.exit(1)

    model_dir = os.path.join(os.path.dirname(__file__), "..", "kokoro")
    model_path = os.path.join(model_dir, "kokoro-v1.0.onnx")
    voices_path = os.path.join(model_dir, "voices-v1.0.bin")

    if not os.path.exists(model_path):
        print(f"ERROR: Kokoro ONNX model not found at {model_path}")
        sys.exit(1)

    print(f"Loading Kokoro from {model_dir} ...")
    kokoro = Kokoro(model_path, voices_path)

    os.makedirs(AUDIO_DIR, exist_ok=True)
    references = {}

    for slug, text in SENTENCES.items():
        fname = slug_to_filename(slug)
        out_path = os.path.join(AUDIO_DIR, fname)
        print(f"  Synthesizing [{slug}] -> {fname}")

        # Kokoro returns (samples_float32, sample_rate)
        samples, sr = kokoro.create(text, voice="af_sky", speed=1.0, lang="en-us")
        samples = np.array(samples, dtype=np.float32)

        # Resample to 16 kHz if needed
        if sr != TARGET_SR:
            samples = soxr.resample(samples, sr, TARGET_SR)

        # Write 16-bit PCM WAV
        sf.write(out_path, samples, TARGET_SR, subtype="PCM_16")
        references[fname] = text
        print(f"    -> {len(samples)/TARGET_SR:.2f}s of audio")

    with open(REFS_PATH, "w", encoding="utf-8") as f:
        json.dump(references, f, indent=2, ensure_ascii=False)

    print(f"\nDone. {len(references)} WAV files in {AUDIO_DIR}")
    print(f"References saved to {REFS_PATH}")


if __name__ == "__main__":
    main()
