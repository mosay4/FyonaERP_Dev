"""Synthesizes the Personal report cues (22.05 kHz, mono, 16-bit WAV).

Same synth as tools/report_scene_sounds.py (imported from it), keyed to
the Personal scene in lib/features/reports/presentation/widgets/
report_scenes.dart (D = 2200 ms):
  * report_personal_wallet.wav — cue at t=.04: the wallet flap opens
    (.08 → .18) and three coins land in it at t = .24, .31, .38.
  * report_personal_export.wav — played when the Personal report PDF is
    ready: a sheet slides out, then a soft two-note confirmation.
The ring (.50) and settle (.80) cues reuse the overview files, because the
Personal scene draws its ring on the same keyframes.
Usage: python3 tools/personal_report_sounds.py assets/audio
"""
import importlib.util
import math
import os
import sys

OUT = sys.argv[1]
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'report_scene_synth', os.path.join(_here, 'report_scene_sounds.py'))
# The shared synth writes its own files on import; point it at a scratch
# directory so only the two Personal cues are written to OUT.
_scratch = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'fyona_report_synth')
os.makedirs(_scratch, exist_ok=True)
_argv = sys.argv
sys.argv = [_argv[0], _scratch]
synth = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(synth)
sys.argv = _argv
synth.OUT = OUT
synth.random.seed(11)

buf, add, bell, tick, thud, noise_sweep, write, ms_of = (
    synth.buf, synth.add, synth.bell, synth.tick, synth.thud,
    synth.noise_sweep, synth.write, synth.ms_of)

CUE = .04  # where the wallet file starts on the timeline

# ---------------------------------------------------------------- wallet
s = buf(960)
# Flap opens over [.08, .18]: a hushed leather swish, a soft click at rest.
add(s, noise_sweep(ms_of(.10), 700, 1900, 1.3,
                   lambda x: math.sin(math.pi * x) ** 2), ms_of(.08 - CUE), .55)
add(s, tick(1700, 24), ms_of(.18 - CUE), .5)
add(s, thud(150, 95, 90), ms_of(.18 - CUE), .25)
# Coins land at .24, .31, .38: bright clinks rising a step each.
for k, f in enumerate((1760, 2093, 2637)):
    at = ms_of(.24 + .07 * k - CUE)
    add(s, bell(f, 300, .07, ((1, 1), (1.47, .4), (2.09, .22), (2.56, .1)),
                attack_ms=.6), at, .7)
    add(s, thud(210, 130, 60), at, .18)
write('report_personal_wallet', s, .42)

# ---------------------------------------------------------------- export
s = buf(820)
add(s, noise_sweep(240, 1800, 4200, 1.1,
                   lambda x: math.sin(math.pi * x ** .8) ** 2), 0, .5)
add(s, tick(3000, 22), 230, .35)
add(s, bell(1318.5, 420, .16, ((1, 1), (2, .22))), 250, .62)
add(s, bell(1975.5, 520, .2, ((1, 1), (2, .2))), 360, .58)
write('report_personal_export', s, .45)
print('ok')
