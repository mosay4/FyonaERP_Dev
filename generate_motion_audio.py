import math
import random
import struct
import wave
from pathlib import Path

root = Path(__file__).parent / 'assets' / 'audio'
rate = 24000
for name, tones, duration in [
    ('motion_section.wav', [(440, 0), (659.25, .075), (880, .13)], .62),
    ('motion_branch.wav', [(523.25, 0), (783.99, .06)], .48),
]:
    rng = random.Random(71)
    samples = []
    for i in range(int(duration * rate)):
        t = i / rate
        value = 0.0
        for frequency, delay in tones:
            age = t - delay
            if age >= 0:
                envelope = (1 - math.exp(-age * 110)) * math.exp(-age * 10)
                value += .13 * envelope * math.sin(2 * math.pi * frequency * age)
                value += .015 * envelope * math.sin(2 * math.pi * frequency * 2 * age)
        value += .018 * rng.uniform(-1, 1) * math.sin(math.pi * t / duration) ** 3
        value *= min(1, (duration - t) / .07)
        samples.append(struct.pack('<h', int(max(-1, min(1, value)) * 32767)))
    with wave.open(str(root / name), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(b''.join(samples))
    print(name, len(samples), 'samples')
