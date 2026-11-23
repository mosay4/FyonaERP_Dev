"""Reproducible tiny, distinct local chat cues (90/130 ms, mono PCM)."""
import math
import struct
import wave
from pathlib import Path


def main():
    root = Path(__file__).parent / "assets" / "audio"
    for name, duration, start, end in (
        ("sent", 0.09, 900, 1400), ("received", 0.13, 650, 420)
    ):
        count = int(16000 * duration)
        frames = bytearray()
        phase = 0.0
        for i in range(count):
            progress = i / count
            phase += 2 * math.pi * (start + (end - start) * progress) / 16000
            envelope = math.sin(math.pi * progress) ** 2
            frames.extend(struct.pack("<h", int(9000 * envelope * math.sin(phase))))
        with wave.open(str(root / f"chat_{name}.wav"), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            out.writeframes(frames)


if __name__ == "__main__":
    main()
