"""Synthesizes the report-gate sound cues (22.05 kHz, mono, 16-bit WAV).

Every offset below is derived from the keyframes in
lib/features/reports/presentation/widgets/report_scenes.dart
(D = 2200 ms scene). Pure stdlib: wave + math + random.
Usage: python3 tools/report_scene_sounds.py assets/audio
"""
import math
import random
import struct
import sys
import wave

SR = 22050  # chimes/ticks need no more; halves the APK cost
D = 2200.0  # ms, scene duration
OUT = sys.argv[1]
random.seed(7)


def buf(ms):
    return [0.0] * int(SR * ms / 1000.0)


def add(dst, src, at_ms, gain=1.0):
    o = int(SR * at_ms / 1000.0)
    for i, v in enumerate(src):
        j = o + i
        if 0 <= j < len(dst):
            dst[j] += v * gain


class Biquad:
    def __init__(self, kind, f, q=0.707):
        w = 2 * math.pi * f / SR
        a = math.sin(w) / (2 * q)
        c = math.cos(w)
        if kind == 'lp':
            b0, b1, b2 = (1 - c) / 2, 1 - c, (1 - c) / 2
        elif kind == 'hp':
            b0, b1, b2 = (1 + c) / 2, -(1 + c), (1 + c) / 2
        else:  # band-pass, 0 dB peak
            b0, b1, b2 = a, 0.0, -a
        a0, a1, a2 = 1 + a, -2 * c, 1 - a
        self.b = (b0 / a0, b1 / a0, b2 / a0)
        self.a = (a1 / a0, a2 / a0)
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def __call__(self, x):
        b0, b1, b2 = self.b
        a1, a2 = self.a
        y = b0 * x + b1 * self.x1 + b2 * self.x2 - a1 * self.y1 - a2 * self.y2
        self.x2, self.x1, self.y2, self.y1 = self.x1, x, self.y1, y
        return y


def env_ad(n, attack, decay_tau):
    """Attack (samples) then exponential decay (seconds)."""
    out = []
    for i in range(n):
        if i < attack:
            out.append(math.sin(0.5 * math.pi * i / attack))
        else:
            out.append(math.exp(-(i - attack) / (SR * decay_tau)))
    return out


def bell(f, ms, tau, partials=((1, 1.0), (2.0, .32), (3.01, .12), (4.2, .05)),
         attack_ms=2.0):
    n = int(SR * ms / 1000)
    e = env_ad(n, int(SR * attack_ms / 1000), tau)
    out = []
    for i in range(n):
        t = i / SR
        s = 0.0
        for r, g in partials:
            # Higher partials die faster: softer, glassier tone.
            s += g * math.sin(2 * math.pi * f * r * t) * math.exp(-t * (r - 1) * 6)
        out.append(s * e[i])
    return out


def tick(f=2600, ms=28, gain=1.0):
    n = int(SR * ms / 1000)
    bp = Biquad('bp', f, 4.0)
    out = []
    for i in range(n):
        t = i / SR
        noise = bp(random.uniform(-1, 1)) * math.exp(-t / .0025) * 2.2
        tone = .35 * math.sin(2 * math.pi * f * .5 * t) * math.exp(-t / .006)
        out.append((noise + tone) * gain)
    return out


def thud(f0=150, f1=85, ms=150, gain=1.0):
    n = int(SR * ms / 1000)
    lp = Biquad('lp', 900, .8)
    out, ph = [], 0.0
    for i in range(n):
        t = i / SR
        f = f1 + (f0 - f1) * math.exp(-t / .025)
        ph += 2 * math.pi * f / SR
        body = math.sin(ph) * math.exp(-t / .045) * min(1, i / (SR * .0015))
        knock = lp(random.uniform(-1, 1)) * math.exp(-t / .006) * .9
        out.append((body + knock) * gain)
    return out


def noise_sweep(ms, f_from, f_to, q, shape, gain=1.0):
    """Band-passed noise whose centre glides; `shape(x)` is the envelope."""
    n = int(SR * ms / 1000)
    out = []
    bp = None
    for i in range(n):
        x = i / n
        if i % 64 == 0:
            f = f_from * (f_to / f_from) ** x
            nb = Biquad('bp', f, q)
            if bp is not None:
                nb.x1, nb.x2, nb.y1, nb.y2 = bp.x1, bp.x2, bp.y1, bp.y2
            bp = nb
        out.append(bp(random.uniform(-1, 1)) * shape(x) * gain)
    return out


