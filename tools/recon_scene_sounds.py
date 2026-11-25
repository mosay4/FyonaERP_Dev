"""Synthesizes the reconciliation motion cues (22.05 kHz, mono, 16-bit WAV).

Offsets are derived from the keyframes in
lib/features/reconciliation/presentation/widgets/recon_scenes.dart:
  - opening scenes: D = 1500 ms, the motion cue starts at t=0, the reveal
    cue starts when the gate releases the hold point (t=.80).
  - settle mark: D = 900 ms, the cue starts with the motion.
Pure stdlib (wave + math + random): soft sine/bell partials, no harsh
transients, gentle fade in/out, every file < 1.2 s.
Usage: python3 tools/recon_scene_sounds.py assets/audio
"""
import math
import random
import struct
import sys
import wave

SR = 22050
OUT = sys.argv[1] if len(sys.argv) > 1 else 'assets/audio'
random.seed(11)


def buf(ms):
    return [0.0] * int(SR * ms / 1000.0)


def add(dst, src, at_ms, gain=1.0):
    o = int(SR * at_ms / 1000.0)
    for i, v in enumerate(src):
        j = o + i
        if 0 <= j < len(dst):
            dst[j] += v * gain


def lowpass(samples, f):
    a = 1 - math.exp(-2 * math.pi * f / SR)
    y, out = 0.0, []
    for v in samples:
        y += a * (v - y)
        out.append(y)
    return out


def bell(f, ms, tau, attack_ms=6.0,
         partials=((1, 1.0), (2.0, .22), (3.0, .07), (4.16, .025))):
    """Soft glass/bell: slow-ish attack, higher partials die faster."""
    n = int(SR * ms / 1000)
    att = SR * attack_ms / 1000
    out = []
    for i in range(n):
        t = i / SR
        e = math.sin(.5 * math.pi * min(1, i / att)) * math.exp(-t / tau)
        s = 0.0
        for r, g in partials:
            s += g * math.sin(2 * math.pi * f * r * t) * math.exp(-t * (r - 1) * 7)
        out.append(s * e)
    return out


def mallet(f, ms=160, tau=.07, attack_ms=3.0):
    """Muted wooden «tock» (marimba-like, low partial count)."""
    return bell(f, ms, tau, attack_ms,
                partials=((1, 1.0), (3.9, .12), (9.2, .02)))


def thud(f0=170, f1=95, ms=140, gain=1.0):
    """Soft cardboard landing: a gliding low sine + very quiet felt noise."""
    n = int(SR * ms / 1000)
    noise = lowpass([random.uniform(-1, 1) for _ in range(n)], 700)
    out, ph = [], 0.0
    for i in range(n):
        t = i / SR
        f = f1 + (f0 - f1) * math.exp(-t / .02)
        ph += 2 * math.pi * f / SR
        a = min(1, i / (SR * .004))
        out.append((math.sin(ph) * math.exp(-t / .04) +
                    noise[i] * 1.4 * math.exp(-t / .01)) * a * gain)
    return out


def air(ms, f, gain=1.0):
    """Very soft breathy swell (low-passed noise, sine envelope)."""
    n = int(SR * ms / 1000)
    noise = lowpass(lowpass([random.uniform(-1, 1) for _ in range(n)], f), f)
    return [v * math.sin(math.pi * i / n) ** 2 * gain * 3 for i, v in enumerate(noise)]


def glide(f_from, f_to, ms, glide_ms, gain=1.0):
    """Sine gliding (ease-in-out) from f_from to f_to, then holding."""
    n = int(SR * ms / 1000)
    g = SR * glide_ms / 1000
    out, ph = [], 0.0
    for i in range(n):
        x = min(1, i / g)
        k = x * x * (3 - 2 * x)
        f = f_from + (f_to - f_from) * k
        ph += 2 * math.pi * f / SR
        env = math.sin(.5 * math.pi * min(1, i / (SR * .05))) * \
            (1 - max(0, (i - g) / (n - g + 1)))
        out.append((math.sin(ph) + .12 * math.sin(2 * ph)) * env * gain)
    return out


def finish(samples, peak, fade_in_ms=4, fade_out_ms=60):
    m = max(abs(v) for v in samples) or 1
    out = [v * peak / m for v in samples]
    fi = int(SR * fade_in_ms / 1000)
    fo = int(SR * fade_out_ms / 1000)
    for i in range(fi):
        out[i] *= i / fi
    for i in range(fo):
        out[-1 - i] *= i / fo
    return out


def write(name, samples, peak):
    samples = finish(samples, peak)
    assert len(samples) / SR < 1.2, name
    with wave.open(f'{OUT}/{name}.wav', 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(
            struct.pack('<h', int(max(-1, min(1, v)) * 32767)) for v in samples))


D = 1500.0  # opening scene, ms


def ms(t):
    return t * D


# ── Financial opening: the beam draws (soft air), three ledger rows land on
# the left pan (descending mallets), three on the right (rising) until level.
s = buf(1150)
add(s, air(420, 900), 0, .35)
for i, f in enumerate((440.0, 392.0, 349.2)):       # A4 G4 F4 — tips down
    add(s, mallet(f), ms(.20 + .07 * i + .07), .55)
for i, f in enumerate((523.3, 587.3, 659.3)):       # C5 D5 E5 — rises level
    add(s, mallet(f), ms(.46 + .07 * i + .07), .55)
write('recon_open_financial', s, .42)

# Reveal (gate releases at .80, ring .80–.90, check .85–.96): warm open fifth.
s = buf(1000)
add(s, bell(659.3, 950, .34), 40, .6)     # E5
add(s, bell(987.8, 900, .30), 110, .38)   # B5
add(s, bell(1318.5, 700, .22), 200, .14)  # E6 shimmer
write('recon_open_financial_end', s, .40)

# ── Inventory opening: six boxes land on the shelves (soft cardboard thuds),
# then the scan passes three columns (gentle glass ticks).
s = buf(1180)
for i in range(6):
    add(s, thud(175 - 8 * i, 100 - 3 * i), ms(.16 + .06 * i + .12) - 6, .7)
add(s, air(300, 2600), ms(.58), .18)
for k, cx in enumerate((112.0, 160.0, 208.0)):
    at = .58 + .20 * ((cx - 76.0) / 168.0)
    add(s, bell(1567.98 + 220 * k, 200, .06, 2.0), ms(at), .22)
write('recon_open_inventory', s, .40)

# Reveal: marimba + bell, a calm «counted» major third.
s = buf(1000)
add(s, mallet(783.99, 300, .12), 40, .55)  # G5 wood
add(s, bell(783.99, 900, .32), 40, .45)
add(s, bell(987.77, 850, .28), 130, .32)   # B5
write('recon_open_inventory_end', s, .40)

# ── Settle mark (D = 900 ms): two tones glide into unison while the bars
# converge (0–.38), then a soft chime as the check draws (.56).
SD = 900.0
s = buf(1150)
add(s, glide(440.0, 523.3, 520, 340), 0, .22)   # system tone rises…
add(s, glide(659.3, 523.3, 520, 340), 0, .22)   # …actual tone falls → C5
add(s, bell(1046.5, 700, .26), SD * .52, .55)  # C6
add(s, bell(1568.0, 620, .22), SD * .58, .30)  # G6
add(s, bell(2093.0, 420, .15), SD * .64, .10)  # C7 air
write('recon_settle', s, .40)
