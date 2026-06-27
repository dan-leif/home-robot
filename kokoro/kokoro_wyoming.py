"""Minimal Wyoming TTS server wrapping kokoro-onnx, serving the af_sky voice.

Listens on tcp://0.0.0.0:10200 and answers Home Assistant's Assist pipeline.
Audio is emitted as 24 kHz mono 16-bit PCM, which is what Kokoro produces.

Supports BOTH:
- classic one-shot Synthesize (whole text in, whole audio out), and
- streaming synthesis (SynthesizeStart -> SynthesizeChunk... -> SynthesizeStop),
  which lets Home Assistant start speaking the first sentence while the LLM is
  still generating the rest of the answer.
"""

import argparse
import asyncio
import logging
import os
import re

import numpy as np
from kokoro_onnx import Kokoro

from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import (
    Synthesize,
    SynthesizeChunk,
    SynthesizeStart,
    SynthesizeStop,
    SynthesizeStopped,
)

_LOGGER = logging.getLogger("kokoro_wyoming")

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(HERE, "kokoro-v1.0.onnx")
VOICES_PATH = os.path.join(HERE, "voices-v1.0.bin")

SAMPLE_RATE = 24000
SAMPLE_WIDTH = 2  # 16-bit
CHANNELS = 1
DEFAULT_VOICE = "af_sky"
LANG = "en-us"
CHUNK_SAMPLES = 1024

# What counts as the end of a "complete" sentence, greedily matched up to the
# LAST boundary currently in the buffer:
#   - "." only when followed by whitespace, so decimals/times like "3.50" and
#     "7:30" stay intact while the next token is still streaming in;
#   - ASCII "!"/"?" immediately;
#   - CJK "。！？" immediately (Chinese text has no space after them — needed
#     for the planned Chinese mode);
#   - a newline.
_BOUNDARY_RE = re.compile(r"^(.*(?:\.(?=\s)|[!?。！？]|\n))", re.DOTALL)


def _build_info() -> Info:
    return Info(
        tts=[
            TtsProgram(
                name="kokoro",
                description="Kokoro ONNX TTS (af_sky)",
                installed=True,
                version="0.5.0",
                attribution=Attribution(
                    name="hexgrad/kokoro + thewh1teagle/kokoro-onnx",
                    url="https://github.com/thewh1teagle/kokoro-onnx",
                ),
                supports_synthesize_streaming=True,
                voices=[
                    TtsVoice(
                        name=DEFAULT_VOICE,
                        description="US English female (Sky)",
                        installed=True,
                        version=None,
                        attribution=Attribution(name="hexgrad", url="https://github.com/hexgrad/kokoro"),
                        languages=["en-us"],
                    )
                ],
            )
        ]
    )


class KokoroEventHandler(AsyncEventHandler):
    def __init__(self, kokoro: Kokoro, info: Info, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._kokoro = kokoro
        self._info = info
        # Streaming state (one streaming request at a time per connection).
        self._streaming = False
        self._buffer = ""
        self._voice = DEFAULT_VOICE
        self._audio_started = False

    async def handle_event(self, event) -> bool:
        if Describe.is_type(event.type):
            await self.write_event(self._info.event())
            return True

        # --- Streaming path -------------------------------------------------
        if SynthesizeStart.is_type(event.type):
            start = SynthesizeStart.from_event(event)
            self._streaming = True
            self._buffer = ""
            self._audio_started = False
            self._voice = DEFAULT_VOICE
            if start.voice and start.voice.name:
                self._voice = start.voice.name
            _LOGGER.info("SynthesizeStart (voice=%s)", self._voice)
            return True

        if SynthesizeChunk.is_type(event.type):
            if not self._streaming:
                return True
            self._buffer += SynthesizeChunk.from_event(event).text
            await self._drain_complete_sentences()
            return True

        if SynthesizeStop.is_type(event.type):
            # Flush whatever is left, then close the audio stream.
            remaining = self._buffer.strip()
            if remaining:
                await self._speak(remaining)
            if not self._audio_started:
                # Empty/whitespace-only response: still open+close a stream.
                await self._begin_audio()
            await self.write_event(AudioStop().event())
            await self.write_event(SynthesizeStopped().event())
            _LOGGER.debug("SynthesizeStop -> stream closed")
            self._streaming = False
            self._buffer = ""
            self._audio_started = False
            return True

        # --- Classic one-shot path -----------------------------------------
        if Synthesize.is_type(event.type):
            synth = Synthesize.from_event(event)
            text = synth.text.strip()
            voice = DEFAULT_VOICE
            if synth.voice and synth.voice.name:
                voice = synth.voice.name
            _LOGGER.info("Synthesize (%s): %s", voice, text)

            pcm = self._render(text, voice)
            await self.write_event(
                AudioStart(rate=SAMPLE_RATE, width=SAMPLE_WIDTH, channels=CHANNELS).event()
            )
            await self._write_pcm(pcm)
            await self.write_event(AudioStop().event())
            _LOGGER.debug("Done (%d bytes)", len(pcm))
            return True

        return True

    async def _drain_complete_sentences(self) -> None:
        """Synthesize and emit any complete sentences sitting in the buffer."""
        match = _BOUNDARY_RE.match(self._buffer)
        if not match:
            return
        ready = match.group(1)
        self._buffer = self._buffer[match.end():]
        text = ready.strip()
        if text:
            await self._speak(text)

    async def _speak(self, text: str) -> None:
        """Render text and stream it into the (single) audio response."""
        pcm = self._render(text, self._voice)
        if not self._audio_started:
            await self._begin_audio()
        await self._write_pcm(pcm)

    async def _begin_audio(self) -> None:
        await self.write_event(
            AudioStart(rate=SAMPLE_RATE, width=SAMPLE_WIDTH, channels=CHANNELS).event()
        )
        self._audio_started = True

    def _render(self, text: str, voice: str) -> bytes:
        """Kokoro returns float32 in [-1, 1]; convert to 16-bit PCM bytes."""
        if not text:
            return b""
        _LOGGER.info("Render (%s): %s", voice, text)
        samples, _sr = self._kokoro.create(text, voice=voice, speed=1.0, lang=LANG)
        pcm = np.clip(samples, -1.0, 1.0)
        return (pcm * 32767.0).astype("<i2").tobytes()

    async def _write_pcm(self, pcm: bytes) -> None:
        bytes_per_chunk = CHUNK_SAMPLES * SAMPLE_WIDTH * CHANNELS
        for i in range(0, len(pcm), bytes_per_chunk):
            chunk = pcm[i : i + bytes_per_chunk]
            await self.write_event(
                AudioChunk(
                    rate=SAMPLE_RATE,
                    width=SAMPLE_WIDTH,
                    channels=CHANNELS,
                    audio=chunk,
                ).event()
            )


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--uri", default="tcp://0.0.0.0:10200")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

    _LOGGER.info("Loading Kokoro model...")
    kokoro = Kokoro(MODEL_PATH, VOICES_PATH)
    info = _build_info()
    _LOGGER.info("Ready. Listening on %s (voice=%s)", args.uri, DEFAULT_VOICE)

    server = AsyncServer.from_uri(args.uri)
    await server.run(
        lambda *a, **k: KokoroEventHandler(kokoro, info, *a, **k)
    )


if __name__ == "__main__":
    asyncio.run(main())