def finish(samples, peak=.5, fade_ms=6):
    n = len(samples)
    f = int(SR * fade_ms / 1000)
    for i in range(min(f, n)):
        samples[i] *= i / f
        samples[n - 1 - i] *= i / f
    hp = Biquad('hp', 60, .7)
    samples = [hp(v) for v in samples]
    m = max(1e-9, max(abs(v) for v in samples))
    return [v * peak / m for v in samples]


def write(name, samples, peak=.5):
    samples = finish(samples, peak)
    with wave.open(f'{OUT}/{name}.wav', 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(
            struct.pack('<h', int(max(-1, min(1, v)) * 32767)) for v in samples))


# Easing identical to the painter.
def eio(x):  # easeInOutCubic
    return 4 * x ** 3 if x < .5 else 1 - (-2 * x + 2) ** 3 / 2


def eios(x):  # easeInOutSine
    return -(math.cos(math.pi * x) - 1) / 2


def solve(fn, target):
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if fn(mid) < target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def ms_of(t):
    return t * D


# ---------------------------------------------------------------- overview
# Tiles land at t = .26, .33, .40, .47  -> cue at .26, ticks every 154 ms.
s = buf(640)
for k in range(4):
    add(s, tick(2300 + 180 * k, 30), k * ms_of(.07), .9)
    add(s, bell(1320 + 110 * k, 120, .035, ((1, 1), (2.0, .2))), k * ms_of(.07), .28)
write('report_overview_tiles', s, .42)

# Ring sweeps from t=.50 (cue), ECG spike peaks at t=.6993 -> +438 ms.
spike = ms_of(.62 + .18 * ((155 - 118) / 84) - .50)
s = buf(820)
add(s, noise_sweep(430, 500, 3200, 1.6,
                   lambda x: math.sin(math.pi * x) ** 2), 0, .55)
add(s, bell(660, 420, .22, ((1, 1), (1.5, .35), (2, .2))), 40, .12)
add(s, thud(110, 62, 260), spike, 1.0)
add(s, bell(880, 300, .12, ((1, 1), (2, .25))), spike, .18)
write('report_overview_ring', s, .5)

# Settle at .80: bright two-note bell A5 -> E6.
s = buf(720)
add(s, bell(880, 700, .28), 0, .8)
add(s, bell(1318.5, 600, .26), 110, .7)
write('report_overview_settle', s, .5)

# ---------------------------------------------------------------- sales
# Paper L = 128 * seg(t, .05, .45) (linear), lines at u+4 from the edge.
speed = 128 / ms_of(.40)
s = buf(900)
hum_lp = Biquad('lp', 420, .7)
hum = [hum_lp(random.uniform(-1, 1)) * (1.0 + .25 * math.sin(2 * math.pi * 38 * i / SR))
       for i in range(int(SR * .88))]
for i in range(len(hum)):
    x = i / len(hum)
    hum[i] *= min(1, x / .06) * min(1, (1 - x) / .12)
add(s, hum, 0, .55)
for u in (18, 30, 44, 56, 68, 80, 104, 116):
    # A line becomes visible when it clears the printer lip (u + 6).
    add(s, tick(3100 if u != 18 else 2500, 26), (u + 6) / speed, .8)
write('report_sales_print', s, .38)

# Coins land on bars at .50, .56, .62, .68 -> clinks every 132 ms.
s = buf(760)
for k, f in enumerate((2093, 2349, 2637, 3136)):
    add(s, bell(f, 330, .07, ((1, 1), (1.47, .45), (2.09, .25), (2.56, .12)),
                attack_ms=.6), k * ms_of(.06), .7)
write('report_sales_coins', s, .45)

# Settle: soft register ding (C6 with a fifth shimmer).
s = buf(760)
add(s, bell(1046.5, 750, .3), 0, .8)
add(s, bell(1568, 600, .2), 12, .25)
write('report_sales_settle', s, .5)

