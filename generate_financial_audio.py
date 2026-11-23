"""Deterministic original synthesis for the seven Flutter financial scenes."""
import math
import random
import struct
import subprocess
import wave
from pathlib import Path

ROOT = Path(__file__).parent / 'assets' / 'audio'
RATE = 24000
DURATION = 2.8
SCORES = {
    'sales': [(0.12, 660, .18), (.48, 830, .16), (.86, 990, .15), (1.65, 330, .18)],
    'treasury': [(.12, 110, .24), (.3, 220, .11), (1.2, 587, .14), (1.65, 880, .12)],
    'inventory': [(.15+i*.16, 170+i*32, .13) for i in range(7)],
    'debts': [(.2, 392, .17), (.56, 587, .14), (1.7, 294, .13), (1.72, 440, .1)],
    'executive': [(.15, 440, .14), (.45, 554, .14), (.75, 660, .14),
                  (1.05, 880, .13), (1.9, 165, .19), (1.92, 660, .13)],
    'precision': [(.18+i*.21, 720+(i%3)*95, .075) for i in range(9)],
    'balance': [(.15, 196, .12), (1.28, 1175, .09), (1.7, 440, .19), (1.72, 660, .16)],
}

for index, (name, score) in enumerate(SCORES.items()):
    rng = random.Random(810 + index)
    values = []
    filtered = 0
    for i in range(int(RATE * DURATION)):
        t = i / RATE
        value = 0.0
        for delay, frequency, level in score:
            age = t - delay
            if age < 0:
                continue
            decay = 22 if name in ('inventory', 'precision') else 10
            env = (1-math.exp(-age*220))*math.exp(-age*decay)
            value += level*env*(math.sin(math.tau*frequency*age) +
                                    .18*math.sin(math.tau*frequency*2.01*age))
        filtered = .86*filtered + .14*rng.uniform(-1, 1)
        sweep_at = {'sales': 1.4, 'treasury': .9, 'inventory': 1.5,
                    'debts': 1.5, 'executive': 1.65, 'precision': .6,
                    'balance': .8}[name]
        span = .6 if name != 'balance' else .75
        p = (t-sweep_at)/span
        if 0 <= p <= 1:
            value += filtered*.07*math.sin(math.pi*p)**2
        value *= min(1, max(0, (DURATION-t)/.1))
        values.append(max(-1, min(1, value)))
    wav = ROOT / f'financial_{name}.wav'
    ogg = ROOT / f'financial_{name}.ogg'
    with wave.open(str(wav), 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b''.join(struct.pack('<h', round(x*32767)) for x in values))
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(wav),
                    '-c:a', 'libvorbis', '-q:a', '3', str(ogg)], check=True)
    wav.unlink()
    print(name, ogg.stat().st_size, 'bytes')
