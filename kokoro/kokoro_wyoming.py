"""Minimal Wyoming TTS server wrapping kokoro-onnx, serving the af_sky voice.

Listens on tcp://0.0.0.0:10200 and answers Home Assistant's Assist pipeline.
Audio is emitted as 24 kHz mono 16-bit PCM, which is what Kokoro produces.
"""

import argparse
import asyncio
import logging
import os

import numpy as np
from kokoro_onnx import Kokoro

from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import Synthesize

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

    async def handle_event(self, event) -> bool:
        if Describe.is_type(event.type):
            await self.write_event(self._info.event())
            return True

        if Synthesize.is_type(event.type):
            synth = Synthesize.from_event(event)
            text = synth.text.strip()
            voice = DEFAULT_VOICE
            if synth.voice and synth.voice.name:
                voice = synth.voice.name
            _LOGGER.info("Synthesize (%s): %s", voice, text)

            # Kokoro returns float32 in [-1, 1]; convert to 16-bit PCM.
            samples, _sr = self._kokoro.create(text, voice=voice, speed=1.0, lang=LANG)
            pcm = np.clip(samples, -1.0, 1.0)
            pcm = (pcm * 32767.0).astype("<i2").tobytes()

            await self.write_event(
                AudioStart(rate=SAMPLE_RATE, width=SAMPLE_WIDTH, channels=CHANNELS).event()
            )
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
            await self.write_event(AudioStop().event())
            _LOGGER.debug("Done (%d bytes)", len(pcm))
            return True

        return True


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