# ---------------------------------------------------------------- money
# Handle angle -120 + 120 * eio(seg(t, .12, .42)): a detent every 15 deg.
s = buf(720)
for k in range(1, 9):
    x = solve(eio, k / 8)
    add(s, tick(1900 if k < 8 else 1500, 26), x * ms_of(.30), .55 if k < 8 else .9)
write('report_money_dial', s, .36)

# Coins arrive in the receiving account at .60, .67, .74 (cue .60).
s = buf(780)
for k, f in enumerate((1568, 1975.5, 2349)):
    add(s, bell(f, 380, .12, ((1, 1), (2.0, .3), (2.76, .1))), k * ms_of(.07), .7)
write('report_money_flow', s, .45)

# Settle: the vault locks (low click) + warm chime G5.
s = buf(780)
add(s, thud(240, 140, 90), 0, .6)
add(s, tick(1200, 30), 0, .7)
add(s, bell(784, 760, .32, ((1, 1), (2, .3), (3, .1))), 30, .8)
write('report_money_settle', s, .5)

# ---------------------------------------------------------------- inventory
# Box i lands at .26 + .055 i (cue .26): soft cardboard thuds.
s = buf(860)
for k in range(7):
    add(s, thud(165 - 6 * (k % 3), 92, 140), k * ms_of(.055), .75 + .05 * (k % 2))
write('report_inventory_boxes', s, .5)

# Scan y = 40 + 144 * eios(seg(t, .62, .80)); rows checked at y 61, 94, 157.
s = buf(620)
sweep_len = ms_of(.18)
n = int(SR * sweep_len / 1000)
ph = 0.0
tone = []
for i in range(n):
    x = i / n
    f = 900 + 500 * eios(x)
    ph += 2 * math.pi * f / SR
    tone.append(math.sin(ph) * math.sin(math.pi * x) ** 1.5)
add(s, tone, 0, .16)
for y in (61, 94, 157):
    x = solve(eios, (y - 40) / 144)
    add(s, bell(2637, 130, .03, ((1, 1), (2, .15))), x * sweep_len, .55)
write('report_inventory_scan', s, .42)

# Settle: two soft confirmation tones E6, A6.
s = buf(700)
add(s, bell(1318.5, 380, .14, ((1, 1), (2, .2))), 0, .7)
add(s, bell(1760, 560, .22, ((1, 1), (2, .2))), 120, .75)
write('report_inventory_settle', s, .5)

# ---------------------------------------------------------------- debts
# Book opens over [.02, .18] (cue .02): hushed whoosh, cover rests at .18.
s = buf(470)
add(s, noise_sweep(360, 300, 1200, 1.2, lambda x: math.sin(math.pi * x ** .7) ** 2), 0, .7)
add(s, thud(120, 80, 110), ms_of(.16), .3)
write('report_debts_open', s, .3)

# Page turns over [.20, .36] (cue .20): paper rustle peaking mid-turn.
s = buf(400)
add(s, noise_sweep(352, 2400, 5200, 1.1,
                   lambda x: (math.sin(math.pi * x) ** 2) * (.75 + .25 * math.sin(2 * math.pi * 9 * x))),
    0, 1.0)
add(s, tick(4200, 20), 330, .35)
write('report_debts_page', s, .32)

# Left weight lands .60, right weight .64 (cue .60), then a damped wobble
# theta = -A e^{-4 tau} cos(3 pi tau) (1 - tau^2) over [.64, .80].
s = buf(760)
add(s, thud(200, 120, 120), 0, .8)
add(s, thud(185, 115, 120), ms_of(.04), .8)
start = ms_of(.04)
n = int(SR * ms_of(.16) / 1000)
wob = []
for i in range(n):
    tau = i / n
    a = abs(math.exp(-4 * tau) * math.cos(3 * math.pi * tau) * (1 - tau * tau))
    wob.append(math.sin(2 * math.pi * 392 * i / SR) * a * min(1, i / 300))
add(s, wob, start, .22)
write('report_debts_scale', s, .45)

# Settle: balanced chord C5 + G5 + C6.
s = buf(780)
for f, g, at in ((523.25, .6, 0), (784, .5, 20), (1046.5, .45, 40)):
    add(s, bell(f, 740, .3, ((1, 1), (2, .22))), at, g)
write('report_debts_settle', s, .5)
print('ok')
