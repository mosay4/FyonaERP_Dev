"""Deterministic original FYONA Sara earcons, no samples or voice recordings."""
import math
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'assets' / 'audio'
RATE = 24000
SCORES = {
    'welcome': (1.05, [(0, 659.25, .55), (.12, 987.77, .65), (.27, 1318.51, .65)]),
    'sent': (.10, [(0, 880, .085)]),
    'reply': (.22, [(0, 783.99, .19), (.045, 1174.66, .16)]),
    'success': (.48, [(0, 659.25, .35), (.07, 987.77, .37)]),
    'error': (.21, [(0, 392, .17), (.055, 369.99, .14)]),
    'tap': (.055, [(0, 1046.5, .045)]),
}


def generate():
    for name, (duration, notes) in SCORES.items():
        samples = []
        for n in range(round(duration * RATE)):
            time = n / RATE
            value = 0
            for start, hz, length in notes:
                t = time - start
                if 0 <= t < length:
                    envelope = min(1, t / .012) * math.exp(-7 * t / length) * min(1, (length - t) / .025)
                    value += envelope * (math.sin(2 * math.pi * hz * t) + .15 * math.sin(2 * math.pi * hz * 2.003 * t))
            samples.append(max(-1, min(1, value * .13)))
        with wave.open(str(ROOT / f'sara_{name}.wav'), 'wb') as output:
            output.setparams((1, 2, RATE, len(samples), 'NONE', 'not compressed'))
            output.writeframes(b''.join(struct.pack('<h', round(v * 32767)) for v in samples))
        print(name, len(samples), 'samples')


if __name__ == '__main__':
    generate()
