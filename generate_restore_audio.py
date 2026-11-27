"""Original, soft cues for the backup/restore/import motion (synthesised)."""
import math
import random
import struct
import wave
from pathlib import Path

root = Path(__file__).parent / 'assets' / 'audio'
rate = 24000


def write(name, duration, fn):
    rng = random.Random(name)
    out = []
    for i in range(int(duration * rate)):
        t = i / rate
        v = fn(t, rng)
        v *= min(1, t / .012) * min(1, (duration - t) / .08)
        out.append(struct.pack('<h', int(max(-1, min(1, v)) * 32767)))
    with wave.open(str(root / name), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b''.join(out))
    print(name, len(out))


def bell(t, f, start, decay, amp):
    a = t - start
    if a < 0:
        return 0
    env = (1 - math.exp(-a * 140)) * math.exp(-a * decay)
    return amp * env * (math.sin(2 * math.pi * f * a) + .25 * math.sin(2 * math.pi * f * 2.01 * a))


# A soft rising air-swell: the work begins.
write('restore_start.wav', .9, lambda t, r: .10 * math.sin(math.pi * t / .9) ** 2 * (
    math.sin(2 * math.pi * (220 + 260 * t) * t) * .5 + r.uniform(-1, 1) * .35 * math.sin(math.pi * t / .9)))
# A tiny glass tick between stages.
write('restore_tick.wav', .14, lambda t, r: bell(t, 1567.98, 0, 38, .10))
# Done: a warm rising major arpeggio with a shimmer.
write('restore_done.wav', 1.5, lambda t, r: sum(bell(t, f, d, 3.4, .085) for f, d in
      [(523.25, 0), (659.25, .09), (783.99, .18), (1046.5, .29)]) + .01 * math.sin(2 * math.pi * 2093 * t) * math.exp(-t * 3))
# Not completed: two low, gentle descending tones (never harsh).
write('restore_fail.wav', .7, lambda t, r: bell(t, 392.0, 0, 6, .09) + bell(t, 311.13, .18, 6, .09))
