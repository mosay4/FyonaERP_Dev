"""Synthesizes the product / barcode / invoice cues (22.05 kHz mono 16-bit).

Original FYONA sounds (license-free), pure stdlib (wave + math):
- product_select.wav   calm soft «tock» for picking a product (~150 ms)
- product_alert.wav    gentle two-step descending alert: out of stock,
                       insufficient quantity, unknown code (~320 ms)
- barcode_capture.wav  clean rounded scanner beep on a decode (~140 ms)
- invoice_done.wav     short bright bell arpeggio for a created invoice
                       (~520 ms), synced to the success motion.
Usage: python3 tools/product_sounds.py assets/audio
"""
import math
import struct
import sys
import wave

SR = 22050
OUT = sys.argv[1] if len(sys.argv) > 1 else 'assets/audio'


def buf(ms):
    return [0.0] * int(SR * ms / 1000.0)


def add(dst, src, at_ms, gain=1.0):
    o = int(SR * at_ms / 1000.0)
    for i, v in enumerate(src):
        j = o + i
        if 0 <= j < len(dst):
            dst[j] += v * gain


def tone(freq, ms, attack_ms=4.0, tau=0.06, partials=((1.0, 1.0),),
         glide=0.0):
    """Sine partials with a smooth attack and exponential decay.

    partials: (ratio, gain). glide: relative pitch change over the note.
    """
    n = int(SR * ms / 1000.0)
    a = max(1, int(SR * attack_ms / 1000.0))
    out = []
    phases = [0.0] * len(partials)
    for i in range(n):
        t = i / SR
        f = freq * (1.0 + glide * (i / n))
        v = 0.0
        for k, (r, g) in enumerate(partials):
            phases[k] += 2 * math.pi * f * r / SR
            v += g * math.sin(phases[k])
        if i < a:
            e = 0.5 - 0.5 * math.cos(math.pi * i / a)
        else:
            e = math.exp(-(t - a / SR) / tau)
        # 6 ms raised-cosine tail → never a click at the end
        tail = n - i
        rel = int(SR * 0.006)
        if tail < rel:
            e *= tail / rel
        out.append(v * e)
    return out


def lowpass(x, f):
    w = 2 * math.pi * f / SR
    alpha = w / (w + 1)
    y, prev = [], 0.0
    for v in x:
        prev += alpha * (v - prev)
        y.append(prev)
    return y


def write(name, x, peak=0.55):
    m = max(1e-9, max(abs(v) for v in x))
    k = peak / m
    with wave.open(f'{OUT}/{name}', 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(
            struct.pack('<h', int(max(-1.0, min(1.0, v * k)) * 32767))
            for v in x))


def product_select():
    # Soft marimba-like tock: warm fundamental + faint woody overtone.
    x = buf(160)
    add(x, tone(784, 150, attack_ms=2.5, tau=0.045,
                partials=((1.0, 1.0), (3.98, 0.12), (2.0, 0.18))), 0)
    add(x, tone(1175, 110, attack_ms=3.0, tau=0.03), 18, 0.25)
    write('product_select.wav', lowpass(x, 3800), peak=0.45)


def product_alert():
    # Two rounded descending notes (A4 → F4), soft but unmistakable.
    x = buf(330)
    p = ((1.0, 1.0), (2.0, 0.22), (3.0, 0.08))
    add(x, tone(440, 150, attack_ms=6, tau=0.07, partials=p), 0)
    add(x, tone(349, 190, attack_ms=6, tau=0.09, partials=p), 140)
    write('product_alert.wav', lowpass(x, 2600), peak=0.6)


def barcode_capture():
    # Rounded scanner beep: steady sine with gentle edges, a hint of shimmer.
    n_ms = 140
    n = int(SR * n_ms / 1000.0)
    x = []
    ph = ph2 = 0.0
    for i in range(n):
        ph += 2 * math.pi * 1760 / SR
        ph2 += 2 * math.pi * 3520 / SR
        v = math.sin(ph) + 0.1 * math.sin(ph2)
        a = int(SR * 0.008)
        r = int(SR * 0.045)
        if i < a:
            e = 0.5 - 0.5 * math.cos(math.pi * i / a)
        elif i > n - r:
            e = 0.5 - 0.5 * math.cos(math.pi * (n - i) / r)
        else:
            e = 1.0
        x.append(v * e)
    write('barcode_capture.wav', lowpass(x, 5000), peak=0.42)


def invoice_done():
    # Bright rising bell arpeggio C6-E6-G6 + soft C7 sparkle.
    x = buf(540)
    bell = ((1.0, 1.0), (2.76, 0.16), (5.4, 0.05))
    add(x, tone(1047, 300, attack_ms=3, tau=0.12, partials=bell), 0, 0.8)
    add(x, tone(1319, 300, attack_ms=3, tau=0.12, partials=bell), 80, 0.8)
    add(x, tone(1568, 420, attack_ms=3, tau=0.16, partials=bell), 160, 0.9)
    add(x, tone(2093, 300, attack_ms=5, tau=0.12), 250, 0.25)
    write('invoice_done.wav', lowpass(x, 6000), peak=0.5)


if __name__ == '__main__':
    product_select()
    product_alert()
    barcode_capture()
    invoice_done()
